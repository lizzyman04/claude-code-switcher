#Requires -Version 5.1

$CCS_DIR      = "$env:USERPROFILE\.config\claude-profiles"
$PROFILES_DIR = "$CCS_DIR\profiles"
$HOMES_DIR    = "$CCS_DIR\homes"
$SHARED_DIR   = "$CCS_DIR\shared"
$BACKUPS_DIR  = "$CCS_DIR\backups"
$ACTIVE_LINK  = "$CCS_DIR\active"
$DEFAULT_HOME = "$env:USERPROFILE\.claude"

# On Windows active-home is a plain text file holding the path, not a link.
# Reading a junction's target differs between PowerShell 5.1 and 7, and creating
# a directory symlink needs elevation; a text file needs neither and leaves one
# source of truth.
$ACTIVE_HOME_FILE = "$CCS_DIR\active-home.path"

$CCS_BLOCK_START = "# >>> ccs (claude-code-switcher) >>>"
$CCS_BLOCK_END   = "# <<< ccs (claude-code-switcher) <<<"

# ── paths ────────────────────────────────────────────────────────────────────

function _ProfileDir([string]$p)   { return Join-Path $PROFILES_DIR $p }
function _ProfileMeta([string]$p)  { return Join-Path (_ProfileDir $p) "profile.json" }
function _AccountsDir([string]$p)  { return Join-Path (_ProfileDir $p) "accounts" }
function _AccountPath([string]$p, [string]$a) { return Join-Path (_AccountsDir $p) "$a.json" }

function _ProviderExists([string]$p) { return (Test-Path (_AccountsDir $p) -PathType Container) }
function _AccountExists([string]$p, [string]$a) { return (Test-Path (_AccountPath $p $a) -PathType Leaf) }

function _ListProviders {
    if (-not (Test-Path $PROFILES_DIR)) { return @() }
    return @(Get-ChildItem $PROFILES_DIR -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "accounts") -PathType Container } |
        ForEach-Object { $_.Name })
}

function _ListAccounts([string]$p) {
    $dir = _AccountsDir $p
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem $dir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { $_.BaseName })
}

# ── metadata ─────────────────────────────────────────────────────────────────

function _ReadJson([string]$path) {
    if (-not (Test-Path $path -PathType Leaf)) { return $null }
    try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch { return $null }
}

function _MetaGet([string]$p, [string]$key) {
    $json = _ReadJson (_ProfileMeta $p)
    if ($null -eq $json) { return "" }
    $val = $json.$key
    if ($null -eq $val) { return "" }
    return [string]$val
}

function _MetaSet([string]$p, [string]$key, [string]$value) {
    $meta = _ProfileMeta $p
    $json = _ReadJson $meta
    if ($null -eq $json) { return }
    if ($json.PSObject.Properties[$key]) { $json.$key = $value }
    else { $json | Add-Member -NotePropertyName $key -NotePropertyValue $value }
    $json | ConvertTo-Json -Depth 10 | Set-Content $meta -Encoding UTF8
}

function _SetLastAccount([string]$p, [string]$a) { _MetaSet $p "last_account" $a }

function _ReadEnvField([string]$path, [string]$field) {
    $json = _ReadJson $path
    if ($null -eq $json -or $null -eq $json.env) { return "" }
    $val = $json.env.$field
    if ($null -eq $val) { return "" }
    return [string]$val
}

# oauth (isolated by config dir) or token (isolated by API key).
function _ProviderAuth([string]$p) {
    $auth = _MetaGet $p "auth"
    if ($auth) { return $auth }
    $first = @(_ListAccounts $p) | Select-Object -First 1
    if ($first) {
        if (_ReadEnvField (_AccountPath $p $first) "ANTHROPIC_BASE_URL") { return "token" }
    }
    return "oauth"
}

# ── spec parsing ─────────────────────────────────────────────────────────────

function _DefaultAccount([string]$p) {
    foreach ($c in @((_MetaGet $p "last_account"), (_MetaGet $p "default_account"), "main")) {
        if ($c -and (_AccountExists $p $c)) { return $c }
    }
    return (@(_ListAccounts $p) | Select-Object -First 1)
}

# Returns a hashtable @{Provider=..; Account=..} or $null.
function _ParseSpec([string]$spec) {
    if ([string]::IsNullOrEmpty($spec)) { return $null }
    if ($spec.Contains("@")) {
        $provider = $spec.Substring(0, $spec.IndexOf("@"))
        $account  = $spec.Substring($spec.IndexOf("@") + 1)
    } else {
        $provider = $spec
        $account  = ""
    }
    if (-not $provider) { return $null }
    if (-not (_ProviderExists $provider)) { return $null }
    if (-not $account) { $account = _DefaultAccount $provider }
    if (-not $account -or -not (_AccountExists $provider $account)) { return $null }
    return @{ Provider = $provider; Account = $account }
}

