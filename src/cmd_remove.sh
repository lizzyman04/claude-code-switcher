cmd_remove() {
  local spec="${1:-}"
  [[ -z "$spec" ]] && { echo "usage: ccs remove <provider>[@<account>]" >&2; exit 1; }

  # No @ means the whole provider; with @ it is a single account.
  if [[ "$spec" != *@* ]]; then
    _remove_provider "$spec"
    return
  fi

  _resolve_spec_or_die "$spec"
  local provider="$SPEC_PROVIDER" account="$SPEC_ACCOUNT" path home
  path="$(_account_path "$provider" "$account")"
  home="$(_resolve_home "$provider" "$account")"

  if [[ "$(_list_accounts "$provider" | grep -c . || true)" -le 1 ]]; then
    echo "error: '$account' is the only account for '$provider'" >&2
    echo "Remove the whole provider with: ccs remove $provider" >&2
    exit 1
  fi

  if [[ -L "$ACTIVE_LINK" ]] && [[ "$(readlink "$ACTIVE_LINK")" == "$path" ]]; then
    rm -f "$ACTIVE_LINK" "$ACTIVE_HOME_LINK"
  fi
  rm "$path"
  [[ "$(_meta_get "$provider" last_account)" == "$account" ]] && \
    _set_last_account "$provider" "$(_default_account "$provider")"

  echo "Removed: $provider@$account"

  # The config dir is left in place on purpose: it holds credentials and session
  # history, and deleting it silently would be unrecoverable. Note that `ccs
  # logout` can no longer reach it -- the account no longer resolves -- so the
  # only remaining step is a manual delete.
  if ! _is_native_home "$home" && [[ -d "$home" ]]; then
    echo "Its config dir was kept (credentials and history):"
    echo "  $home"
    echo "Delete it to discard those. Next time, 'ccs logout $provider@$account'"
    echo "first if you want the credentials revoked properly."
  fi
}

_remove_provider() {
  local provider="$1"
  _provider_exists "$provider" || { echo "error: profile '$provider' not found" >&2; exit 1; }

  local count
  count="$(_list_accounts "$provider" | grep -c . || true)"
  echo "This removes provider '$provider' and all $count of its accounts."
  printf 'Continue? [y/N] '
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }

  if _active_spec && [[ "$ACTIVE_PROVIDER" == "$provider" ]]; then
    rm -f "$ACTIVE_LINK" "$ACTIVE_HOME_LINK"
  fi

  local account home kept=""
  while IFS= read -r account; do
    [[ -z "$account" ]] && continue
    home="$(_resolve_home "$provider" "$account")"
    if ! _is_native_home "$home" && [[ -d "$home" ]]; then
      kept+="  $home"$'\n'
    fi
  done < <(_list_accounts "$provider")

  rm -rf "$(_profile_dir "$provider")"
  echo "Removed: $provider"
  if [[ -n "$kept" ]]; then
    echo "Config dirs were kept (they hold credentials and history):"
    printf '%s' "$kept"
  fi
}
