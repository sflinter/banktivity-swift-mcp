# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Swift MCP (Model Context Protocol) server and CLI for [Banktivity](https://www.iggsoftware.com/banktivity/) personal finance vaults. It reads and writes `.bank8` files using Core Data's `NSPersistentContainer`, ensuring changes are properly tracked for CloudKit sync. This replaces an earlier TypeScript implementation that used direct SQL and corrupted vaults.

## Build & Run

```sh
swift build                    # Debug build
swift build -c release         # Release build

# Install binaries
cp .build/release/banktivity-mcp ~/.local/bin/
cp .build/release/banktivity-cli ~/.local/bin/
codesign -fs - ~/.local/bin/banktivity-mcp   # Re-sign after copy
codesign -fs - ~/.local/bin/banktivity-cli

# Run MCP server
BANKTIVITY_FILE_PATH="/path/to/file.bank8" swift run banktivity-mcp

# Run CLI
BANKTIVITY_FILE_PATH="/path/to/file.bank8" swift run banktivity-cli accounts list
swift run banktivity-cli --vault "/path/to/file.bank8" accounts list
```

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
  CoreData/          PersistentContainer, DateConversion, WriteGuard, SyncRecords
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

`BaseRepository` provides KVC helpers (`stringValue()`, `intValue()`, `doubleValue()`, `relatedObject()`, `relatedSet()`), fetch-by-PK with entity inheritance traversal, and write operations via background contexts (`performWrite()`, `performWriteReturning()`). Domain repositories inherit from it.

### Entity Hierarchy

`Account` (Z_ENT=1) is the base entity. `Category` (Z_ENT=2) and `PrimaryAccount` (Z_ENT=3) are sibling subentities. `pAccountClass` lives on the base: 6000=income, 7000=expense. All income/expense categories are `Category` entities.

## Critical Constraints

**Never enable persistent history tracking.** Banktivity uses `ZSYNCEDENTITY` for its own sync — Core Data's `NSPersistentHistoryTrackingKey` adds Z_PRIMARYKEY entries (entity IDs 16001+) that Banktivity doesn't recognize, corrupting the vault.

**Handle null-account line items.** Transactions can have line items where `pAccount` is NULL (orphaned slots). The recategorize logic must reuse these rather than creating new line items, which would cause false split transactions.

**Transactions require balancing offset line items.** Every transaction must have line items that sum to zero (double-entry). When `TransactionRepository.create()` receives line items that don't sum to zero, it automatically creates a balancing offset line item with no account (uncategorized). Without this, Opening Balance transactions won't affect the account's running cash balance in Banktivity.

**Security prices must set `pClosePrice`.** Some price records (from older imports or Banktivity itself) have `pClosePrice=0` with the actual value only in `pAdjustedClosePrice`. The sync blob embeds only `closePrice`, so the mobile app shows 0. Security price history does **not** sync via CloudKit — only the `latestSecurityPrice` embedded in the Security entity's sync blob propagates. Use `securities fix-prices` to repair broken records; it marks the affected securities modified so Banktivity re-uploads them (whether the upload carries the new latest price is unverified).

**WriteGuard before mutations.** All write tools check `WriteGuard.guardWriteAccess()` first. If Banktivity.app has the SQLite file open (detected via `lsof`), writes are blocked to prevent corruption.

### Sync: signal by modification date, never touch the merge base

Banktivity 10 finds local changes to upload by date: an entity whose `pCreationTime` or `pModificationDate` is later than the last sync is uploaded. `ZSYNCEDENTITY` (`SyncedHostedEntity`) records hold `pRemoteEntityData`, a gzipped XML blob of what the server last held. Banktivity uses that blob as the **base of a three-way merge**, creates the record itself when it first uploads a row, and is the only thing that should write the blob.

**Rules for every write** (see `SyncRecords`):
- **Insert:** set `pCreationTime` and `pModificationDate` in the same save. Do not create a `SyncedHostedEntity`.
- **Update:** set the owning entity's `pModificationDate` in the same save. Line items have no record of their own (they travel inside the Transaction's record), so editing a line item, its tags, its statement or its category stamps the parent Transaction.
- **Delete of a synced entity** (Transaction, Statement, Tag): `SyncRecords.markDeletedIfPresent` sets `pSyncedState = 3` and `pSyncedModificationDate` to now, in the same save as the delete, keeping the blob so Banktivity knows what to delete. It is idempotent, and a row with no record (never synced) is simply deleted.
- **Price history does not sync.** A write that changes what a Security's record carries, such as its latest price, stamps the Security. `resetKnownPriceRange` changes only the local `SecurityPriceItem`, so it stamps nothing.
- **Never write `pRemoteEntityData`.** Rewriting the merge base to match a CLI edit tells Banktivity the server already has the edit; when the server sends back its older copy, the older copy wins and the CLI edit is silently undone. An edit made in the Banktivity UI, which leaves the base alone, survives the same sync.

`transactions sync-info` reads a record for diagnostics without changing it.
