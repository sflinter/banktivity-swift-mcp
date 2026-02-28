# Banktivity CLI — Complete Tool Reference

All 55 tools with their input schemas. Invoke with:
```sh
BANKTIVITY_FILE_PATH="$HOME/Documents/Banktivity/My Accounts.bank8" banktivity-cli <tool> [--key value ...] 2>/dev/null
```

---

## Querying Tools

### list_accounts
List all accounts in Banktivity with their types and current balances.

```json
{
  "properties": {
    "include_categories": { "type": "boolean", "description": "Include income/expense categories" },
    "include_hidden": { "type": "boolean", "description": "Include hidden accounts" }
  }
}
```

### get_account_balance
Get the current balance for a specific account.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "The account ID" },
    "account_name": { "type": "string", "description": "The account name (alternative to account_id)" }
  }
}
```

### get_transactions
Get transactions with optional filtering by account and date range.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "Filter by account ID" },
    "account_name": { "type": "string", "description": "Filter by account name (alternative to account_id)" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" },
    "limit": { "type": "number", "description": "Maximum number of transactions to return" },
    "offset": { "type": "number", "description": "Number of transactions to skip" }
  }
}
```

### get_transaction
Get a single transaction by ID with all its line items.

```json
{
  "properties": {
    "transaction_id": { "type": "number", "description": "The transaction ID" }
  },
  "required": ["transaction_id"]
}
```

### search_transactions
Search transactions by payee name or notes. **Does NOT search tags** — use `get_transactions_by_tag` for that.

```json
{
  "properties": {
    "query": { "type": "string", "description": "Search query (matches payee name and notes)" },
    "limit": { "type": "number", "description": "Maximum number of results (default 50)" }
  },
  "required": ["query"]
}
```

### get_transactions_by_tag
Find transactions that have a specific tag.

```json
{
  "properties": {
    "tag_id": { "type": "number", "description": "The tag ID (alternative to tag_name)" },
    "tag_name": { "type": "string", "description": "The tag name to search for" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" },
    "limit": { "type": "number", "description": "Maximum number of transactions to return (default: 50)" }
  }
}
```

