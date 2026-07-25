cmd_next() {
  if ! _active_spec; then
    echo "error: no active account (run: ccs switch <provider>)" >&2
    exit 1
  fi

  local provider="$ACTIVE_PROVIDER" accounts count
  accounts="$(_list_accounts "$provider")"
  count="$(echo "$accounts" | grep -c . || true)"

  # Never crosses provider boundaries: switching provider stays explicit.
  if [[ "$count" -le 1 ]]; then
    echo "'$provider' has only one account ($ACTIVE_ACCOUNT)."
    echo "Add another with: ccs login $provider@<name>"
    return 0
  fi

  local idx=0 target_idx found=0 a
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    if [[ "$a" == "$ACTIVE_ACCOUNT" ]]; then found=1; break; fi
    idx=$((idx + 1))
  done < <(echo "$accounts")

  if [[ $found -eq 0 ]]; then
    target_idx=0
  else
    target_idx=$(( (idx + 1) % count ))
  fi

  local target
  target="$(echo "$accounts" | sed -n "$((target_idx + 1))p")"
  cmd_switch "$provider@$target"
}
