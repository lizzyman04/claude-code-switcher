cmd_switch() {
  local spec="${1:-}"
  if [[ -z "$spec" ]]; then
    echo "Available profiles:"
    cmd_list
    echo ""
    echo "Usage: ccs switch <provider>[@<account>]"
    return 1
  fi

  _resolve_spec_or_die "$spec"
  local provider="$SPEC_PROVIDER" account="$SPEC_ACCOUNT" path
  path="$(_account_path "$provider" "$account")"

  local token base_url
  token="$(_read_env_field "$path" ANTHROPIC_AUTH_TOKEN)"
  base_url="$(_read_env_field "$path" ANTHROPIC_BASE_URL)"

  if [[ -n "$base_url" ]]; then
    if [[ -z "$token" || "$token" == '""' ]]; then
      echo "error: '$provider@$account' has no API key set" >&2
      echo "Set it with: ccs key $provider@$account" >&2
      return 1
    fi
  fi

  local home
  home="$(_resolve_home "$provider" "$account")"
  _require_wrapper "$home" "switching to $provider@$account" || return 1

  # Unconditional, and deliberately not inside _prepare_home: that returns early
  # for the native home, so a switch to the native account rebuilt nothing. While
  # a shared/<item> is missing every isolated home's link to it dangles, so the
  # repair has to be reachable from the account the user is on most.
  # Captured before the links are rewritten, because afterwards there is no way
  # to tell a real switch from a no-op. A bare provider resolves to last_account,
  # which is mutable state the user cannot see in the command they typed, so
  # `ccs anthropic` can mean two different accounts on the same day -- claiming a
  # switch that did not happen makes the output untrustworthy exactly when it is
  # being used to confirm which account is live.
  local was_active=0
  if _active_spec && [[ "$ACTIVE_PROVIDER" == "$provider" && "$ACTIVE_ACCOUNT" == "$account" ]]; then
    was_active=1
  fi

  _ensure_shared
  _prepare_home "$home"

  ln -sfn "$path" "$ACTIVE_LINK"
  # active-home is what the shell function reads to decide whether to export
  # CLAUDE_CONFIG_DIR. It always points at the resolved dir; the function
  # compares it against ~/.claude and exports only when they differ.
  ln -sfn "$home" "$ACTIVE_HOME_LINK"
  _set_last_account "$provider" "$account"

  # The work above still runs in the no-op case: _ensure_shared, _prepare_home
  # and the chmod are idempotent by design and are what repair a degraded home.
  # Only the message changes.
  local label="$provider"
  [[ "$(_list_accounts "$provider" | wc -l | tr -d ' ')" -le 1 ]] || label="$provider@$account"
  if [[ $was_active -eq 1 ]]; then
    echo "Already on $label"
  else
    echo "Switched to $label"
  fi

  _warn_isolated "$home"
}
