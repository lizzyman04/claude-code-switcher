# Manual test: two Anthropic accounts, no logout

Confirms that two Claude Pro subscriptions coexist and that `ccs next` rotates
between them without a logout or a browser round-trip.

You need **two Claude accounts** (two Pro subscriptions, or one Pro and one
Console account). Steps 1–5 are the core; 6–12 cover the edges.

Run it from any git repository. Nothing here deletes anything, and step 0 gives
you a way back.

---

## 0. Baseline

```bash
ccs --help          # should list: next, login, logout, accounts, doctor
ccs                 # your providers
ccs current         # should show your existing account and "Wrapper: active"
ls -la ~/.claude/.credentials.json
```

Note that credentials file's **mtime**. It must not change in step 2.

If `ccs current` says `Wrapper: NOT LOADED`, run `ccs shell-install`, then open a
new terminal. If you have an old install, `ccs` prints a one-line migration
notice and the backup path on first run — that backup is your way back.

Expected from `ccs current`:

```
Provider: anthropic
Account:  main
Auth:     oauth
Email:    <your first account>
Home:     /home/you/.claude
Wrapper:  active
```

`Home` being `~/.claude` is deliberate — see the README section on why the first
account is not isolated.

---

## 1. Confirm the shell integration is a function, not an alias

```bash
type claude
```

Must say **`claude is a function`**. If it says `aliased to ...`, run
`unalias claude` and open a new terminal — an alias cannot export
`CLAUDE_CONFIG_DIR`, and it would shadow the function.

---

## 2. Add the second account

```bash
ccs login anthropic@second
```

A browser opens. **Sign in with your second account.** Then:

```bash
ls -la ~/.config/claude-profiles/homes/anthropic-second/
ls -la ~/.claude/.credentials.json
```

Expected:

- `homes/anthropic-second/.credentials.json` exists and is **mode `-rw-------`**
  (on macOS it will be absent — the token is in the Keychain, which is correct)
- `homes/anthropic-second/.claude.json` exists
- `~/.claude/.credentials.json` **mtime is unchanged from step 0** — the first
  account was not touched

You should also have seen the daemon warning:

```
ccs: background agents and the daemon are unavailable on isolated
ccs: accounts (Claude Code requires the default config dir)
```

---

## 3. Both accounts are visible at once

```bash
ccs accounts
```

Expected — two **different** emails, no logout having happened:

```
   ACCOUNT                IDENTITY                       BG AGENTS
*  anthropic@main         first@example.com              yes
   anthropic@second       second@example.com             no
   deepseek@main          api key                        yes
```

---

## 4. Rotate — the actual point of all this

```bash
ccs next     && ccs current | head -5
ccs next     && ccs current | head -5
```

The `Email:` line must alternate between your two accounts. **No browser, no
`/logout`, no re-authentication.**

---

## 5. Two live sessions, two accounts, simultaneously

In terminal A:

```bash
ccs anthropic@main
claude
```

Type `/status` and note the account email.

In terminal B, leaving A running:

```bash
ccs anthropic@second
claude
```

`/status` here must show the **other** email. Two Claude Code sessions, two
subscriptions, at the same time.

> The second account asks for folder trust once per repository. That is expected:
> trust flags live in `.claude.json`, which is per-account because it also holds
> the account identity.

---

## 6. Cross-account resume

This is what makes rotating mid-task useful.

```bash
ccs anthropic@main
claude          # ask it anything, so the session is recorded, then exit
ccs next
claude --resume
```

The session you just had under `main` must appear in the list and be resumable
under `second`. If it does not, that is a bug — report it rather than working
around it.

---

## 7. The wrapper guard

Silent wrong-account routing is the worst thing this feature could do, so it is
guarded. In a throwaway terminal:

```bash
unalias claude 2>/dev/null
unset CCS_WRAPPER
ccs anthropic@second
```

Must **refuse**, with instructions. Then confirm the escape hatch still works:

```bash
ccs run anthropic@second --version
```

That works with no shell integration at all, because it sets the config dir in
its own process.

---

## 8. `ccs clean` affects one account only

This was previously broken: cleaning any account disabled agents and skills for
all of them.

Terminal A:

```bash
ccs anthropic@main
claude          # leave it running
```

Terminal B:

```bash
ccs clean anthropic@second
```

Inside B's session your custom agents and skills are gone. Terminal A still has
them, and so does `ls ~/.claude/agents`. Exit B; its links come back.

Cleaning `anthropic@main` **does** briefly affect other accounts, because there
those directories are real rather than links — `ccs clean` warns when that is the
case.

---

## 9. Crash recovery

```bash
ccs clean anthropic@second
# kill the terminal window outright, rather than exiting
ccs clean --restore
ccs doctor
```

`doctor` must report the shared links intact.

---

## 10. Token providers still work

```bash
ccs deepseek
ccs test
ccs anthropic
```

---

## 11. `ccs doctor`

```bash
ccs doctor
```

Everything `ok`, except the expected `background agents unavailable` note on
isolated accounts.

---

## 12. Installer idempotence

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/claude-code-switcher/main/install.sh | bash
grep -c '>>> ccs (claude-code-switcher) >>>' ~/.bashrc   # 1
grep -c '^alias claude=' ~/.bashrc                       # 0
grep -c "^alias deepseek=" ~/.bashrc                     # 1
ccs accounts                                             # both emails still there
```

Exactly one integration block, no leftover legacy alias, the `deepseek` alias
preserved, and no account lost.

---

## If something fails

`ccs doctor` first. Then:

- **`Wrapper: NOT LOADED`** — `ccs shell-install`, new terminal, `type claude`.
- **`claude is aliased to ...`** — `unalias claude`, new terminal.
- **wrong account in a session** — `ccs current` shows the *real* identity of the
  active account, read from its config dir. If that is right but the session
  disagrees, the wrapper is not in effect in that terminal.
- **a migration went wrong** — `~/.config/claude-profiles/backups/pre-multiaccount-*/`
  holds the pre-migration `profiles/` verbatim.
