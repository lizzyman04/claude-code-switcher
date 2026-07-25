#Requires -Version 5.1

$INSTALL_DIR  = "$env:USERPROFILE\.local\bin"
$CCS_DIR      = "$env:USERPROFILE\.config\claude-profiles"
$PROFILES_DIR = "$CCS_DIR\profiles"
$RAW_BASE     = "https://raw.githubusercontent.com/lizzyman04/claude-code-switcher/main"

New-Item -ItemType Directory -Force -Path $INSTALL_DIR  | Out-Null
New-Item -ItemType Directory -Force -Path $PROFILES_DIR | Out-Null

Write-Host "Installing ccs to $INSTALL_DIR\ccs.ps1..."
Invoke-WebRequest -Uri "$RAW_BASE/src/ccs.ps1" -OutFile "$INSTALL_DIR\ccs.ps1"

Write-Host "Installing default profiles..."

# Only seed a provider that is absent, so re-running never overwrites an account
# file the user has put an API key in.
@("anthropic", "deepseek") | ForEach-Object {
    $dir = "$PROFILES_DIR\$_"
    if (-not (Test-Path "$dir\accounts")) {
        New-Item -ItemType Directory -Force -Path "$dir\accounts" | Out-Null
        Invoke-WebRequest -Uri "$RAW_BASE/profiles/$_/profile.json" -OutFile "$dir\profile.json"
        Invoke-WebRequest -Uri "$RAW_BASE/profiles/$_/accounts/main.json" -OutFile "$dir\accounts\main.json"
    }
}

# The shell integration is installed by ccs itself, so the block exists in
# exactly one place (src/ccs.ps1) rather than being duplicated here. It replaces
# any `Set-Alias claude` -- an alias cannot set CLAUDE_CONFIG_DIR, which
# multi-account switching requires.
Write-Host ""
& "$INSTALL_DIR\ccs.ps1" shell-install

# ccs itself is fine as an alias: it needs no environment of its own.
$ccsAlias = 'Set-Alias ccs "$env:USERPROFILE\.local\bin\ccs.ps1"'
if ($PROFILE -and (Test-Path $PROFILE)) {
    if (-not (Select-String -Path $PROFILE -SimpleMatch 'Set-Alias ccs' -Quiet -ErrorAction SilentlyContinue)) {
        Add-Content $PROFILE "`n$ccsAlias"
        Write-Host "ccs: added the ccs alias to $PROFILE"
    }
}

if (-not (Test-Path "$CCS_DIR\active")) {
    & "$INSTALL_DIR\ccs.ps1" switch anthropic
}

Write-Host ""
Write-Host "----------------------------------------"
Write-Host "ccs installed!"
Write-Host "Open a new PowerShell window, or run: . `$PROFILE"
Write-Host ""
& "$INSTALL_DIR\ccs.ps1" --help
