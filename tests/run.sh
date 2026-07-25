#!/usr/bin/env bash
# Regression tests for ccs.
#
# Every test runs the built binary against a throwaway HOME under a temp dir, so
# nothing here can see or touch a real ~/.config/claude-profiles -- which on a
# developer's machine holds authenticated accounts.
#
# Usage: tests/run.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccs-tests-XXXXXX")"
BIN="$WORK/ccs"
trap 'rm -rf "$WORK"' EXIT

_pass=0
_fail=0
ok()  { echo "  PASS  $1"; _pass=$((_pass + 1)); }
bad() { echo "  FAIL  $1"; _fail=$((_fail + 1)); }
check() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi
}

# Build the binary the way install.sh does -- MANIFEST order, one entry point --
# so the tests exercise the shipped artifact, not ./ccs.sh.
build_bin() {
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo ''
    while IFS= read -r f; do
      [[ -z "$f" || "$f" == \#* ]] && continue
      cat "$REPO/src/$f"
      echo ''
    done < "$REPO/src/MANIFEST"
    echo 'ccs_main "$@"'
  } > "$BIN"
  chmod +x "$BIN"
}

# A fake HOME in the current layout: anthropic (oauth, native main) with two
# accounts, deepseek (token).
new_home() {
  local h="$WORK/$1"
  rm -rf "$h"
  mkdir -p "$h/.claude/agents" "$h/.claude/skills" \
           "$h/.config/claude-profiles/profiles/anthropic/accounts" \
           "$h/.config/claude-profiles/profiles/deepseek/accounts"
  printf '{"hooks":{}}\n' > "$h/.claude/settings.json"
  printf '# memory\n'     > "$h/.claude/CLAUDE.md"
  printf '{}\n'           > "$h/.claude/agents/a.json"

  local p="$h/.config/claude-profiles/profiles"
  printf '{\n  "env": {}\n}\n' > "$p/anthropic/accounts/main.json"
  printf '{\n  "env": {}\n}\n' > "$p/anthropic/accounts/second.json"
  cat > "$p/anthropic/profile.json" << 'EOF'
{
  "auth": "oauth",
  "default_account": "main",
  "last_account": "main",
  "native_account": "main"
}
EOF
  cat > "$p/deepseek/accounts/main.json" << 'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "not-a-real-key",
    "ANTHROPIC_MODEL": "deepseek-chat"
  }
}
EOF
  cat > "$p/deepseek/profile.json" << 'EOF'
{
  "auth": "token",
  "default_account": "main",
  "last_account": "main"
}
EOF
  echo "$h"
}

# A fake HOME in the old flat layout, for the migration tests.
new_flat_home() {
  local h="$WORK/$1"
  rm -rf "$h"
  mkdir -p "$h/.claude/agents" "$h/.config/claude-profiles/profiles"
  printf '{"hooks":{}}\n' > "$h/.claude/settings.json"
  printf '{}\n'           > "$h/.claude/agents/a.json"
  local p="$h/.config/claude-profiles/profiles"
  printf '{\n  "env": {}\n}\n' > "$p/anthropic.json"
  cat > "$p/deepseek.json" << 'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "not-a-real-key",
    "ANTHROPIC_MODEL": "deepseek-chat"
  }
}
EOF
  ln -s "$p/anthropic.json" "$h/.config/claude-profiles/active"
  echo "$h"
}

# CCS_WRAPPER marks the shell integration as loaded, so switch is not refused.
ccs_in() {
  local h="$1"; shift
  HOME="$h" CCS_WRAPPER=1 "$BIN" "$@"
}

