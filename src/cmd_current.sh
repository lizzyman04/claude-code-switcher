cmd_current() {
  if ! _active_spec; then
    echo "No active profile. Run: ccs switch <provider>[@<account>]"
    return
  fi

  local provider="$ACTIVE_PROVIDER" account="$ACTIVE_ACCOUNT" auth home email
  auth="$(_provider_auth "$provider")"
  home="$(_resolve_home "$provider" "$account")"

  echo "Provider: $provider"
  echo "Account:  $account"
  echo "Auth:     $auth"

  if [[ "$auth" == "oauth" ]]; then
    # The email comes from the resolved home's config JSON, so this reports the
    # identity actually logged in there rather than what ccs intends.
    email="$(_account_email "$home")"
    echo "Email:    ${email:-(not logged in)}"
    echo "Home:     $home"
  fi

  if _wrapper_loaded; then
    echo "Wrapper:  active"
  else
    echo "Wrapper:  NOT LOADED — 'claude' ignores this selection (ccs shell-install)"
  fi

  _require_jq
  jq 'del(.env.ANTHROPIC_AUTH_TOKEN)' "$ACTIVE_LINK"
}