### get_uncategorized_transactions
Find transactions without any category assigned.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "Filter by account ID" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" },
    "exclude_transfers": { "type": "boolean", "description": "Exclude transfer transactions (default: true)" },
    "limit": { "type": "number", "description": "Maximum number of transactions to return (default: 50)" }
  }
}
```

### get_net_worth
Calculate current net worth (assets minus liabilities).

```json
{
  "properties": {}
}
```

### get_summary
Get a summary of the Banktivity database including account counts and transaction totals.

```json
{
  "properties": {}
}
```

---

## Category Tools

### list_categories
List income/expense categories with optional type filter.

```json
{
  "properties": {
    "type": { "type": "string", "description": "Filter by category type: 'income' or 'expense'" },
    "top_level_only": { "type": "boolean", "description": "Only return top-level categories (default: false)" },
    "include_hidden": { "type": "boolean", "description": "Include hidden categories (default: false)" }
  }
}
```

### get_category
Get a category by ID or name/path (e.g., 'Insurance:Life').

```json
{
  "properties": {
    "category_id": { "type": "number", "description": "The category ID" },
    "category_name": { "type": "string", "description": "The category name or full path (e.g., 'Insurance:Life')" }
  }
}
```

### get_category_tree
Get the full category hierarchy as a tree structure.

```json
{
  "properties": {
    "type": { "type": "string", "description": "Filter by category type: 'income' or 'expense'" }
  }
}
```

### create_category
Create a new income or expense category.

```json
{
  "properties": {
    "name": { "type": "string", "description": "The category name" },
    "type": { "type": "string", "description": "Category type: 'income' or 'expense'" },
    "parent_id": { "type": "number", "description": "Parent category ID (for subcategories)" },
    "parent_path": { "type": "string", "description": "Parent category path (e.g., 'Insurance')" },
    "currency_code": { "type": "string", "description": "Currency code (e.g., 'EUR')" },
    "hidden": { "type": "boolean", "description": "Whether the category should be hidden (default: false)" }
  },
  "required": ["name", "type"]
}
```

### get_spending_by_category
Get spending breakdown by expense category.

```json
{
  "properties": {
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" }
  }
}
```

### get_income_by_category
Get income breakdown by income category.

```json
{
  "properties": {
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" }
  }
}
```

---

## Tag Tools

### get_tags
List all tags used for transactions.

```json
{
  "properties": {}
}
```

### create_tag
Create a new tag for categorizing transactions.

```json
{
  "properties": {
    "name": { "type": "string", "description": "The tag name" }
  },
  "required": ["name"]
}
```

### tag_transaction
Add or remove a tag from a transaction.

```json
{
  "properties": {
    "transaction_id": { "type": "number", "description": "The transaction ID" },
    "tag_id": { "type": "number", "description": "The tag ID (alternative to tag_name)" },
    "tag_name": { "type": "string", "description": "The tag name (will be created if it doesn't exist)" },
    "action": { "type": "string", "description": "Whether to 'add' or 'remove' the tag (default: add)" }
  },
  "required": ["transaction_id"]
}
```

### bulk_tag_transactions
Add or remove a tag from multiple transactions at once.

```json
{
  "properties": {
    "transaction_ids": { "type": "array", "description": "Array of transaction IDs to tag" },
    "tag_id": { "type": "number", "description": "The tag ID (alternative to tag_name)" },
    "tag_name": { "type": "string", "description": "The tag name (will be created if it doesn't exist)" },
    "action": { "type": "string", "description": "Whether to 'add' or 'remove' the tag (default: add)" }
  },
  "required": ["transaction_ids"]
}
```

---

## Categorization Tools

### recategorize_transaction
Change or assign a category on a single transaction.

```json
{
  "properties": {
    "transaction_id": { "type": "number", "description": "The transaction ID to recategorize" },
    "category_id": { "type": "number", "description": "The category ID to assign" },
    "category_name": { "type": "string", "description": "The category name or path (alternative to category_id)" }
  },
  "required": ["transaction_id"]
}
```

### bulk_recategorize_by_payee
Recategorize all transactions matching a payee pattern. Supports dry_run mode to preview changes.

```json
{
  "properties": {
    "payee_pattern": { "type": "string", "description": "Payee/title pattern to match" },
    "category_id": { "type": "number", "description": "The category ID to assign" },
    "category_name": { "type": "string", "description": "The category name or path (alternative to category_id)" },
    "dry_run": { "type": "boolean", "description": "If true, return what would change without making changes" },
    "uncategorized_only": { "type": "boolean", "description": "If true, only recategorize uncategorized transactions" }
  },
  "required": ["payee_pattern"]
}
```

### review_categorizations
List transactions with their current category for review. Useful for spotting miscategorized transactions.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "Filter by account ID" },
    "category_id": { "type": "number", "description": "Filter by category ID" },
    "category_name": { "type": "string", "description": "Filter by category name or path" },
    "payee_pattern": { "type": "string", "description": "Filter by payee/title pattern (partial match)" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" },
    "limit": { "type": "number", "description": "Maximum number of transactions to return (default: 50)" }
  }
}
```

