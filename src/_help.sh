cmd_help() {
  cat << 'USAGE'
ccs — Claude Code Switcher

Usage: ccs <command> [args]

Commands:
  list              List all providers and accounts
  switch <p>[@<a>]  Set the active account
  current           Show the active account
  add <p>[@<a>]     Add a profile interactively
  edit <p>[@<a>]    Edit a profile in $EDITOR
  key <p>[@<a>]     Update an API key
  remove <p>[@<a>]  Delete an account, or a whole provider
  test [<p>[@<a>]]  Test a profile: API call, or login status for OAuth
  run <p>[@<a>]     Run claude with a specific account
  clean [<p>[@<a>]] Launch Claude with zero custom agents/skills
  clean --restore   Manually restore agents/skills (if a session crashed)
  next              Rotate to the next account of the CURRENT provider
  login <p>[@<a>]   Sign in to an account (OAuth providers)
  logout <p>@<a>    Clear one account's credentials
  accounts [<p>]    List accounts with identity and daemon availability
  doctor            Check shell integration, links and credential modes
  shell-install     (Re)install the shell integration in .bashrc/.zshrc

Most commands accept <provider>@<account> as well as a bare <provider>.

Available providers:
USAGE
  cmd_list
}
