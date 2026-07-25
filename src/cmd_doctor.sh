_doctor_ok=0
_doctor_warn=0

_d_pass() { echo "  ok    $1"; }
_d_warn() { echo "  warn  $1"; _doctor_warn=$((_doctor_warn + 1)); }
_d_fail() { echo "  FAIL  $1"; _doctor_ok=1; }

# True when the shell integration is loaded in the calling shell. ccs is a
# separate process, so this is the only thing it can actually observe -- it
# cannot inspect the parent shell's aliases or functions.
_wrapper_loaded() { [[ -n "${CCS_WRAPPER:-}" ]]; }

_require_wrapper() {
  local target_home="$1" what="$2"
  _wrapper_loaded && return 0

  # An isolated home is only reachable through the wrapper. Without it, claude
  # would silently run the previous account -- so refuse rather than pretend.
  if ! _is_native_home "$target_home"; then
    echo "error: the ccs shell integration is not loaded in this shell." >&2
    echo "       $what needs it to export CLAUDE_CONFIG_DIR; without it claude" >&2
    echo "       would keep using the previous account." >&2
    echo "" >&2
    echo "  Fix:  open a new terminal, or:  source ~/.bashrc && unalias claude" >&2
    echo "  Set up: ccs shell-install" >&2
    echo "  Or run without the wrapper:  ccs run <provider>@<account>" >&2
    return 1
  fi

  # The default home needs no exported variable, so there is no wrong-account
  # risk here. Warn, but do not lock the user out of their own tool.
  echo "ccs: warning: shell integration not loaded — 'claude' will not pick up" >&2
  echo "ccs:          the active settings. Run: ccs shell-install" >&2
  return 0
}

cmd_doctor() {
  echo "ccs doctor"
  echo ""

  echo "shell integration"
  if _wrapper_loaded; then
    _d_pass "loaded in this shell (CCS_WRAPPER set)"
  else
    _d_warn "not loaded in this shell — run: ccs shell-install, then open a new terminal"
  fi
  local rc rcs
  rcs="$(_shell_rc_files)"
  if [[ -z "$rcs" ]]; then
    _d_warn "no ~/.bashrc or ~/.zshrc found"
  else
    while IFS= read -r rc; do
      [[ -z "$rc" ]] && continue
      local blocks legacy
      blocks="$(grep -cF "$CCS_BLOCK_START" "$rc" 2>/dev/null || true)"
      legacy="$(grep -c '^alias claude=' "$rc" 2>/dev/null || true)"
      if [[ "$blocks" == "1" ]]; then
        _d_pass "$rc: one ccs block"
      elif [[ "$blocks" == "0" ]]; then
        _d_warn "$rc: no ccs block — run: ccs shell-install"
      else
        _d_fail "$rc: $blocks ccs blocks — run: ccs shell-install"
      fi
      [[ "$legacy" == "0" ]] || _d_fail "$rc: $legacy legacy 'alias claude=' line(s) shadow the function"
    done <<< "$rcs"
  fi
  echo "  note  ccs cannot see this shell's aliases; confirm with: type claude"

  echo ""
  echo "active selection"
  if _active_spec; then
    _d_pass "active: $ACTIVE_PROVIDER@$ACTIVE_ACCOUNT"
    [[ -f "$ACTIVE_LINK" ]] && _d_pass "settings resolve: $(readlink "$ACTIVE_LINK")" \
                            || _d_fail "active symlink is dangling"
  else
    _d_warn "no active account — run: ccs switch <provider>"
  fi

  echo ""
  echo "accounts"
  local provider account home email
  while IFS= read -r provider; do
    [[ -z "$provider" ]] && continue
    while IFS= read -r account; do
      [[ -z "$account" ]] && continue
      home="$(_resolve_home "$provider" "$account")"
      if _is_native_home "$home"; then
        _d_pass "$provider@$account: default config dir (background agents available)"
      else
        email="$(_account_email "$home")"
        if [[ -d "$home" ]]; then
          _d_pass "$provider@$account: isolated${email:+ ($email)} — background agents unavailable"
        else
          _d_warn "$provider@$account: home not created yet — run: ccs login $provider@$account"
        fi
        _doctor_check_creds "$home" "$provider@$account"
        _doctor_check_links "$home" "$provider@$account"
      fi
    done < <(_list_accounts "$provider")
  done < <(_list_providers)

  echo ""
  if [[ $_doctor_ok -ne 0 ]]; then
    echo "result: problems found"
    return 1
  elif [[ $_doctor_warn -ne 0 ]]; then
    echo "result: $_doctor_warn warning(s)"
  else
    echo "result: all good"
  fi
}

_doctor_check_creds() {
  local home="$1" label="$2" mode
  local creds="$home/.credentials.json"
  # Absent is normal on macOS, where the token is in the Keychain, never on disk.
  [[ -f "$creds" ]] || return 0
  mode="$(_file_mode "$creds")"
  if [[ "$mode" == "600" ]]; then
    _d_pass "$label: credentials are mode 600"
  else
    _d_fail "$label: credentials are mode $mode, expected 600"
  fi
  return 0
}

_doctor_check_links() {
  local home="$1" label="$2" item broken=0
  [[ -d "$home" ]] || return 0
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    if [[ -L "$home/$item" && ! -e "$home/$item" ]]; then
      _d_fail "$label: $item is a dangling link"
      broken=1
    elif [[ -e "$home/$item" && ! -L "$home/$item" ]]; then
      _d_warn "$label: $item is a real file, not shared with the other accounts"
      broken=1
    fi
  done < <(_shared_items)
  [[ $broken -eq 0 ]] && _d_pass "$label: shared config links intact"
  # A reported problem must not abort the rest of the report under `set -e`.
  return 0
}
