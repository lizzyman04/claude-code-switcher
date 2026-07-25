CCS_BLOCK_START="# >>> ccs (claude-code-switcher) >>>"
CCS_BLOCK_END="# <<< ccs (claude-code-switcher) <<<"

# The shell integration, emitted verbatim into .bashrc/.zshrc.
#
# It has to be a function rather than an alias. Claude Code reads
# CLAUDE_CONFIG_DIR from process.env only -- never from a settings file -- so the
# variable must be exported by the shell before `claude` starts. An alias cannot
# export anything, which is why `alias claude='claude --settings ...'` cannot
# support multiple accounts.
_shell_block() {
  cat << 'BLOCK'
# >>> ccs (claude-code-switcher) >>>
# Managed by ccs. Changes here are replaced when the installer runs.
unalias claude 2>/dev/null || true
export CCS_WRAPPER=1
claude() {
  local _ccs="$HOME/.config/claude-profiles"
  local _s="$_ccs/active" _h="$_ccs/active-home"
  local -a _a=()
  [ -e "$_s" ] && _a+=(--settings "$_s")
  # Export the config dir only when it differs from the default, so the default
  # account keeps Claude Code features that require the default dir.
  if [ -d "$_h" ]; then
    local _t _d
    _t="$(cd -P "$_h" 2>/dev/null && pwd -P)"
    _d="$(cd -P "$HOME/.claude" 2>/dev/null && pwd -P)"
    if [ -n "$_t" ] && [ "$_t" != "$_d" ]; then
      CLAUDE_CONFIG_DIR="$_t" command claude ${_a[@]+"${_a[@]}"} "$@"
      return
    fi
  fi
  command claude ${_a[@]+"${_a[@]}"} "$@"
}
alias deepseek='ccs run deepseek'
# <<< ccs (claude-code-switcher) <<<
BLOCK
}

_shell_rc_files() {
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] && echo "$rc"
  done
  # Explicit: without it the function inherits the last test's exit status, and
  # a missing .zshrc would abort the caller under `set -e`.
  return 0
}

_shell_has_block() {
  grep -qF "$CCS_BLOCK_START" "$1" 2>/dev/null
}

# Strip any previous ccs integration, including the pre-function aliases. awk
# rather than `sed -i`, whose in-place flag differs between GNU and BSD.
_shell_strip() {
  local rc="$1" tmp
  tmp="$(mktemp)"
  awk '
    index($0, "# >>> ccs (claude-code-switcher) >>>") == 1 { skip = 1; next }
    skip && index($0, "# <<< ccs (claude-code-switcher) <<<") == 1 { skip = 0; next }
    skip { next }
    /^# ccs aliases$/ { next }
    /^# ccs .* Claude Code Switcher aliases$/ { next }
    /^alias claude=.*claude-profiles\/active/ { next }
    /^alias deepseek=.*ccs run deepseek/ { next }
    { print }
  ' "$rc" > "$tmp" && mv "$tmp" "$rc"
}

_shell_install() {
  local rcs rc stamp
  rcs="$(_shell_rc_files)"

  if [[ -z "$rcs" ]]; then
    echo "ccs: no ~/.bashrc or ~/.zshrc found — add this to your shell config:" >&2
    _shell_block
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  while IFS= read -r rc; do
    [[ -z "$rc" ]] && continue
    cp -p "$rc" "$rc.ccs-backup-$stamp"
    _shell_strip "$rc"
    {
      echo ""
      _shell_block
    } >> "$rc"
    echo "ccs: shell integration installed in $rc (backup: $rc.ccs-backup-$stamp)"
  done <<< "$rcs"

  echo "ccs: open a new terminal, or run: source ${rcs%%$'\n'*}"
}
