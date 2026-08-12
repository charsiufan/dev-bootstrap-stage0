$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Development Bootstrap - Stage 0" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Test-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

# ------------------------------------------------------------
# WinGet
# ------------------------------------------------------------

if (-not (Test-Command "winget")) {
    throw "WinGet is not available. Install/update Windows App Installer first."
}

Write-Host "[OK]      WinGet available."

# ------------------------------------------------------------
# Git
# ------------------------------------------------------------

if (-not (Test-Command "git")) {
    Write-Host "[INSTALL] Git" -ForegroundColor Yellow

    winget install `
        --id Git.Git `
        --exact `
        --source winget `
        --accept-source-agreements `
        --accept-package-agreements

    Refresh-Path
}
else {
    Write-Host "[KEEP]    Git already installed."
}

# ------------------------------------------------------------
# GitHub CLI
# ------------------------------------------------------------

if (-not (Test-Command "gh")) {
    Write-Host "[INSTALL] GitHub CLI" -ForegroundColor Yellow

    winget install `
        --id GitHub.cli `
        --exact `
        --source winget `
        --accept-source-agreements `
        --accept-package-agreements

    Refresh-Path
}
else {
    Write-Host "[KEEP]    GitHub CLI already installed."
}

# ------------------------------------------------------------
# GitHub authentication
# ------------------------------------------------------------

function Test-GitHubAuthentication {
    cmd.exe /d /c "gh auth status --hostname github.com >nul 2>&1"
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-GitHubAuthentication)) {
    Write-Host ""
    Write-Host "[LOGIN]   GitHub authentication required." -ForegroundColor Yellow
    Write-Host "          A browser window will open for GitHub sign-in."
    Write-Host ""

    gh auth login `
        --hostname github.com `
        --git-protocol https `
        --web

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub authentication was not completed."
    }

    if (-not (Test-GitHubAuthentication)) {
        throw "GitHub authentication could not be verified."
    }
}

Write-Host "[OK]      GitHub authenticated."

# ------------------------------------------------------------
# DEV_ROOT
# ------------------------------------------------------------

if (Test-Path "D:\") {
    $DevRoot = "D:\Users\$env:USERNAME\Dev"
}
else {
    $DevRoot = Join-Path $HOME "Dev"
}

[Environment]::SetEnvironmentVariable("DEV_ROOT", $DevRoot, "User")
$env:DEV_ROOT = $DevRoot

$projectsRoot = Join-Path $DevRoot "projects"
$bootstrapPath = Join-Path $projectsRoot "dev-bootstrap"

New-Item -ItemType Directory -Force -Path $projectsRoot | Out-Null

Write-Host ""
Write-Host "DEV_ROOT:"
Write-Host "  $DevRoot"

# ------------------------------------------------------------
# Clone bootstrap repository
# ------------------------------------------------------------

if (Test-Path (Join-Path $bootstrapPath ".git")) {
    Write-Host "[KEEP]    dev-bootstrap already cloned."
}
elseif (Test-Path $bootstrapPath) {
    throw "Destination already exists but is not a Git repository: $bootstrapPath"
}
else {
    Write-Host "[CLONE]   charsiufan/dev-bootstrap" -ForegroundColor Yellow

    gh repo clone charsiufan/dev-bootstrap $bootstrapPath

    if ($LASTEXITCODE -ne 0) {
        throw "Could not clone dev-bootstrap."
    }

    Write-Host "[OK]      dev-bootstrap cloned." -ForegroundColor Green
}

# ------------------------------------------------------------
# Run main bootstrap
# ------------------------------------------------------------

$bootstrapScript = Join-Path $bootstrapPath "windows\bootstrap.ps1"

if (-not (Test-Path $bootstrapScript)) {
    throw "Main bootstrap script not found: $bootstrapScript"
}

Write-Host ""
Write-Host "Starting main bootstrap..." -ForegroundColor Cyan
Write-Host ""

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $bootstrapScript

if ($LASTEXITCODE -ne 0) {
    throw "Main bootstrap failed."
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Development machine setup complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