# ── #13: shared/ must be repairable from the native account ──────────────────
#
# _prepare_home and _link_shared both return early for the native home, so
# before the fix a switch to anthropic@main rebuilt nothing and the item stayed
# missing -- while every isolated home's link to it dangled.
test_shared_repair_from_native() {
  echo "shared/ repair from the native account (#13)"
  local h c
  h="$(new_home shared-native)"
  c="$h/.config/claude-profiles"

  ccs_in "$h" anthropic@second > /dev/null 2>&1
  [[ -L "$c/shared/settings.json" ]] && ok "shared/settings.json linked after switch" \
                                     || bad "shared/settings.json linked after switch"

  rm -f "$c/shared/settings.json"
  ccs_in "$h" anthropic@main > /dev/null 2>&1
  if [[ -L "$c/shared/settings.json" && -e "$c/shared/settings.json" ]]; then
    ok "switching to the NATIVE account rebuilds shared/settings.json"
  else
    bad "switching to the NATIVE account rebuilds shared/settings.json"
  fi

  # The isolated home's link is only useful if it resolves again afterwards.
  rm -f "$c/shared/agents"
  ccs_in "$h" anthropic@main > /dev/null 2>&1
  [[ -e "$c/homes/anthropic-second/agents" ]] \
    && ok "the isolated home's link resolves again after a native repair" \
    || bad "the isolated home's link resolves again after a native repair"
}

# A missing shared/<item> used to be reported as "links intact".
test_doctor_flags_missing_shared() {
  echo "doctor FAILs on a missing shared item (#13)"
  local h c out
  h="$(new_home shared-doctor)"
  c="$h/.config/claude-profiles"
  ccs_in "$h" anthropic@second > /dev/null 2>&1
  rm -f "$c/shared/settings.json" "$c/homes/anthropic-second/settings.json"

  out="$(ccs_in "$h" doctor 2>&1)" || true
  grep -q "FAIL  shared/settings.json is missing" <<< "$out" \
    && ok "missing shared/settings.json is a FAIL" \
    || bad "missing shared/settings.json is a FAIL"
  grep -q "settings.json is not linked into this account" <<< "$out" \
    && ok "an absent home link is a FAIL" \
    || bad "an absent home link is a FAIL"
  grep -q "^result: problems found" <<< "$out" \
    && ok "doctor exits with problems found" \
    || bad "doctor exits with problems found"
}

# A real file where a shared link belongs must never be discarded.
test_doctor_real_file_not_clobbered() {
  echo "doctor reports a degraded shared item without discarding it (#13)"
  local h c out
  h="$(new_home shared-real)"
  c="$h/.config/claude-profiles"
  ccs_in "$h" anthropic@second > /dev/null 2>&1
  rm -f "$c/shared/settings.json"
  printf '{"hooks":{"custom":1}}\n' > "$c/shared/settings.json"

  out="$(ccs_in "$h" doctor 2>&1)" || true
  grep -q "FAIL  shared/settings.json is a real file" <<< "$out" \
    && ok "a real file in shared/ is a FAIL" \
    || bad "a real file in shared/ is a FAIL"

  ccs_in "$h" anthropic@main > /dev/null 2>&1
  check "the real file's content survives a switch" \
    "$(cat "$c/shared/settings.json")" '{"hooks":{"custom":1}}'
}

# ── #11: active-home ─────────────────────────────────────────────────────────
#
# Migration created `active` but not `active-home`, and doctor never looked at
# active-home at all -- so the file wrong-account routing depends on could be
# absent, dangling or mismatched and every check still passed.
test_migration_creates_both_links() {
  echo "migration creates active and active-home (#11)"
  local h c
  h="$(new_flat_home migrate-links)"
  c="$h/.config/claude-profiles"

  ccs_in "$h" list > /dev/null 2>&1
  [[ -L "$c/active" ]]      && ok "active exists"      || bad "active exists"
  [[ -L "$c/active-home" ]] && ok "active-home exists" || bad "active-home exists"
  [[ -d "$c/active-home" ]] && ok "active-home resolves to a directory" \
                            || bad "active-home resolves to a directory"
  # anthropic had no base URL, so it migrated as oauth with native_account=main:
  # its home is the default dir, not a sibling under homes/.
  check "active-home points at the native home" \
    "$(cd -P "$c/active-home" 2>/dev/null && pwd -P)" "$(cd -P "$h/.claude" && pwd -P)"

  # Idempotence: a second run must not disturb either link.
  ccs_in "$h" list > /dev/null 2>&1
  [[ -L "$c/active-home" && -d "$c/active-home" ]] \
    && ok "active-home survives a second run" || bad "active-home survives a second run"
}

