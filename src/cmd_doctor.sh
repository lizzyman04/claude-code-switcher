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
    _doctor_check_active_home "$ACTIVE_PROVIDER" "$ACTIVE_ACCOUNT"
  else
    _d_warn "no active account — run: ccs switch <provider>"
  fi

  echo ""
  echo "shared configuration"
  _doctor_check_shared

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

# active-home is the single file wrong-account routing depends on, and it is the
# one fault the wrapper cannot report: it guards with `[[ -d "$_h" ]]`, which
# follows the link, so an absent or dangling active-home fails that test and falls
# through to plain `command claude` against the default account. No error, no
# output, wrong quota. Every fault here is therefore a FAIL, never a warning.
_doctor_check_active_home() {
  local provider="$1" account="$2" want got
  want="$(_resolve_home "$provider" "$account")"

  if [[ ! -L "$ACTIVE_HOME_LINK" ]]; then
    if [[ -e "$ACTIVE_HOME_LINK" ]]; then
      _d_fail "active-home is not a symlink; repair: ccs $provider@$account"
    else
      _d_fail "active-home is missing — claude would use $DEFAULT_HOME regardless of"
      echo "        the active account; repair: ccs $provider@$account"
    fi
    return 0
  fi

  if [[ ! -d "$ACTIVE_HOME_LINK" ]]; then
    _d_fail "active-home is dangling ($(readlink "$ACTIVE_HOME_LINK")) — the wrapper"
    echo "        silently falls back to $DEFAULT_HOME; repair: ccs $provider@$account"
    return 0
  fi

  # Compare resolved paths, not link text: the target may be reached through a
  # symlinked HOME, and the wrapper itself compares with `cd -P; pwd -P`.
  got="$(_realdir "$ACTIVE_HOME_LINK")"
  if [[ "$got" == "$(_realdir "$want")" ]]; then
    _d_pass "active-home resolves: $want"
  else
    _d_fail "active-home points at $got but $provider@$account resolves to $want"
    echo "        claude would run the wrong account; repair: ccs $provider@$account"
  fi
  return 0
}

# The repair for anything under shared/ or inside a home is a switch: cmd_switch
# calls _ensure_shared unconditionally and then _prepare_home, which relinks.
_doctor_repair_cmd() {
  local name
  name="$(_active_name)"
  [[ "$name" == "(none)" ]] && { echo "ccs switch <provider>"; return 0; }
  echo "ccs $name"
}

# shared/ is the hinge every isolated home hangs off, so a fault here is a fault
# in every isolated account at once. Until this check existed an entry missing
# from shared/ was reported as "links intact", because _doctor_check_links only
# tested for a dangling link or a real file -- never for absence.
_doctor_check_shared() {
  local item status repair problems=0 count=0
  repair="$(_doctor_repair_cmd)"

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    count=$((count + 1))
    status="$(_shared_status "$item")"
    case "$status" in
      ok) ;;
      missing)
        _d_fail "shared/$item is missing — isolated accounts lose it; repair: $repair"
        problems=1 ;;
      dangling)
        _d_fail "shared/$item is a dangling link; repair: $repair"
        problems=1 ;;
      stale)
        _d_fail "shared/$item does not point at $DEFAULT_HOME/$item; repair: $repair"
        problems=1 ;;
      real)
        # Never auto-repaired: the real file and the canonical one can differ, and
        # discarding either without being asked would lose the user's settings.
        _d_fail "shared/$item is a real file, so it is no longer shared"
        echo "        compare it with $DEFAULT_HOME/$item, keep the version you want,"
        echo "        then move the other aside and run: $repair"
        problems=1 ;;
    esac
  done < <(_shared_items)

  # An item deleted from ~/.claude leaves a link behind that _shared_items no
  # longer lists, so sweep for orphans separately or they stay invisible.
  local link name
  for link in "$SHARED_DIR"/*; do
    [[ -L "$link" ]] || continue
    [[ -e "$link" ]] && continue
    name="$(basename "$link")"
    _d_fail "shared/$name points at $DEFAULT_HOME/$name, which no longer exists"
    echo "        restore that file, or remove the link: rm $link"
    problems=1
  done

  if [[ $count -eq 0 ]]; then
    _d_warn "nothing to share — $DEFAULT_HOME looks empty"
  elif [[ $problems -eq 0 ]]; then
    _d_pass "$count shared item(s) linked to $DEFAULT_HOME"
  fi
  # A reported problem must not abort the rest of the report under `set -e`.
  return 0
}

_doctor_check_links() {
  local home="$1" label="$2" item broken=0
  [[ -d "$home" ]] || return 0
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    if [[ -L "$home/$item" && ! -e "$home/$item" ]]; then
      _d_fail "$label: $item is a dangling link; repair: ccs $label"
      broken=1
    elif [[ -e "$home/$item" && ! -L "$home/$item" ]]; then
      _d_warn "$label: $item is a real file, not shared with the other accounts"
      broken=1
    elif [[ ! -e "$home/$item" && ! -L "$home/$item" ]]; then
      # Absence was the invisible case: neither branch above matches, so doctor
      # printed "links intact" while the account was missing the item entirely.
      _d_fail "$label: $item is not linked into this account; repair: ccs $label"
      broken=1
    fi
  done < <(_shared_items)
  [[ $broken -eq 0 ]] && _d_pass "$label: shared config links intact"
  # A reported problem must not abort the rest of the report under `set -e`.
  return 0
}
