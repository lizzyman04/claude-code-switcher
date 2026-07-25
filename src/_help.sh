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
  next              Rotate to the next account of the CURRENT provider
  login <p>[@<a>]   Sign in to an account (OAuth providers)
  logout <p>@<a>    Clear one account's credentials
  accounts [p]      List accounts with identity and daemon availability
  doctor            Check shell integration, links and credential modes
  shell-install     (Re)install the shell integration in .bashrc/.zshrc

Most commands accept <provider>@<account> as well as a bare <provider>.

Available providers:
USAGE
  cmd_list
}