test_doctor_flags_dangling_active_home() {
  echo "doctor FAILs on a dangling active-home (#11)"
  local h c out
  h="$(new_home dangling-home)"
  c="$h/.config/claude-profiles"
  ccs_in "$h" anthropic@second > /dev/null 2>&1

  # Exactly the fail-open case: the wrapper guards with `[[ -d "$_h" ]]`, which
  # follows the link, so this state routes to the default account in silence.
  ln -sfn "$c/homes/anthropic-gone" "$c/active-home"
  out="$(ccs_in "$h" doctor 2>&1)" || true
  grep -q "FAIL  active-home is dangling" <<< "$out" \
    && ok "a dangling active-home is a FAIL" || bad "a dangling active-home is a FAIL"
  grep -q "^result: problems found" <<< "$out" \
    && ok "doctor reports problems" || bad "doctor reports problems"

  rm -f "$c/active-home"
  out="$(ccs_in "$h" doctor 2>&1)" || true
  grep -q "FAIL  active-home is missing" <<< "$out" \
    && ok "a missing active-home is a FAIL" || bad "a missing active-home is a FAIL"

  # Mismatch: points at a real directory, but not the active account's.
  ln -sfn "$h/.claude" "$c/active-home"
  out="$(ccs_in "$h" doctor 2>&1)" || true
  grep -q "FAIL  active-home points at" <<< "$out" \
    && ok "a mismatched active-home is a FAIL" || bad "a mismatched active-home is a FAIL"

  ccs_in "$h" anthropic@second > /dev/null 2>&1
  out="$(ccs_in "$h" doctor 2>&1)" || true
  grep -q "ok    active-home resolves" <<< "$out" \
    && ok "a switch repairs active-home" || bad "a switch repairs active-home"
}

# ── #14: a no-op switch must not claim it switched ───────────────────────────
#
# A bare provider resolves to last_account, so `ccs anthropic` can mean a real
# switch one minute and nothing at all the next. It printed "Switched to ..."
# either way.
test_noop_switch_message() {
  echo "a no-op switch says so (#14)"
  local h out c
  h="$(new_home noop)"
  c="$h/.config/claude-profiles"

  out="$(ccs_in "$h" anthropic@second 2>/dev/null)"
  check "an actual switch still says Switched to" \
    "$(grep -c '^Switched to anthropic@second$' <<< "$out")" "1"

  # The bare provider resolves to last_account, which is now second.
  out="$(ccs_in "$h" anthropic 2>/dev/null)"
  check "a bare provider resolving to the current account says Already on" \
    "$(grep -c '^Already on anthropic@second$' <<< "$out")" "1"
  check "and does not claim a switch" \
    "$(grep -c '^Switched to' <<< "$out")" "0"

  out="$(ccs_in "$h" anthropic@main 2>/dev/null)"
  check "switching accounts within a provider still says Switched to" \
    "$(grep -c '^Switched to anthropic@main$' <<< "$out")" "1"

  # A single-account provider keeps the bare label, in both wordings.
  out="$(ccs_in "$h" deepseek 2>/dev/null)"
  check "a single-account provider says Switched to <provider>" \
    "$(grep -c '^Switched to deepseek$' <<< "$out")" "1"
  out="$(ccs_in "$h" deepseek 2>/dev/null)"
  check "and Already on <provider> when repeated" \
    "$(grep -c '^Already on deepseek$' <<< "$out")" "1"

  # The idempotent repair work must still run on a no-op, since that is what
  # heals a degraded home.
  ccs_in "$h" anthropic@second > /dev/null 2>&1
  rm -f "$c/shared/settings.json" "$c/homes/anthropic-second/settings.json"
  out="$(ccs_in "$h" anthropic 2>/dev/null)"
  check "a no-op still reports itself as a no-op" \
    "$(grep -c '^Already on anthropic@second$' <<< "$out")" "1"
  [[ -L "$c/shared/settings.json" && -e "$c/homes/anthropic-second/settings.json" ]] \
    && ok "a no-op still repairs shared links" || bad "a no-op still repairs shared links"
}

build_bin
test_noop_switch_message
test_migration_creates_both_links
test_doctor_flags_dangling_active_home
test_shared_repair_from_native
test_doctor_flags_missing_shared
test_doctor_real_file_not_clobbered

echo ""
echo "$_pass passed, $_fail failed"
[[ $_fail -eq 0 ]]
