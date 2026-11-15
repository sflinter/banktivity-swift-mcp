// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Base repository providing Core Data context access and common helpers
open class BaseRepository: @unchecked Sendable {
    public let container: NSPersistentContainer
    public let reportingCurrency: String

    public init(container: NSPersistentContainer, reportingCurrency: String = ReportingCurrency.defaultCode) {
        self.container = container
        self.reportingCurrency = ReportingCurrency.resolve(reportingCurrency)
    }

    /// Construct the Core Data object URI for a given store, entity, and PK.
    /// Format: x-coredata://<storeUUID>/<entityName>/p<pk>
    public func objectURI(store: NSPersistentStore, entityName: String, pk: Int) -> URL {
        var components = URLComponents()
        components.scheme = "x-coredata"
        components.host = store.identifier
        components.path = "/\(entityName)/p\(pk)"
        return components.url!
    }

    /// Count entities matching a predicate
    public func count(entityName: String, predicate: NSPredicate? = nil) throws -> Int {
        nonisolated(unsafe) let pred = predicate
        return try performRead { ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = pred
            return try ctx.count(for: request)
        }
    }

    /// Perform a read on a fresh background context, returning a Sendable value.
    /// Use this for all reads to avoid Core Data threading violations when called
    /// from Swift concurrency cooperative threads.
    ///
    /// A fresh context reads what is saved in the store. The view context only
    /// catches up with background saves when the main queue runs its merge, so
    /// reading through it could return stale objects right after a write.
    public func performRead<T: Sendable>(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> T) throws -> T {
        try perform(on: container.newBackgroundContext(), save: false, block)
    }

    /// Perform work on a background context and save.
    ///
    /// The viewContext is configured with `automaticallyMergesChangesFromParent = true`,
    /// but the merge happens asynchronously on the main run loop — which doesn't run
    /// in this CLI/MCP-server process. Subsequent reads through `performRead` therefore
    /// re-fetch from the persistent store rather than relying on cached objects in the
    /// viewContext, which is why every read path here goes through `fetchByPK` or a
    /// fresh `NSFetchRequest`. Don't cache `NSManagedObject` instances across calls.
    public func performWrite(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> Void) throws {
        _ = try perform(on: container.newBackgroundContext(), save: true) { ctx in
            try block(ctx)
        }
    }

    /// Perform a write that returns a value. See `performWrite` for context lifecycle notes.
    public func performWriteReturning<T: Sendable>(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> T) throws -> T {
        try perform(on: container.newBackgroundContext(), save: true, block)
    }

    /// Run `block` on `ctx`'s queue via performAndWait, optionally saving on success,
    /// and propagate the result or error back to the caller's thread.
    private func perform<T: Sendable>(
        on ctx: NSManagedObjectContext,
        save: Bool,
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) throws -> T {
        if save {
            return try CoreDataWriteCoordinator.perform {
                try performOnContext(on: ctx, save: save, block)
            }
        }
        return try performOnContext(on: ctx, save: save, block)
    }

    private func performOnContext<T: Sendable>(
        on ctx: NSManagedObjectContext,
        save: Bool,
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) throws -> T {
        nonisolated(unsafe) var outcome: Result<T, Error>!
        ctx.performAndWait {
            outcome = Result {
                let value = try block(ctx)
                if save && ctx.hasChanges {
                    // Mark the synced records that own any changed rows as modified,
                    // which is what makes Banktivity upload them.
                    try Self.markOwnersModified(in: ctx)
                    // Keep the desktop's cached running balances (its account cash) current.
                    let stale = Self.accountsNeedingRunningBalance(in: ctx)
                    try ctx.save()
                    if !stale.isEmpty {
                        for (id, from) in stale {
                            if let account = try? ctx.existingObject(with: id), !account.isDeleted {
                                _ = try Self.recalculateRunningBalances(account: account, force: true, from: from, in: ctx)
                            }
                        }
                        if ctx.hasChanges { try ctx.save() }
                    }
                }
                return value
            }
        }
        return try outcome.get()
    }

    /// Create a new managed object in the given context
    public static func createObject(entityName: String, in context: NSManagedObjectContext) -> NSManagedObject {
        NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
    }

