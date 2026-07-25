<div align="center">

# `ccs` — Claude Code Switcher

**Switch LLM providers — and Claude accounts — with one command.**  
Two Pro subscriptions, no `/logout`. No mess. No restarts.

[![bash](https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![requires jq](https://img.shields.io/badge/requires-jq-333?style=flat-square&logo=json&logoColor=white)](https://stedolan.github.io/jq/)
[![requires curl](https://img.shields.io/badge/requires-curl-073551?style=flat-square&logo=curl&logoColor=white)](https://curl.se/)
[![license MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

</div>

---

## Install

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/claude-code-switcher/main/install.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/lizzyman04/claude-code-switcher/main/install.ps1 | iex
```

The installer writes both the `ccs` alias and the `claude` function into your
`$PROFILE`, so there is nothing to add by hand. Directory sharing uses junctions
and hard links rather than symlinks, so **no elevation and no Developer Mode are
required**.

> The PowerShell implementation mirrors the shell one command for command, but it
> has had far less real-world use. If something looks wrong, please
> [open an issue](https://github.com/lizzyman04/claude-code-switcher/issues).

---

Open a new terminal, then:

```bash
ccs
```

Done. Your providers are listed. The installer handles profiles, the active symlink, and the shell integration — zero manual setup.

---

## Two Claude accounts, one command

Hit the limit on one Pro subscription? Add the second one once:

```bash
ccs login anthropic@second
```

Then, forever after:

```bash
ccs next
```

That is the whole feature. `ccs next` rotates to the next account **of the
current provider** — no `/logout`, no browser, no re-authentication. Both
accounts stay logged in simultaneously, and you can run a session on each at the
same time in different terminals.

```bash
$ ccs accounts
   ACCOUNT                IDENTITY                       BG AGENTS
*  anthropic@main         you@example.com                yes
   anthropic@second       you+work@example.com           no
   deepseek@main          api key                        yes
```

Your session history is shared, so `claude --resume` finds the session you were
just in even if you rotated accounts mid-task.

`ccs next` never crosses provider boundaries — switching provider changes model
and billing, so that stays explicit.

---

## Commands

`<p>` is a provider, `<a>` an account. Every command taking a provider also
accepts `<provider>@<account>`; a bare provider means its last-used account.

| Command | What it does |
| :--- | :--- |
| `ccs` | List providers and accounts, marking the active one |
| `ccs <p>[@<a>]` | Switch (shorthand for `switch`) |
| `ccs next` | Rotate to the next account of the **current** provider |
| `ccs login <p>[@<a>]` | Sign in to an account — creates it if needed |
| `ccs logout <p>@<a>` | Clear one account's credentials |
| `ccs accounts [<p>]` | List accounts with identity and daemon availability |
| `ccs current` | Active provider, account, email (API key hidden) |
| `ccs switch <p>[@<a>]` | Set the active account |
| `ccs add <p>[@<a>]` | Add a new profile interactively |
| `ccs key <p>[@<a>]` | Update an API key in seconds |
| `ccs edit <p>[@<a>]` | Open a profile in `$EDITOR` |
| `ccs remove <p>[@<a>]` | Delete an account, or a whole provider |
| `ccs test [<p>[@<a>]]` | Real API call, or login status for OAuth accounts |
| `ccs run <p>[@<a>] [args]` | Run claude with a specific account |
| `ccs run --provider <p> --model <m>` | Run without a saved profile (ephemeral) |
| `ccs clean [<p>[@<a>]]` | Launch Claude Code with no custom agents/skills |
| `ccs doctor` | Check the shell integration, links and credential modes |
| `ccs --help` | Show help |

---

## Shell Integration

The installer writes this to your `.bashrc` **and** `.zshrc`, between
`# >>> ccs …` markers:

```bash
claude() { ...; CLAUDE_CONFIG_DIR="$target" command claude --settings "$active" "$@"; }
alias deepseek='ccs run deepseek'
```

After `ccs deepseek`, `claude` talks to DeepSeek. After `ccs next`, it talks to
your other account. No flags, no env vars.

**It has to be a function, not an alias.** Claude Code reads
`CLAUDE_CONFIG_DIR` from the environment before it loads any settings file, so
that variable must be exported by the shell — and an alias cannot export
anything. Earlier versions of `ccs` shipped
`alias claude='claude --settings …'`; the installer detects and removes it,
backing up your rc file first.

If `type claude` does not say **`claude is a function`**, run:

```bash
ccs shell-install     # then open a new terminal
```

`ccs switch` and `ccs next` refuse outright rather than silently send you to the
wrong account when the integration is missing. `ccs run <p>@<a>` always works
regardless, because it sets the config dir in its own process.

---

## Clean Mode

Need a session without your custom agents and skills eating context tokens?

```bash
ccs clean                   # active account
ccs clean deepseek          # a specific provider
ccs clean anthropic@second  # a specific account
ccs clean --restore         # recover after a crashed session
```

Everything is restored when you exit. Nothing is deleted.

For an isolated account this only removes that account's own links, so another
account's live session is unaffected. For `anthropic@main` — whose config dir
*is* `~/.claude` — the directories are real rather than links, so a concurrent
session on another account loses them until this one exits. `ccs clean` says
which case applies.

---

## How It Works

Each account owns a settings file. A symlink at
`~/.config/claude-profiles/active` points at the current one, and a second
symlink, `active-home`, points at that account's config directory.

```
~/.config/claude-profiles/
├── profiles/
│   ├── anthropic/
│   │   ├── profile.json          auth kind, default/last/native account
│   │   └── accounts/
│   │       ├── main.json         ← {"env": {}} — OAuth has no API key
│   │       └── second.json
│   └── deepseek/
│       ├── profile.json
│       └── accounts/main.json    ← {"env": {"ANTHROPIC_AUTH_TOKEN": "…"}}
├── homes/
│   └── anthropic-second/         ← this account's CLAUDE_CONFIG_DIR
├── shared/                       ← links into ~/.claude
├── backups/
├── active       -> profiles/anthropic/accounts/main.json
└── active-home  -> ~/.claude
```

Switching a **provider** updates `active`. Switching an **account** also updates
`active-home`, and the shell function exports it as `CLAUDE_CONFIG_DIR`.

Every switch also rebuilds `shared/`, from **any** account including
`anthropic@main`, so a link that went missing is repaired by the next `ccs <p>`.
`ccs doctor` reports anything it cannot repair on its own — in particular real
content sitting where a shared link belongs, which is never overwritten because
your version and the canonical one may differ.

### Why accounts need a whole directory

For DeepSeek or OpenRouter an account is just a different API key, and that fits
in the settings file. For a Claude Pro login there is **no API key** — that is
why `anthropic/accounts/main.json` is `{"env": {}}`. The credentials live in
`<config-dir>/.credentials.json`, or on macOS in a Keychain entry whose name is
derived from the config directory path. Nothing in a settings file can point at
them. Giving each account its own `CLAUDE_CONFIG_DIR` is the only way to keep
two logins side by side.

### About `~/.claude/`

Earlier versions of this README claimed `~/.claude/` is *never touched*. That
was never quite true and is now plainly not, so here is what actually happens:

- **`~/.claude/` is the `anthropic@main` account's live config directory.** It is
  not a copy and not a sandbox. That account runs with `CLAUDE_CONFIG_DIR`
  **unset**, exactly as Claude Code does without `ccs`.
- `ccs` does not restructure it. The links live in `shared/` and *point into*
  `~/.claude/`; those are what get linked into the sibling homes under `homes/`.
  Your files stay exactly where they are.
- Claude Code itself writes to `~/.claude/` while that account is active — as it
  always did. Because `settings.json`, `agents/`, `skills/`, `commands/`,
  `plugins/`, `projects/`, `history.jsonl` and your `*.md` memory files are
  shared, an edit made from *any* account lands in `~/.claude/`. That is the
  point: one source of truth, not per-account copies.
- **`ccs clean` on `anthropic@main` moves `~/.claude/agents` and
  `~/.claude/skills` aside** for the life of that session, and restores them on
  exit. For any other account it only removes that account's own symlinks, so
  nothing shared is at risk. `ccs clean` tells you which case you are in.
- Additional accounts under `homes/` **are** fully isolated. `ccs` never creates
  or deletes real files in `~/.claude/`.

### Why the first account isn't isolated

It would be tidier to give every account its own directory. It also costs a
feature: a custom `CLAUDE_CONFIG_DIR` **disables Claude Code's background-agent
daemon**, and `claude daemon service install` refuses to run at all. So one
account per OAuth provider — `native_account` in `profile.json` — deliberately
stays on the default directory and keeps working normally. `ccs accounts` shows
this per account in its `BG AGENTS` column, and switching into an isolated
account says so.

### Shared vs per-account

| Shared across accounts | Per-account |
| :--- | :--- |
| `agents/` `skills/` `commands/` `plugins/` | `.credentials.json` |
| `settings.json`, all top-level `*.md` | `.claude.json` (identity, trust flags) |
| `projects/` (so `--resume` works) | `sessions/` (live-PID registry) |
| `history.jsonl`, `todos/`, `session-env/` | `shell-snapshots/`, `file-history/` |

One consequence worth knowing: `.claude.json` holds the account identity, so it
cannot be shared — and it also stores per-project trust flags. A second account
therefore asks you to trust each folder once.

### Upgrading from a single-account install

Nothing to do. On first run `ccs` migrates `profiles/<name>.json` to the new
layout, after copying the whole tree to
`~/.config/claude-profiles/backups/pre-multiaccount-<timestamp>/`. It is
idempotent, and your existing Anthropic login is untouched — it becomes
`anthropic@main` and stays on `~/.claude`.

---

## Testing it

[`docs/TESTING-multi-account.md`](docs/TESTING-multi-account.md) is a
step-by-step run that proves two Pro accounts coexist without a logout,
including cross-account `--resume`.

---

## Requirements

- **[Claude Code](https://code.claude.com/docs)** — in `PATH`
- **[jq](https://jqlang.org/)** — for `switch`, `current`, `key` and `test`.
  `ccs`, `ccs accounts` and the automatic migration deliberately work without it,
  so a box missing `jq` can still list and migrate.
- **[curl](https://curl.se/)** — for `test` and the installer
- **PowerShell 5.1+** — Windows only
- **bash or zsh** — the shell integration is a function, so a POSIX-only `sh`
  will not do

---

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

<div align="center">

Issues and PRs welcome — [open one here](https://github.com/lizzyman04/claude-code-switcher/issues)

</div>