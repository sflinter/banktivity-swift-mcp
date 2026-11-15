# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Swift MCP (Model Context Protocol) server and CLI for [Banktivity](https://www.iggsoftware.com/banktivity/) personal finance vaults. It reads and writes `.bank8` files using Core Data's `NSPersistentContainer`, ensuring changes are properly tracked for CloudKit sync. This replaces an earlier TypeScript implementation that used direct SQL and corrupted vaults.

## Build & Run

```sh
swift build                    # Debug build
swift build -c release         # Release build

# Install binaries (builds universal release, copies to ~/.local/bin, signs)
make install

# Run MCP server
BANKTIVITY_FILE_PATH="/path/to/file.bank8" swift run banktivity-mcp

# Run CLI
BANKTIVITY_FILE_PATH="/path/to/file.bank8" swift run banktivity-cli accounts list
swift run banktivity-cli --vault "/path/to/file.bank8" accounts list
```

**Code signing.** `make install` signs with the self-signed "Banktivity MCP Code Signing" certificate in the login keychain and fixed identifiers (`com.flinter.banktivity-cli` / `-mcp`). The vault lives in Banktivity's Group Container, so both binaries need Full Disk Access. That grant is keyed to identifier + certificate, so it survives rebuilds. With an ad-hoc signature (`codesign -s -`, the fallback when the certificate is absent) it is lost on every rebuild. Recreate the certificate with `openssl req -x509 ... -addext "extendedKeyUsage=critical,codeSigning"` and `security import ... -T /usr/bin/codesign`. The "not trusted" status doesn't matter.

If the build fails with `module compiled with Swift 6.x cannot be imported by the Swift 6.y compiler` (e.g. for `ArgumentParserToolInfo`), the `.build` cache was produced by a different Swift toolchain. Fix with `rm -rf .build && swift build`.

## Testing

Tests use Swift Testing framework (`import Testing`). The Command Line Tools don't ship Testing or XCTest, so tests must run with the Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
swift test \
  -Xswiftc -F -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  -Xlinker -rpath -Xlinker /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
```

Integration tests require a Banktivity vault at `~/Documents/Banktivity/Steves Accounts MCP.bank8`. Tests copy it to `/tmp` before each run and skip gracefully if the vault is missing.

## Architecture

Three-target package structure:

```
BanktivityLib        ← Pure domain library (no MCP dependency)
  CoreData/          PersistentContainer, DateConversion, WriteGuard, SyncBlobUpdater
  Repositories/      BaseRepository + 10 domain repositories
  Models/            DTOs, Constants, Errors, Formatting
  Export/            RDF export: TurtleWriter, TurtleSerializer, VaultExporter

