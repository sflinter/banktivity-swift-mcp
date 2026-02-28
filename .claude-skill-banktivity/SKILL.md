---
name: banktivity
description: Query and manage Banktivity financial data. Use when the user asks about transactions, accounts, spending, categories, or tags in their Banktivity database.
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
| `get_net_worth` | (none) | Assets minus liabilities |
| `get_account_balance` | `--account_id N` or `--account_name "name"` | Balance for one account |
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
| `delete_statement` | `--statement_id N` | Cascade-unreconciles line items |
| `reconcile_line_items` | `--statement_id N --line_item_ids 1,2,3` | Sets pCleared=true; validates account/date |
| `unreconcile_line_items` | `--statement_id N --line_item_ids 1,2,3` | Sets pCleared=false |
| `get_unreconciled_line_items` | `--account_id N --start_date --end_date` | Unreconciled line items for date range |

### Modifying

| Tool | Key Arguments | Notes |
|---|---|---|
| `recategorize_transaction` | `--transaction_id N --category_id N` or `--category_name "Name"` | Use `--category_id` for subcategories |
| `bulk_recategorize_by_payee` | `--payee_pattern "pat" --category_id N --dry_run true --uncategorized_only true` | **Always dry_run first** |
| `tag_transaction` | `--transaction_id N --tag_name "name" --action add\|remove` | Add or remove a tag |
| `bulk_tag_transactions` | `--transaction_ids [1,2,3] --tag_name "name" --action add\|remove` | Bulk tag/untag |
| `create_tag` | `--name "name"` | Create a new tag |
| `create_category` | `--name "name" --type expense\|income --parent_path "Parent"` | Create category or subcategory |

### Other Tools

Run `banktivity-cli <tool> --help 2>/dev/null` to see any tool's input schema. See `references/tools.md` for the complete list of all tools with full schemas.

## Common Gotchas

1. **Category names are exact**: `"Gift Given"` not `"Gifts Given"`, `"Motor:Tolls"` not `"Motor:Tools"`
2. **Use `--category_id` for subcategories**: `--category_name "Vacation:Entertainment"` may resolve to the top-level `"Entertainment"` instead. Look up the ID with `list_categories` first and use `--category_id`
3. **`search_transactions` does not search tags**: Use `get_transactions_by_tag` for tag-based queries
4. **Transaction dates may differ by a day**: Posting date vs transaction date. Search by reference/payee text is more reliable than exact dates
5. **`bulk_recategorize_by_payee` affects all history**: Not just recent transactions. `--uncategorized_only true` limits scope to uncategorized ones
6. **Always dry-run first**: When recategorizing across history, use `--dry_run true` and show the user the count before applying
7. **Tags live on line items**: Tags are stored on individual line items, not the transaction itself
8. **CLI writes commit immediately**: Unlike the Banktivity UI which may buffer writes, CLI changes are persisted through Core Data instantly
