cmd_help() {
  cat << 'USAGE'
ccs — Claude Code Switcher

Usage: ccs <command> [args]

Commands:
  list              List all profiles
  switch <name>     Set active profile
  current           Show active profile
  add <name>        Add a new profile interactively
  edit <name>       Edit profile in $EDITOR
  key <name>        Update API key for a profile
  remove <name>     Delete a profile
  test              Test active profile connection
  clean [name]      Launch Claude with zero custom agents/skills
  clean --restore   Manually restore agents/skills (if session crashed)

Available providers:
USAGE
  cmd_list
}
