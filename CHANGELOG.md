# Changelog

## Unreleased

- Anchor date-only writes to a fixed offset (10:00 UTC) so a calendar day reads
  back as the same day wherever the vault is opened; previously a date-only value
  was stored at the writer's local midnight, so the rendered day depended on the
  reader's time zone
- Keep the sync blob's `date` field in step with the anchored Core Data write, so
  CloudKit and the local store describe the same instant
- Close the end bound on date windows: `endDate` is now an exclusive
  next-midnight bound (`pDate <`), so transactions later in the end day are no
  longer silently dropped from `transactions list`, account activity, statement
  membership, tag and categorization queries

## v0.13.0

- Fix deletion sync: set `pSyncedState = 3` with current timestamp to signal deletion to CloudKit, instead of clearing blob and nulling modification date (which Banktivity ignored)
- Fix statement deletion sync: `StatementRepository.delete()` now marks the statement's own sync record for deletion
- Add `transactions sync-info` CLI command for inspecting sync record state
- Add `SyncBlobUpdater.inspectSyncRecord()` diagnostic method

## v0.12.0

- Fix statement reconciliation balance to include SecurityLineItem amounts (`pAmount`) alongside regular line item amounts (`pTransactionAmount`), matching Banktivity's own calculation for investment accounts

## v0.11.0

- Add RDF/Turtle export (`export turtle` CLI, `export_turtle` MCP tool) using schema.org + custom [personal-finance-ontology](https://github.com/sflinter/personal-finance-ontology)
- Add optional `tags` field to `LineItemDTO` (populated from `pTags` relationship)
- Fix sync propagation: `performBlobUpdate` now NULLs `pSyncedModificationDate` so blob patches propagate after initial desktop sync
- Fix deletion sync: `deleteSyncRecord` keeps the sync record with cleared blob instead of deleting it, so deletions propagate to CloudKit
- Add Makefile for repeatable builds (`make build`, `make test`, `make release`, `make install`, `make package`)
- Update MCP SDK from 0.11.0 to 0.12.0

## v0.10.0

- Add `securities update-trade` CLI command to update SecurityLineItem fields (shares, price, amount, security) on existing transactions
- Add `--transaction-type` option to `transactions update` CLI and `transaction_type` parameter on MCP `update_transaction` tool
- Add transaction type and SecurityLineItem sync blob patching to SyncBlobUpdater
- Fix transaction type base type code mappings (withdrawal=2, move-shares-in=210, dividend=301, etc.)

## v0.9.0

- Update Security sync blobs with latest price on import

## v0.8.0

- Fix currency bug in transaction/security creation
- Add sync record creation for new transactions

## v0.7.0

- Add ZSYNCEDENTITY sync blob updates for CLI/MCP write operations
- Fix sync blob updates: never set pSyncedModificationDate

## v0.6.1

- Fix fetchByPK entity inheritance and statement reconciliation bugs

## v0.6.0

- Add security creation and share adjustment support

## v0.5.0

- Add security holdings, trades, and income support

## v0.4.0

- Add security price history support

## v0.3.0

- Add statement reconciliation support

## v0.2.0

- Separate domain library from MCP and add CLI
- Add `--account-name`, tag commands, multi-line-item create, `--version`
- Add `--format` CLI option
- Add `/banktivity` Claude Code skill

## v0.1.0

- Initial Swift rewrite with Core Data (replacing TypeScript/SQL implementation)
