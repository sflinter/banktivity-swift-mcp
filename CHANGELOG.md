# Changelog

## Unreleased

### Changed
- **README rewritten:** safety notes up front, how to find a Banktivity 10 vault and grant Full Disk Access, configuration table, CLI and MCP tool tables checked against the code, exit codes, and a section on how the tool works with Banktivity's sync, amounts and running balances
- **Removed dead and obsolete code (about 1,000 lines):** the sync-blob patching machinery made obsolete in v0.18.0, explicit running-balance recalculation now done by the save hook, and unused helpers and parameters (found with Periphery). `TagRepository` and `CategorizationRepository` no longer take a `SyncBlobUpdater`

## v0.18.0 (2026-11-15)

### New
- **Cross-currency transfer repair:** `transactions repair-forex` / `repair_forex_transfer` rewrites an existing transfer as source (gross), fee and target (at the rate) lines, validating that gross − fee × rate matches the amount received, editing existing lines in place and refusing transactions with other lines (from #6). The rebuilt sync record lists the lines without statement or tag references; Banktivity uploads the vault's values, so nothing is lost
- **`securities audit-prices` / `audit_security_prices`:** lists trades stored with a price of 0 and flags those that zero a held security on other devices
- **Security trades and income:** `securities create-trade` / `create_security_trade` writes a buy or sell with its security line, cash line and balancing line; `securities create-income` / `create_security_income` writes native dividend and other income (optionally with tax withheld), so holdings and income reports see them (#13)
- **Security delete:** `securities delete` / `delete_security` removes a security no trade references; refuses otherwise, keeps prices unless `--with-prices`, supports `--dry-run` (#13)
- **Security rename:** `securities rename` / `rename_security` changes a ticker or name and updates the sync record (#48)
- **Trade corrections:** `update-trade` / `update_security_trade` can set commission, and `--basis-only-transfer` records a zero-cash transfer-in (#8)
- **Realised gains:** `securities realized-gains` / `get_security_realized_gains`: realised capital gains per closed lot, with acquisition date, holding period and term. Banktivity computes gains at render time and persists nothing (`SecurityLot` ships empty), so this recomputes them by FIFO lot matching; it refuses rather than guessing when a security uses a cost-basis method other than FIFO (exit 65) (#46)
- **Multi-currency net worth:** `get_net_worth` / `get_summary` convert each account to the reporting currency with the vault's latest exchange rates and include holdings value; adds `breakdown.byCurrency` and `warnings` (from #20)
- **Exit codes:** the CLI exits 64 usage, 65 validation failed, 66 not found, 70 store failure, 77 write blocked, with `Error: [category] message` on stderr (#24)
- **Categories:** `categories delete` and `categories audit-entities` / `audit_category_entities` (#42)
- **Statements:** `statements status` / `get_account_reconciliation_status`, `statements update` / `update_statement` (balances in place), and `statements get` lists the statement's line items (from #4)
- **MCP tool annotations:** every tool advertises `readOnlyHint` / `destructiveHint`, so clients can tell reads from writes; unlabelled tools default to destructive, and a test refuses a read-only label on any tool that guards writes

### Fixed
- **Edits can no longer be undone by sync:** the CLI no longer rewrites a record's sync blob (`pRemoteEntityData`) when it edits it. Banktivity uses that blob as the three-way merge base, so a patched blob let an incoming remote copy of the record silently revert the edit (confirmed in `+[IGGCSyncObject mergedFieldFromBase:remote:local:]`). Every save now marks the owning Transaction or Security modified instead, which is what selects a record for upload. New-row sync records and deletion tombstones are unchanged (from #50's analysis)
- **No more zero-price trades:** a device that receives a trade writes its price per share into the security's price history for that date, zero included (read from Banktivity's IGGAccounting), so a 0 made the phone value the whole holding at 0. `securities adjust` / `create_share_adjustment` take `--price-per-share` and require a positive price for a buy or sell (or derive it from `--amount`); `create-trade` and `update-trade` refuse a price ≤ 0; income and share moves store no price instead of 0, written as null in the sync record
- **Running balances kept current:** every write recalculates the cached running balance (the desktop app's account cash) of the accounts it touched, from the earliest changed date, with Banktivity's own line-amount rule. The old recalculation summed raw `pTransactionAmount` over the whole account, which is what left investment accounts' desktop cash wrong
- **Desktop cash out of date:** `accounts recalc-balances` recomputes the cached `LineItem.pRunningBalance` that Banktivity's desktop app shows as an account's cash, which rows written by the CLI leave stale. It follows Banktivity's own rule and order, only touches accounts whose final balance is wrong, and marks nothing modified (the cache is not synced)
- **Line amounts follow Banktivity:** balances and statement totals use Banktivity's own per-line rule (read from IGGAccounting): for investment transactions the security line's amount + income, otherwise amount x exchange rate. 239 of 240 investment statements in a real vault now balance, against 202 before
- **Cleared is kept:** unreconciling a line or deleting a statement no longer un-ticks its lines (from #4)
- Reads use a fresh background context, so a read straight after a write no longer returns stale objects
- **Investment balances:** account balances now count native trade cash (`SecurityLineItem.pAmount` when the line item amount is 0, skipping share-only adjustments), matching Banktivity's running balance; holdings market value is reported beside cash as `holdingsValue` (#51, built from #19/#33; fixes #2)
- **Exchange rates in balances:** each line's exchange rate is applied, and a missing or zero rate counts as 1 (#51)
- **Categories:** created as `Category` entities, not `PrimaryAccount`, which could crash bank sync (#37); `categories create` returns the new row, not an older one with the same name; parents must be categories, and the class is validated (#42)
- **Categorization reads** apply the account and category filters (#54)
- **Transaction types:** the CLI's transaction-type vocabulary is kept separate from sync's (#43)
- **Serialized writes:** Core Data writes are serialized through one gate, refused at the vault level while Banktivity has it open (#7)
- **Account classes:** complete `AccountClass` values from the Banktivity framework (#18)
- **Reporting currency:** `BANKTIVITY_REPORTING_CURRENCY` sets the currency for net worth and summary (#17)
- **Tests:** `make test` runs in release configuration against the built CLI (#39)
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

## v0.17.0

- **Transaction type inference:** `transactions create` picks the transaction type from the accounts and sign (Charge/Refund/Payment on credit cards, Transfer between real accounts, otherwise Withdrawal/Deposit) instead of the first type in the vault; adds `charge`, `refund` and `payment` to `transactions update --transaction-type`
- **Tag lookup crash:** fixed `tags get-by-tag` / `get_transactions_by_tag`, which crashed on an unsupported Core Data keypath
- **Late-posted reconciles:** added `statements reconcile --allow-out-of-range` (MCP `allow_out_of_range`) for card charges posted on a later statement
- **Stable signing:** `make install` signs with a stable local identity and fixed identifiers so macOS Full Disk Access survives rebuilds; `make install` / `make package` locate release binaries via `--show-bin-path`
- **Merged contributions:**
  - fixed `transactions create` return value (#5)
  - Core Data threading fixes in repository reads (#3)
  - negative numeric CLI option values accepted (#9)
  - security trade cash line repair (#10)
  - deterministic currency formatting (#12)
  - fail loudly for missing account filters (#15)
  - read-only store opening (#38)
  - trade transaction types read from the vault (#40)
  - forget a security's price history (#44)
  - Core Data tests on the main actor (#45)
  - refuse to categorize transfers and non-category targets (#47)
  - silence value-transformer warnings (#52)

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
