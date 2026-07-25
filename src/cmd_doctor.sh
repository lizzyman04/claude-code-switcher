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
  echo "MCP servers"
  _doctor_check_mcp

  echo ""
  echo "accounts"
  local provider account home email
  while IFS= read -r provider; do
    [[ -z "$provider" ]] && continue
    while IFS= read -r account; do
      [[ -z "$account" ]] && continue
      home="$(_resolve_home "$provider" "$account")"
      # Read the identity on both branches. Doctor exists to confirm which login
      # is live, and it was the one command that would not say so for the native
      # account -- `ccs current` and `ccs accounts` both do.
      #
      # oauth only: a token provider resolves to the default config dir as well,
      # and that .claude.json holds the *native oauth* login, so printing it next
      # to deepseek@main would name an identity that has nothing to do with it.
      email=""
      if [[ "$(_provider_auth "$provider")" == "oauth" ]]; then
        email="$(_account_email "$home")"
      fi
      if _is_native_home "$home"; then
        _d_pass "$provider@$account: default config dir${email:+ ($email)} (background agents available)"
      else
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

# `claude mcp list` shows two kinds of entry, and ccs can only see one of them.
#
#   1. servers added with `claude mcp add` -> .mcpServers in .claude.json, which
#      is per-account because that file carries oauthAccount, so they do not
#      follow a switch;
#   2. account-managed claude.ai connectors -> fetched from
#      /api/oauth/organizations/:orgUUID/mcp/connectors/search, scoped to the
#      claude.ai org rather than the config dir, and never cached on disk.
#
# The first version of this check counted only (1) and labelled it "user-scope
# server(s)". On a real machine with three connectors on one account and none on
# the other it printed 0/0 with no warning, because .mcpServers was empty in both
# -- reporting "aligned" for the exact divergence it was written to catch. Silence
# read as zero, which is worse than having no check at all.
#
# So the incompleteness is now stated unconditionally, never inferred from a
# count, and claudeAiMcpEverConnected is used as a divergence signal. That key is
# a record of everything ever connected rather than what is live -- observed as 4
# recorded against 3 live -- so it is reported as a hint and never as a count of
# active connectors.
_doctor_check_mcp() {
  local provider account home names ever count ever_count
  local first_names="" first_ever="" first_account="" diverged=0 ever_diverged=0 reported=0

  if ! command -v jq &>/dev/null; then
    _d_warn "jq not installed — cannot read per-account MCP servers"
    return 0
  fi

  while IFS= read -r provider; do
    [[ -z "$provider" ]] && continue
    [[ "$(_provider_auth "$provider")" == "oauth" ]] || continue

    first_names=""
    first_ever=""
    first_account=""
    diverged=0
    ever_diverged=0
    while IFS= read -r account; do
      [[ -z "$account" ]] && continue
      home="$(_resolve_home "$provider" "$account")"
      names="$(_mcp_servers "$home")"
      ever="$(_mcp_ever_connected "$home")"
      count="$(printf '%s' "$names" | grep -c . || true)"
      ever_count="$(printf '%s' "$ever" | grep -c . || true)"
      echo "  note  $provider@$account: $count added with 'claude mcp add', $ever_count claude.ai connector(s) ever connected"
      reported=1
      if [[ -z "$first_account" ]]; then
        first_account="$account"
        first_names="$names"
        first_ever="$ever"
      else
        [[ "$names" != "$first_names" ]] && diverged=1
        [[ "$ever" != "$first_ever" ]] && ever_diverged=1
      fi
    done < <(_list_accounts "$provider")

    if [[ $diverged -eq 1 ]]; then
      _d_warn "$provider: accounts have different 'claude mcp add' servers — they live"
      echo "        in .claude.json, which is per-account, so they do not follow a switch."
      echo "        Add one to the account that is missing it: claude mcp add <name> …"
    fi

    if [[ $ever_diverged -eq 1 ]]; then
      _d_warn "$provider: accounts have connected different claude.ai connectors"
      echo "        Connectors follow the claude.ai account, not the config dir, so ccs"
      echo "        cannot copy them. Align them at https://claude.ai/customize/connectors"
    fi
  done < <(_list_providers)

  if [[ $reported -eq 1 ]]; then
    # Unconditional, and deliberately not a pass: the counts above cannot be
    # complete, so any summary that reads as "aligned" would be the original bug.
    echo "  note  ccs cannot see account-managed claude.ai connectors — these counts"
    echo "        are incomplete. Compare with: claude mcp list"
  else
    _d_pass "no OAuth accounts to compare"
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

# What a degraded item actually costs. The old text described a broken link and
# stopped there, which reads as cosmetic; it is not. settings.json carries hooks
# and permissions, so while it is degraded the isolated account runs with none of
# the user's hooks -- security guards among them -- and nothing in the session
# says so.
_shared_item_cost() {
  case "$1" in
    settings.json)
      echo "isolated accounts run with none of your hooks or permissions" ;;
    projects|history.jsonl|todos|session-env)
      echo "isolated accounts lose your session history — claude --resume will not find it" ;;
    agents|skills|commands|plugins)
      echo "isolated accounts run without your $1" ;;
    *)
      echo "isolated accounts do not see your $1" ;;
  esac
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
        _d_fail "shared/$item is missing, so sharing of it has stopped"
        echo "        $(_shared_item_cost "$item")"
        echo "        repair: $repair"
        problems=1 ;;
      dangling)
        _d_fail "shared/$item is a dangling link, so sharing of it has stopped"
        echo "        $(_shared_item_cost "$item")"
        echo "        repair: $repair"
        problems=1 ;;
      stale)
        _d_fail "shared/$item does not point at $DEFAULT_HOME/$item"
        echo "        $(_shared_item_cost "$item")"
        echo "        repair: $repair"
        problems=1 ;;
      copy)
        # Bytes still match, so nothing is lost yet -- but the link is gone, so
        # the next edit to the canonical file will not reach isolated accounts.
        _d_warn "shared/$item is a copy, not a link — further edits to $DEFAULT_HOME/$item"
        echo "        will not reach isolated accounts; repaired by: $repair"
        problems=1 ;;
      diverged)
        # Sharing has genuinely stopped. The repair displaces this content rather
        # than discarding it, so say where it will go before the switch does it.
        _d_fail "shared/$item is a file that differs from $DEFAULT_HOME/$item"
        echo "        $(_shared_item_cost "$item")"
        echo "        compare: diff '$SHARED_DIR/$item' '$DEFAULT_HOME/$item'"
        echo "        $repair moves it to backups/displaced/ and restores the link"
        problems=1 ;;
      real)
        # A directory, or something that is not a regular file. Never auto-repaired:
        # merging two directories is not a choice ccs can make for the user.
        _d_fail "shared/$item is real content that differs from $DEFAULT_HOME/$item"
        echo "        $(_shared_item_cost "$item")"
        echo "        compare: diff -r '$SHARED_DIR/$item' '$DEFAULT_HOME/$item'"
        echo "        keep the version you want, move the other aside, then run: $repair"
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

  # Content a repair moved out of the way. Nothing is broken -- the file is
  # preserved and sharing is back -- but a repair that restores sharing also
  # reverts whatever the displaced version held, and the line saying so scrolled
  # past during a switch. Report it here so that is recoverable later, not lost.
  local d
  for d in "$BACKUPS_DIR"/displaced/*; do
    [[ -e "$d" ]] || continue
    echo "  note  moved aside by a repair, not deleted: $d"
    echo "        compare with the live one, then delete it once reviewed"
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
