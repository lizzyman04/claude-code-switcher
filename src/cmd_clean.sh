CLEAN_STATE="$CCS_DIR/clean.state"

# Disable agents/skills for one session without touching any other account.
#
# The old implementation always `mv`d $HOME/.claude/agents aside. Now that
# isolated homes reach agents/ and skills/ through symlinks into ~/.claude, that
# would blank them out for *every* account at once, including live sessions.
#
# So the mechanism depends on what the entry actually is:
#   symlink (isolated home) -- remove the link, never the target. Nothing outside
#     this home is touched, and the shared data is never at risk.
#   real directory (the default home) -- fall back to the move, and warn: a
#     concurrent session on another account loses them for the duration.
cmd_clean() {
  local first_arg="${1:-}"

  if [[ "$first_arg" == "--provider" ]]; then
    shift
    cmd_run --provider "$@"
    return
  fi

  local provider account path home
  if [[ -n "$first_arg" ]]; then
    _resolve_spec_or_die "$first_arg"
    provider="$SPEC_PROVIDER"
    account="$SPEC_ACCOUNT"
    shift
  else
    _active_spec || { echo "error: no active account (run: ccs switch <provider>)" >&2; exit 1; }
    provider="$ACTIVE_PROVIDER"
    account="$ACTIVE_ACCOUNT"
  fi

  path="$(_account_path "$provider" "$account")"
  home="$(_resolve_home "$provider" "$account")"
  _prepare_home "$home"

  local -a cleaned=()
  local item target
  for item in agents skills; do
    target="$home/$item"
    if [[ -L "$target" ]]; then
      # Record the link's target so the trap can recreate exactly this link.
      local link_dest
      link_dest="$(readlink "$target")"
      rm "$target"
      cleaned+=("link:$item:$link_dest")
      echo "ccs: disabled $item for this session (this account only)"
    elif [[ -d "$target" ]]; then
      mv "$target" "$target.ccs-disabled"
      cleaned+=("move:$item:")
      echo "ccs: disabled $item for this session"
      # Only the default home holds these as real directories that other
      # accounts reach by symlink, so only there is the blast radius wider than
      # this session.
      if _is_native_home "$home"; then
        echo "ccs: note — $item is a real directory here, so any concurrent" >&2
        echo "ccs: session on another account loses it until this one exits" >&2
      fi
    fi
  done

  _clean_write_state "$home" "${cleaned[@]+"${cleaned[@]}"}"

  _cleanup_clean() {
    _clean_restore_from_state
  }
  trap _cleanup_clean EXIT SIGINT

  if _is_native_home "$home"; then
    claude --settings "$path" "$@"
  else
    env CLAUDE_CONFIG_DIR="$home" claude --settings "$path" "$@"
  fi
}

# State on disk, not just in the trap: a killed shell must still be recoverable
# via `ccs clean --restore`.
_clean_write_state() {
  local home="$1"
  shift
  if [[ $# -eq 0 ]]; then
    rm -f "$CLEAN_STATE"
    return 0
  fi
  {
    echo "home=$home"
    local entry
    for entry in "$@"; do
      echo "entry=$entry"
    done
  } > "$CLEAN_STATE"
}

_clean_restore_from_state() {
  [[ -f "$CLEAN_STATE" ]] || return 0

  local home="" line kind item dest restored=0
  while IFS= read -r line; do
    case "$line" in
      home=*) home="${line#home=}" ;;
      entry=*)
        entry="${line#entry=}"
        kind="${entry%%:*}"
        item="${entry#*:}"; item="${item%%:*}"
        dest="${entry#*:*:}"
        case "$kind" in
          link)
            if [[ ! -e "$home/$item" && ! -L "$home/$item" ]]; then
              ln -sfn "$dest" "$home/$item"
              echo "ccs: restored $item"
              restored=1
            fi
            ;;
          move)
            if [[ -d "$home/$item.ccs-disabled" ]]; then
              mv "$home/$item.ccs-disabled" "$home/$item"
              echo "ccs: restored $item"
              restored=1
            fi
            ;;
        esac
        ;;
    esac
  done < "$CLEAN_STATE"

  rm -f "$CLEAN_STATE"
  [[ $restored -eq 1 ]] && return 0
  return 0
}

# Recovery path for a crashed session. Uses the state file when present, and
# otherwise sweeps every known home for leftovers -- including ~/.claude, so a
# crash from before this change is still recoverable.
cmd_clean_restore() {
  _clean_restore_from_state

  local provider account home item
  while IFS= read -r provider; do
    [[ -z "$provider" ]] && continue
    while IFS= read -r account; do
      [[ -z "$account" ]] && continue
      home="$(_resolve_home "$provider" "$account")"
      for item in agents skills; do
        if [[ -d "$home/$item.ccs-disabled" && ! -e "$home/$item" ]]; then
          mv "$home/$item.ccs-disabled" "$home/$item"
          echo "ccs: restored $item in $home"
        fi
      done
    done < <(_list_accounts "$provider")
  done < <(_list_providers)

  echo "ccs: cleanup complete"
}
