cmd_list() {
  _ensure_aliases
  _active_spec || true

  local providers
  providers="$(_list_providers)"
  if [[ -z "$providers" ]]; then
    echo "No profiles found. Run: ccs add <name>"
    return
  fi

  local provider account count
  while IFS= read -r provider; do
    [[ -z "$provider" ]] && continue
    count="$(_list_accounts "$provider" | wc -l | tr -d ' ')"

    # A single-account provider prints as one line: there is nothing to choose
    # between, so nesting it would be noise.
    if [[ "$count" -le 1 ]]; then
      account="$(_list_accounts "$provider" | head -1)"
      if [[ "$provider" == "${ACTIVE_PROVIDER:-}" ]]; then
        echo "* $provider (active)"
      else
        echo "  $provider"
      fi
      continue
    fi

    if [[ "$provider" == "${ACTIVE_PROVIDER:-}" ]]; then
      echo "* $provider"
    else
      echo "  $provider"
    fi
    while IFS= read -r account; do
      [[ -z "$account" ]] && continue
      if [[ "$provider" == "${ACTIVE_PROVIDER:-}" && "$account" == "${ACTIVE_ACCOUNT:-}" ]]; then
        echo "    * $account (active)"
      else
        echo "      $account"
      fi
    done < <(_list_accounts "$provider")
  done < <(echo "$providers")
}
