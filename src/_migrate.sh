# Migrate a flat profiles/<name>.json layout to profiles/<name>/accounts/main.json.
#
# Runs on every invocation, so it must be cheap and idempotent. It is both: the
# glob check below is the only work done once migration has happened, and step 2
# removes the flat files, so a second run cannot see anything to migrate.
_migrate_flat_layout() {
  local flat=() f
  for f in "$PROFILES_DIR"/*.json; do
    [[ -f "$f" ]] && flat+=("$f")
  done
  [[ ${#flat[@]} -eq 0 ]] && return 0

  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUPS_DIR/pre-multiaccount-$stamp"

  # Back up before touching anything. cp -a rather than tar: no extra dependency
  # and the result stays browsable.
  mkdir -p "$backup"
  cp -a "$PROFILES_DIR" "$backup/profiles"
  if [[ -L "$ACTIVE_LINK" ]]; then
    readlink "$ACTIVE_LINK" > "$backup/active.target"
  fi

  local old_active=""
  if [[ -L "$ACTIVE_LINK" ]]; then
    old_active="$(basename "$(readlink "$ACTIVE_LINK")" .json)"
  fi

  local migrated=0 name base_url auth
  for f in "${flat[@]}"; do
    name="$(basename "$f" .json)"

    # Both layouts present: the new one wins and the old file is left untouched
    # rather than guessed at. This warns on every run by design -- it is an
    # unresolved state -- so the message says how to resolve it.
    if [[ -d "$PROFILES_DIR/$name/accounts" ]]; then
      echo "ccs: warning: '$name' exists in both layouts; ignoring the old file" >&2
      echo "ccs:          delete $f to silence this" >&2
      continue
    fi

    mkdir -p "$PROFILES_DIR/$name/accounts"
    mv "$f" "$PROFILES_DIR/$name/accounts/main.json"

    # A base URL means the account authenticates with an API key: token auth.
    # Its absence means OAuth, which is why the anthropic profile is {"env":{}}.
    # A present-but-empty value counts as absent, so a half-filled profile is
    # not misread as token auth.
    base_url="$(_env_field_soft "$PROFILES_DIR/$name/accounts/main.json" ANTHROPIC_BASE_URL)"

    if [[ -n "$base_url" ]]; then
      auth="token"
      cat > "$PROFILES_DIR/$name/profile.json" << EOF
{
  "auth": "token",
  "default_account": "main",
  "last_account": "main"
}
EOF
    else
      auth="oauth"
      # native_account: this account keeps using ~/.claude, so an existing OAuth
      # login survives the migration untouched and no re-login is needed.
      cat > "$PROFILES_DIR/$name/profile.json" << EOF
{
  "auth": "oauth",
  "default_account": "main",
  "last_account": "main",
  "native_account": "main"
}
EOF
    fi

    migrated=$((migrated + 1))
  done

  [[ $migrated -eq 0 ]] && return 0

  if [[ -n "$old_active" && -f "$PROFILES_DIR/$old_active/accounts/main.json" ]]; then
    ln -sfn "$PROFILES_DIR/$old_active/accounts/main.json" "$ACTIVE_LINK"
  fi

  # active-home is what the shell function reads to decide whether to export
  # CLAUDE_CONFIG_DIR, and migration used to leave it absent until the first
  # switch. That is not merely untidy: the wrapper guards with `[[ -d "$_h" ]]`,
  # which follows the link, so an absent or dangling active-home falls straight
  # through to `command claude` against the default account -- silently, which is
  # the exact failure the wrapper exists to prevent.
  if _active_spec; then
    ln -sfn "$(_resolve_home "$ACTIVE_PROVIDER" "$ACTIVE_ACCOUNT")" "$ACTIVE_HOME_LINK"
  fi

  _ensure_shared

  echo "ccs: migrated $migrated profile(s) to the multi-account layout" >&2
  echo "ccs: backup at $backup" >&2
}
