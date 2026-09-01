// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("StatementRepository")
struct StatementRepositoryTests {

    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault,
        accounts: AccountRepository,
        transactions: TransactionRepository,
        statements: StatementRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)
        let statements = StatementRepository(container: vault.container, lineItemRepo: lineItems)

        return (vault, accounts, transactions, statements)
    }

    private func createCreditCard(named name: String, using accounts: AccountRepository) throws -> AccountDTO {
        try accounts.create(name: name, accountClass: AccountClass.creditCard, currencyCode: "USD")
    }

    private func createCheckingAccount(named name: String, using accounts: AccountRepository) throws -> AccountDTO {
        try accounts.create(name: name, accountClass: AccountClass.checking, currencyCode: "EUR")
    }

    private func createInvestmentAccount(named name: String, using accounts: AccountRepository) throws -> AccountDTO {
        try accounts.create(name: name, accountClass: AccountClass.investment, currencyCode: "USD")
    }

    private func accountLineItemId(in transaction: TransactionDTO, accountId: Int) throws -> Int {
        try #require(transaction.lineItems.first { $0.accountId == accountId }?.id)
    }

    @Test("Explicit reconciliation allows manually selected pre-start line items")
    func reconcileAllowsManualPreStartLineItems() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Synthetic Statement Account", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-03-26",
            title: "Sample Merchant",
            lineItems: [(accountId: card.id, amount: -10.0, memo: nil)]
        )
        let lineItemId = try accountLineItemId(in: transaction, accountId: card.id)

        let statement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-03-29",
            endDate: "2026-04-28",
            beginningBalance: 0,
            endingBalance: -10.0,
            name: "April statement"
        )

        let result = try repos.statements.reconcileLineItems(
            statementId: statement.id,
            lineItemIds: [lineItemId]
        )

        #expect(result.reconciledLineItemCount == 1)
        #expect(abs(result.reconciledBalance - -10.0) < 0.005)
        #expect(result.isBalanced)
    }

    @Test("Explicit reconciliation accepts line items on visible statement end date")
    func reconcileAllowsVisibleEndDateLineItems() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Visible End Date Card", using: repos.accounts)
        let base = BaseRepository(container: repos.vault.container)
        let lineItemId: Int = try base.performWriteReturning { ctx in
            guard let accountObject = try base.fetchByPK(entityName: "Account", pk: card.id, in: ctx) else {
                throw ToolError.notFound("Account not found: \(card.id)")
            }

            let transaction = BaseRepository.createObject(entityName: "Transaction", in: ctx)
            transaction.setValue("End-date charge", forKey: "pTitle")
            transaction.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            transaction.setValue(false, forKey: "pCleared")
            transaction.setValue(false, forKey: "pVoid")
            transaction.setValue(false, forKey: "pAdjustment")
            transaction.setValue(BaseRepository.relatedObject(accountObject, "currency"), forKey: "pCurrency")
            BaseRepository.setNow(transaction, "pCreationTime")
            BaseRepository.setNow(transaction, "pModificationDate")
            let endDateTs = try #require(DateConversion.fromISO("2026-04-28"))
            transaction.setValue(DateConversion.toDate(endDateTs + 3600), forKey: "pDate")

            let lineItem = BaseRepository.createObject(entityName: "LineItem", in: ctx)
            lineItem.setValue(-25.0 as NSNumber, forKey: "pTransactionAmount")
            lineItem.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            lineItem.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            lineItem.setValue(false, forKey: "pCleared")
            lineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            BaseRepository.setNow(lineItem, "pCreationTime")
            lineItem.setValue(accountObject, forKey: "pAccount")
            lineItem.setValue(transaction, forKey: "pTransaction")
            try ctx.obtainPermanentIDs(for: [lineItem])
            return BaseRepository.extractPK(from: lineItem.objectID)
        }

        let statement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-03-29",
            endDate: "2026-04-28",
            beginningBalance: 0,
            endingBalance: -25.0,
            name: "April statement"
        )

        let result = try repos.statements.reconcileLineItems(
            statementId: statement.id,
            lineItemIds: [lineItemId]
        )

        #expect(result.reconciledLineItemCount == 1)
        #expect(abs(result.reconciledBalance - -25.0) < 0.005)
        #expect(result.isBalanced)
    }

    @Test("Statement balances use account-currency line item amounts")
    func statementBalancesUseAccountCurrencyLineItemAmounts() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try createCheckingAccount(named: "Multi Currency Checking", using: repos.accounts)
        let base = BaseRepository(container: repos.vault.container)
        let lineItemId: Int = try base.performWriteReturning { ctx in
            guard let accountObject = try base.fetchByPK(entityName: "Account", pk: checking.id, in: ctx) else {
                throw ToolError.notFound("Account not found: \(checking.id)")
            }

            let transaction = BaseRepository.createObject(entityName: "Transaction", in: ctx)
            transaction.setValue("Converted deposit", forKey: "pTitle")
            transaction.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            transaction.setValue(false, forKey: "pCleared")
            transaction.setValue(false, forKey: "pVoid")
            transaction.setValue(false, forKey: "pAdjustment")
            transaction.setValue(BaseRepository.relatedObject(accountObject, "currency"), forKey: "pCurrency")
            BaseRepository.setNow(transaction, "pCreationTime")
            BaseRepository.setNow(transaction, "pModificationDate")
            let transactionDateTs = try #require(DateConversion.fromISO("2026-04-10"))
            transaction.setValue(DateConversion.toDate(transactionDateTs), forKey: "pDate")

            let lineItem = BaseRepository.createObject(entityName: "LineItem", in: ctx)
            lineItem.setValue(100.0 as NSNumber, forKey: "pTransactionAmount")
            lineItem.setValue(1.5 as NSNumber, forKey: "pExchangeRate")
            lineItem.setValue(150.0 as NSNumber, forKey: "pRunningBalance")
            lineItem.setValue(false, forKey: "pCleared")
            lineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            BaseRepository.setNow(lineItem, "pCreationTime")
            lineItem.setValue(accountObject, forKey: "pAccount")
            lineItem.setValue(transaction, forKey: "pTransaction")
            try ctx.obtainPermanentIDs(for: [lineItem])
            return BaseRepository.extractPK(from: lineItem.objectID)
        }

        let statement = try repos.statements.create(
            accountId: checking.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: 150.0,
            name: "April checking statement"
        )

        _ = try repos.statements.reconcileLineItems(
            statementId: statement.id,
            lineItemIds: [lineItemId]
        )

        let result = try #require(try repos.statements.get(statementId: statement.id))
        let lineItem = try #require(result.lineItems.first)
        #expect(abs(lineItem.amount - 100.0) < 0.005)
        #expect(abs(result.reconciledBalance - 150.0) < 0.005)
        #expect(abs(result.difference) < 0.005)
        #expect(result.isBalanced)

        let summary = try #require(try repos.statements.list(accountId: checking.id).first { $0.id == statement.id })
        #expect(summary.isBalanced)
    }

    @Test("Investment statement advisory ignores zero-cash transfer-in basis amounts")
    func investmentStatementAdvisoryIgnoresZeroCashTransferInBasisAmounts() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let investment = try createInvestmentAccount(named: "Basis Transfer Brokerage", using: repos.accounts)
        let base = BaseRepository(container: repos.vault.container)
        let lineItemIds: [Int] = try base.performWriteReturning { ctx in
            guard let accountObject = try base.fetchByPK(entityName: "Account", pk: investment.id, in: ctx) else {
                throw ToolError.notFound("Account not found: \(investment.id)")
            }
            let currency = try #require(BaseRepository.relatedObject(accountObject, "currency"))

            let security = BaseRepository.createObject(entityName: "Security", in: ctx)
            security.setValue("RBLX", forKey: "pSymbol")
            security.setValue("Roblox Corp", forKey: "pName")
            security.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            security.setValue(currency, forKey: "pCurrency")
            security.setValue(false, forKey: "pExcludeFromQuoteUpdates")
            security.setValue(false, forKey: "pIsIndex")
            security.setValue(false, forKey: "pTradesInPence")
            security.setValue(Int16(0), forKey: "pType")
            security.setValue(Int16(0), forKey: "pRiskType")
            security.setValue(NSDecimalNumber.one, forKey: "pContractSize")
            security.setValue(NSDecimalNumber.zero, forKey: "pParValue")
            BaseRepository.setNow(security, "pCreationTime")
            BaseRepository.setNow(security, "pModificationDate")

            let transaction = BaseRepository.createObject(entityName: "Transaction", in: ctx)
            transaction.setValue("TRANSFER IN RBLX", forKey: "pTitle")
            transaction.setValue("SECURITY ADJUSTMENT", forKey: "pNote")
            transaction.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            transaction.setValue(false, forKey: "pCleared")
            transaction.setValue(false, forKey: "pVoid")
            transaction.setValue(false, forKey: "pAdjustment")
            transaction.setValue(currency, forKey: "pCurrency")
            BaseRepository.setDate(transaction, "pDate", isoString: "2026-04-10")
            BaseRepository.setNow(transaction, "pCreationTime")
            BaseRepository.setNow(transaction, "pModificationDate")

            let lineItem = BaseRepository.createObject(entityName: "LineItem", in: ctx)
            lineItem.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
            lineItem.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            lineItem.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            lineItem.setValue(false, forKey: "pCleared")
            lineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            BaseRepository.setNow(lineItem, "pCreationTime")
            lineItem.setValue(accountObject, forKey: "pAccount")
            lineItem.setValue(transaction, forKey: "pTransaction")

            let securityLineItem = BaseRepository.createObject(entityName: "SecurityLineItem", in: ctx)
            securityLineItem.setValue(security, forKey: "pSecurity")
            securityLineItem.setValue(lineItem, forKey: "pLineItem")
            securityLineItem.setValue(20.0 as NSNumber, forKey: "pShares")
            securityLineItem.setValue(-1986.59 as NSNumber, forKey: "pAmount")
            securityLineItem.setValue(99.3295 as NSNumber, forKey: "pPricePerShare")
            securityLineItem.setValue(0.0 as NSNumber, forKey: "pCommission")
            securityLineItem.setValue(0.0 as NSNumber, forKey: "pIncome")
            securityLineItem.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")

            let depositTransaction = BaseRepository.createObject(entityName: "Transaction", in: ctx)
            depositTransaction.setValue("Cash deposit", forKey: "pTitle")
            depositTransaction.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            depositTransaction.setValue(false, forKey: "pCleared")
            depositTransaction.setValue(false, forKey: "pVoid")
            depositTransaction.setValue(false, forKey: "pAdjustment")
            depositTransaction.setValue(currency, forKey: "pCurrency")
            BaseRepository.setDate(depositTransaction, "pDate", isoString: "2026-04-11")
            BaseRepository.setNow(depositTransaction, "pCreationTime")
            BaseRepository.setNow(depositTransaction, "pModificationDate")

            let depositLineItem = BaseRepository.createObject(entityName: "LineItem", in: ctx)
            depositLineItem.setValue(321.41 as NSNumber, forKey: "pTransactionAmount")
            depositLineItem.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            depositLineItem.setValue(321.41 as NSNumber, forKey: "pRunningBalance")
            depositLineItem.setValue(false, forKey: "pCleared")
            depositLineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            BaseRepository.setNow(depositLineItem, "pCreationTime")
            depositLineItem.setValue(accountObject, forKey: "pAccount")
            depositLineItem.setValue(depositTransaction, forKey: "pTransaction")

            let cashBearingTransaction = BaseRepository.createObject(entityName: "Transaction", in: ctx)
            cashBearingTransaction.setValue("Provider sweep repair offset", forKey: "pTitle")
            cashBearingTransaction.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            cashBearingTransaction.setValue(false, forKey: "pCleared")
            cashBearingTransaction.setValue(false, forKey: "pVoid")
            cashBearingTransaction.setValue(false, forKey: "pAdjustment")
            cashBearingTransaction.setValue(currency, forKey: "pCurrency")
            BaseRepository.setDate(cashBearingTransaction, "pDate", isoString: "2026-04-11")
            BaseRepository.setNow(cashBearingTransaction, "pCreationTime")
            BaseRepository.setNow(cashBearingTransaction, "pModificationDate")

            let cashBearingLineItem = BaseRepository.createObject(entityName: "LineItem", in: ctx)
            cashBearingLineItem.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
            cashBearingLineItem.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            cashBearingLineItem.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            cashBearingLineItem.setValue(false, forKey: "pCleared")
            cashBearingLineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            BaseRepository.setNow(cashBearingLineItem, "pCreationTime")
            cashBearingLineItem.setValue(accountObject, forKey: "pAccount")
            cashBearingLineItem.setValue(cashBearingTransaction, forKey: "pTransaction")

            let cashBearingSecurityLineItem = BaseRepository.createObject(entityName: "SecurityLineItem", in: ctx)
            cashBearingSecurityLineItem.setValue(security, forKey: "pSecurity")
            cashBearingSecurityLineItem.setValue(cashBearingLineItem, forKey: "pLineItem")
            cashBearingSecurityLineItem.setValue(0.0 as NSNumber, forKey: "pShares")
            cashBearingSecurityLineItem.setValue(-321.41 as NSNumber, forKey: "pAmount")
            cashBearingSecurityLineItem.setValue(0.0 as NSNumber, forKey: "pPricePerShare")
            cashBearingSecurityLineItem.setValue(0.0 as NSNumber, forKey: "pCommission")
            cashBearingSecurityLineItem.setValue(0.0 as NSNumber, forKey: "pIncome")
            cashBearingSecurityLineItem.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")

            try ctx.obtainPermanentIDs(for: [
                lineItem, securityLineItem, depositLineItem, cashBearingLineItem, cashBearingSecurityLineItem,
            ])
            return [
                BaseRepository.extractPK(from: lineItem.objectID),
                BaseRepository.extractPK(from: depositLineItem.objectID),
                BaseRepository.extractPK(from: cashBearingLineItem.objectID),
            ]
        }

        let statement = try repos.statements.create(
            accountId: investment.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: 0,
            name: "April investment statement"
        )

        let reconciled = try repos.statements.reconcileLineItems(
            statementId: statement.id,
            lineItemIds: lineItemIds
        )
        #expect(reconciled.cashLineBalanced)
        #expect(reconciled.isBalancedAdvisory)
        #expect(abs(reconciled.reconciledBalance) < 0.005)
        #expect(abs(reconciled.difference) < 0.005)

        let summary = try #require(try repos.statements.list(accountId: investment.id).first { $0.id == statement.id })
        #expect(summary.cashLineBalanced)
        #expect(summary.isBalancedAdvisory)
    }

    @Test("Statement JSON qualifies balance status instead of emitting raw isBalanced")
    func statementJSONUsesQualifiedBalanceFields() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try createCheckingAccount(named: "Qualified Balance Checking", using: repos.accounts)
        let statement = try repos.statements.create(
            accountId: checking.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: 0,
            name: "April checking statement"
        )

        let encoded = try JSONEncoder().encode(statement)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"cashLineBalanced\""))
        #expect(json.contains("\"isBalancedAdvisory\""))
        #expect(json.contains("\"uiVerificationRequired\""))
        #expect(!json.contains("\"isBalanced\""))
    }

    @Test("Investment statement reads require UI verification and warnings")
    func investmentStatementReadsEmitWarnings() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let investment = try createInvestmentAccount(named: "Advisory Brokerage", using: repos.accounts)
        let statement = try repos.statements.create(
            accountId: investment.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: 0,
            name: "April investment statement"
        )

        let result = try #require(try repos.statements.get(statementId: statement.id))
        #expect(result.accountClass == AccountClass.investment)
        #expect(result.uiVerificationRequired)
        #expect(result.cashLineBalanced)
        #expect(result.isBalancedAdvisory)
        #expect(result.rowKind == "visible_named_investment")
        #expect(result.isVisibleNamedRow)
        #expect(!result.isUnnamedInvestmentRow)
        #expect(!result.operatorConfirmedVisibleRequired)
        #expect(result.warnings.contains { $0.contains("UI verification is required") })

        let summary = try #require(try repos.statements.list(accountId: investment.id).first { $0.id == statement.id })
        #expect(summary.uiVerificationRequired)
        #expect(summary.rowKind == "visible_named_investment")
        #expect(summary.warnings.contains { $0.contains("advisory cash-line checks") })

        let accountWarnings = try repos.statements.warningsForStatementReads(accountId: investment.id)
        #expect(accountWarnings.count == 1)
    }

    @Test("Visible row correction plan uses only operator-entered UI values")
    func visibleRowCorrectionPlanUsesOperatorEnteredValues() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let plan = repos.statements.visibleRowCorrectionPlan(
            statementId: 735,
            uiStart: 100,
            uiEnd: 125,
            uiMissing: -5,
            correctedStart: 200
        )

        #expect(plan.inputSource == "operator_entered_ui_values")
        #expect(plan.uiCompatibleRowDelta == 30)
        #expect(plan.correctedEndingBalance == 230)
        #expect(plan.backupRequiredBeforeWrite)
        #expect(plan.postUIVerificationRequired)
        #expect(plan.warnings.contains { $0.contains("did not discover or verify UI state") })
    }

    @Test("Unnamed investment statement rows are diagnostics unless operator confirms visible UI match")
    func unnamedInvestmentStatementRowsRequireVisibleConfirmation() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let investment = try createInvestmentAccount(named: "Unnamed Row Brokerage", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-04-10",
            title: "Investment cash row",
            lineItems: [(accountId: investment.id, amount: 10.0, memo: nil)]
        )
        let lineItemId = try accountLineItemId(in: transaction, accountId: investment.id)
        let internalStatement = try repos.statements.create(
            accountId: investment.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: 10
        )

        #expect(try repos.statements.list(accountId: investment.id).isEmpty)
        let diagnosticRow = try #require(try repos.statements.list(
            accountId: investment.id,
            includeInternal: true
        ).first { $0.id == internalStatement.id })
        #expect(diagnosticRow.rowKind == "unnamed_investment_requires_operator_confirmation")
        #expect(diagnosticRow.isUnnamedInvestmentRow)
        #expect(diagnosticRow.isInternalRowCandidate)
        #expect(diagnosticRow.operatorConfirmedVisibleRequired)

        let readback = try #require(try repos.statements.get(statementId: internalStatement.id))
        #expect(readback.rowKind == "unnamed_investment_requires_operator_confirmation")
        #expect(readback.isUnnamedInvestmentRow)
        #expect(readback.isInternalRowCandidate)

        #expect(throws: (any Error).self) {
            try repos.statements.reconcileLineItems(
                statementId: internalStatement.id,
                lineItemIds: [lineItemId]
            )
        }

        let reconciled = try repos.statements.reconcileLineItems(
            statementId: internalStatement.id,
            lineItemIds: [lineItemId],
            operatorConfirmedVisible: true
        )
        #expect(reconciled.reconciledLineItemCount == 1)

        let unreconciled = try #require(try repos.statements.unreconcileLineItems(
            statementId: internalStatement.id,
            lineItemIds: [lineItemId],
            operatorConfirmedVisible: true
        ))
        #expect(unreconciled.reconciledLineItemCount == 0)

        #expect(throws: (any Error).self) {
            try repos.statements.update(statementId: internalStatement.id, endingBalance: 10)
        }

        let visibleUpdated = try repos.statements.update(
            statementId: internalStatement.id,
            endingBalance: 5,
            operatorConfirmedVisible: true
        )
        #expect(visibleUpdated.endingBalance == 5)

        let updated = try repos.statements.update(
            statementId: internalStatement.id,
            endingBalance: 0,
            beginningBalance: 0,
            allowInternal: true
        )
        #expect(updated.beginningBalance == 0)
        #expect(updated.endingBalance == 0)
    }

    @Test("Explicit reconciliation still rejects line items from another account")
    func reconcileRejectsWrongAccountLineItems() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let statementCard = try createCreditCard(named: "Statement Card", using: repos.accounts)
        let otherCard = try createCreditCard(named: "Other Card", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-04-10",
            title: "Other account charge",
            lineItems: [(accountId: otherCard.id, amount: -10.0, memo: nil)]
        )
        let otherLineItemId = try accountLineItemId(in: transaction, accountId: otherCard.id)

        let statement = try repos.statements.create(
            accountId: statementCard.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: -10.0
        )

        #expect(throws: (any Error).self) {
            try repos.statements.reconcileLineItems(
                statementId: statement.id,
                lineItemIds: [otherLineItemId]
            )
        }
    }

    @Test("Explicit reconciliation still rejects line items already assigned to another statement")
    func reconcileRejectsLineItemsAssignedToAnotherStatement() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Double Assignment Card", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-01-15",
            title: "Assigned charge",
            lineItems: [(accountId: card.id, amount: -25.0, memo: nil)]
        )
        let lineItemId = try accountLineItemId(in: transaction, accountId: card.id)

        let firstStatement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-01-01",
            endDate: "2026-01-31",
            beginningBalance: 0,
            endingBalance: -25.0
        )
        let secondStatement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-02-01",
            endDate: "2026-02-28",
            beginningBalance: -25.0,
            endingBalance: -25.0
        )

        _ = try repos.statements.reconcileLineItems(
            statementId: firstStatement.id,
            lineItemIds: [lineItemId]
        )

        #expect(throws: (any Error).self) {
            try repos.statements.reconcileLineItems(
                statementId: secondStatement.id,
                lineItemIds: [lineItemId]
            )
        }
    }

    @Test("Account reconciliation status is derived from active statements")
    func accountReconciliationStatusUsesActiveStatements() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Statement History Card", using: repos.accounts)
        let initialStatus = try repos.statements.getAccountReconciliationStatus(accountId: card.id)

        #expect(initialStatus.accountId == card.id)
        #expect(!initialStatus.hasReconciledStatements)
        #expect(initialStatus.statementCount == 0)
        #expect(initialStatus.lastStatementId == nil)
        #expect(initialStatus.lastReconciledStatementEndDate == nil)

        _ = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-01-01",
            endDate: "2026-01-31",
            beginningBalance: 0,
            endingBalance: -25.0
        )
        let latestStatement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-02-01",
            endDate: "2026-02-28",
            beginningBalance: -25.0,
            endingBalance: -40.0
        )

        let status = try repos.statements.getAccountReconciliationStatus(accountId: card.id)

        #expect(status.hasReconciledStatements)
        #expect(status.statementCount == 2)
        #expect(status.lastStatementId == latestStatement.id)
        #expect(status.lastReconciledStatementEndDate == "2026-02-28")
    }

    @Test("Statement get returns deterministic reconciled line item membership")
    func getReturnsStatementLineItems() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Membership Card", using: repos.accounts)
        let laterTransaction = try repos.transactions.create(
            date: "2026-04-20",
            title: "Later statement charge",
            lineItems: [(accountId: card.id, amount: -20.0, memo: "later")]
        )
        let earlierTransaction = try repos.transactions.create(
            date: "2026-04-05",
            title: "Earlier statement charge",
            lineItems: [(accountId: card.id, amount: -10.0, memo: "earlier")]
        )
        let laterLineItemId = try accountLineItemId(in: laterTransaction, accountId: card.id)
        let earlierLineItemId = try accountLineItemId(in: earlierTransaction, accountId: card.id)

        let statement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: -30.0
        )

        _ = try repos.statements.reconcileLineItems(
            statementId: statement.id,
            lineItemIds: [laterLineItemId, earlierLineItemId]
        )

        let result = try #require(try repos.statements.get(statementId: statement.id))
        #expect(result.reconciledLineItemCount == 2)
        #expect(result.lineItems.map(\.id) == [earlierLineItemId, laterLineItemId])
        #expect(result.lineItems.allSatisfy { $0.statementId == statement.id })
    }

    @Test("Deleting a statement preserves line item cleared state")
    func deleteStatementPreservesLineItemClearedState() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Delete Statement Card", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-03-15",
            title: "Statement charge",
            lineItems: [(accountId: card.id, amount: -12.0, memo: nil)]
        )
        let lineItemId = try accountLineItemId(in: transaction, accountId: card.id)
        let statement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-03-01",
            endDate: "2026-03-31",
            beginningBalance: 0,
            endingBalance: -12.0
        )

        _ = try repos.statements.reconcileLineItems(statementId: statement.id, lineItemIds: [lineItemId])
        let reconciledStatement = try #require(try repos.statements.get(statementId: statement.id))
        #expect(reconciledStatement.reconciledLineItemCount == 1)

        #expect(try repos.statements.delete(statementId: statement.id))

        let status = try repos.statements.getAccountReconciliationStatus(accountId: card.id)
        #expect(!status.hasReconciledStatements)
        let lineItem = try #require(repos.statements.getUnreconciledLineItems(accountId: card.id).first { $0.id == lineItemId })
        #expect(lineItem.statementId == nil)
        #expect(lineItem.cleared)
    }

    @Test("Unreconciling line items preserves cleared state")
    func unreconcileLineItemsPreservesClearedState() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try createCreditCard(named: "Unreconcile Card", using: repos.accounts)
        let transaction = try repos.transactions.create(
            date: "2026-04-15",
            title: "Statement charge",
            lineItems: [(accountId: card.id, amount: -18.0, memo: nil)]
        )
        let lineItemId = try accountLineItemId(in: transaction, accountId: card.id)
        let statement = try repos.statements.create(
            accountId: card.id,
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            beginningBalance: 0,
            endingBalance: -18.0
        )

        _ = try repos.statements.reconcileLineItems(statementId: statement.id, lineItemIds: [lineItemId])
        let result = try #require(try repos.statements.unreconcileLineItems(statementId: statement.id, lineItemIds: [lineItemId]))

        #expect(result.reconciledLineItemCount == 0)
        let lineItem = try #require(repos.statements.getUnreconciledLineItems(accountId: card.id).first { $0.id == lineItemId })
        #expect(lineItem.statementId == nil)
        #expect(lineItem.cleared)
    }
}
