#Requires -Version 5.1

$CCS_DIR = "$HOME\.config\claude-profiles"
$PROFILES_DIR = "$CCS_DIR\profiles"
$ACTIVE_LINK = "$CCS_DIR\active"

function _ProfilePath([string]$name) {
    return Join-Path $PROFILES_DIR "$name.json"
}

function _ActiveName {
    if (-not (Test-Path $ACTIVE_LINK)) { return "(none)" }
    $item = Get-Item $ACTIVE_LINK -ErrorAction SilentlyContinue
    if (-not $item) { return "(none)" }
    return [System.IO.Path]::GetFileNameWithoutExtension($item.Target)
}

function _ReadEnvField([string]$path, [string]$field) {
    $json = Get-Content $path -Raw | ConvertFrom-Json
    $val = $json.env.$field
    if ($null -eq $val) { return "" }
    return $val
}

function Cmd-List {
    $active = _ActiveName
    $profiles = @(Get-ChildItem $PROFILES_DIR -Filter "*.json" -ErrorAction SilentlyContinue)
    if ($profiles.Count -eq 0) {
        Write-Host "No profiles found. Run: ccs add <name>"
        return
    }
    foreach ($f in $profiles) {
        $name = $f.BaseName
        if ($name -eq $active) {
            Write-Host "* $name (active)"
        } else {
            Write-Host "  $name"
        }
    }
}

function Cmd-Switch([string]$name) {
    if ([string]::IsNullOrEmpty($name)) {
        Write-Host "Available profiles:"
        Cmd-List
        Write-Host ""
        Write-Host "Usage: ccs switch <name>"
        exit 1
    }
    $path = _ProfilePath $name
    if (-not (Test-Path $path)) {
        Write-Error "error: profile '$name' not found"
        exit 1
    }

    $baseUrl = _ReadEnvField $path "ANTHROPIC_BASE_URL"
    $token   = _ReadEnvField $path "ANTHROPIC_AUTH_TOKEN"

    if (-not [string]::IsNullOrEmpty($baseUrl)) {
        if ([string]::IsNullOrEmpty($token) -or $token -eq '""') {
            Write-Error "error: profile '$name' has no API key set"
            Write-Host "Set it with: ccs key $name" -ForegroundColor Red
            exit 1
        }
    }

    if (Test-Path $ACTIVE_LINK) { Remove-Item $ACTIVE_LINK -Force }
    New-Item -ItemType SymbolicLink -Path $ACTIVE_LINK -Target $path | Out-Null
    Write-Host "Switched to $name"
}

function Cmd-Current {
    $active = _ActiveName
    if ($active -eq "(none)") {
        Write-Host "No active profile. Run: ccs switch <name>"
        return
    }
    Write-Host "Active: $active"
    $json = Get-Content $ACTIVE_LINK -Raw | ConvertFrom-Json
    if ($json.env.PSObject.Properties["ANTHROPIC_AUTH_TOKEN"]) {
        $json.env.PSObject.Properties.Remove("ANTHROPIC_AUTH_TOKEN")
    }
    $json | ConvertTo-Json -Depth 10
}

