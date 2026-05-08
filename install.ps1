#Requires -Version 5.1

$INSTALL_DIR = "$env:USERPROFILE\.local\bin"
$CCS_DIR     = "$env:USERPROFILE\.config\claude-profiles"
$PROFILES_DIR = "$CCS_DIR\profiles"
$RAW_BASE    = "https://raw.githubusercontent.com/lizzyman04/claude-code-switcher/main"

New-Item -ItemType Directory -Force -Path $INSTALL_DIR  | Out-Null
New-Item -ItemType Directory -Force -Path $PROFILES_DIR | Out-Null

Write-Host "Installing ccs to $INSTALL_DIR\ccs.ps1..."
Invoke-WebRequest -Uri "$RAW_BASE/src/ccs.ps1" -OutFile "$INSTALL_DIR\ccs.ps1"

Write-Host "Installing default profiles..."
@("anthropic", "deepseek", "openai") | ForEach-Object {
    Invoke-WebRequest -Uri "$RAW_BASE/profiles/$_.json" -OutFile "$PROFILES_DIR\$_.json"
}

if (Test-Path "$CCS_DIR\active") { Remove-Item "$CCS_DIR\active" -Force }
New-Item -ItemType SymbolicLink -Path "$CCS_DIR\active" -Target "$PROFILES_DIR\anthropic.json" | Out-Null

Write-Host ""
Write-Host "ccs installed!"
Write-Host "Add this to your PowerShell profile:"
Write-Host '  Set-Alias ccs "$env:USERPROFILE\.local\bin\ccs.ps1"'