### get_payee_category_summary
Aggregate view: for each distinct payee, show which categories were used and how often. Surfaces inconsistencies and uncategorized counts.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "Filter by account ID" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" },
    "min_transactions": { "type": "number", "description": "Minimum number of transactions for a payee to be included (default: 1)" }
  }
}
```

### suggest_category_for_merchant
Given a merchant name, suggest categories based on import rules and historical transaction patterns.

```json
{
  "properties": {
    "merchant_name": { "type": "string", "description": "The merchant/payee name to look up" }
  },
  "required": ["merchant_name"]
}
```

---

## Transaction CRUD

### create_transaction
Create a new transaction with line items.

```json
{
  "properties": {
    "date": { "type": "string", "description": "Transaction date in ISO format (YYYY-MM-DD)" },
    "title": { "type": "string", "description": "Transaction title/payee" },
    "note": { "type": "string", "description": "Optional note" },
    "line_items": { "type": "array", "description": "Line items: [{account_id, amount, memo?}]" }
  },
  "required": ["date", "title", "line_items"]
}
```

### update_transaction
Update an existing transaction's title, note, date, or cleared status.

```json
{
  "properties": {
    "transaction_id": { "type": "number", "description": "The transaction ID to update" },
    "title": { "type": "string", "description": "New title" },
    "note": { "type": "string", "description": "New note" },
    "date": { "type": "string", "description": "New date in ISO format (YYYY-MM-DD)" },
    "cleared": { "type": "boolean", "description": "Set cleared status" }
  },
  "required": ["transaction_id"]
}
```

### delete_transaction
Delete a transaction and all its line items.

```json
{
  "properties": {
    "transaction_id": { "type": "number", "description": "The transaction ID to delete" }
  },
  "required": ["transaction_id"]
}
```

---

## Line Item Tools

### add_line_item
Add a new line item to an existing transaction.

```json
{
  "properties": {
    "transaction_id": { "type": "number", "description": "The transaction ID to add the line item to" },
    "amount": { "type": "number", "description": "The amount" },
    "account_id": { "type": "number", "description": "The account ID for this line item" },
    "account_name": { "type": "string", "description": "The account name (alternative to account_id)" },
    "memo": { "type": "string", "description": "Optional memo" }
  },
  "required": ["transaction_id", "amount"]
}
```

### get_line_item
Get a specific line item by ID.

```json
{
  "properties": {
    "line_item_id": { "type": "number", "description": "The line item ID" }
  },
  "required": ["line_item_id"]
}
```

### update_line_item
Update a line item's account, amount, or memo.

```json
{
  "properties": {
    "line_item_id": { "type": "number", "description": "The line item ID to update" },
    "account_id": { "type": "number", "description": "New account ID" },
    "account_name": { "type": "string", "description": "New account name (alternative to account_id)" },
    "amount": { "type": "number", "description": "New amount" },
    "memo": { "type": "string", "description": "New memo" }
  },
  "required": ["line_item_id"]
}
```

### delete_line_item
Delete a line item from a transaction.

```json
{
  "properties": {
    "line_item_id": { "type": "number", "description": "The line item ID to delete" }
  },
  "required": ["line_item_id"]
}
```

---

## Statement Tools (Reconciliation)

### list_statements
List statements for an account, sorted by start date.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "The account ID" },
    "account_name": { "type": "string", "description": "The account name (alternative to account_id)" }
  }
}
```

### get_statement
Get a statement with reconciliation progress (reconciled balance, difference, isBalanced).

```json
{
  "properties": {
    "statement_id": { "type": "number", "description": "The statement ID" }
  },
  "required": ["statement_id"]
}
```

