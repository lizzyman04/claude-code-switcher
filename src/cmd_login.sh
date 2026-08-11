cmd_login() {
  local spec="${1:-}"
  [[ -z "$spec" ]] && { echo "usage: ccs login <provider>[@<account>]" >&2; exit 1; }

  local provider account
  if [[ "$spec" == *@* ]]; then
    provider="${spec%%@*}"
    account="${spec#*@}"
  else
    provider="$spec"
    account="main"
  fi
  [[ -n "$provider" && -n "$account" ]] || { echo "usage: ccs login <provider>[@<account>]" >&2; exit 1; }

  if _provider_exists "$provider" && [[ "$(_provider_auth "$provider")" == "token" ]]; then
    echo "error: '$provider' authenticates with an API key, not OAuth" >&2
    echo "Set the key with: ccs key $provider@$account" >&2
    exit 1
  fi

  local meta accounts_dir path
  meta="$(_profile_meta "$provider")"
  accounts_dir="$(_accounts_dir "$provider")"
  path="$(_account_path "$provider" "$account")"

  mkdir -p "$accounts_dir"

  # An OAuth account has no API key, so its settings file is genuinely empty.
  # Credentials never live here -- they go in the account's own config dir.
  [[ -f "$path" ]] || printf '{\n  "env": {}\n}\n' > "$path"

  if [[ ! -f "$meta" ]]; then
    cat > "$meta" << EOF
{
  "auth": "oauth",
  "default_account": "$account",
  "last_account": "$account",
  "native_account": "$account"
}
EOF
  fi

  local home
  home="$(_resolve_home "$provider" "$account")"
  _prepare_home "$home"

  echo "ccs: signing in to $provider@$account"
  if _is_native_home "$home"; then
    echo "ccs: using the default config dir ($home)"
    claude auth login || { echo "error: login failed" >&2; exit 1; }
  else
    echo "ccs: using an isolated config dir ($home)"
    env CLAUDE_CONFIG_DIR="$home" claude auth login || { echo "error: login failed" >&2; exit 1; }
  fi

  # Claude Code writes credentials 0600 itself; re-assert it rather than assume.
  [[ -f "$home/.credentials.json" ]] && chmod 600 "$home/.credentials.json"

  # This account is signed in now, so the first-run wizard has nothing left to ask
  # -- and asking anyway is how one `ccs login` used to cost two sign-ins.
  _mark_onboarded "$home"

  local email
  email="$(_account_email "$home")"
  if [[ -n "$email" ]]; then
    echo "ccs: $provider@$account is now $email"
  else
    echo "ccs: $provider@$account logged in"
  fi

  _set_last_account "$provider" "$account"
  _warn_isolated "$home"
  echo "ccs: switch to it with: ccs $provider@$account"
}

cmd_logout() {
  local spec="${1:-}"

  # Requires the explicit form: this destroys credentials, so it must never act
  # on a guessed account.
  if [[ -z "$spec" || "$spec" != *@* ]]; then
    echo "usage: ccs logout <provider>@<account>" >&2
    echo "The account must be named explicitly — logout clears its credentials." >&2
    exit 1
  fi

  _resolve_spec_or_die "$spec"
  local provider="$SPEC_PROVIDER" account="$SPEC_ACCOUNT" home email
  home="$(_resolve_home "$provider" "$account")"
  email="$(_account_email "$home")"

  echo "This clears the credentials for $provider@$account${email:+ ($email)}."
  if _is_native_home "$home"; then
    echo "That is the default config dir: $home"
  fi
  if _active_spec && [[ "$ACTIVE_PROVIDER" == "$provider" && "$ACTIVE_ACCOUNT" == "$account" ]]; then
    echo "It is also the currently active account."
  fi
  printf 'Continue? [y/N] '
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }

  # `claude auth logout` rather than deleting files: on macOS the token is in the
  # Keychain, not on disk, so removing .credentials.json would not log anything
  # out.
  if _is_native_home "$home"; then
    claude auth logout
  else
    env CLAUDE_CONFIG_DIR="$home" claude auth logout
  fi
  echo "ccs: logged out $provider@$account"
}

cmd_accounts() {
  local only="${1:-}"
  _active_spec || true

  local providers
  if [[ -n "$only" ]]; then
    _provider_exists "$only" || { echo "error: provider '$only' not found" >&2; exit 1; }
    providers="$only"
  else
    providers="$(_list_providers)"
  fi
  [[ -z "$providers" ]] && { echo "No profiles found. Run: ccs add <name>"; return; }

  printf '%-2s %-22s %-30s %s\n' "" "ACCOUNT" "IDENTITY" "BG AGENTS"
  local provider account home email mark identity daemon
  while IFS= read -r provider; do
    [[ -z "$provider" ]] && continue
    while IFS= read -r account; do
      [[ -z "$account" ]] && continue
      home="$(_resolve_home "$provider" "$account")"

      if _is_native_home "$home"; then
        daemon="yes"
      else
        # A custom CLAUDE_CONFIG_DIR disables the background-agent daemon.
        daemon="no"
      fi

      if [[ "$(_provider_auth "$provider")" == "token" ]]; then
        identity="api key"
      else
        email="$(_account_email "$home")"
        identity="${email:-(not logged in)}"
      fi

      mark=" "
      [[ "$provider" == "${ACTIVE_PROVIDER:-}" && "$account" == "${ACTIVE_ACCOUNT:-}" ]] && mark="*"
      printf '%-2s %-22s %-30s %s\n' "$mark" "$provider@$account" "$identity" "$daemon"
    done < <(_list_accounts "$provider")
  done < <(echo "$providers")
}