    /// Generate a UUID string for new entities
    public static func generateUUID() -> String {
        UUID().uuidString
    }

    /// Set a date value (as Foundation Date) on a managed object
    public static func setDate(_ object: NSManagedObject, _ key: String, isoString: String?) {
        // Date-only labels are anchored, never host-local: see DateConversion.dateOnlyTimeZone.
        // Full ISO timestamps (creation/modification audit stamps) are unaffected --
        // fromISO only applies the zone to the 10-character date-only branch.
        guard let iso = isoString,
              let ts = DateConversion.fromDateOnly(iso) else { return }
        object.setValue(DateConversion.toDate(ts), forKey: key)
    }

    /// Set current timestamp on a managed object
    public static func setNow(_ object: NSManagedObject, _ key: String) {
        object.setValue(Date(), forKey: key)
    }

    /// Transactions with a line item on this account. An unknown ID throws rather than
    /// matching nothing: an empty answer would say the account has no such rows when the
    /// question itself was wrong.
    func accountPredicate(accountId: Int, in ctx: NSManagedObjectContext) throws -> NSPredicate {
        guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
            throw ToolError.notFound("Account not found: \(accountId)")
        }
        return NSPredicate(format: "ANY lineItems.pAccount == %@", account)
    }

    /// Fetch an object by PK in a specific context (for write operations on background contexts)
    public func fetchByPK(entityName: String, pk: Int, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        let coordinator = container.persistentStoreCoordinator
        guard let store = coordinator.persistentStores.first,
              let entity = container.managedObjectModel.entitiesByName[entityName]
        else { return nil }

        var entityNames = [entity.name!]
        func collectSubentities(_ e: NSEntityDescription) {
            for sub in e.subentities {
                if let name = sub.name { entityNames.append(name) }
                collectSubentities(sub)
            }
        }
        collectSubentities(entity)

        for name in entityNames {
            let uri = objectURI(store: store, entityName: name, pk: pk)
            guard let objectID = coordinator.managedObjectID(forURIRepresentation: uri) else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.predicate = NSPredicate(format: "SELF == %@", objectID)
            request.fetchLimit = 1
            if let obj = try? ctx.fetch(request).first { return obj }
        }
        return nil
    }

    // MARK: - KVC Helpers

    /// Safely get a string value from a managed object
    public static func string(_ object: NSManagedObject, _ key: String) -> String? {
        object.value(forKey: key) as? String
    }

    /// Safely get a string value with a default
    public static func stringValue(_ object: NSManagedObject, _ key: String, default defaultValue: String = "") -> String {
        (object.value(forKey: key) as? String) ?? defaultValue
    }

    /// Safely get an integer value from a managed object
    public static func intValue(_ object: NSManagedObject, _ key: String) -> Int {
        (object.value(forKey: key) as? Int) ?? 0
    }

    /// Safely get an optional integer value
    public static func optionalInt(_ object: NSManagedObject, _ key: String) -> Int? {
        object.value(forKey: key) as? Int
    }

    /// Safely get a double value from a managed object
    public static func doubleValue(_ object: NSManagedObject, _ key: String) -> Double {
        if let decimal = object.value(forKey: key) as? NSDecimalNumber {
            return decimal.doubleValue
        }
        return (object.value(forKey: key) as? Double) ?? 0.0
    }

    /// Read a decimal attribute without going through `Double`, for sums.
    public static func decimalValue(_ object: NSManagedObject, _ key: String) -> Decimal {
        if let decimal = object.value(forKey: key) as? NSDecimalNumber {
            return decimal.decimalValue
        }
        if let double = object.value(forKey: key) as? Double {
            return Decimal(string: String(double)) ?? 0
        }
        return 0
    }

    /// The line item's exchange rate, with a missing or zero rate read as 1.
    ///
    /// `pTransactionAmount * pExchangeRate` is the account-currency amount. A
    /// line with no rate, or a stored 0, would otherwise drop out of a
    /// balance. Banktivity writes 1 for a same-currency line, so 1 is the
    /// neutral reading (as in #27 and #19).
    public static func effectiveExchangeRate(_ lineItem: NSManagedObject) -> Double {
        let rate = doubleValue(lineItem, "pExchangeRate")
        return rate == 0 ? 1.0 : rate
    }

    // MARK: - Running balances

    public struct RunningBalanceRecalc: Sendable {
        public let lineItemCount: Int
        public let changedCount: Int
        public let previousBalance: Double
        public let balance: Double
        public let wasStale: Bool
    }

    /// See `AccountRepository.recalculateRunningBalances(accountId:force:)`.
    /// With `from` (a transaction date), only lines on or after it are
    /// recomputed, continuing from the stored running balance of the last line
    /// before it, as Banktivity's `recalculateBalanceForDate:` does.
    public static func recalculateRunningBalances(account: NSManagedObject, force: Bool, from: Double? = nil, in ctx: NSManagedObjectContext) throws -> RunningBalanceRecalc {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = NSPredicate(format: "pAccount == %@", account)
        request.relationshipKeyPathsForPrefetching = ["pSecurityLineItem", "pTransaction.pTransactionType"]
        let lines = try ctx.fetch(request)

        func cents(_ value: Double) -> Decimal { Decimal(string: String(format: "%.2f", value)) ?? 0 }
        let amounts = Dictionary(uniqueKeysWithValues: lines.map { ($0.objectID, cents(Self.accountAmount($0))) })
        let date = { (li: NSManagedObject) in Self.relatedObject(li, "pTransaction").flatMap { Self.dateValue($0, "pDate") } ?? 0 }
        let created = { (li: NSManagedObject) in Self.dateValue(li, "pCreationTime") ?? 0 }
        let pk = { (li: NSManagedObject) in Self.extractPK(from: li.objectID) }
        let intraday = { (li: NSManagedObject) in Self.intValue(li, "pIntraDaySortIndex") }
        let byCreation = lines.sorted {
            (date($0), created($0), intraday($0), pk($0)) < (date($1), created($1), intraday($1), pk($1))
        }
        let byRow = lines.sorted { (date($0), intraday($0), pk($0)) < (date($1), intraday($1), pk($1)) }

        func balances(_ ordered: [NSManagedObject]) -> [Decimal] {
            var running = Decimal(0)
            if let from, let before = ordered.last(where: { date($0) < from }) {
                running = decimalValue(before, "pRunningBalance")
            }
            return ordered.map {
                if let from, date($0) < from { return decimalValue($0, "pRunningBalance") }
                running += amounts[$0.objectID] ?? 0
                return running
            }
        }
        func matches(_ ordered: [NSManagedObject], _ values: [Decimal]) -> Int {
            zip(ordered, values).filter { Self.decimalValue($0.0, "pRunningBalance") == $0.1 }.count
        }
        let creationValues = balances(byCreation), rowValues = balances(byRow)
        let (ordered, values) = matches(byCreation, creationValues) >= matches(byRow, rowValues)
            ? (byCreation, creationValues) : (byRow, rowValues)

        let total = values.last ?? 0
        // Banktivity's last row (in either order) already holds the total: not stale.
        let lastDate = ordered.last.map(date)
        let finalIsRight = lines.isEmpty || ordered.contains {
            date($0) == lastDate && Self.decimalValue($0, "pRunningBalance") == total
        }
        let previous = byRow.last.map { Self.doubleValue($0, "pRunningBalance") } ?? 0

        var changed = 0
        if force || !finalIsRight {
            for (line, value) in zip(ordered, values) where Self.decimalValue(line, "pRunningBalance") != value {
                line.setValue(NSDecimalNumber(decimal: value), forKey: "pRunningBalance")
                changed += 1
            }
        }
        return RunningBalanceRecalc(
            lineItemCount: lines.count, changedCount: changed, previousBalance: previous,
            balance: NSDecimalNumber(decimal: total).doubleValue, wasStale: !finalIsRight)
    }

    /// Banktivity uploads a record when its `pModificationDate` is after the
    /// last sync (`+[IGGCAccountingSyncedDocument enitities:modifiedAfterDate:]`).
    /// Line items, security lines and prices have no sync record of their own:
    /// they travel inside their Transaction or Security. So any real change to
    /// them marks the owner modified. A change to the cached `pRunningBalance`
    /// alone does not, so recalculation never triggers uploads.
    static func markOwnersModified(in ctx: NSManagedObjectContext) throws {
        var transactions = Set<NSManagedObject>()
        var securityIDs = Set<String>()
        func addTx(_ tx: Any?) {
            if let tx = tx as? NSManagedObject, !tx.isDeleted { transactions.insert(tx) }
        }
        func addLine(_ li: NSManagedObject) {
            addTx(li.value(forKey: "pTransaction"))
            addTx(li.committedValues(forKeys: ["pTransaction"])["pTransaction"])
        }
        for object in ctx.insertedObjects.union(ctx.updatedObjects).union(ctx.deletedObjects) {
            let changed = Set(object.changedValues().keys).subtracting(["pRunningBalance"])
            guard object.isInserted || object.isDeleted || !changed.isEmpty else { continue }
            switch object.entity.name {
            case "LineItem":
                addLine(object)
            case "SecurityLineItem":
                let li = object.value(forKey: "pLineItem") ?? object.committedValues(forKeys: ["pLineItem"])["pLineItem"]
                if let li = li as? NSManagedObject { addLine(li) }
            case "SecurityPrice":
                let item = object.value(forKey: "pSecurityPriceItem") ?? object.committedValues(forKeys: ["pSecurityPriceItem"])["pSecurityPriceItem"]
                if let item = item as? NSManagedObject { securityIDs.insert(stringValue(item, "pSecurityID")) }
            default:
                break
            }
        }
        for tx in transactions where !tx.isInserted {
            setNow(tx, "pModificationDate")
        }
        if !securityIDs.isEmpty {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Security")
            request.predicate = NSPredicate(format: "pUniqueID IN %@", Array(securityIDs))
            for security in try ctx.fetch(request) { setNow(security, "pModificationDate") }
        }
    }

    /// Real (non-category) accounts whose cached running balances a pending
    /// save will make stale: line amounts, rates, accounts or transactions
    /// changed, security amounts changed, or a transaction's date or type
    /// changed. Changes to `pRunningBalance` alone don't count.
    static func accountsNeedingRunningBalance(in ctx: NSManagedObjectContext) -> [NSManagedObjectID: Double] {
        // Account -> earliest affected transaction date.
        var accounts: [NSManagedObjectID: Double] = [:]
        func add(_ account: Any?, _ date: Double) {
            guard let account = account as? NSManagedObject,
                  intValue(account, "pAccountClass") < AccountClass.income else { return }
            accounts[account.objectID] = min(accounts[account.objectID] ?? date, date)
        }
        func txDate(_ tx: Any?) -> Double {
            guard let tx = tx as? NSManagedObject else { return 0 }
            let now = dateValue(tx, "pDate") ?? 0
            let then = (tx.committedValues(forKeys: ["pDate"])["pDate"] as? Date).map { DateConversion.fromDate($0) } ?? now
            return min(now, then)
        }
        func lineAccounts(_ li: NSManagedObject) {
            let tx = li.value(forKey: "pTransaction") ?? li.committedValues(forKeys: ["pTransaction"])["pTransaction"]
            let date = txDate(tx)
            add(li.value(forKey: "pAccount"), date)
            add(li.committedValues(forKeys: ["pAccount"])["pAccount"], date)
        }
        let lineKeys: Set<String> = ["pTransactionAmount", "pExchangeRate", "pAccount", "pTransaction", "pSecurityLineItem"]
        let securityKeys: Set<String> = ["pAmount", "pIncome", "pDistributionType", "pLineItem"]
        let transactionKeys: Set<String> = ["pDate", "pTransactionType"]
        for object in ctx.insertedObjects.union(ctx.updatedObjects).union(ctx.deletedObjects) {
            let changed = Set(object.changedValues().keys)
            let whole = object.isInserted || object.isDeleted
            switch object.entity.name {
            case "LineItem" where whole || !changed.isDisjoint(with: lineKeys):
                lineAccounts(object)
            case "SecurityLineItem" where whole || !changed.isDisjoint(with: securityKeys):
                if let li = (object.value(forKey: "pLineItem") ?? object.committedValues(forKeys: ["pLineItem"])["pLineItem"]) as? NSManagedObject {
                    lineAccounts(li)
                }
            case "Transaction" where !changed.isDisjoint(with: transactionKeys):
                // Transaction -> lines is `lineItems` (no p prefix) in Banktivity's model.
                for li in relatedSet(object, "lineItems") { lineAccounts(li) }
            default:
                break
            }
        }
        return accounts
    }

    /// A line item's amount in its account's currency, as Banktivity computes it
    /// for balances and statement totals (`-[IGGCAccountingLineItem accountAmount]`
    /// in IGGAccounting).
    ///
    /// For an investment transaction (base type 100-310) with a security line,
    /// Banktivity ignores `pTransactionAmount` and takes the security line's
    /// figure: `pAmount` (0 for share moves, 210-212) plus `pIncome`, counted
    /// only when the distribution type resolves to cash (1). An unset or 0
    /// distribution type is cash, except for share adjustments (210-212, 250).
    /// Types 2 and 3 (transfer, reinvest) count as non-cash here; Banktivity
    /// falls back to cash when the transaction type cannot transfer or reinvest,
    /// which this does not model. Every other line is amount x exchange rate.
    public static func accountAmount(_ lineItem: NSManagedObject) -> Double {
        let baseType = relatedObject(lineItem, "pTransaction")
            .flatMap { relatedObject($0, "pTransactionType") }
            .map { intValue($0, "pBaseType") }
        if let baseType, (100...310).contains(baseType),
           let sli = relatedObject(lineItem, "pSecurityLineItem") {
            let raw = intValue(sli, "pDistributionType")
            let distribution = raw == 0 ? (shareAdjustmentBaseTypes.contains(baseType) ? 0 : 1) : raw
            guard distribution == 1 else { return 0 }
            let amount = (210...212).contains(baseType) ? 0 : doubleValue(sli, "pAmount")
            return amount + doubleValue(sli, "pIncome")
        }
        return doubleValue(lineItem, "pTransactionAmount") * effectiveExchangeRate(lineItem)
    }

    /// Move Shares In / Out, Transfer Shares, Split Shares: they move shares, not cash.
    public static let shareAdjustmentBaseTypes: Set<Int> = [210, 211, 212, 250]

    /// Safely get a boolean value from a managed object
    public static func boolValue(_ object: NSManagedObject, _ key: String) -> Bool {
        (object.value(forKey: key) as? Bool) ?? false
    }

    /// Safely get a date value (as Core Data timestamp) from a managed object
    public static func dateValue(_ object: NSManagedObject, _ key: String) -> Double? {
        if let date = object.value(forKey: key) as? Date {
            return date.timeIntervalSinceReferenceDate
        }
        return nil
    }

    /// Get the currency code from an object that may have a currency relationship
    public static func currencyCode(_ object: NSManagedObject) -> String? {
        // PrimaryAccount has "currency" relationship, Account (categories) does not
        if object.entity.relationshipsByName["currency"] != nil,
           let currency = object.value(forKey: "currency") as? NSManagedObject
        {
            return currency.value(forKey: "pCode") as? String
        }
        return nil
    }

    /// Get a to-one related object
    public static func relatedObject(_ object: NSManagedObject, _ key: String) -> NSManagedObject? {
        guard object.entity.relationshipsByName[key] != nil else { return nil }
        return object.value(forKey: key) as? NSManagedObject
    }

    /// Extract the Z_PK (primary key) from a Core Data objectID.
    /// The URI format is: x-coredata://<storeID>/<entity>/p<pk>
    public static func extractPK(from objectID: NSManagedObjectID) -> Int {
        let uri = objectID.uriRepresentation()
        let lastComponent = uri.lastPathComponent  // "p123"
        if lastComponent.hasPrefix("p"), let pk = Int(lastComponent.dropFirst()) {
            return pk
        }
        return 0
    }

    /// Get a to-many related object set
    public static func relatedSet(_ object: NSManagedObject, _ key: String) -> Set<NSManagedObject> {
        guard object.entity.relationshipsByName[key] != nil else { return [] }
        if let set = object.value(forKey: key) as? Set<NSManagedObject> {
            return set
        }
        if let nsSet = object.value(forKey: key) as? NSSet {
            return nsSet as! Set<NSManagedObject>
        }
        return []
    }
}