### create_statement
Create a new statement for an account with beginning/ending balance validation.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "The account ID" },
    "account_name": { "type": "string", "description": "The account name (alternative to account_id)" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" },
    "beginning_balance": { "type": "number", "description": "Beginning balance" },
    "ending_balance": { "type": "number", "description": "Ending balance" },
    "name": { "type": "string", "description": "Optional statement name" },
    "note": { "type": "string", "description": "Optional note" }
  },
  "required": ["start_date", "end_date", "beginning_balance", "ending_balance"]
}
```

### delete_statement
Delete a statement and unreconcile all its line items.

```json
{
  "properties": {
    "statement_id": { "type": "number", "description": "The statement ID to delete" }
  },
  "required": ["statement_id"]
}
```

### reconcile_line_items
Assign line items to a statement (sets pCleared=true). Validates account ownership, date range, and no double-assignment.

```json
{
  "properties": {
    "statement_id": { "type": "number", "description": "The statement ID" },
    "line_item_ids": { "type": "array", "description": "Array of line item IDs to reconcile" }
  },
  "required": ["statement_id", "line_item_ids"]
}
```

### unreconcile_line_items
Remove line items from a statement (sets pCleared=false).

```json
{
  "properties": {
    "statement_id": { "type": "number", "description": "The statement ID" },
    "line_item_ids": { "type": "array", "description": "Array of line item IDs to unreconcile" }
  },
  "required": ["statement_id", "line_item_ids"]
}
```

### get_unreconciled_line_items
List unreconciled line items for an account, optionally filtered by date range.

```json
{
  "properties": {
    "account_id": { "type": "number", "description": "The account ID" },
    "account_name": { "type": "string", "description": "The account name (alternative to account_id)" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD)" }
  }
}
```

---

## Import Rules

### list_import_rules
List all import rules (patterns to match and categorize imported transactions).

```json
{
  "properties": {}
}
```

### get_import_rule
Get a specific import rule by ID.

```json
{
  "properties": {
    "rule_id": { "type": "number", "description": "The import rule ID" }
  },
  "required": ["rule_id"]
}
```

### create_import_rule
Create a new import rule to automatically categorize imported transactions based on a regex pattern.

```json
{
  "properties": {
    "template_id": { "type": "number", "description": "The transaction template ID to apply when this rule matches" },
    "pattern": { "type": "string", "description": "Regex pattern to match against transaction descriptions" },
    "account_id": { "type": "string", "description": "Optional account UUID to filter by" }
  },
  "required": ["template_id", "pattern"]
}
```

### update_import_rule
Update an existing import rule.

```json
{
  "properties": {
    "rule_id": { "type": "number", "description": "The import rule ID to update" },
    "pattern": { "type": "string", "description": "New regex pattern" },
    "account_id": { "type": "string", "description": "New account UUID" }
  },
  "required": ["rule_id"]
}
```

### delete_import_rule
Delete an import rule.

```json
{
  "properties": {
    "rule_id": { "type": "number", "description": "The import rule ID to delete" }
  },
  "required": ["rule_id"]
}
```

### match_import_rules
Test which import rules match a given transaction description.

```json
{
  "properties": {
    "description": { "type": "string", "description": "The transaction description to test against import rules" }
  },
  "required": ["description"]
}
```

---

## Transaction Templates

### list_transaction_templates
List all transaction templates (used for import rules and scheduled transactions).

```json
{
  "properties": {}
}
```

### get_transaction_template
Get a specific transaction template by ID.

```json
{
  "properties": {
    "template_id": { "type": "number", "description": "The template ID" }
  },
  "required": ["template_id"]
}
```

### create_transaction_template
Create a new transaction template for use with import rules or scheduled transactions.

```json
{
  "properties": {
    "title": { "type": "string", "description": "The template title (payee name)" },
    "amount": { "type": "number", "description": "The default transaction amount" },
    "note": { "type": "string", "description": "Optional note" },
    "currency_id": { "type": "string", "description": "Currency UUID" },
    "line_items": { "type": "array", "description": "Line items: [{account_id (UUID string), amount, memo?}]" }
  },
  "required": ["title", "amount"]
}
```

### update_transaction_template
Update an existing transaction template.

```json
{
  "properties": {
    "template_id": { "type": "number", "description": "The template ID to update" },
    "title": { "type": "string", "description": "New title" },
    "amount": { "type": "number", "description": "New amount" },
    "note": { "type": "string", "description": "New note" },
    "active": { "type": "boolean", "description": "Set active status" }
  },
  "required": ["template_id"]
}
```

### delete_transaction_template
Delete a transaction template (also deletes associated import rules and schedules).

```json
{
  "properties": {
    "template_id": { "type": "number", "description": "The template ID to delete" }
  },
  "required": ["template_id"]
}
```

---

## Scheduled Transactions

### list_scheduled_transactions
List all scheduled/recurring transactions.

```json
{
  "properties": {}
}
```

### get_scheduled_transaction
Get a specific scheduled transaction by ID.

```json
{
  "properties": {
    "schedule_id": { "type": "number", "description": "The scheduled transaction ID" }
  },
  "required": ["schedule_id"]
}
```

### create_scheduled_transaction
Create a new scheduled/recurring transaction.

```json
{
  "properties": {
    "template_id": { "type": "number", "description": "The transaction template ID to use" },
    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD)" },
    "repeat_interval": { "type": "number", "description": "Repeat interval (1=daily, 7=weekly, 30=monthly)" },
    "repeat_multiplier": { "type": "number", "description": "Multiplier for repeat interval" },
    "reminder_days": { "type": "number", "description": "Days in advance to show reminder" },
    "account_id": { "type": "string", "description": "Account UUID for the transaction" }
  },
  "required": ["template_id", "start_date"]
}
```

### update_scheduled_transaction
Update an existing scheduled transaction.

```json
{
  "properties": {
    "schedule_id": { "type": "number", "description": "The scheduled transaction ID to update" },
    "start_date": { "type": "string", "description": "New start date in ISO format" },
    "next_date": { "type": "string", "description": "New next occurrence date in ISO format" },
    "repeat_interval": { "type": "number", "description": "New repeat interval" },
    "repeat_multiplier": { "type": "number", "description": "New repeat multiplier" },
    "reminder_days": { "type": "number", "description": "New reminder days" },
    "account_id": { "type": "string", "description": "New account UUID" }
  },
  "required": ["schedule_id"]
}
```

### delete_scheduled_transaction
Delete a scheduled transaction.

```json
{
  "properties": {
    "schedule_id": { "type": "number", "description": "The scheduled transaction ID to delete" }
  },
  "required": ["schedule_id"]
}
```

---

## Schema Inspection

### dump_schema
Dump the Core Data model schema showing all entity names, attributes, and relationships.

```json
{
  "properties": {
    "entity_name": { "type": "string", "description": "Optional: filter to a specific entity name (e.g. 'Transaction', 'Account')" }
  }
}
```