BanktivityMCPLib     ← MCP glue (depends on BanktivityLib + MCP SDK)
  MCP/               ToolRegistry, ToolHelpers, Tools/*.swift

banktivity-mcp       ← MCP server executable (stdio transport)
banktivity-cli       ← CLI executable (depends on BanktivityLib + ArgumentParser)
```

**MCP server flow**: `main.swift` → reads `BANKTIVITY_FILE_PATH` env → `PersistentContainerFactory.create()` → `WriteGuard` → `ToolRegistry.registerAllTools()` → MCP Server (stdio)

**CLI flow**: `banktivity-cli <subcommand>` → reads `--vault` or `BANKTIVITY_FILE_PATH` → creates container + repos → executes command → JSON output

**Export flow**: `VaultExporter.collectData()` fetches all DTOs from repositories → `TurtleSerializer` maps DTOs to Turtle triples via `TurtleWriter` → output as `.ttl` string. The `RDFSerializer` protocol allows adding JSON-LD or other formats later. The ontology ([sflinter/personal-finance-ontology](https://github.com/sflinter/personal-finance-ontology)) uses schema.org types where applicable and a custom `pfo:` namespace for personal finance concepts.

Tests import `@testable import BanktivityLib`.

### Core Data Access

Banktivity's `.bank8` bundle contains compiled Core Data models (`.momd` files) in `StoreContent/`. We load and merge these at runtime — no `.xcdatamodeld` in this project. All entity access uses KVC on `NSManagedObject`:

```swift
let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
request.predicate = NSPredicate(format: "pDate >= %@", startDate)
let tx = try context.fetch(request)
let name = tx.value(forKey: "pName") as? String
```

Property names are prefixed with `p` (e.g., `pName`, `pDate`, `pAccountClass`, `pHidden`). Use the `dump_schema` MCP tool or `banktivity-cli schema` to inspect entity/attribute names.

### Repository Pattern

`BaseRepository` provides KVC helpers (`stringValue()`, `intValue()`, `doubleValue()`, `relatedObject()`, `relatedSet()`), fetch-by-PK with entity inheritance traversal, reads via a fresh background context per call (`performRead()`, so a read never sees stale view-context objects after a write), and write operations via background contexts (`performWrite()`, `performWriteReturning()`). Domain repositories inherit from it.

### Entity Hierarchy

`Account` (Z_ENT=1) is the base entity. `Category` (Z_ENT=2) and `PrimaryAccount` (Z_ENT=3) are sibling subentities. `pAccountClass` lives on the base: 6000=income, 7000=expense. All income/expense categories must be `Category` entities. A category stored as `PrimaryAccount` can freeze Banktivity reports or crash bank sync. `categories audit-entities` lists any such rows, and `categories delete` removes an unused one.

## Critical Constraints

**Never enable persistent history tracking.** Banktivity uses `ZSYNCEDENTITY` for its own sync — Core Data's `NSPersistentHistoryTrackingKey` adds Z_PRIMARYKEY entries (entity IDs 16001+) that Banktivity doesn't recognize, corrupting the vault.

**Handle null-account line items.** Transactions can have line items where `pAccount` is NULL (orphaned slots). The recategorize logic must reuse these rather than creating new line items, which would cause false split transactions.

**Transactions require balancing offset line items.** Every transaction must have line items that sum to zero (double-entry). When `TransactionRepository.create()` receives line items that don't sum to zero, it automatically creates a balancing offset line item with no account (uncategorized). Without this, Opening Balance transactions won't affect the account's running cash balance in Banktivity.

**Security prices must set `pClosePrice`.** Some price records (from older imports or Banktivity itself) have `pClosePrice=0` with the actual value only in `pAdjustedClosePrice`. The sync blob embeds only `closePrice`, so the mobile app shows 0. Security price history does **not** sync via CloudKit — only the `latestSecurityPrice` embedded in the Security entity's sync blob propagates. Use `securities fix-prices` to repair broken records and update sync blobs.

**Line amounts: use `BaseRepository.accountAmount`.** It is Banktivity's own rule (`-[IGGCAccountingLineItem accountAmount]` in IGGAccounting): for an investment transaction (base type 100–310) with a security line, the amount is the security line's `pAmount` (0 for share moves 210–212) + `pIncome`, counted only for a cash distribution type, and `pTransactionAmount` is ignored. Every other line is amount × exchange rate. Balances and statement totals both use it. Investment balances are cash only, with holdings market value reported beside them as `holdingsValue`. Don't read `pRunningBalance` for balances: it's a per-device cache (not in sync records) that the desktop app shows as an account's cash, and rows the CLI writes leave it stale. `accounts recalc-balances` recomputes it (Banktivity orders by transaction date, then creation time or row order within a day). Every repository save also does this automatically for the real accounts it touched, from the earliest changed date (`BaseRepository.accountsNeedingRunningBalance`); don't add separate recalculation calls.

**Never write a trade with pricePerShare 0.** A device that receives a transaction writes its security line's pricePerShare into that security's price history for the trade date, with no zero check, so a 0 makes every other device value the holding at 0. Write a real price, or leave it nil. `SecurityRepository.validatedPricePerShare` enforces this, and `securities audit-prices` finds existing ones.

**Statements have no name in Banktivity.** The app's statement class has no name property and the sync blob carries only account, dates and balances. `pName` is set only by this CLI, so an unnamed statement is normal, not internal.

**WriteGuard before mutations.** All write tools check `WriteGuard.guardWriteAccess()` first. Register read tools with `access: .read` and pure creates with `access: .additive`; anything else keeps the `.destructive` default. These become MCP tool annotations, and `ToolAccessLabelTests` fails if a tool that calls the guard is labelled read. If Banktivity.app has the SQLite file open (detected via `lsof`), writes are blocked to prevent corruption.

**Agent write safety.** AI assistants issue parallel tool calls and can start more than one MCP server, so the harness needs its own layer: one MCP/CLI process per vault, serialized writes, and read-before-write checks where practical so a write only applies while the target row still holds the expected value. Close every MCP/CLI process before opening the same vault in Banktivity.app, and back up before a write run. Local numeric IDs change across a Banktivity 10 restore, import, or migration, so re-resolve account, transaction, statement, and category IDs afterwards.

### Sync Blob Updates (SyncBlobUpdater)

Banktivity's CloudKit sync uses `ZSYNCEDENTITY` records with gzipped XML blobs (`pRemoteEntityData`) representing each entity's last-synced state. When CLI/MCP tools modify transactions, the `SyncBlobUpdater` patches these blobs so Banktivity recognizes the changes and pushes them to CloudKit.

**How it works**: After a Core Data write succeeds, `SyncBlobUpdater` fetches the `SyncedHostedEntity` by the transaction's `pUniqueID`, decompresses the gzip blob, applies XML string patches to the relevant fields, validates the result, saves the compressed blob back, and nulls `pSyncedModificationDate` so Banktivity re-checks the record on next sync.

**Operations patched**:
- Reconcile/unreconcile: patches `cleared` and `statement` fields on line items in the blob
- Recategorize: patches `account` reference on the category line item
- Tag/untag: patches `tags` collection on line items
- Transaction update: patches `title`, `note`, `date` at the transaction level
- Transaction delete: keeps the `SyncedHostedEntity` record, sets `pSyncedState = 3` and `pSyncedModificationDate` to the current timestamp — Banktivity recognises state 3 as "deleted" and pushes the deletion to CloudKit. The blob (`pRemoteEntityData`) is preserved so Banktivity knows what to delete.

**Non-fatal by design**: All blob updates are wrapped in try/catch. If a sync record is missing, decompression fails, or the XML can't be patched, the Core Data write still succeeds — only the sync push is skipped. Failures log to stderr.

**`pSyncedModificationDate` on normal records is NULL.** Blob patches null it after saving. The older rule here ("non-NULL means already synced, skip") is not supported by a live vault: on 2026-11-15, all 27,368 state-0 records had it NULL, and only state-3 tombstones carried a date. Banktivity removed those tombstones after its next sync. What actually triggers an upload of a modified record is unverified. PR #50 argues it is the entity's `pModificationDate`, and that rewriting `pRemoteEntityData` (the three-way merge base) can let an older server copy win. Until a controlled round trip settles it, keep the current blob patching, which has been seen to sync, and always set `pModificationDate` on the entity you change.

**LineItems have no separate sync records** — they're serialized inside the parent Transaction's blob. The `identifier` field in the XML maps to `pUniqueID` in Core Data. **Statements DO have their own sync records** in `ZSYNCEDENTITY` with `pHostedEntityType = "Statement"`.

**`pSyncedState` values**: 0 = normal/synced, 3 = deleted. For deletions, set state to 3 and `pSyncedModificationDate` to the current timestamp (preserving the blob); Banktivity pushes the deletion and removes the record on its next sync. For modifications, null `pSyncedModificationDate` (keeping state at 0).
