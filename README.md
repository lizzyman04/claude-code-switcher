<div align="center">

# `ccs` — Claude Code Switcher

**Switch LLM providers in Claude Code with one command.**  
No config files touched. No mess. No restarts.

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

Then add this to your PowerShell profile (`$PROFILE`):

```powershell
Set-Alias ccs "$env:USERPROFILE\.local\bin\ccs.ps1"
```

---

Open a new terminal, then:

```bash
ccs
```

Done. Your providers are listed. The installer handles profiles, the active symlink, and shell aliases — zero manual setup.

---

## Commands

| Command | What it does |
| :--- | :--- |
| `ccs` | List all profiles |
| `ccs <name>` | Switch to provider by name (shorthand for `switch`) |
| `ccs switch <name>` | Set the active provider |
| `ccs current` | Show active profile (API key hidden) |
| `ccs add <name>` | Add a new provider interactively |
| `ccs key <name>` | Update an API key in seconds |
| `ccs edit <name>` | Open a profile in `$EDITOR` |
| `ccs remove <name>` | Delete a profile |
| `ccs test` | Ping the active provider — real API call |
| `ccs run <name> [args]` | Run claude with a named profile |
| `ccs run --provider <p> --model <m>` | Run without a saved profile (ephemeral) |
| `ccs clean [name]` | Launch Claude Code with no custom agents/skills |
| `ccs --help` | Show help |

---

## Shell Aliases

The installer writes these to your `.bashrc` / `.zshrc`:

```bash
alias claude='claude --settings $HOME/.config/claude-profiles/active'
alias deepseek='ccs run deepseek'
```

After `ccs switch deepseek`, `claude` talks to DeepSeek. No flags, no env vars.

---

## Clean Mode

Need a session without your custom agents, skills, and memory files eating context tokens?

```bash
ccs clean           # clean session with active provider
ccs clean deepseek  # clean session with DeepSeek
```

Everything is restored when you exit. Nothing is deleted.

---

## How It Works

Profiles are JSON files in `~/.config/claude-profiles/profiles/`.  
A symlink at `~/.config/claude-profiles/active` points to whichever profile is current.

Claude is always invoked as:

```
claude --settings ~/.config/claude-profiles/active
```

`~/.claude/` is **never touched.** `ccs` lives entirely in `~/.config/claude-profiles/`.

```
~/.config/claude-profiles/
├── profiles/
│   ├── anthropic.json
│   └── deepseek.json
└── active -> profiles/anthropic.json   ← just a symlink
```

Switching providers = updating the symlink. That's the whole trick.

---

## Requirements

- **[Claude Code](https://code.claude.com/docs)** — in `PATH`
- **[jq](https://jqlang.org/)** — for `current`, `key`, and `test`
- **[curl](https://curl.se/)** — for `test` and the installer
- **PowerShell 5.1+** — Windows only

---

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

<div align="center">

Issues and PRs welcome — [open one here](https://github.com/lizzyman04/claude-code-switcher/issues)

</div>