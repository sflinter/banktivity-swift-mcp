# banktivity-swift-mcp

A Swift library, [MCP](https://modelcontextprotocol.io/) server and CLI for [Banktivity](https://www.iggsoftware.com/banktivity/) personal finance vaults (`.bank8`). It reads and writes accounts, transactions, categories, tags, statements, securities, templates, import rules and scheduled transactions, and exports the vault as RDF.

- **banktivity-mcp**: MCP server exposing 77 tools over stdio, for AI assistants such as Claude
- **banktivity-cli**: standalone CLI for scripting and automation, with JSON output
- **BanktivityLib**: the Core Data repositories both are built on

Every write goes through Core Data (`NSPersistentContainer`), never direct SQL. The rules it follows (how amounts are counted, how running balances are kept, how changes reach other devices) were checked against Banktivity's own frameworks; see [How it works with Banktivity](#how-it-works-with-banktivity).

## Before you start

> **This tool modifies your financial records.** Write commands make real changes to your vault, and AI assistants can and will make mistakes. Back up the vault before any write session, and consider working on a copy until you trust your workflow. The authors are not responsible for data loss or corruption.

- **Quit Banktivity first.** Writes are refused while Banktivity has the vault open (detected with `lsof`). Close every `banktivity-mcp` and `banktivity-cli` process before opening the vault in Banktivity again.
- **One process per vault.** Writes are serialized within a process, which covers concurrent MCP tool calls, but this is not a cross-process lock. Never run two servers or CLIs against the same vault at once.
- **IDs are local to one store.** The numeric IDs returned are Core Data row IDs for the SQLite file you opened. The same record has a different ID on another Mac syncing the vault, and IDs can change after a restore, import or migration. An ID replayed elsewhere points at a *different real record*. Resolve IDs in the same session on the machine you are writing to, and read a row back before changing it. The stable identifier is `pUniqueID`.

## Requirements

- macOS 14 or later
- Banktivity 10. Behaviour has been verified against **Banktivity 10.2.2**.
- A Banktivity vault (`.bank8`)

### Finding your vault

Banktivity 10 keeps synced vaults in its app-group library, not in `~/Documents`:

```
~/Library/Group Containers/group.com.iggsoftware.banktivity.library/IGGFinance/production/Documents/<UUID>/1.bank8
```

`library.txt` in `.../IGGFinance/production/` lists the local documents by UUID. A symlink with a friendlier name is convenient:

```sh
ln -s ~/Library/Group\ Containers/group.com.iggsoftware.banktivity.library/IGGFinance/production/Documents/<UUID>/1.bank8 \
      ~/Documents/Banktivity/My\ Accounts.bank8
```

Reading the Group Container needs **Full Disk Access**, both for your terminal and for the installed `banktivity-cli` and `banktivity-mcp` binaries (System Settings → Privacy & Security → Full Disk Access). Without it you get `Operation not permitted`.

## Installation

### Homebrew (recommended)

```sh
brew install sflinter/tap/banktivity-swift-mcp
```

This installs `banktivity-mcp` and `banktivity-cli` as universal binaries (Apple Silicon and Intel).

### Download a release

Download the universal tarball from [GitHub Releases](https://github.com/sflinter/banktivity-swift-mcp/releases), extract it, and put both binaries on your `PATH`:

```sh
tar xzf banktivity-swift-mcp-vX.Y.Z-macos-universal.tar.gz
mv banktivity-mcp banktivity-cli ~/.local/bin/
```

### Build from source

Requires Xcode 16 or later (for Swift Testing and universal builds):

```sh
git clone https://github.com/sflinter/banktivity-swift-mcp.git
cd banktivity-swift-mcp
make install        # universal release build, installed to ~/.local/bin
```

`make install` signs the binaries with a code-signing identity named "Banktivity MCP Code Signing" if your keychain has one (override with `CODESIGN_IDENTITY=...`), otherwise ad hoc. macOS ties Full Disk Access to the signature, so with a stable identity the grant survives rebuilds; with ad-hoc signing you have to grant it again after each rebuild. A self-signed certificate with the code-signing extended key usage is enough.

## Configuration

| Variable | Purpose |
|---|---|
| `BANKTIVITY_FILE_PATH` | Path to the `.bank8` vault. The CLI also accepts `--vault`. |
| `BANKTIVITY_REPORTING_CURRENCY` | Currency that `get_net_worth` and `get_summary` convert every account into, using the vault's own exchange rates (default `EUR`). Accounts with no usable rate are left out and named in the response's warnings. |
| `BANKTIVITY_STORE_READ_ONLY` | `1`, `true` or `yes` opens the store read-only, so even SQLite housekeeping leaves the vault untouched. Writes then fail at the store layer. SQLite may still open `core.sql-shm` for writing, so treat this as an extra layer, not a substitute for backups. |

### Claude Code

```sh
claude mcp add banktivity \
  -e BANKTIVITY_FILE_PATH="$HOME/Documents/Banktivity/My Accounts.bank8" \
  -- "$HOME/.local/bin/banktivity-mcp"
```

Or add it to a project's `.mcp.json`:

```json
{
  "mcpServers": {
    "banktivity": {
      "command": "/Users/you/.local/bin/banktivity-mcp",
      "env": { "BANKTIVITY_FILE_PATH": "/Users/you/Documents/Banktivity/My Accounts.bank8" }
    }
  }
}
```

### Claude Desktop

Add the same `mcpServers` entry to `~/Library/Application Support/Claude/claude_desktop_config.json`. Claude Desktop runs `banktivity-mcp` itself, so that binary needs Full Disk Access (see [Finding your vault](#finding-your-vault)).

## CLI

Pass `--vault` or set `BANKTIVITY_FILE_PATH`. Output is pretty-printed JSON; `--format compact` gives single-line JSON.

```sh
banktivity-cli accounts list --vault ~/Documents/Banktivity/My\ Accounts.bank8
banktivity-cli accounts balance --account-name "Checking"
banktivity-cli transactions list --account-name "Checking" --start-date 2026-01-01 --limit 10
banktivity-cli transactions create --account-name "Checking" --date 2026-06-15 --title "Coffee" --amount -4.50 --category-name "Dining"
banktivity-cli statements status --account-name "Checking"
banktivity-cli securities realized-gains --account-id 41 --start-date 2025-01-01 --end-date 2025-12-31
banktivity-cli export turtle --output vault.ttl
```

| Group | Subcommands |
|---|---|
| `accounts` | `list`, `balance`, `net-worth`, `spending`, `income`, `summary`, `create`, `recalc-balances` |
| `transactions` | `list`, `search`, `get`, `create`, `update`, `delete`, `repair-forex`, `sync-info` |
| `line-items` | `get`, `add`, `update`, `delete` |
| `categories` | `list`, `get`, `tree`, `create`, `delete`, `audit-entities` |
| `uncategorized` | `list`, `suggest`, `recategorize`, `bulk-recategorize`, `review`, `payee-summary` |
| `tags` | `list`, `create`, `tag-transaction`, `get-by-tag`, `bulk-tag` |
| `statements` | `list`, `status`, `get`, `create`, `update`, `delete`, `reconcile`, `unreconcile`, `unreconciled` |
| `securities` | `list`, `create`, `delete`, `rename`, `prices`, `holdings`, `trades`, `realized-gains`, `income`, `create-trade`, `create-income`, `adjust`, `update-trade`, `import-prices`, `delete-prices`, `reset-price-range`, `fix-prices`, `audit-prices` |
| `templates` | `list`, `get`, `create`, `update`, `delete` |
| `import-rules` | `list`, `get`, `match`, `create`, `update`, `delete` |
| `scheduled` | `list`, `get`, `create`, `update`, `delete` |
| other | `export turtle`, `schema` |

Run `banktivity-cli <group> <subcommand> --help` for options. Most commands that take `--account-id` also take `--account-name`, and `transactions create` takes `--line-items` (a JSON array) for split transactions.

**Exit codes:** `0` success, `64` usage error, `65` validation failed (for example a zero share price or an unbalanced repair), `66` not found, `70` store failure, `77` write blocked (Banktivity has the vault open). Errors are printed to stderr as `Error: [category] message`.

**Shell completion:** `banktivity-cli --generate-completion-script zsh` (or `bash`, `fish`).

## MCP tools

Every tool advertises MCP annotations: `readOnlyHint` for reads, and `destructiveHint` true or false for writes. Clients can use these to tell reads from writes. Full input schemas are in [`skills/banktivity/references/tools.md`](skills/banktivity/references/tools.md).

| Area | Tools |
|---|---|
| Accounts | `list_accounts`, `get_account_balance`, `get_net_worth`, `get_summary`, `get_spending_by_category`, `get_income_by_category` |
| Transactions | `get_transactions`, `search_transactions`, `get_transaction`, `create_transaction`, `update_transaction`, `delete_transaction`, `repair_forex_transfer` |
| Line items | `get_line_item`, `add_line_item`, `update_line_item`, `delete_line_item` |
| Categories | `list_categories`, `get_category`, `get_category_tree`, `create_category`, `audit_category_entities` |
| Categorization | `get_uncategorized_transactions`, `suggest_category_for_merchant`, `recategorize_transaction`, `bulk_recategorize_by_payee`, `review_categorizations`, `get_payee_category_summary` |
| Tags | `get_tags`, `create_tag`, `tag_transaction`, `get_transactions_by_tag`, `bulk_tag_transactions` |
| Statements | `list_statements`, `get_statement`, `get_account_reconciliation_status`, `create_statement`, `update_statement`, `delete_statement`, `reconcile_line_items`, `unreconcile_line_items`, `get_unreconciled_line_items` |
| Securities | `list_securities`, `create_security`, `rename_security`, `delete_security`, `get_security_prices`, `import_security_prices`, `delete_security_prices`, `reset_security_price_range`, `audit_security_prices`, `get_security_holdings`, `get_security_trades`, `get_security_income`, `get_security_realized_gains`, `create_security_trade`, `update_security_trade`, `create_security_income`, `create_share_adjustment` |
| Templates | `list_transaction_templates`, `get_transaction_template`, `create_transaction_template`, `update_transaction_template`, `delete_transaction_template` |
| Import rules | `list_import_rules`, `get_import_rule`, `match_import_rules`, `create_import_rule`, `update_import_rule`, `delete_import_rule` |
| Scheduled | `list_scheduled_transactions`, `get_scheduled_transaction`, `create_scheduled_transaction`, `update_scheduled_transaction`, `delete_scheduled_transaction` |
| Export and diagnostics | `export_turtle`, `dump_schema` |

## How it works with Banktivity

A `.bank8` vault is a directory holding Banktivity's compiled Core Data models (`.momd`) and a SQLite store (`StoreContent/core.sql`). The tool loads Banktivity's own models at runtime and accesses entities by key-value coding (properties are `p`-prefixed, e.g. `pName`, `pDate`). The behaviours below were read from Banktivity 10.2.2's frameworks and checked against a real vault.

- **Sync.** Banktivity uploads a record when its `pModificationDate` is newer than the last sync. Each record's stored sync copy is the base of a three-way merge, so the tool never rewrites it: doing so would let a remote copy silently undo an edit. Every write marks the owning transaction or security as modified. New records get a sync record, and deletions are marked so that Banktivity removes them from other devices. Persistent history tracking is never enabled; it adds metadata Banktivity doesn't recognize.
- **Amounts.** Balances and statement totals use Banktivity's own per-line rule. An investment transaction counts its security line's amount plus income, not the line item's own amount; everything else is amount × exchange rate. Investment account balances are cash; holdings market value is reported separately as `holdingsValue`.
- **Running balances.** The desktop app shows an account's cash from the running balance cached on each line. It isn't synced, so every write recalculates it for the accounts it touched, from the earliest changed date. `accounts recalc-balances` repairs balances that are already stale.
- **Share prices.** A device that receives a trade writes its price per share into that security's price history, zero included. A trade priced at 0 therefore makes other devices value the whole holding at 0. Buys and sells must have a positive price (or one derived from the amount), and `securities audit-prices` finds existing zero-priced trades.
- **Statements** in Banktivity have no names: statements created in the app are unnamed. Only statements created with `--name` carry one.
- **Write guard.** Before any write, the tool checks with `lsof` whether Banktivity has the vault open and refuses if it does. Writes run on background contexts, and each read uses a fresh one.

## Claude Code skill

A `/banktivity` [skill](https://docs.anthropic.com/en/docs/claude-code/skills) lets Claude use the CLI to answer questions such as "What did I spend on groceries last month?". Install it into your global config and set your vault path in `SKILL.md`:

```sh
mkdir -p ~/.claude/skills
cp -r skills/banktivity ~/.claude/skills/banktivity
```

Claude then uses it automatically for questions about accounts, transactions, spending or categories, or you can invoke it with `/banktivity`.

## Development

```sh
make build          # debug build
make test           # all tests, release configuration, single worker, Xcode toolchain
make test-filter FILTER=TurtleWriter
make release        # universal release build (arm64 + x86_64)
make package        # release tarball with its SHA-256
make help           # all targets
```

Tests use Swift Testing, which the Command Line Tools don't ship, so they run with the Xcode toolchain (`make test` sets this up). Most suites build a fresh vault from `Tests/Fixtures`; integration tests that need a real vault skip when it is absent. [`CLAUDE.md`](CLAUDE.md) documents the architecture and the rules a change must keep, such as never patching sync blobs and never writing a zero share price.

## Credits

Inspired by [banktivity-mcp](https://github.com/mhriemers/banktivity-mcp) (TypeScript), which reads and writes Core Data's SQLite store directly. This Swift rewrite goes through Core Data so that changes are tracked and sync properly.

## License

[MIT](LICENSE)