function _ResolveSpecOrDie([string]$spec) {
    $r = _ParseSpec $spec
    if ($null -ne $r) { return $r }
    if ($spec -and $spec.Contains("@")) {
        $p = $spec.Substring(0, $spec.IndexOf("@"))
        if (_ProviderExists $p) {
            Write-Host "error: account '$($spec.Substring($spec.IndexOf('@')+1))' not found for provider '$p'" -ForegroundColor Red
            Write-Host "Available: $((_ListAccounts $p) -join ' ')" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "error: profile '$spec' not found" -ForegroundColor Red
    exit 1
}

# ── homes ────────────────────────────────────────────────────────────────────

function _NormPath([string]$p) {
    if (-not $p) { return "" }
    try { return [System.IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return $p.TrimEnd('\') }
}

function _IsNativeHome([string]$home) {
    return ((_NormPath $home) -ieq (_NormPath $DEFAULT_HOME))
}

# token providers isolate on the API key alone. For oauth there is no key --
# credentials live in the config dir -- so each account needs its own, except the
# native_account, which stays on the default dir.
function _ResolveHome([string]$p, [string]$a) {
    if ((_ProviderAuth $p) -ne "oauth") { return $DEFAULT_HOME }
    $native = _MetaGet $p "native_account"
    if ($native -and $a -eq $native) { return $DEFAULT_HOME }
    return (Join-Path $HOMES_DIR "$p-$a")
}

# CLAUDE_CONFIG_DIR relocates .claude.json into itself; unset it stays beside the
# user profile, not inside .claude.
function _ConfigJson([string]$home) {
    if (_IsNativeHome $home) { return "$env:USERPROFILE\.claude.json" }
    return (Join-Path $home ".claude.json")
}

function _AccountEmail([string]$home) {
    $json = _ReadJson (_ConfigJson $home)
    if ($null -eq $json -or $null -eq $json.oauthAccount) { return "" }
    $v = $json.oauthAccount.emailAddress
    if ($null -eq $v) { return "" }
    return [string]$v
}

function _ActiveHome {
    if (Test-Path $ACTIVE_HOME_FILE -PathType Leaf) {
        return (Get-Content $ACTIVE_HOME_FILE -Raw).Trim()
    }
    return ""
}

# User-scope MCP server names for a home, sorted.
#
# These live in .claude.json, which cannot be shared because it carries
# oauthAccount -- the account identity itself. So they do not follow an account
# switch, and a freshly created account starts with none. ccs reports the
# divergence; it does not sync it, because merging server definitions between
# config dirs can duplicate or clobber them.
function _McpServers([string]$home) {
    $json = _ReadJson (_ConfigJson $home)
    if ($null -eq $json -or $null -eq $json.mcpServers) { return @() }
    return @($json.mcpServers.PSObject.Properties.Name | Sort-Object)
}

# Names of claude.ai connectors this account has EVER connected, sorted.
#
# The only local trace of account-managed connectors: Claude Code fetches the real
# list from /api/oauth/organizations/:orgUUID/mcp/connectors/search, scoped to the
# claude.ai org rather than the config dir, and never caches it on disk.
#
# Deliberately not treated as a count of live connectors -- it records everything
# ever connected, so it over-reports. Usable only as a divergence signal.
function _McpEverConnected([string]$home) {
    $json = _ReadJson (_ConfigJson $home)
    if ($null -eq $json -or $null -eq $json.claudeAiMcpEverConnected) { return @() }
    return @($json.claudeAiMcpEverConnected | Sort-Object)
}

# ── shared configuration ─────────────────────────────────────────────────────

# Configuration plus work context. projects/ and history.jsonl are shared so a
# session started under one account is resumable under another -- rotating
# accounts happens mid-task, which is exactly when that matters.
function _SharedItems {
    $items = @()
    foreach ($i in @("agents", "skills", "commands", "plugins", "settings.json",
                     "projects", "history.jsonl", "todos", "session-env")) {
        if (Test-Path (Join-Path $DEFAULT_HOME $i)) { $items += $i }
    }
    if (Test-Path $DEFAULT_HOME) {
        $items += @(Get-ChildItem $DEFAULT_HOME -Filter "*.md" -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name })
    }
    return $items
}

# Byte-for-byte comparison, for deciding whether a degraded shared entry can be
# relinked without losing anything. Length first, so differing files cost no read.
function _SameFileContent([string]$a, [string]$b) {
    try {
        $ia = Get-Item $a -Force -ErrorAction Stop
        $ib = Get-Item $b -Force -ErrorAction Stop
        if ($ia.PSIsContainer -or $ib.PSIsContainer) { return $false }
        if ($ia.Length -ne $ib.Length) { return $false }
        $ba = [System.IO.File]::ReadAllBytes($a)
        $bb = [System.IO.File]::ReadAllBytes($b)
        for ($i = 0; $i -lt $ba.Length; $i++) {
            if ($ba[$i] -ne $bb[$i]) { return $false }
        }
        return $true
    } catch { return $false }
}

# Directories use a junction and files a hard link: both work without elevation
# or Developer Mode, unlike symlinks. Never clobbers content that differs.
# Move a degraded shared entry out of the way instead of deleting it. Timestamped
# because the same item degrades repeatedly, and a second occurrence must not
# overwrite the evidence from the first. Returns the path it wrote, or $null.
function _DisplaceShared([string]$link) {
    $dir = Join-Path $BACKUPS_DIR "displaced"
    New-Item -ItemType Directory -Force -Path $dir -ErrorAction SilentlyContinue | Out-Null
    $item = Split-Path $link -Leaf
    $ts   = Get-Date -Format "yyyyMMdd-HHmmss"
    $dest = Join-Path $dir "$item.$ts"
    $n = 1
    while (Test-Path $dest) { $dest = Join-Path $dir "$item.$ts.$n"; $n++ }
    try {
        Move-Item -LiteralPath $link -Destination $dest -Force -ErrorAction Stop
        return $dest
    } catch { return $null }
}

function _LinkItem([string]$target, [string]$link) {
    if (-not (Test-Path $target)) { return }
    $existing = Get-Item $link -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return }
        if ($existing.PSIsContainer) {
            # A real directory. Divergence between two directories is a merge
            # rather than a choice between versions, so ccs never guesses.
            Write-Host "ccs: warning: $link is real content, not a shared link - leaving it alone" -ForegroundColor Yellow
            Write-Host "ccs:          compare: robocopy /L /E `"$link`" `"$target`"" -ForegroundColor Yellow
            return
        }
        # A plain file where a shared link belongs. If its bytes already match the
        # canonical file, relinking cannot lose anything, so repair it -- an
        # external writer that resolves one link level and renames onto
        # shared\<item> produces exactly this state.
        if (_SameFileContent $link $target) {
            Remove-Item $link -Force -ErrorAction SilentlyContinue
            Write-Host "ccs: relinked $link (was a copy, byte-identical to $target)" -ForegroundColor Yellow
        } else {
            # Content differs, so sharing has genuinely stopped: while it does,
            # this account runs with none of the hooks in the canonical file.
            # Restore sharing, but never destroy the displaced version -- the same
            # writer produces this state for a deliberate edit just as readily as
            # for a fresh-file stub.
            $kept = _DisplaceShared $link
            if ($null -eq $kept) {
                Write-Host "ccs: warning: could not move $link aside - leaving it alone" -ForegroundColor Yellow
                return
            }
            Write-Host "ccs: $link had been replaced by a file whose content differs" -ForegroundColor Yellow
            Write-Host "ccs:   moved aside: $kept" -ForegroundColor Yellow
            Write-Host "ccs:   relinked, so this account uses $target again" -ForegroundColor Yellow
            Write-Host "ccs:   if the moved version is the one you want: fc.exe `"$kept`" `"$target`"" -ForegroundColor Yellow
        }
    }
    $isDir = (Get-Item $target -Force).PSIsContainer
    try {
        if ($isDir) {
            New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        } else {
            New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Host "ccs: warning: could not link $link ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# Classify one entry, for doctor. A shared item is the hinge every isolated home
# hangs off: while shared\<item> is missing, every home's link to it is broken and
# that account silently loses the item.
#   ok        present and, for a directory, a reparse point
#   missing   nothing there at all -- the state doctor used to skip silently
#   diverged  a file whose content differs; sharing has stopped, and the next
#             switch moves it into backups\ and restores the link
#   real      a directory where a link belongs; never touched, because merging
#             two directories is not a choice ccs can make for the user
#
# Windows caveat: shared files use hard links, which carry no reparse point and
# are indistinguishable from a copy without comparing file IDs. So a file with
# matching bytes reports ok -- there is no "copy" state to report here, and none
# is needed: matching bytes share nothing that a relink would change.
# What a degraded item actually costs. The old text described a broken link and
# stopped there, which reads as cosmetic; it is not. settings.json carries hooks
# and permissions, so while it is degraded the isolated account runs with none of
# the user's hooks -- security guards among them -- and nothing in the session
# says so.
function _SharedItemCost([string]$item) {
    switch -Regex ($item) {
        '^settings\.json$'                      { return "isolated accounts run with none of your hooks or permissions" }
        '^(projects|history\.jsonl|todos|session-env)$' { return "isolated accounts lose your session history - claude --resume will not find it" }
        '^(agents|skills|commands|plugins)$'    { return "isolated accounts run without your $item" }
        default                                 { return "isolated accounts do not see your $item" }
    }
}

function _SharedStatus([string]$item) {
    $link   = Join-Path $SHARED_DIR $item
    $target = Join-Path $DEFAULT_HOME $item
    $it = Get-Item $link -Force -ErrorAction SilentlyContinue
    if ($null -eq $it) { return "missing" }
    if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return "ok" }
    if ($it.PSIsContainer) { return "real" }
    # A file with no reparse point is either a hard link or a plain copy, and the
    # two cannot be told apart without comparing file IDs. Compare content
    # instead: matching bytes are harmless either way (a copy gets relinked on the
    # next switch), while differing bytes mean sharing has genuinely stopped --
    # which this check previously reported as ok.
    if (_SameFileContent $link $target) { return "ok" }
    return "diverged"
}

function _EnsureShared {
    if (-not (Test-Path $DEFAULT_HOME)) { return }
    New-Item -ItemType Directory -Force -Path $SHARED_DIR | Out-Null
    foreach ($item in _SharedItems) {
        _LinkItem (Join-Path $DEFAULT_HOME $item) (Join-Path $SHARED_DIR $item)
    }
}

function _LinkShared([string]$home) {
    if (_IsNativeHome $home) { return }
    _EnsureShared
    New-Item -ItemType Directory -Force -Path $home | Out-Null
    foreach ($item in _SharedItems) {
        _LinkItem (Join-Path $SHARED_DIR $item) (Join-Path $home $item)
    }
}

function _PrepareHome([string]$home) {
    if (_IsNativeHome $home) { return }
    New-Item -ItemType Directory -Force -Path $home | Out-Null
    _LinkShared $home
}

# A custom CLAUDE_CONFIG_DIR turns off Claude Code's background-agent daemon, so
# isolated accounts really are less capable than the default one.
function _WarnIsolated([string]$home) {
    if (_IsNativeHome $home) { return }
    Write-Host "ccs: background agents and the daemon are unavailable on isolated" -ForegroundColor Yellow
    Write-Host "ccs: accounts (Claude Code requires the default config dir)" -ForegroundColor Yellow
}

# ── active account ───────────────────────────────────────────────────────────

$script:ACTIVE_PROVIDER = ""
$script:ACTIVE_ACCOUNT  = ""

# active is a hard link to the account's settings file, so --settings can point
# at one stable path. Recorded separately because a hard link cannot be read back
# to its origin.
$ACTIVE_SPEC_FILE = "$CCS_DIR\active.spec"

function _ActiveSpec {
    $script:ACTIVE_PROVIDER = ""
    $script:ACTIVE_ACCOUNT  = ""
    if (-not (Test-Path $ACTIVE_SPEC_FILE -PathType Leaf)) { return $false }
    $spec = (Get-Content $ACTIVE_SPEC_FILE -Raw).Trim()
    if (-not $spec.Contains("@")) { return $false }
    $script:ACTIVE_PROVIDER = $spec.Substring(0, $spec.IndexOf("@"))
    $script:ACTIVE_ACCOUNT  = $spec.Substring($spec.IndexOf("@") + 1)
    return ($script:ACTIVE_PROVIDER -and $script:ACTIVE_ACCOUNT)
}

function _WrapperLoaded { return [bool]$env:CCS_WRAPPER }

function _RequireWrapper([string]$home, [string]$what) {
    if (_WrapperLoaded) { return $true }
    if (-not (_IsNativeHome $home)) {
        Write-Host "error: the ccs shell integration is not loaded in this session." -ForegroundColor Red
        Write-Host "       $what needs it to set CLAUDE_CONFIG_DIR; without it claude" -ForegroundColor Red
        Write-Host "       would keep using the previous account." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Fix:    open a new PowerShell window, or: . `$PROFILE"
        Write-Host "  Set up: ccs shell-install"
        Write-Host "  Or run without the wrapper: ccs run <provider>@<account>"
        return $false
    }
    Write-Host "ccs: warning: shell integration not loaded - 'claude' will not pick up" -ForegroundColor Yellow
    Write-Host "ccs:          the active settings. Run: ccs shell-install" -ForegroundColor Yellow
    return $true
}

# ── shell integration ────────────────────────────────────────────────────────

function _ShellBlock {
    return @"
$CCS_BLOCK_START
# Managed by ccs. Changes here are replaced when the installer runs.
# A function, not an alias: Claude Code reads CLAUDE_CONFIG_DIR from the
# environment only, and an alias cannot set it.
Remove-Item Alias:claude -Force -ErrorAction SilentlyContinue
`$env:CCS_WRAPPER = "1"
function claude {
    `$ccs = Join-Path `$env:USERPROFILE ".config\claude-profiles"
    `$settings = Join-Path `$ccs "active"
    `$homeFile = Join-Path `$ccs "active-home.path"
    `$claudeArgs = @()
    if (Test-Path `$settings) { `$claudeArgs += @("--settings", `$settings) }
    `$target = ""
    if (Test-Path `$homeFile) { `$target = (Get-Content `$homeFile -Raw).Trim() }
    `$default = Join-Path `$env:USERPROFILE ".claude"
    if (`$target -and (`$target.TrimEnd('\') -ine `$default.TrimEnd('\'))) {
        `$prev = `$env:CLAUDE_CONFIG_DIR
        `$env:CLAUDE_CONFIG_DIR = `$target
        try { & claude.exe @claudeArgs @args } finally { `$env:CLAUDE_CONFIG_DIR = `$prev }
    } else {
        & claude.exe @claudeArgs @args
    }
}
Set-Alias deepseek-run "ccs run deepseek"
$CCS_BLOCK_END
"@
}

function _ShellStrip([string[]]$lines) {
    $out = @()
    $skip = $false
    foreach ($line in $lines) {
        if ($line.TrimEnd() -eq $CCS_BLOCK_START) { $skip = $true; continue }
        if ($skip -and $line.TrimEnd() -eq $CCS_BLOCK_END) { $skip = $false; continue }
        if ($skip) { continue }
        if ($line -match '^\s*Set-Alias\s+claude\b') { continue }
        if ($line -match '^\s*Set-Alias\s+ccs\b.*ccs\.ps1') { $out += $line; continue }
        $out += $line
    }
    return $out
}

function _ShellInstall {
    $profilePath = $PROFILE
    if (-not $profilePath) {
        Write-Host "ccs: no PowerShell profile path available; add this manually:"
        _ShellBlock
        return
    }
    $dir = Split-Path $profilePath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $existing = @()
    if (Test-Path $profilePath) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        Copy-Item $profilePath "$profilePath.ccs-backup-$stamp" -Force
        $existing = @(Get-Content $profilePath)
        Write-Host "ccs: backed up $profilePath to $profilePath.ccs-backup-$stamp"
    }

    $kept = _ShellStrip $existing
    ($kept + @("") + @(_ShellBlock)) | Set-Content $profilePath -Encoding UTF8
    Write-Host "ccs: shell integration installed in $profilePath"
    Write-Host "ccs: open a new PowerShell window, or run: . `$PROFILE"
}

function _EnsureShellIntegration {
    if (-not $PROFILE -or -not (Test-Path $PROFILE)) { return }
    if (Select-String -Path $PROFILE -SimpleMatch $CCS_BLOCK_START -Quiet -ErrorAction SilentlyContinue) { return }
    Write-Host "Shell integration not configured. Run: ccs shell-install" -ForegroundColor Yellow
}

# ── migration ────────────────────────────────────────────────────────────────

# Flat profiles/<name>.json -> profiles/<name>/accounts/main.json. Idempotent:
# the moved files cannot be seen twice, and this is the only check on the
# steady-state path.
function _MigrateFlatLayout {
    if (-not (Test-Path $PROFILES_DIR)) { return }
    $flat = @(Get-ChildItem $PROFILES_DIR -Filter "*.json" -File -ErrorAction SilentlyContinue)
    if ($flat.Count -eq 0) { return }

    $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = Join-Path $BACKUPS_DIR "pre-multiaccount-$stamp"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    Copy-Item $PROFILES_DIR (Join-Path $backup "profiles") -Recurse -Force

    $oldActive = ""
    if (Test-Path $ACTIVE_SPEC_FILE) { $oldActive = (Get-Content $ACTIVE_SPEC_FILE -Raw).Trim() }

    $migrated = 0
    foreach ($f in $flat) {
        $name = $f.BaseName
        if (Test-Path (_AccountsDir $name) -PathType Container) {
            Write-Host "ccs: warning: '$name' exists in both layouts; ignoring the old file" -ForegroundColor Yellow
            Write-Host "ccs:          delete $($f.FullName) to silence this" -ForegroundColor Yellow
            continue
        }
        New-Item -ItemType Directory -Force -Path (_AccountsDir $name) | Out-Null
        Move-Item $f.FullName (_AccountPath $name "main") -Force

        # A base URL means the account authenticates with an API key.
        $baseUrl = _ReadEnvField (_AccountPath $name "main") "ANTHROPIC_BASE_URL"
        if ($baseUrl) {
            $meta = [ordered]@{ auth = "token"; default_account = "main"; last_account = "main" }
        } else {
            # native_account keeps this account on the default config dir, so an
            # existing OAuth login survives migration with no re-login.
            $meta = [ordered]@{ auth = "oauth"; default_account = "main"
                                last_account = "main"; native_account = "main" }
        }
        $meta | ConvertTo-Json -Depth 10 | Set-Content (_ProfileMeta $name) -Encoding UTF8
        $migrated++
    }

    if ($migrated -eq 0) { return }

    # active-home.path is what the claude wrapper reads to decide whether to set
    # CLAUDE_CONFIG_DIR, and migration used to leave it absent until the first
    # switch. The wrapper falls back to the default config dir when it cannot read
    # it, so the account would be silently wrong. Always write it here, through
    # _SetActive so the spec file and the settings link stay consistent with it.
    $target = $null
    if ($oldActive -and $oldActive -match '^([^@]+)@(.+)$') {
        if (Test-Path (_AccountPath $Matches[1] $Matches[2])) {
            $target = @($Matches[1], $Matches[2])
        }
    }
    if (-not $target) {
        $first = @(_ListProviders) | Select-Object -First 1
        if ($first) { $target = @($first, (_DefaultAccount $first)) }
    }
    if ($target) { _SetActive $target[0] $target[1] }

    _EnsureShared
    Write-Host "ccs: migrated $migrated profile(s) to the multi-account layout" -ForegroundColor Yellow
    Write-Host "ccs: backup at $backup" -ForegroundColor Yellow
}

# ── commands ─────────────────────────────────────────────────────────────────

function _SetActive([string]$p, [string]$a) {
    $path = _AccountPath $p $a
    $home = _ResolveHome $p $a

    # A hard link rather than a symlink: no elevation needed, and the content
    # stays in sync with the account file it points at.
    if (Test-Path $ACTIVE_LINK) { Remove-Item $ACTIVE_LINK -Force }
    try {
        New-Item -ItemType HardLink -Path $ACTIVE_LINK -Target $path -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item $path $ACTIVE_LINK -Force
        Write-Host "ccs: note - copied settings instead of linking; re-run 'ccs $p@$a' after editing" -ForegroundColor Yellow
    }
    Set-Content $ACTIVE_SPEC_FILE "$p@$a" -Encoding UTF8 -NoNewline
    Set-Content $ACTIVE_HOME_FILE $home -Encoding UTF8 -NoNewline
}

function Cmd-List {
    _EnsureShellIntegration
    [void](_ActiveSpec)
    $providers = @(_ListProviders)
    if ($providers.Count -eq 0) { Write-Host "No profiles found. Run: ccs add <name>"; return }
    foreach ($p in $providers) {
        $accounts = @(_ListAccounts $p)
        if ($accounts.Count -le 1) {
            if ($p -eq $ACTIVE_PROVIDER) { Write-Host "* $p (active)" } else { Write-Host "  $p" }
            continue
        }
        if ($p -eq $ACTIVE_PROVIDER) { Write-Host "* $p" } else { Write-Host "  $p" }
        foreach ($a in $accounts) {
            if ($p -eq $ACTIVE_PROVIDER -and $a -eq $ACTIVE_ACCOUNT) {
                Write-Host "    * $a (active)"
            } else {
                Write-Host "      $a"
            }
        }
    }
}

function Cmd-Switch([string]$spec) {
    if ([string]::IsNullOrEmpty($spec)) {
        Write-Host "Available profiles:"; Cmd-List
        Write-Host ""; Write-Host "Usage: ccs switch <provider>[@<account>]"
        exit 1
    }
    $r = _ResolveSpecOrDie $spec
    $p = $r.Provider; $a = $r.Account
    $path = _AccountPath $p $a

    $baseUrl = _ReadEnvField $path "ANTHROPIC_BASE_URL"
    $token   = _ReadEnvField $path "ANTHROPIC_AUTH_TOKEN"
    if ($baseUrl -and (-not $token -or $token -eq '""')) {
        Write-Host "error: '$p@$a' has no API key set" -ForegroundColor Red
        Write-Host "Set it with: ccs key $p@$a" -ForegroundColor Red
        exit 1
    }

    $home = _ResolveHome $p $a
    if (-not (_RequireWrapper $home "switching to $p@$a")) { exit 1 }

    # Captured before the links are rewritten: afterwards a real switch and a
    # no-op are indistinguishable. A bare provider resolves to last_account,
    # mutable state the user cannot see in the command they typed, so claiming a
    # switch that did not happen makes the output untrustworthy exactly when it
    # is being read to confirm which account is live.
    $wasActive = ((_ActiveSpec) -and $ACTIVE_PROVIDER -eq $p -and $ACTIVE_ACCOUNT -eq $a)

    # Unconditional, and deliberately not inside _PrepareHome: that returns early
    # for the native home, so a switch to the native account rebuilt nothing.
    # While a shared\<item> is missing, every isolated home's link to it is
    # broken, so the repair has to be reachable from the account the user is on
    # most.
    _EnsureShared
    _PrepareHome $home
    _SetActive $p $a
    _SetLastAccount $p $a

    # The work above still runs in the no-op case: _EnsureShared and _PrepareHome
    # are idempotent by design and are what repair a degraded home. Only the
    # message changes.
    $label = if (@(_ListAccounts $p).Count -le 1) { $p } else { "$p@$a" }
    if ($wasActive) { Write-Host "Already on $label" } else { Write-Host "Switched to $label" }
    _WarnIsolated $home
}

function Cmd-Current {
    if (-not (_ActiveSpec)) {
        Write-Host "No active profile. Run: ccs switch <provider>[@<account>]"
        return
    }
    $p = $ACTIVE_PROVIDER; $a = $ACTIVE_ACCOUNT
    $auth = _ProviderAuth $p
    $home = _ResolveHome $p $a
    Write-Host "Provider: $p"
    Write-Host "Account:  $a"
    Write-Host "Auth:     $auth"
    if ($auth -eq "oauth") {
        $email = _AccountEmail $home
        if (-not $email) { $email = "(not logged in)" }
        Write-Host "Email:    $email"
        Write-Host "Home:     $home"
    }
    if (_WrapperLoaded) { Write-Host "Wrapper:  active" }
    else { Write-Host "Wrapper:  NOT LOADED - 'claude' ignores this selection (ccs shell-install)" }

    $json = _ReadJson (_AccountPath $p $a)
    if ($null -ne $json -and $null -ne $json.env -and $json.env.PSObject.Properties["ANTHROPIC_AUTH_TOKEN"]) {
        $json.env.PSObject.Properties.Remove("ANTHROPIC_AUTH_TOKEN")
    }
    $json | ConvertTo-Json -Depth 10
}

function Cmd-Accounts([string]$only) {
    [void](_ActiveSpec)
    if ($only) {
        if (-not (_ProviderExists $only)) { Write-Host "error: provider '$only' not found" -ForegroundColor Red; exit 1 }
        $providers = @($only)
    } else {
        $providers = @(_ListProviders)
    }
    if ($providers.Count -eq 0) { Write-Host "No profiles found. Run: ccs add <name>"; return }

    Write-Host ("{0,-2} {1,-22} {2,-30} {3}" -f "", "ACCOUNT", "IDENTITY", "BG AGENTS")
    foreach ($p in $providers) {
        foreach ($a in @(_ListAccounts $p)) {
            $home = _ResolveHome $p $a
            $daemon = if (_IsNativeHome $home) { "yes" } else { "no" }
            if ((_ProviderAuth $p) -eq "token") {
                $identity = "api key"
            } else {
                $identity = _AccountEmail $home
                if (-not $identity) { $identity = "(not logged in)" }
            }
            $mark = if ($p -eq $ACTIVE_PROVIDER -and $a -eq $ACTIVE_ACCOUNT) { "*" } else { " " }
            Write-Host ("{0,-2} {1,-22} {2,-30} {3}" -f $mark, "$p@$a", $identity, $daemon)
        }
    }
}

function Cmd-Next {
    if (-not (_ActiveSpec)) {
        Write-Host "error: no active account (run: ccs switch <provider>)" -ForegroundColor Red
        exit 1
    }
    $p = $ACTIVE_PROVIDER
    $accounts = @(_ListAccounts $p)
    # Never crosses provider boundaries: switching provider stays explicit.
    if ($accounts.Count -le 1) {
        Write-Host "'$p' has only one account ($ACTIVE_ACCOUNT)."
        Write-Host "Add another with: ccs login $p@<name>"
        return
    }
    $idx = [array]::IndexOf($accounts, $ACTIVE_ACCOUNT)
    if ($idx -lt 0) { $idx = -1 }
    $next = $accounts[($idx + 1) % $accounts.Count]
    Cmd-Switch "$p@$next"
}

function Cmd-Login([string]$spec) {
    if ([string]::IsNullOrEmpty($spec)) { Write-Host "usage: ccs login <provider>[@<account>]" -ForegroundColor Red; exit 1 }
    if ($spec.Contains("@")) {
        $p = $spec.Substring(0, $spec.IndexOf("@")); $a = $spec.Substring($spec.IndexOf("@") + 1)
    } else { $p = $spec; $a = "main" }
    if (-not $p -or -not $a) { Write-Host "usage: ccs login <provider>[@<account>]" -ForegroundColor Red; exit 1 }

    if ((_ProviderExists $p) -and (_ProviderAuth $p) -eq "token") {
        Write-Host "error: '$p' authenticates with an API key, not OAuth" -ForegroundColor Red
        Write-Host "Set the key with: ccs key $p@$a" -ForegroundColor Red
        exit 1
    }

    New-Item -ItemType Directory -Force -Path (_AccountsDir $p) | Out-Null
    $path = _AccountPath $p $a
    # An OAuth account has no API key, so its settings file is genuinely empty.
    if (-not (Test-Path $path)) { '{ "env": {} }' | Set-Content $path -Encoding UTF8 }
    if (-not (Test-Path (_ProfileMeta $p))) {
        [ordered]@{ auth = "oauth"; default_account = $a; last_account = $a; native_account = $a } |
            ConvertTo-Json -Depth 10 | Set-Content (_ProfileMeta $p) -Encoding UTF8
    }

    $home = _ResolveHome $p $a
    _PrepareHome $home
    Write-Host "ccs: signing in to $p@$a"
    if (_IsNativeHome $home) {
        Write-Host "ccs: using the default config dir ($home)"
        & claude.exe auth login
    } else {
        Write-Host "ccs: using an isolated config dir ($home)"
        $prev = $env:CLAUDE_CONFIG_DIR
        $env:CLAUDE_CONFIG_DIR = $home
        try { & claude.exe auth login } finally { $env:CLAUDE_CONFIG_DIR = $prev }
    }
    if ($LASTEXITCODE -ne 0) { Write-Host "error: login failed" -ForegroundColor Red; exit 1 }

    $email = _AccountEmail $home
    if ($email) { Write-Host "ccs: $p@$a is now $email" } else { Write-Host "ccs: $p@$a logged in" }
    _SetLastAccount $p $a
    _WarnIsolated $home
    Write-Host "ccs: switch to it with: ccs $p@$a"
}

function Cmd-Logout([string]$spec) {
    # Requires the explicit form: this destroys credentials.
    if ([string]::IsNullOrEmpty($spec) -or -not $spec.Contains("@")) {
        Write-Host "usage: ccs logout <provider>@<account>" -ForegroundColor Red
        Write-Host "The account must be named explicitly - logout clears its credentials." -ForegroundColor Red
        exit 1
    }
    $r = _ResolveSpecOrDie $spec
    $p = $r.Provider; $a = $r.Account
    $home = _ResolveHome $p $a
    $email = _AccountEmail $home
    $suffix = if ($email) { " ($email)" } else { "" }

    Write-Host "This clears the credentials for $p@$a$suffix."
    if (_IsNativeHome $home) { Write-Host "That is the default config dir: $home" }
    if ((_ActiveSpec) -and $ACTIVE_PROVIDER -eq $p -and $ACTIVE_ACCOUNT -eq $a) {
        Write-Host "It is also the currently active account."
    }
    $reply = Read-Host "Continue? [y/N]"
    if ($reply -notmatch '^[Yy]$') { Write-Host "Aborted."; return }

    if (_IsNativeHome $home) {
        & claude.exe auth logout
    } else {
        $prev = $env:CLAUDE_CONFIG_DIR
        $env:CLAUDE_CONFIG_DIR = $home
        try { & claude.exe auth logout } finally { $env:CLAUDE_CONFIG_DIR = $prev }
    }
    Write-Host "ccs: logged out $p@$a"
}

function Cmd-Add([string]$spec) {
    if ([string]::IsNullOrEmpty($spec)) { Write-Host "usage: ccs add <provider>[@<account>]" -ForegroundColor Red; exit 1 }
    if ($spec.Contains("@")) {
        $p = $spec.Substring(0, $spec.IndexOf("@")); $a = $spec.Substring($spec.IndexOf("@") + 1)
    } else { $p = $spec; $a = "main" }

    $path = _AccountPath $p $a
    if (Test-Path $path) {
        Write-Host "error: '$p@$a' already exists (use: ccs edit $p@$a)" -ForegroundColor Red
        exit 1
    }
    New-Item -ItemType Directory -Force -Path (_AccountsDir $p) | Out-Null

    $baseUrl    = Read-Host "BASE URL"
    $authToken  = Read-Host "AUTH TOKEN"
    $model      = Read-Host "MAIN MODEL"
    $smallModel = Read-Host "SMALL/FAST MODEL"

    [ordered]@{
        env = [ordered]@{
            ANTHROPIC_BASE_URL         = $baseUrl
            ANTHROPIC_AUTH_TOKEN       = $authToken
            ANTHROPIC_MODEL            = $model
            ANTHROPIC_SMALL_FAST_MODEL = $smallModel
        }
    } | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8

    if (-not (Test-Path (_ProfileMeta $p))) {
        $auth = if ($baseUrl) { "token" } else { "oauth" }
        $meta = [ordered]@{ auth = $auth; default_account = $a; last_account = $a }
        if ($auth -eq "oauth") { $meta["native_account"] = $a }
        $meta | ConvertTo-Json -Depth 10 | Set-Content (_ProfileMeta $p) -Encoding UTF8
    }
    Write-Host "Created: $p@$a"
}

function Cmd-Edit([string]$spec) {
    if ([string]::IsNullOrEmpty($spec)) { Write-Host "usage: ccs edit <provider>[@<account>]" -ForegroundColor Red; exit 1 }
    $r = _ResolveSpecOrDie $spec
    $editor = if ($env:EDITOR) { $env:EDITOR } else { "notepad" }
    & $editor (_AccountPath $r.Provider $r.Account)
}

function Cmd-Key([string]$spec) {
    if ([string]::IsNullOrEmpty($spec)) { Write-Host "usage: ccs key <provider>[@<account>]" -ForegroundColor Red; exit 1 }
    $r = _ResolveSpecOrDie $spec
    $p = $r.Provider; $a = $r.Account

    # An OAuth account has no API key: credentials live in its config dir.
    if ((_ProviderAuth $p) -eq "oauth") {
        Write-Host "error: '$p' signs in with OAuth - there is no API key to set" -ForegroundColor Red
        Write-Host "Sign in with: ccs login $p@$a" -ForegroundColor Red
        exit 1
    }

    $path = _AccountPath $p $a
    $secureKey = Read-Host -AsSecureString "New API key for '$p@$a'"
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $newKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $json = _ReadJson $path
    if ($null -eq $json.env) { $json | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
    if ($json.env.PSObject.Properties["ANTHROPIC_AUTH_TOKEN"]) { $json.env.ANTHROPIC_AUTH_TOKEN = $newKey }
    else { $json.env | Add-Member -NotePropertyName ANTHROPIC_AUTH_TOKEN -NotePropertyValue $newKey }
    $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    Write-Host "Updated API key for $p@$a"
}

function Cmd-Remove([string]$spec) {
    if ([string]::IsNullOrEmpty($spec)) { Write-Host "usage: ccs remove <provider>[@<account>]" -ForegroundColor Red; exit 1 }

    if (-not $spec.Contains("@")) {
        if (-not (_ProviderExists $spec)) { Write-Host "error: profile '$spec' not found" -ForegroundColor Red; exit 1 }
        $accounts = @(_ListAccounts $spec)
        Write-Host "This removes provider '$spec' and all $($accounts.Count) of its accounts."
        $reply = Read-Host "Continue? [y/N]"
        if ($reply -notmatch '^[Yy]$') { Write-Host "Aborted."; return }
        $kept = @()
        foreach ($a in $accounts) {
            $h = _ResolveHome $spec $a
            if (-not (_IsNativeHome $h) -and (Test-Path $h)) { $kept += $h }
        }
        if ((_ActiveSpec) -and $ACTIVE_PROVIDER -eq $spec) {
            Remove-Item $ACTIVE_LINK, $ACTIVE_SPEC_FILE, $ACTIVE_HOME_FILE -Force -ErrorAction SilentlyContinue
        }
        Remove-Item (_ProfileDir $spec) -Recurse -Force
        Write-Host "Removed: $spec"
        if ($kept.Count -gt 0) {
            Write-Host "Config dirs were kept (they hold credentials and history):"
            $kept | ForEach-Object { Write-Host "  $_" }
        }
        return
    }

    $r = _ResolveSpecOrDie $spec
    $p = $r.Provider; $a = $r.Account
    if (@(_ListAccounts $p).Count -le 1) {
        Write-Host "error: '$a' is the only account for '$p'" -ForegroundColor Red
        Write-Host "Remove the whole provider with: ccs remove $p" -ForegroundColor Red
        exit 1
    }
    $home = _ResolveHome $p $a
    if ((_ActiveSpec) -and $ACTIVE_PROVIDER -eq $p -and $ACTIVE_ACCOUNT -eq $a) {
        Remove-Item $ACTIVE_LINK, $ACTIVE_SPEC_FILE, $ACTIVE_HOME_FILE -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (_AccountPath $p $a) -Force
    if ((_MetaGet $p "last_account") -eq $a) { _SetLastAccount $p (_DefaultAccount $p) }
    Write-Host "Removed: $p@$a"
    # Kept on purpose: it holds credentials and history, and `ccs logout` can no
    # longer reach this account.
    if (-not (_IsNativeHome $home) -and (Test-Path $home)) {
        Write-Host "Its config dir was kept (credentials and history):"
        Write-Host "  $home"
        Write-Host "Delete it to discard those. Next time, 'ccs logout $p@$a'"
        Write-Host "first if you want the credentials revoked properly."
    }
}

function Cmd-Test([string]$spec) {
    if ($spec) {
        $r = _ResolveSpecOrDie $spec
        $p = $r.Provider; $a = $r.Account
    } else {
        if (-not (_ActiveSpec)) { Write-Host "error: no active account (run: ccs switch <provider>)" -ForegroundColor Red; exit 1 }
        $p = $ACTIVE_PROVIDER; $a = $ACTIVE_ACCOUNT
    }

    # OAuth accounts have no API key to sign a request with, so ask Claude Code
    # about the account's config dir instead.
    if ((_ProviderAuth $p) -eq "oauth") {
        $home = _ResolveHome $p $a
        Write-Host -NoNewline "Testing $p@$a... "
        if (_IsNativeHome $home) {
            $out = & claude.exe auth status --json 2>&1 | Out-String
        } else {
            $prev = $env:CLAUDE_CONFIG_DIR
            $env:CLAUDE_CONFIG_DIR = $home
            try { $out = & claude.exe auth status --json 2>&1 | Out-String } finally { $env:CLAUDE_CONFIG_DIR = $prev }
        }
        try { $st = $out | ConvertFrom-Json } catch { $st = $null }
        if ($null -ne $st -and $st.loggedIn) {
            $extra = @($st.email, $st.subscriptionType) | Where-Object { $_ }
            if ($extra) { Write-Host "OK ($($extra -join ', '))" } else { Write-Host "OK" }
        } else {
            Write-Host "NOT LOGGED IN"
            Write-Host "Sign in with: ccs login $p@$a" -ForegroundColor Red
            exit 1
        }
        return
    }

    $path = _AccountPath $p $a
    $baseUrl   = _ReadEnvField $path "ANTHROPIC_BASE_URL"
    $authToken = _ReadEnvField $path "ANTHROPIC_AUTH_TOKEN"
    $model     = _ReadEnvField $path "ANTHROPIC_MODEL"
    if (-not $authToken) {
        Write-Host "error: '$p@$a' has no API key set (ccs key $p@$a)" -ForegroundColor Red
        exit 1
    }

    Write-Host -NoNewline "Testing $p@$a ($model)... "
    $body = ConvertTo-Json -Depth 5 @{
        model = $model; max_tokens = 1; messages = @(@{ role = "user"; content = "hi" })
    }
    try {
        Invoke-RestMethod -Uri "$baseUrl/messages" -Method POST -Headers @{
            "x-api-key" = $authToken; "anthropic-version" = "2023-06-01"; "content-type" = "application/json"
        } -Body $body -ErrorAction Stop | Out-Null
        Write-Host "OK"
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        $msg = ""
        try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch {}
        # Some providers echo the rejected key back; never relay it.
        if ($msg -and $authToken) { $msg = $msg.Replace($authToken, "***") }
        $suffix = if ($msg) { ": $msg" } else { "" }
        Write-Host "FAIL (HTTP $status$suffix)"
        exit 1
    }
}

function Cmd-Run([string]$spec, [string[]]$rest) {
    if ([string]::IsNullOrEmpty($spec)) {
        Write-Host "usage: ccs run <provider>[@<account>] [claude args...]" -ForegroundColor Red
        exit 1
    }
    $r = _ResolveSpecOrDie $spec
    $path = _AccountPath $r.Provider $r.Account
    $home = _ResolveHome $r.Provider $r.Account
    # Sets the config dir in this process, so it works with no shell integration
    # loaded - the escape hatch when 'claude' is not the ccs function.
    if (_IsNativeHome $home) {
        & claude.exe --settings $path @rest
    } else {
        _PrepareHome $home
        $prev = $env:CLAUDE_CONFIG_DIR
        $env:CLAUDE_CONFIG_DIR = $home
        try { & claude.exe --settings $path @rest } finally { $env:CLAUDE_CONFIG_DIR = $prev }
    }
}

$CLEAN_STATE = "$CCS_DIR\clean.state"

# Disable agents/skills for one session without touching any other account.
#
# Keyed on what the entry actually is in the resolved home: a junction (isolated
# home) is removed, never its target, so nothing outside this home changes. A
# real directory (the default home) is moved aside, which does affect any
# concurrent session on another account -- so that case says so.
function Cmd-Clean([string]$spec, [string[]]$rest) {
    if ($spec) {
        $r = _ResolveSpecOrDie $spec
        $p = $r.Provider; $a = $r.Account
    } else {
        if (-not (_ActiveSpec)) { Write-Host "error: no active account (run: ccs switch <provider>)" -ForegroundColor Red; exit 1 }
        $p = $ACTIVE_PROVIDER; $a = $ACTIVE_ACCOUNT
    }

    $path = _AccountPath $p $a
    $home = _ResolveHome $p $a
    _PrepareHome $home

    $entries = @()
    foreach ($item in @("agents", "skills")) {
        $target = Join-Path $home $item
        $it = Get-Item $target -Force -ErrorAction SilentlyContinue
        if ($null -eq $it) { continue }
        if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $dest = Join-Path $SHARED_DIR $item
            Remove-Item $target -Force -Recurse -ErrorAction SilentlyContinue
            $entries += "link|$item|$dest"
            Write-Host "ccs: disabled $item for this session (this account only)"
        } elseif ($it.PSIsContainer) {
            Move-Item $target "$target.ccs-disabled" -Force
            $entries += "move|$item|"
            Write-Host "ccs: disabled $item for this session"
            if (_IsNativeHome $home) {
                Write-Host "ccs: note - $item is a real directory here, so any concurrent" -ForegroundColor Yellow
                Write-Host "ccs: session on another account loses it until this one exits" -ForegroundColor Yellow
            }
        }
    }

    # On disk, not just in memory: a killed window must still be recoverable via
    # `ccs clean --restore`.
    if ($entries.Count -gt 0) {
        (@("home=$home") + ($entries | ForEach-Object { "entry=$_" })) |
            Set-Content $CLEAN_STATE -Encoding UTF8
    } else {
        Remove-Item $CLEAN_STATE -Force -ErrorAction SilentlyContinue
    }

    try {
        if (_IsNativeHome $home) {
            & claude.exe --settings $path @rest
        } else {
            $prev = $env:CLAUDE_CONFIG_DIR
            $env:CLAUDE_CONFIG_DIR = $home
            try { & claude.exe --settings $path @rest } finally { $env:CLAUDE_CONFIG_DIR = $prev }
        }
    } finally {
        _CleanRestoreFromState
    }
}

function _CleanRestoreFromState {
    if (-not (Test-Path $CLEAN_STATE -PathType Leaf)) { return }
    $home = ""
    foreach ($line in @(Get-Content $CLEAN_STATE)) {
        if ($line -like "home=*") { $home = $line.Substring(5); continue }
        if (-not ($line -like "entry=*")) { continue }
        $parts = $line.Substring(6).Split("|")
        $kind = $parts[0]; $item = $parts[1]; $dest = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $target = Join-Path $home $item
        if ($kind -eq "link") {
            if (-not (Test-Path $target) -and (Test-Path $dest)) {
                _LinkItem $dest $target
                Write-Host "ccs: restored $item"
            }
        } elseif ($kind -eq "move") {
            if ((Test-Path "$target.ccs-disabled") -and -not (Test-Path $target)) {
                Move-Item "$target.ccs-disabled" $target -Force
                Write-Host "ccs: restored $item"
            }
        }
    }
    Remove-Item $CLEAN_STATE -Force -ErrorAction SilentlyContinue
}

# Recovery for a crashed session: the state file when present, plus a sweep of
# every known home for leftovers, so a crash from before this change recovers too.
function Cmd-CleanRestore {
    _CleanRestoreFromState
    foreach ($p in @(_ListProviders)) {
        foreach ($a in @(_ListAccounts $p)) {
            $home = _ResolveHome $p $a
            foreach ($item in @("agents", "skills")) {
                $disabled = Join-Path $home "$item.ccs-disabled"
                $target = Join-Path $home $item
                if ((Test-Path $disabled) -and -not (Test-Path $target)) {
                    Move-Item $disabled $target -Force
                    Write-Host "ccs: restored $item in $home"
                }
            }
        }
    }
    Write-Host "ccs: cleanup complete"
}

function Cmd-Doctor {
    $problems = 0
    $warnings = 0
    Write-Host "ccs doctor"; Write-Host ""

    Write-Host "shell integration"
    if (_WrapperLoaded) { Write-Host "  ok    loaded in this session (CCS_WRAPPER set)" }
    else { Write-Host "  warn  not loaded - run: ccs shell-install, then open a new window"; $warnings++ }

    if ($PROFILE -and (Test-Path $PROFILE)) {
        $lines = @(Get-Content $PROFILE)
        $blocks = @($lines | Where-Object { $_.TrimEnd() -eq $CCS_BLOCK_START }).Count
        $legacy = @($lines | Where-Object { $_ -match '^\s*Set-Alias\s+claude\b' }).Count
        if ($blocks -eq 1) { Write-Host "  ok    $PROFILE`: one ccs block" }
        elseif ($blocks -eq 0) { Write-Host "  warn  $PROFILE`: no ccs block - run: ccs shell-install"; $warnings++ }
        else { Write-Host "  FAIL  $PROFILE`: $blocks ccs blocks - run: ccs shell-install"; $problems++ }
        if ($legacy -gt 0) { Write-Host "  FAIL  $PROFILE`: $legacy legacy 'Set-Alias claude' line(s)"; $problems++ }
    } else {
        Write-Host "  warn  no PowerShell profile found"; $warnings++
    }
    Write-Host "  note  ccs cannot see this session's aliases; confirm with: Get-Command claude"

    Write-Host ""; Write-Host "active selection"
    if (_ActiveSpec) {
        Write-Host "  ok    active: $ACTIVE_PROVIDER@$ACTIVE_ACCOUNT"
        if (Test-Path $ACTIVE_LINK) { Write-Host "  ok    settings resolve: $ACTIVE_LINK" }
        else { Write-Host "  FAIL  active settings file is missing"; $problems++ }

        # active-home.path is the single file wrong-account routing depends on,
        # and it is the one fault the wrapper cannot report: it falls back to the
        # default config dir when the recorded path is missing or gone. Silent,
        # and the wrong subscription. Every fault here is a FAIL.
        $repairCmd = "ccs $ACTIVE_PROVIDER@$ACTIVE_ACCOUNT"
        $want = _ResolveHome $ACTIVE_PROVIDER $ACTIVE_ACCOUNT
        $recorded = _ActiveHome
        if (-not $recorded) {
            Write-Host "  FAIL  active-home.path is missing - claude would use $DEFAULT_HOME"
            Write-Host "        regardless of the active account; repair: $repairCmd"
            $problems++
        } elseif (-not (Test-Path $recorded -PathType Container)) {
            Write-Host "  FAIL  active-home.path points at $recorded, which does not exist;"
            Write-Host "        the wrapper silently falls back to $DEFAULT_HOME; repair: $repairCmd"
            $problems++
        } elseif ((_NormPath $recorded) -ine (_NormPath $want)) {
            Write-Host "  FAIL  active-home.path is $recorded but $ACTIVE_PROVIDER@$ACTIVE_ACCOUNT"
            Write-Host "        resolves to $want; claude would run the wrong account; repair: $repairCmd"
            $problems++
        } else {
            Write-Host "  ok    active-home resolves: $want"
        }
    } else {
        Write-Host "  warn  no active account - run: ccs switch <provider>"; $warnings++
    }

    # shared\ is the hinge every isolated home hangs off, so a fault here is a
    # fault in every isolated account at once. Until this check existed, an entry
    # missing from shared\ was reported as intact.
    Write-Host ""; Write-Host "shared configuration"
    $repair = if (_ActiveSpec) { "ccs $ACTIVE_PROVIDER@$ACTIVE_ACCOUNT" } else { "ccs switch <provider>" }
    $sharedItems = @(_SharedItems)
    $sharedBad = 0
    foreach ($item in $sharedItems) {
        switch (_SharedStatus $item) {
            "missing" {
                Write-Host "  FAIL  shared\$item is missing, so sharing of it has stopped"
                Write-Host "        $(_SharedItemCost $item)"
                Write-Host "        repair: $repair"
                $problems++; $sharedBad++
            }
            "diverged" {
                # Sharing has genuinely stopped. The repair displaces this content
                # rather than discarding it, so say so before the switch does it.
                Write-Host "  FAIL  shared\$item is a file that differs from $DEFAULT_HOME\$item"
                Write-Host "        $(_SharedItemCost $item)"
                Write-Host "        compare: fc.exe `"$SHARED_DIR\$item`" `"$DEFAULT_HOME\$item`""
                Write-Host "        $repair moves it to backups\displaced\ and restores the link"
                $problems++; $sharedBad++
            }
            "real" {
                # A directory. Never auto-repaired: merging two directories is not
                # a choice ccs can make for the user.
                Write-Host "  FAIL  shared\$item is real content that differs from $DEFAULT_HOME\$item"
                Write-Host "        $(_SharedItemCost $item)"
                Write-Host "        compare: robocopy /L /E `"$SHARED_DIR\$item`" `"$DEFAULT_HOME\$item`""
                Write-Host "        keep the version you want, move the other aside, then run: $repair"
                $problems++; $sharedBad++
            }
        }
    }

    # Content a repair moved out of the way. Nothing is broken -- the file is
    # preserved and sharing is back -- but restoring the link also reverts
    # whatever the displaced version held, and the line saying so scrolled past
    # during a switch. Report it here so that stays recoverable.
    $displacedDir = Join-Path $BACKUPS_DIR "displaced"
    if (Test-Path $displacedDir) {
        foreach ($d in @(Get-ChildItem $displacedDir -Force -ErrorAction SilentlyContinue)) {
            Write-Host "  note  moved aside by a repair, not deleted: $($d.FullName)"
            Write-Host "        compare with the live one, then delete it once reviewed"
        }
    }

    if ($sharedItems.Count -eq 0) {
        Write-Host "  warn  nothing to share - $DEFAULT_HOME looks empty"; $warnings++
    } elseif ($sharedBad -eq 0) {
        Write-Host "  ok    $($sharedItems.Count) shared item(s) linked to $DEFAULT_HOME"
    }

    # `claude mcp list` shows two kinds of entry and ccs can only see one:
    # servers added with `claude mcp add` (.mcpServers in the per-account
    # .claude.json) and account-managed claude.ai connectors, which are fetched
    # per claude.ai org and never cached on disk.
    #
    # The first version of this check counted only the former and labelled it
    # "user-scope server(s)". With three connectors on one account and none on the
    # other it printed 0/0 and no warning, because .mcpServers was empty in both --
    # reporting "aligned" for the very divergence it was written to catch. So the
    # incompleteness is now stated unconditionally, never inferred from a count.
    Write-Host ""; Write-Host "MCP servers"
    $mcpReported = $false
    foreach ($p in @(_ListProviders)) {
        if ((_ProviderAuth $p) -ne "oauth") { continue }
        $firstNames = $null
        $firstEver = $null
        $diverged = $false
        $everDiverged = $false
        foreach ($a in @(_ListAccounts $p)) {
            $home = _ResolveHome $p $a
            $names = @(_McpServers $home)
            $ever  = @(_McpEverConnected $home)
            Write-Host "  note  $p@$a`: $($names.Count) added with 'claude mcp add', $($ever.Count) claude.ai connector(s) ever connected"
            $mcpReported = $true
            if ($null -eq $firstNames) { $firstNames = $names; $firstEver = $ever }
            else {
                if (($names -join "`n") -ne ($firstNames -join "`n")) { $diverged = $true }
                if (($ever -join "`n") -ne ($firstEver -join "`n")) { $everDiverged = $true }
            }
        }
        if ($diverged) {
            Write-Host "  warn  $p`: accounts have different 'claude mcp add' servers - they"
            Write-Host "        live in .claude.json, which is per-account, so they do not follow a switch."
            Write-Host "        Add one to the account that is missing it: claude mcp add <name> ..."
            $warnings++
        }
        if ($everDiverged) {
            Write-Host "  warn  $p`: accounts have connected different claude.ai connectors"
            Write-Host "        Connectors follow the claude.ai account, not the config dir, so ccs"
            Write-Host "        cannot copy them. Align them at https://claude.ai/customize/connectors"
            $warnings++
        }
    }
    if ($mcpReported) {
        # Unconditional, and deliberately not an "ok": the counts above cannot be
        # complete, so any summary reading as "aligned" would be the original bug.
        Write-Host "  note  ccs cannot see account-managed claude.ai connectors - these counts"
        Write-Host "        are incomplete. Compare with: claude mcp list"
    } else {
        Write-Host "  ok    no OAuth accounts to compare"
    }

    Write-Host ""; Write-Host "accounts"
    foreach ($p in @(_ListProviders)) {
        foreach ($a in @(_ListAccounts $p)) {
            $home = _ResolveHome $p $a
            if (_IsNativeHome $home) {
                Write-Host "  ok    $p@$a`: default config dir (background agents available)"
                continue
            }
            if (Test-Path $home) {
                $email = _AccountEmail $home
                $suffix = if ($email) { " ($email)" } else { "" }
                Write-Host "  ok    $p@$a`: isolated$suffix - background agents unavailable"
            } else {
                Write-Host "  warn  $p@$a`: home not created yet - run: ccs login $p@$a"; $warnings++
            }
            foreach ($item in _SharedItems) {
                $link = Join-Path $home $item
                $it = Get-Item $link -Force -ErrorAction SilentlyContinue
                if ($null -eq $it) {
                    # Absence was the invisible case: this loop used to `continue`
                    # here, so doctor said nothing while the account was missing
                    # the item entirely.
                    Write-Host "  FAIL  $p@$a`: $item is not linked into this account; repair: ccs $p@$a"
                    $problems++
                    continue
                }
                if (-not ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $it.PSIsContainer) {
                    Write-Host "  warn  $p@$a`: $item is a real directory, not shared"; $warnings++
                }
            }
        }
    }

    Write-Host ""
    if ($problems -gt 0) { Write-Host "result: problems found"; exit 1 }
    elseif ($warnings -gt 0) { Write-Host "result: $warnings warning(s)" }
    else { Write-Host "result: all good" }
}

function Show-Help {
    Write-Host @"
ccs - Claude Code Switcher

Usage: ccs <command> [args]

Commands:
  list              List all providers and accounts
  switch <p>[@<a>]  Set the active account
  current           Show the active account
  add <p>[@<a>]     Add a profile interactively
  edit <p>[@<a>]    Edit a profile in `$EDITOR / notepad
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
  doctor            Check shell integration, links and settings
  shell-install     (Re)install the shell integration in `$PROFILE

Most commands accept <provider>@<account> as well as a bare <provider>.

Available providers:
"@
    Cmd-List
}

# ── entry point ──────────────────────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $PROFILES_DIR | Out-Null
_MigrateFlatLayout

$cmd  = if ($args.Count -gt 0) { $args[0] } else { "" }
$arg1 = if ($args.Count -gt 1) { $args[1] } else { "" }
$rest = if ($args.Count -gt 2) { $args[2..($args.Count - 1)] } else { @() }

switch ($cmd) {
    { $_ -eq "" -or $_ -eq "list" } { Cmd-List }
    "switch"   { Cmd-Switch $arg1 }
    "current"  { Cmd-Current }
    "add"      { Cmd-Add $arg1 }
    "edit"     { Cmd-Edit $arg1 }
    "key"      { Cmd-Key $arg1 }
    "remove"   { Cmd-Remove $arg1 }
    "test"     { Cmd-Test $arg1 }
    "run"      { Cmd-Run $arg1 $rest }
    "clean"    {
        if ($arg1 -eq "--restore") { Cmd-CleanRestore }
        else { Cmd-Clean $arg1 $rest }
    }
    "next"     { Cmd-Next }
    "login"    { Cmd-Login $arg1 }
    "logout"   { Cmd-Logout $arg1 }
    "accounts" { Cmd-Accounts $arg1 }
    "doctor"   { Cmd-Doctor }
    "shell-install" { _ShellInstall }
    { $_ -in @("help", "--help", "-h") } { Show-Help }
    default {
        # Bare <provider> or <provider>@<account> is shorthand for switch.
        $bare = $cmd
        $p = if ($bare -and $bare.Contains("@")) { $bare.Substring(0, $bare.IndexOf("@")) } else { $bare }
        if ($null -ne (_ParseSpec $bare) -or (_ProviderExists $p)) {
            Cmd-Switch $bare
        } else {
            Write-Host "Unknown command: $cmd"
            Write-Host ""
            Show-Help
        }
    }
}
