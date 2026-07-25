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

# .env.<field> without hard-requiring jq, for the paths that must work before
# `ccs list` has a chance to tell the user jq is missing.
_env_field_soft() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  if command -v jq &>/dev/null; then
    jq -r --arg k "$key" '.env[$k] // empty' "$file" 2>/dev/null
  else
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1
  fi
}

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
      base_url="$(_env_field_soft "$(_account_path "$provider" "$first")" ANTHROPIC_BASE_URL)"
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

# Octal permission bits. stat's flags differ between GNU and BSD/macOS.
_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"
}

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

# Names of MCP servers added with `claude mcp add`, sorted, one per line.
#
# This is only ONE of the two kinds of entry `claude mcp list` shows, and the
# smaller one. It lives in .mcpServers in .claude.json, which cannot be shared
# because that file carries oauthAccount -- the account identity itself -- so
# these do not follow an account switch.
#
# The other kind is account-managed claude.ai connectors, which ccs cannot see at
# all: Claude Code fetches them from
# /api/oauth/organizations/:orgUUID/mcp/connectors/search, scoped to the claude.ai
# org rather than the config dir, and never caches the list on disk. Reporting
# this count alone as though it were complete is how doctor came to print 0/0 for
# accounts that genuinely differed. See _mcp_ever_connected.
#
# Prints nothing when jq is absent: the caller distinguishes that case, since
# "no jq" and "no servers" must not look alike.
_mcp_servers() {
  local cj
  cj="$(_config_json "$1")"
  [[ -f "$cj" ]] || return 0
  command -v jq &>/dev/null || return 0
  jq -r '(.mcpServers // {}) | keys[]' "$cj" 2>/dev/null | LC_ALL=C sort
  return 0
}

# Names of claude.ai connectors this account has EVER connected, sorted.
#
# The only local trace of account-managed connectors. Claude Code appends to it
# when a connector is connected:
#
#   xlr(e){ ... hr((t)=>{let r=t.claudeAiMcpEverConnected??[]; ...
#            return {...t, claudeAiMcpEverConnected:[...r,e]}}) }
#
# Deliberately NOT treated as a count of live connectors -- it records everything
# ever connected, so it over-reports (observed: 4 recorded against 3 live). It is
# usable only as a divergence signal, and the caller must label it as a hint.
_mcp_ever_connected() {
  local cj
  cj="$(_config_json "$1")"
  [[ -f "$cj" ]] || return 0
  command -v jq &>/dev/null || return 0
  jq -r '(.claudeAiMcpEverConnected // []) | .[]' "$cj" 2>/dev/null | LC_ALL=C sort
  return 0
}

# ── shared configuration ─────────────────────────────────────────────────────

# Items linked from ~/.claude into every isolated home.
#
# Two groups. Configuration (agents, skills, commands, plugins, settings.json,
# CLAUDE.md) is shared so it is not duplicated per account. Work context
# (projects, history.jsonl, todos, session-env) is shared because rotating
# accounts happens mid-task: if transcripts were per-account, `claude --resume`
# could not find the session you were just in, which is the moment you need it
# most. Both directories are config-dir relative in Claude Code, so a symlink is
# all it takes.
#
# Every top-level *.md is included, not just CLAUDE.md, because CLAUDE.md may
# @-import siblings that must resolve inside the home too.
#
# Deliberately NOT shared, and per-account: .credentials.json and .claude.json
# (they carry the account identity), sessions/ (a live-PID registry),
# shell-snapshots/, file-history/, statsig/, and tasks/ + jobs/ (background-agent
# state, which only works on the default config dir anyway).
_shared_items() {
  local i
  for i in agents skills commands plugins settings.json \
           projects history.jsonl todos session-env; do
    [[ -e "$DEFAULT_HOME/$i" ]] && echo "$i"
  done
  for i in "$DEFAULT_HOME"/*.md; do
    # ${i##*/} rather than basename: this runs on every switch now, and one fork
    # per memory file is measurable next to the rest of a switch.
    [[ -f "$i" ]] && echo "${i##*/}"
  done
  # See _shell_rc_files: never leak the last test's exit status to the caller.
  return 0
}

