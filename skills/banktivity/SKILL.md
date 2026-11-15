---
name: banktivity
description: Query and manage Banktivity financial data. Use when the user asks about transactions, accounts, spending, categories, tags, or securities in their Banktivity database.
allowed-tools: Bash, Read
---

# Banktivity CLI Skill

You have access to `banktivity-cli`, a fast CLI tool for querying and managing a Banktivity personal finance database.

## Setup

- **Binary**: `~/.local/bin/banktivity-cli` (on PATH)
- **Database**: `~/Documents/Banktivity/My Accounts.bank8` ← **edit this path**
- **Required env var**: `BANKTIVITY_FILE_PATH` must be set on every invocation

## Invocation Pattern

```sh
BANKTIVITY_FILE_PATH="$HOME/Documents/Banktivity/My Accounts.bank8" banktivity-cli <tool> [--key value ...] 2>/dev/null
```

Always redirect stderr with `2>/dev/null` — CoreData prints harmless warnings to stderr on every invocation.

## Safety Rules For Writes

- Use one `banktivity-mcp` or `banktivity-cli` process per vault. Reads are low risk, but parallel writes from multiple processes can corrupt or lose data.
- Serialize write calls in the agent or harness. Where practical, read the current row first and only write if the value still matches what the agent planned to change.
- Make a fresh backup before any write run. Prefer a copied vault until the workflow is proven.
- Shut down `banktivity-mcp` and any long-running CLI process before opening the same vault in Banktivity.app.
- Re-resolve account, transaction, statement, and category IDs after restoring from backup, importing, or migrating a Banktivity 10 vault; local numeric IDs can change.

## Output Format

- All tools return **JSON on stdout**
- Most return a **flat JSON array** (`[{...}, {...}]`), NOT `{"transactions": [...]}` or similar wrappers
- For large result sets (>50 items), redirect to a temp file first, then parse with `python3`, rather than piping directly into the conversation

## Key Tools Reference

### Querying

