_require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "error: jq is required (apt install jq / brew install jq)" >&2
    exit 1
  fi
}

# ── paths ────────────────────────────────────────────────────────────────────

_profile_dir()   { echo "$PROFILES_DIR/$1"; }
_profile_meta()  { echo "$PROFILES_DIR/$1/profile.json"; }
_accounts_dir()  { echo "$PROFILES_DIR/$1/accounts"; }
_account_path()  { echo "$PROFILES_DIR/$1/accounts/$2.json"; }

_provider_exists() { [[ -d "$PROFILES_DIR/$1/accounts" ]]; }
_account_exists()  { [[ -f "$(_account_path "$1" "$2")" ]]; }

_list_providers() {
  local d
  for d in "$PROFILES_DIR"/*/; do
    [[ -d "$d/accounts" ]] || continue
    basename "$d"
  done
}

_list_accounts() {
  local f
  for f in "$(_accounts_dir "$1")"/*.json; do
    [[ -f "$f" ]] || continue
    basename "$f" .json
  done | sort
}

# ── metadata ─────────────────────────────────────────────────────────────────

# Read a flat top-level string from a JSON file. Uses jq when present, but falls
# back to sed so `ccs list` keeps working on a box without jq.
_json_str() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  if command -v jq &>/dev/null; then
    jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
  else
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1
  fi
}

_meta_get() { _json_str "$(_profile_meta "$1")" "$2"; }

_meta_set() {
  local provider="$1" key="$2" value="$3" meta tmp
  meta="$(_profile_meta "$provider")"
  [[ -f "$meta" ]] || return 0
  _require_jq
  tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$meta" > "$tmp" && mv "$tmp" "$meta"
}

_set_last_account() { _meta_set "$1" last_account "$2"; }

# oauth (no API key, isolated by config dir) or token (isolated by API key).
# Falls back to inferring from the account settings when profile.json is absent.
_provider_auth() {
  local provider="$1" auth
  auth="$(_meta_get "$provider" auth)"
  if [[ -z "$auth" ]]; then
    local first base_url
    first="$(_list_accounts "$provider" | head -1)"
    if [[ -n "$first" ]]; then
      base_url="$(_read_env_field "$(_account_path "$provider" "$first")" ANTHROPIC_BASE_URL)"
      [[ -n "$base_url" ]] && auth="token" || auth="oauth"
    fi
  fi
  echo "${auth:-oauth}"
}

# ── spec parsing ─────────────────────────────────────────────────────────────

# Resolve "<provider>" or "<provider>@<account>" into SPEC_PROVIDER/SPEC_ACCOUNT.
# A bare provider resolves to its last-used account.
_parse_spec() {
  local spec="$1"
  SPEC_PROVIDER=""
  SPEC_ACCOUNT=""
  [[ -z "$spec" ]] && return 1

  if [[ "$spec" == *@* ]]; then
    SPEC_PROVIDER="${spec%%@*}"
    SPEC_ACCOUNT="${spec#*@}"
  else
    SPEC_PROVIDER="$spec"
  fi
  [[ -n "$SPEC_PROVIDER" ]] || return 1
  _provider_exists "$SPEC_PROVIDER" || return 1

  if [[ -z "$SPEC_ACCOUNT" ]]; then
    SPEC_ACCOUNT="$(_default_account "$SPEC_PROVIDER")"
  fi
  [[ -n "$SPEC_ACCOUNT" ]] || return 1
  _account_exists "$SPEC_PROVIDER" "$SPEC_ACCOUNT" || return 1
}

_default_account() {
  local provider="$1" candidate
  for candidate in "$(_meta_get "$provider" last_account)" \
                   "$(_meta_get "$provider" default_account)" \
                   main; do
    [[ -n "$candidate" ]] && _account_exists "$provider" "$candidate" && { echo "$candidate"; return; }
  done
  _list_accounts "$provider" | head -1
}

# Shared error path so every command reports an unknown spec the same way.
_resolve_spec_or_die() {
  local spec="$1"
  if ! _parse_spec "$spec"; then
    if [[ "$spec" == *@* ]] && _provider_exists "${spec%%@*}"; then
      echo "error: account '${spec#*@}' not found for provider '${spec%%@*}'" >&2
      echo "Available: $(_list_accounts "${spec%%@*}" | tr '\n' ' ')" >&2
    else
      echo "error: profile '$spec' not found" >&2
    fi
    exit 1
  fi
}

# ── homes ────────────────────────────────────────────────────────────────────

_realdir() { (cd -P "$1" 2>/dev/null && pwd -P); }

_is_native_home() {
  local a b
  a="$(_realdir "$1")"
  b="$(_realdir "$DEFAULT_HOME")"
  [[ -n "$a" && "$a" == "$b" ]] || [[ "$1" == "$DEFAULT_HOME" ]]
}

# Which CLAUDE_CONFIG_DIR an account runs under.
#
# token providers isolate on the API key alone, so they all share the default
# home. For oauth there is no API key to isolate on -- credentials live in
# $CONFIG_DIR/.credentials.json (or a Keychain entry keyed by a hash of the
# config dir) -- so each account needs its own dir. The one exception is the
# provider's native_account, which stays on ~/.claude: a custom
# CLAUDE_CONFIG_DIR disables Claude Code's background-agent daemon, so one
# account is deliberately left on the default dir.
_resolve_home() {
  local provider="$1" account="$2" native
  [[ "$(_provider_auth "$provider")" == "oauth" ]] || { echo "$DEFAULT_HOME"; return; }
  native="$(_meta_get "$provider" native_account)"
  [[ -n "$native" && "$account" == "$native" ]] && { echo "$DEFAULT_HOME"; return; }
  echo "$HOMES_DIR/$provider-$account"
}

# CLAUDE_CONFIG_DIR relocates .claude.json into itself; with the var unset it
# stays at $HOME/.claude.json (not inside ~/.claude).
_config_json() {
  if _is_native_home "$1"; then echo "$HOME/.claude.json"; else echo "$1/.claude.json"; fi
}

# The logged-in identity for a home. Cross-platform: reads the config JSON
# rather than credentials, so it works on macOS where the token is in the
# Keychain and never on disk.
_account_email() {
  local cj
  cj="$(_config_json "$1")"
  [[ -f "$cj" ]] || return 0
  if command -v jq &>/dev/null; then
    jq -r '.oauthAccount.emailAddress // empty' "$cj" 2>/dev/null
  else
    grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$cj" 2>/dev/null |
      head -1 | sed 's/.*"\([^"]*\)"$/\1/'
  fi
}

# ── shared configuration ─────────────────────────────────────────────────────

# Items linked from ~/.claude into every isolated home, so configuration is not
# duplicated per account. Every top-level *.md is included, not just CLAUDE.md,
# because CLAUDE.md may @-import siblings that must resolve inside the home too.
_shared_items() {
  local i
  for i in agents skills commands plugins settings.json; do
    [[ -e "$DEFAULT_HOME/$i" ]] && echo "$i"
  done
  for i in "$DEFAULT_HOME"/*.md; do
    [[ -f "$i" ]] && basename "$i"
  done
}

# Link, but never clobber: if something real sits where a link belongs, say so
# and leave it. Idempotent, so it can run on every switch to self-heal.
_relink() {
  local target="$1" link="$2"
  if [[ -L "$link" ]]; then
    [[ "$(readlink "$link")" == "$target" ]] || ln -sfn "$target" "$link"
  elif [[ -e "$link" ]]; then
    echo "ccs: warning: $link is a real file, not a shared link — leaving it alone" >&2
    return 1
  else
    ln -sfn "$target" "$link"
  fi
}

_ensure_shared() {
  local item
  [[ -d "$DEFAULT_HOME" ]] || return 0
  mkdir -p "$SHARED_DIR"
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    _relink "$DEFAULT_HOME/$item" "$SHARED_DIR/$item" || true
  done < <(_shared_items)
}

_link_shared() {
  local home="$1" item
  _is_native_home "$home" && return 0
  _ensure_shared
  mkdir -p "$home"
  chmod 700 "$home"
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    [[ -e "$SHARED_DIR/$item" || -L "$SHARED_DIR/$item" ]] || continue
    _relink "$SHARED_DIR/$item" "$home/$item" || true
  done < <(_shared_items)
}

# ── active account ───────────────────────────────────────────────────────────

# Sets ACTIVE_PROVIDER / ACTIVE_ACCOUNT from the active symlink's path shape:
#   profiles/<provider>/accounts/<account>.json
_active_spec() {
  ACTIVE_PROVIDER=""
  ACTIVE_ACCOUNT=""
  [[ -L "$ACTIVE_LINK" ]] || return 1
  local target
  target="$(readlink "$ACTIVE_LINK")"
  [[ -n "$target" ]] || return 1
  ACTIVE_ACCOUNT="$(basename "$target" .json)"
  ACTIVE_PROVIDER="$(basename "$(dirname "$(dirname "$target")")")"
  [[ -n "$ACTIVE_PROVIDER" && -n "$ACTIVE_ACCOUNT" && "$ACTIVE_PROVIDER" != "/" ]] || return 1
}

_active_name() {
  if ! _active_spec; then
    echo "(none)"
    return
  fi
  echo "$ACTIVE_PROVIDER@$ACTIVE_ACCOUNT"
}

_read_env_field() {
  jq -r ".env.$2 // empty" "$1"
}

# Back-compat shim. Commands still keyed on a plain name keep working, and get
# <provider>@<account> for free.
_profile_path() {
  if _parse_spec "$1"; then
    _account_path "$SPEC_PROVIDER" "$SPEC_ACCOUNT"
  else
    echo "$PROFILES_DIR/$1.json"
  fi
}

_ensure_aliases() {
  local shell_config=""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] && { shell_config="$rc"; break; }
  done
  if [[ -n "$shell_config" ]] && ! grep -q "alias claude=.*claude-profiles/active" "$shell_config" 2>/dev/null; then
    echo "Aliases not configured. Add them? [Y/n]"
    read -r response
    if [[ "$response" =~ ^[Yy]?$ ]]; then
      echo "" >> "$shell_config"
      echo "# ccs aliases" >> "$shell_config"
      echo "alias claude='claude --settings \$HOME/.config/claude-profiles/active'" >> "$shell_config"
      echo "alias deepseek='ccs run deepseek'" >> "$shell_config"
      echo "Done. Run: source $shell_config"
    fi
  fi
}