# Link, but never clobber: if something real sits where a link belongs, say so
# and leave it. Idempotent, and repairs a dangling link as well as a missing one.
_relink() {
  local target="$1" link="$2"
  if [[ -L "$link" ]]; then
    # -ef compares device and inode through the link, so an already-correct link
    # costs no subprocess. _ensure_shared runs on every switch now, making this
    # the hot path -- readlink here would fork once per shared item per switch.
    # A dangling link fails -ef and gets recreated.
    [[ "$link" -ef "$target" ]] && return 0
    ln -sfn "$target" "$link"
  elif [[ -e "$link" ]]; then
    echo "ccs: warning: $link is a real file, not a shared link — leaving it alone" >&2
    return 1
  else
    ln -sfn "$target" "$link"
  fi
}

# Classify one entry, for doctor. A shared item is the hinge every isolated home
# hangs off: while shared/<item> is missing, every home's link to it dangles and
# that account silently loses the item.
#   ok        a link resolving to the canonical file under ~/.claude
#   missing   nothing there at all -- the state doctor used to report as intact
#   dangling  a link whose target is gone
#   stale     a link pointing somewhere other than ~/.claude/<item>
#   real      real content where a link belongs; never clobbered, so never auto-repaired
_shared_status() {
  local item="$1" link="$SHARED_DIR/$item" target="$DEFAULT_HOME/$item"
  if [[ -L "$link" ]]; then
    [[ -e "$link" ]] || { echo dangling; return 0; }
    [[ "$link" -ef "$target" ]] && echo ok || echo stale
  elif [[ -e "$link" ]]; then
    echo real
  else
    echo missing
  fi
  return 0
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

# Make an isolated home usable: 0700 dir, shared config linked in, credentials
# locked down. Idempotent, so it runs on every switch.
#
# It returns early for the native home, so it repairs an isolated home's links
# only. Rebuilding shared/ itself is _ensure_shared's job, which cmd_switch calls
# unconditionally -- otherwise switching to the native account, where the user
# spends most of their time, would repair nothing.
_prepare_home() {
  local home="$1"
  _is_native_home "$home" && return 0
  mkdir -p "$home"
  chmod 700 "$home"
  _link_shared "$home"
  # Claude Code writes this 0600 itself, but a restore from backup or a copy
  # between machines can loosen it.
  [[ -f "$home/.credentials.json" ]] && chmod 600 "$home/.credentials.json"
  return 0
}

# A custom CLAUDE_CONFIG_DIR turns off Claude Code's background-agent daemon
# (`if (process.env.CLAUDE_CONFIG_DIR || ...) return false`) and its service
# installer refuses outright. That makes isolated accounts genuinely less
# capable than the default one, so say so at the moment of switching.
_warn_isolated() {
  _is_native_home "$1" && return 0
  echo "ccs: background agents and the daemon are unavailable on isolated" >&2
  echo "ccs: accounts (Claude Code requires the default config dir)" >&2
  return 0
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

# Detect the block marker, not the old alias: a user who has migrated has no
# `alias claude=` line left, and checking for it would nag forever.
_ensure_aliases() {
  local rc rcs missing=0
  rcs="$(_shell_rc_files)"
  [[ -z "$rcs" ]] && return 0
  while IFS= read -r rc; do
    [[ -z "$rc" ]] && continue
    _shell_has_block "$rc" || missing=1
  done <<< "$rcs"
  [[ $missing -eq 0 ]] && return 0

  echo "Shell integration not configured. Add it? [Y/n]"
  read -r response
  if [[ "$response" =~ ^[Yy]?$ ]]; then
    _shell_install
  fi
}
