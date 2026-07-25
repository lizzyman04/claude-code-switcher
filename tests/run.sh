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

build_bin
test_shared_repair_from_native
test_doctor_flags_missing_shared
test_doctor_real_file_not_clobbered

echo ""
echo "$_pass passed, $_fail failed"
[[ $_fail -eq 0 ]]