| Tool | Key Arguments | Notes |
|---|---|---|
| `list_accounts` | (none required) | Returns array of `{id, name, fullName, accountType, balance, ...}` |
| `get_transactions` | `--account_id N --start_date YYYY-MM-DD --end_date YYYY-MM-DD --limit N` | Returns array of transaction objects with `lineItems` |
| `search_transactions` | `--query "text" --limit N` | Searches title and notes only. **Does NOT search tags.** |
| `get_transaction` | `--transaction_id N` | Single transaction with all line items |
| `get_transactions_by_tag` | `--tag_id N` or `--tag_name "name"` | The correct way to find tagged transactions |
| `get_tags` | (none) | List all tags with id and name |
| `list_categories` | `--type expense\|income` | All categories; subcategories have `fullName` like `"Motor:Tolls"` |
| `get_category` | `--category_id N` or `--category_name "Name"` | Lookup by ID or path (e.g. `"Insurance:Life"`) |
| `get_category_tree` | `--type expense\|income` | Full hierarchy as a tree |
| `get_spending_by_category` | `--start_date --end_date` | Spending breakdown by expense category |
| `get_income_by_category` | `--start_date --end_date` | Income breakdown by income category |
| `get_uncategorized_transactions` | `--account_id N --limit N` | Transactions without a category |
| `get_net_worth` | (none) | Assets minus liabilities in the reporting currency (cash + holdings, converted at the vault's latest rates); check `warnings` |
| `get_account_balance` | `--account_id N` or `--account_name "name"` | Balance for one account. Investment accounts: `balance` is cash, `holdingsValue` is market value (add them for Banktivity's total) |
| `get_summary` | (none) | Database overview with account counts and totals |
| `get_payee_category_summary` | `--account_id N --min_transactions N` | Per-payee category breakdown; surfaces inconsistencies |
| `review_categorizations` | `--account_id N --category_name "name" --payee_pattern "pat" --limit N` | Review transactions by category for spotting errors |
| `suggest_category_for_merchant` | `--merchant_name "name"` | Suggest category based on rules and history |
| `match_import_rules` | `--description "text"` | Test which import rules match a description |

### Statements (Reconciliation)

| Tool | Key Arguments | Notes |
|---|---|---|
| `list_statements` | `--account_id N` or `--account_name "name"` | List statements for an account |
| `get_statement` | `--statement_id N` | Full details with reconciliation progress |
| `create_statement` | `--account_id N --start_date --end_date --beginning_balance --ending_balance` | Validates balance continuity |
| `delete_statement` | `--statement_id N` | Removes its line items from it; they stay cleared |
| `update_statement` | `--statement_id N [--beginning_balance X] [--ending_balance Y]` | Fix a statement's balances in place (prefer this to delete + recreate) |
| `get_account_reconciliation_status` | `--account_id N` | Unbalanced statements, last statement end, unreconciled line items |
| `reconcile_line_items` | `--statement_id N --line_item_ids 1,2,3 [--allow_out_of_range true]` | Sets pCleared=true; validates account/date (allow_out_of_range for late-posted card charges) |
| `unreconcile_line_items` | `--statement_id N --line_item_ids 1,2,3` | Removes them from the statement; cleared is kept |
| `get_unreconciled_line_items` | `--account_id N --start_date --end_date` | Unreconciled line items for date range |

### Securities

| Tool | Key Arguments | Notes |
|---|---|---|
| `list_securities` | (none) | All securities with name, symbol, currency |
| `create_security` | `--symbol SYM --name "Name" [--currency EUR]` | Create a new security |
| `get_security_prices` | `--symbol AAPL --start_date --end_date --limit N` | Price history; also accepts `--id N` |
| `get_security_holdings` | `--symbol AAPL --account_id N` | Current positions with shares, cost basis, market value |
| `get_security_trades` | `--symbol AAPL --account_id N --start_date --end_date --limit N` | Trade history (buys, sells, transfers) |
| `get_security_realized_gains` | `--symbol AAPL --account_id N --start_date --end_date --limit N` | Realised gains per closed lot, FIFO. Dates filter the **disposal**. Refuses on a non-FIFO cost-basis method |
| `get_security_income` | `--symbol AAPL --account_id N --start_date --end_date` | Dividends, interest, capital gains distributions |
| `create_security_trade` | `--account_id N --symbol AAPL --shares N --price_per_share N --amount N --cash_line_amount N --date YYYY-MM-DD` | Create a buy (positive shares) or sell (negative shares) |
| `create_security_income` | `--account_id N --symbol AAPL --amount 12.34 --date YYYY-MM-DD --offset_category_id N` | Create native dividend income |
| `create_share_adjustment` | `--account_id N --symbol SYM --shares=-10 --date YYYY-MM-DD --price_per_share P` | Share adjustment (charges, splits). Buys/sells need a positive price (or `--amount`, then amount/shares): a 0 price makes the phone value the holding at 0 |
| `import_security_prices` | `--file_path /path/to/csv --symbol AAPL` | Supports Yahoo Finance, OHLCV, or Date/Close CSV |
| `delete_security_prices` | `--symbol AAPL --start_date --end_date` | Delete prices; date range optional |
| `reset_security_price_range` | `--symbol AAPL` or `--id N` | Clears the known price range and last import date; deletes no prices |
| `delete_security` | `--symbol AAPL [--with_prices] [--dry_run]` | Delete a security no trade references; refuses while trades point at it |
| `update_security_trade` | `--transaction_id N [--shares N] [--price_per_share N] [--amount N] [--commission N] [--symbol SYM] [--basis_only_transfer true]` | Correct an existing trade; `--amount` is the security cost, not the cash line |
| `audit_security_prices` | `--at_risk_only true` | Trades priced at 0; `zeroesHolding` ones make the phone value the holding at 0 |
| `rename_security` | `--symbol OLD [--new_symbol NEW] [--new_name "Name"]` | Fix a security's ticker or name; refuses a ticker another security holds |

### Modifying

| Tool | Key Arguments | Notes |
|---|---|---|
| `update_transaction` | `--transaction_id N [--title] [--note] [--date] [--cleared] [--transaction_type]` | Update title, note, date, cleared, or transaction type (deposit, withdrawal, transfer, charge, refund, payment, buy, sell, etc.) |
| `recategorize_transaction` | `--transaction_id N --category_id N` or `--category_name "Name"` | Use `--category_id` for subcategories |
| `bulk_recategorize_by_payee` | `--payee_pattern "pat" --category_id N --dry_run true --uncategorized_only true` | **Always dry_run first** |
| `tag_transaction` | `--transaction_id N --tag_name "name" --action add\|remove` | Add or remove a tag |
| `bulk_tag_transactions` | `--transaction_ids [1,2,3] --tag_name "name" --action add\|remove` | Bulk tag/untag |
| `create_tag` | `--name "name"` | Create a new tag |
| `create_category` | `--name "name" --type expense\|income --parent_path "Parent"` | Create category or subcategory; parent must be a category |
| `audit_category_entities` | (none) | Lists income/expense rows stored as the wrong entity (should be empty) |
| `categories delete` | `<category_id>` (CLI only) | Deletes an unused category; refuses if any line item uses it |

### Forex Repair

Cross-currency transfer repair is available through MCP as `repair_forex_transfer` and through the CLI as `transactions repair-forex`. Prefer the MCP tool when operating as an assistant, and use the CLI for scripting or manual reproduction. Do not emulate forex repair with `create_transaction`, `update_transaction`, `add_line_item`, or generic line-item edits.

Use forex repair only after the source account, target account, fee category, gross source amount, source-currency fee, target amount, and exchange rate are known from source evidence. The tool repairs an existing transaction. It does not create a new forex transfer. For real vault writes, make a backup first and visually inspect Banktivity after the MCP or CLI write.

The Banktivity model is:

- transaction currency is the source account currency
- source line is the gross source-currency debit
- target line keeps the source amount after fees as the transaction amount, with `pExchangeRate` set to the forex rate and `accountAmount` equal to the target-currency receipt
- fee line is a separate source-currency category split

CLI example:

```sh
banktivity-cli transactions repair-forex --transaction-id 1001 --source-account-id 2001 --target-account-id 2002 --fee-category-id 3001 --gross-source-amount 100 --source-fee-amount 1 --target-amount 74.25 --exchange-rate 0.75
```

### Export

| Tool | Key Arguments | Notes |
|---|---|---|
| `export turtle` | `[--output /path/to/file.ttl]` | Export entire vault as RDF/Turtle; stdout if no output path |

### Other Tools

Run `banktivity-cli <tool> --help 2>/dev/null` to see any tool's input schema. See `references/tools.md` for the complete list of all tools with full schemas.

## Common Gotchas

1. **Category names are exact**: `"Gift Given"` not `"Gifts Given"`, `"Motor:Tolls"` not `"Motor:Tools"`
2. **Use `--category_id` for subcategories**: `--category_name "Vacation:Entertainment"` may resolve to the top-level `"Entertainment"` instead. Look up the ID with `list_categories` first and use `--category_id`
3. **`search_transactions` does not search tags**: Use `get_transactions_by_tag` for tag-based queries
4. **Transaction dates may differ by a day**: Posting date vs transaction date on bank statements. (Date-only values are now anchored at 10:00 UTC, so the CLI no longer shifts dates by time zone.) Search by reference/payee text is more reliable than exact dates
5. **`bulk_recategorize_by_payee` affects all history**: Not just recent transactions. `--uncategorized_only true` limits scope to uncategorized ones
6. **Always dry-run first**: When recategorizing across history, use `--dry_run true` and show the user the count before applying
7. **Tags live on line items**: Tags are stored on individual line items, not the transaction itself
8. **CLI writes commit immediately**: Unlike the Banktivity UI which may buffer writes, CLI changes are persisted through Core Data instantly