function Cmd-Add([string]$name) {
    if ([string]::IsNullOrEmpty($name)) {
        Write-Error "usage: ccs add <name>"
        exit 1
    }
    $path = _ProfilePath $name
    if (Test-Path $path) {
        Write-Error "error: profile '$name' already exists (use: ccs edit $name)"
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $PROFILES_DIR | Out-Null

    $baseUrl    = Read-Host "BASE URL"
    $authToken  = Read-Host "AUTH TOKEN"
    $model      = Read-Host "MAIN MODEL"
    $smallModel = Read-Host "SMALL/FAST MODEL"

    [ordered]@{
        env = [ordered]@{
            ANTHROPIC_BASE_URL       = $baseUrl
            ANTHROPIC_AUTH_TOKEN     = $authToken
            ANTHROPIC_MODEL          = $model
            ANTHROPIC_SMALL_FAST_MODEL = $smallModel
        }
    } | ConvertTo-Json -Depth 10 | Set-Content $path
    Write-Host "Created: $name"
}

function Cmd-Edit([string]$name) {
    if ([string]::IsNullOrEmpty($name)) {
        Write-Error "usage: ccs edit <name>"
        exit 1
    }
    $path = _ProfilePath $name
    if (-not (Test-Path $path)) {
        Write-Error "error: profile '$name' not found"
        exit 1
    }
    $editor = if ($env:EDITOR) { $env:EDITOR } else { "notepad" }
    & $editor $path
}

function Cmd-Key([string]$name) {
    if ([string]::IsNullOrEmpty($name)) {
        Write-Error "usage: ccs key <name>"
        exit 1
    }
    $path = _ProfilePath $name
    if (-not (Test-Path $path)) {
        Write-Error "error: profile '$name' not found"
        exit 1
    }
    $secureKey = Read-Host -AsSecureString "New API key for '$name'"
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $newKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $json = Get-Content $path -Raw | ConvertFrom-Json
    $json.env.ANTHROPIC_AUTH_TOKEN = $newKey
    $json | ConvertTo-Json -Depth 10 | Set-Content $path
    Write-Host "Updated API key for $name"
}

function Cmd-Remove([string]$name) {
    if ([string]::IsNullOrEmpty($name)) {
        Write-Error "usage: ccs remove <name>"
        exit 1
    }
    $path = _ProfilePath $name
    if (-not (Test-Path $path)) {
        Write-Error "error: profile '$name' not found"
        exit 1
    }
    if (Test-Path $ACTIVE_LINK) {
        $target = (Get-Item $ACTIVE_LINK).Target
        if ($target -eq $path) { Remove-Item $ACTIVE_LINK -Force }
    }
    Remove-Item $path -Force
    Write-Host "Removed: $name"
}

function Cmd-Test {
    if (-not (Test-Path $ACTIVE_LINK)) {
        Write-Error "error: no active profile (run: ccs switch <name>)"
        exit 1
    }

    $baseUrl   = _ReadEnvField $ACTIVE_LINK "ANTHROPIC_BASE_URL"
    $authToken = _ReadEnvField $ACTIVE_LINK "ANTHROPIC_AUTH_TOKEN"
    $model     = _ReadEnvField $ACTIVE_LINK "ANTHROPIC_MODEL"

    Write-Host -NoNewline "Testing $(_ActiveName) ($model)... "

    $body = ConvertTo-Json -Depth 5 @{
        model      = $model
        max_tokens = 1
        messages   = @(@{ role = "user"; content = "hi" })
    }

    try {
        Invoke-RestMethod -Uri "$baseUrl/messages" `
            -Method POST `
            -Headers @{
                "x-api-key"          = $authToken
                "anthropic-version"  = "2023-06-01"
                "content-type"       = "application/json"
            } `
            -Body $body `
            -ErrorAction Stop | Out-Null
        Write-Host "OK"
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        $msg = ""
        try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch {}
        $suffix = if ($msg) { ": $msg" } else { "" }
        Write-Host "FAIL (HTTP $status$suffix)"
        exit 1
    }
}

function Cmd-Run([string]$name, [string[]]$rest) {
    if ([string]::IsNullOrEmpty($name)) {
        Write-Error "usage: ccs run <name> [claude args...]"
        exit 1
    }
    $path = _ProfilePath $name
    if (-not (Test-Path $path)) {
        Write-Error "error: profile '$name' not found"
        exit 1
    }
    & claude --settings $path @rest
}

function Show-Help {
    Write-Host @"
ccs — Claude Code Switcher

Usage: ccs <command> [args]

Commands:
  list              List all profiles
  switch <name>     Set active profile
  current           Show active profile
  add <name>        Add a new profile interactively
  edit <name>       Edit profile in `$EDITOR / notepad
  key <name>        Update API key for a profile
  remove <name>     Delete a profile
  test              Test active profile connection
  run <name> [...]  Run claude with a specific profile
"@
}

New-Item -ItemType Directory -Force -Path $PROFILES_DIR | Out-Null

$cmd  = if ($args.Count -gt 0) { $args[0] } else { "" }
$arg1 = if ($args.Count -gt 1) { $args[1] } else { "" }
$rest = if ($args.Count -gt 2) { $args[2..($args.Count - 1)] } else { @() }

switch ($cmd) {
    { $_ -eq "" -or $_ -eq "list" } { Cmd-List }
    "switch"  { Cmd-Switch $arg1 }
    "current" { Cmd-Current }
    "add"     { Cmd-Add $arg1 }
    "edit"    { Cmd-Edit $arg1 }
    "key"     { Cmd-Key $arg1 }
    "remove"  { Cmd-Remove $arg1 }
    "test"    { Cmd-Test }
    "run"     { Cmd-Run $arg1 $rest }
    { $_ -in @("help", "--help", "-h") } { Show-Help }
    default {
        Write-Host "Unknown command: $cmd"
        Write-Host ""
        Cmd-List
    }
}
