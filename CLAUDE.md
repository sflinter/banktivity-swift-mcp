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
  CoreData/          PersistentContainer, DateConversion, WriteGuard
  Repositories/      BaseRepository + 10 domain repositories
  Models/            DTOs, Constants, Errors, Formatting

BanktivityMCPLib     ← MCP glue (depends on BanktivityLib + MCP SDK)
  MCP/               ToolRegistry, ToolHelpers, Tools/*.swift

banktivity-mcp       ← MCP server executable (stdio transport)
banktivity-cli       ← CLI executable (depends on BanktivityLib + ArgumentParser)
```

**MCP server flow**: `main.swift` → reads `BANKTIVITY_FILE_PATH` env → `PersistentContainerFactory.create()` → `WriteGuard` → `ToolRegistry.registerAllTools()` → MCP Server (stdio)

**CLI flow**: `banktivity-cli <subcommand>` → reads `--vault` or `BANKTIVITY_FILE_PATH` → creates container + repos → executes command → JSON output

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

**WriteGuard before mutations.** All write tools check `WriteGuard.guardWriteAccess()` first. If Banktivity.app has the SQLite file open (detected via `lsof`), writes are blocked to prevent corruption.
