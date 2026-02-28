# banktivity-swift-mcp

A [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server for [Banktivity](https://www.iggsoftware.com/banktivity/) personal finance files. It gives AI assistants like Claude full read/write access to your `.bank8` vault — accounts, transactions, categories, tags, templates, import rules, and scheduled transactions.

Inspired by [banktivity-mcp](https://github.com/mhriemers/banktivity-mcp) (TypeScript/Node.js), this is a ground-up rewrite in Swift. The original uses `better-sqlite3` to read and write Core Data's SQLite store directly, bypassing Core Data's internal change tracking. This works for reads, but direct SQL writes are invisible to CloudKit sync — Banktivity doesn't know the data changed, and the vault can become corrupted or fail to sync. This Swift version uses `NSPersistentContainer` so all mutations go through Core Data's API, ensuring proper change tracking and CloudKit compatibility.

> **WARNING: This server can modify your Banktivity data.** Write tools (create, update, delete) make real changes to your `.bank8` vault. While the server uses Core Data for proper change tracking and includes a write guard that blocks mutations when Banktivity is open, AI assistants can and will make mistakes. **Back up your vault regularly** and consider working on a copy until you're confident in your workflow. The authors are not responsible for any data loss or corruption.

## Requirements

- macOS 14+
- A Banktivity `.bank8` vault file

## Installation

### Homebrew (recommended)

```sh
brew install sflinter/tap/banktivity-swift-mcp
```

This installs both `banktivity-mcp` and `banktivity-cli` as universal binaries (Apple Silicon + Intel).

### Download binary

Download the universal binary from [GitHub Releases](https://github.com/sflinter/banktivity-swift-mcp/releases), extract, and move to your PATH:

```sh
tar xzf banktivity-swift-mcp-v0.3.0-macos-universal.tar.gz
mv banktivity-mcp banktivity-cli ~/.local/bin/
```

### Build from source

Requires Swift 6.0+ (Xcode 16+ or Command Line Tools):

```sh
git clone https://github.com/sflinter/banktivity-swift-mcp.git
cd banktivity-swift-mcp
swift build -c release
cp .build/release/banktivity-mcp ~/.local/bin/
cp .build/release/banktivity-cli ~/.local/bin/
codesign -fs - ~/.local/bin/banktivity-mcp
codesign -fs - ~/.local/bin/banktivity-cli
```

## Configuration

### Claude Code

Add to your MCP settings (`~/.claude/settings.json` or project `.mcp.json`):

```json
{
  "mcpServers": {
    "banktivity": {
      "command": "/Users/you/.local/bin/banktivity-mcp",
      "env": {
        "BANKTIVITY_FILE_PATH": "/Users/you/Documents/Banktivity/My Accounts.bank8"
      }
    }
  }
}
```

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "banktivity": {
      "command": "/Users/you/.local/bin/banktivity-mcp",
      "env": {
        "BANKTIVITY_FILE_PATH": "/Users/you/Documents/Banktivity/My Accounts.bank8"
      }
    }
  }
}
```

## Available Tools

### Accounts
- `list_accounts` — List all accounts with balances
- `get_account_balance` — Get balance for a specific account
- `get_net_worth` — Calculate total net worth
- `get_spending_by_category` — Spending breakdown by category for a date range
- `get_income_by_category` — Income breakdown by category for a date range
- `get_summary` — Overall financial summary

### Transactions
- `get_transactions` — List transactions with filtering and pagination
- `search_transactions` — Full-text search across payees, memos, etc.
- `get_transaction` — Get a single transaction by ID
- `create_transaction` — Create a new transaction
- `update_transaction` — Update an existing transaction
- `delete_transaction` — Delete a transaction

### Line Items
- `get_line_item` — Get a specific line item
- `add_line_item` — Add a line item to a transaction (for splits)
- `update_line_item` — Update a line item
- `delete_line_item` — Delete a line item

### Categories
- `list_categories` — List all income/expense categories
- `get_category` — Get a specific category
- `get_category_tree` — Get the full category hierarchy
- `create_category` — Create a new category

### Categorization
- `get_uncategorized_transactions` — Find transactions without categories
- `suggest_category_for_merchant` — Suggest a category based on merchant history
- `recategorize_transaction` — Change a transaction's category
- `bulk_recategorize_by_payee` — Recategorize all transactions for a payee
- `review_categorizations` — Review recent categorization changes
- `get_payee_category_summary` — Summary of categories used per payee

### Tags
- `get_tags` — List all tags
- `create_tag` — Create a new tag
- `tag_transaction` — Tag a transaction
- `get_transactions_by_tag` — Find transactions with a specific tag
- `bulk_tag_transactions` — Tag multiple transactions at once

### Templates
- `list_transaction_templates` — List saved transaction templates
- `get_transaction_template` — Get a specific template
- `create_transaction_template` — Create a new template
- `update_transaction_template` — Update a template
- `delete_transaction_template` — Delete a template

### Import Rules
- `list_import_rules` — List all import rules
- `get_import_rule` — Get a specific import rule
- `match_import_rules` — Find rules matching a payee string
- `create_import_rule` — Create a new import rule
- `update_import_rule` — Update an import rule
- `delete_import_rule` — Delete an import rule

### Scheduled Transactions
- `list_scheduled_transactions` — List all scheduled transactions
- `get_scheduled_transaction` — Get a specific scheduled transaction
- `create_scheduled_transaction` — Create a new scheduled transaction
- `update_scheduled_transaction` — Update a scheduled transaction
- `delete_scheduled_transaction` — Delete a scheduled transaction

### Statements (Reconciliation)
- `list_statements` — List statements for an account
- `get_statement` — Get a statement with reconciliation progress
- `create_statement` — Create a new statement with balance validation
- `delete_statement` — Delete a statement and unreconcile its line items
- `reconcile_line_items` — Assign line items to a statement
- `unreconcile_line_items` — Remove line items from a statement
- `get_unreconciled_line_items` — List unreconciled line items for an account

### Diagnostic
- `dump_schema` — Inspect the Core Data model schema (entity names, attributes, relationships)

## CLI

A standalone CLI (`banktivity-cli`) provides the same functionality without an MCP server. Set `BANKTIVITY_FILE_PATH` or pass `--vault`:

```sh
banktivity-cli --vault ~/Documents/Banktivity/My\ Accounts.bank8 accounts list
banktivity-cli accounts balance --account-name "Checking"
banktivity-cli transactions list --account-name "Checking" --start-date 2025-01-01 --limit 10
banktivity-cli transactions create --account-name "Checking" --date 2025-06-15 --title "Coffee" --amount -4.50 --category-name "Food"
banktivity-cli tags get-by-tag --tag-name "Vacation" --limit 20
banktivity-cli tags bulk-tag --transaction-ids "100,101,102" --tag-name "Vacation"
```

### CLI Subcommands

- `accounts list`, `accounts balance`, `accounts net-worth`, `accounts spending`, `accounts income`, `accounts summary`
- `transactions list`, `transactions search`, `transactions get`, `transactions create`, `transactions update`, `transactions delete`
- `categories list`, `categories get`, `categories tree`, `categories create`
- `tags list`, `tags create`, `tags tag-transaction`, `tags get-by-tag`, `tags bulk-tag`
- `uncategorized list`, `uncategorized suggest`, `uncategorized recategorize`, `uncategorized bulk-recategorize`, `uncategorized review`, `uncategorized payee-summary`
- `line-items get`, `line-items add`, `line-items update`, `line-items delete`
- `templates list`, `templates get`, `templates create`, `templates update`, `templates delete`
- `import-rules list`, `import-rules get`, `import-rules match`, `import-rules create`, `import-rules update`, `import-rules delete`
- `scheduled list`, `scheduled get`, `scheduled create`, `scheduled update`, `scheduled delete`
- `statements list`, `statements get`, `statements create`, `statements delete`, `statements reconcile`, `statements unreconcile`, `statements unreconciled`
- `schema`

Most commands that accept `--account-id` also accept `--account-name` as an alternative. The `transactions create` command supports `--line-items` with a JSON array for multi-line-item (split) transactions.

Use `--format compact` for machine-readable single-line JSON output (default is pretty-printed).

### Shell Completions

ArgumentParser provides shell completion scripts automatically:

```sh
banktivity-cli --generate-completion-script bash   # Bash completions
banktivity-cli --generate-completion-script zsh    # Zsh completions
banktivity-cli --generate-completion-script fish   # Fish completions
```

For example, to install Zsh completions:

```sh
banktivity-cli --generate-completion-script zsh > ~/.zfunc/_banktivity-cli
```

## Claude Code Skill

A `/banktivity` [skill](https://docs.anthropic.com/en/docs/claude-code/skills) is available for Claude Code. It lets Claude use the CLI directly to answer natural-language questions about your finances — "What did I spend on groceries last month?", "Show me uncategorized transactions in Checking", etc.

To install, copy the skill directory into your global Claude Code config:

```sh
mkdir -p ~/.claude/skills
cp -r skills/banktivity ~/.claude/skills/banktivity
```

The `skills/banktivity/` directory contains a `SKILL.md` file that teaches Claude how to invoke `banktivity-cli` with the correct environment variable and arguments. You'll need to edit the `BANKTIVITY_FILE_PATH` in `SKILL.md` to point to your own vault.

Once installed, type `/banktivity` in any Claude Code session to activate it, or Claude will activate it automatically when you ask about transactions, accounts, spending, or categories.

## Safety Features

- **Write guard**: Before any mutation, the server checks if Banktivity.app has the vault open (via `lsof`). If it does, writes are blocked to prevent corruption.
- **No persistent history tracking**: Banktivity uses its own sync mechanism. Core Data's built-in history tracking would add unrecognized metadata that corrupts the vault.
- **Background contexts**: All writes use background `NSManagedObjectContext` instances with `performAndWait` for data integrity.

## How It Works

Banktivity's `.bank8` bundle is a directory containing compiled Core Data models (`.momd` files) and a SQLite database (`StoreContent/core.sql`). This server:

1. Loads and merges all `.momd` model bundles from the vault
2. Opens the SQLite store via `NSPersistentContainer` (no history tracking)
3. Exposes 54 MCP tools over stdio transport
4. Uses KVC (`value(forKey:)`) to access entities since we load Banktivity's own compiled models at runtime

## License

[MIT](LICENSE)
