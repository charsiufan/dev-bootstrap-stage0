[CmdletBinding()]
param(
    [Alias("dry-run")]
    [switch]$DryRun,

    [string]$DataDrive,

    [string]$Branch
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Development Bootstrap - Stage 0" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY-RUN] Preview mode active; no state-changing operations will run." -ForegroundColor Yellow
    Write-Host ""
}

function Update-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Test-MutationAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ($DryRun) {
        Write-Host "[DRY-RUN] $Description" -ForegroundColor Yellow
        return $false
    }

    return $true
}

function Test-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Assert-BootstrapBranchParameter {
    param(
        [bool]$WasSupplied,
        [string]$Value
    )

    if ($WasSupplied -and [string]::IsNullOrWhiteSpace($Value)) {
        throw "Branch must be a non-empty Git branch name."
    }
}

Assert-BootstrapBranchParameter `
    -WasSupplied $PSBoundParameters.ContainsKey("Branch") `
    -Value $Branch

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @()
    )

    $standardOutputPath = [System.IO.Path]::GetTempFileName()
    $standardErrorPath = [System.IO.Path]::GetTempFileName()
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        # File redirection avoids Windows PowerShell 5.1 promoting native stderr
        # into the output stream. Continue prevents its ErrorRecord wrapper from
        # terminating the script; the native exit code remains authoritative.
        $ErrorActionPreference = "Continue"
        & $Command @Arguments 1> $standardOutputPath 2> $standardErrorPath
        $exitCode = $LASTEXITCODE
        $standardOutput = @(Get-Content -LiteralPath $standardOutputPath -ErrorAction SilentlyContinue)
        $standardError = @(Get-Content -LiteralPath $standardErrorPath -ErrorAction SilentlyContinue)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Remove-Item -LiteralPath $standardOutputPath, $standardErrorPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = @($standardOutput)
        StandardError = @($standardError)
        Output = @($standardOutput) + @($standardError)
    }
}

function Format-NativeCommandOutput {
    param([object[]]$Output)

    return (($Output | ForEach-Object { "$_" }) -join "`n").Trim()
}

function ConvertTo-DriveLetter {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalizedValue = $Value.Trim().TrimEnd('\', ':')

    if ($normalizedValue -notmatch '^[A-Za-z]$') {
        return $null
    }

    return $normalizedValue.ToUpperInvariant()
}

function Get-LocalFixedDrives {
    $drives = @()

    foreach ($driveInfo in [System.IO.DriveInfo]::GetDrives()) {
        if ($driveInfo.DriveType -ne [System.IO.DriveType]::Fixed -or -not $driveInfo.IsReady) {
            continue
        }

        $driveLetter = ConvertTo-DriveLetter -Value $driveInfo.Name

        if ($driveLetter) {
            $drives += [pscustomobject]@{
                Letter = $driveLetter
                Label = $driveInfo.VolumeLabel
            }
        }
    }

    return @($drives | Sort-Object -Property Letter -Unique)
}

function Resolve-DataDrive {
    param([string]$RequestedDrive)

    $availableDrives = @(Get-LocalFixedDrives)

    if ($availableDrives.Count -eq 0) {
        throw "No ready local fixed drives are available."
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedDrive)) {
        $requestedLetter = ConvertTo-DriveLetter -Value $RequestedDrive

        if (-not $requestedLetter) {
            throw "Invalid -DataDrive '$RequestedDrive'. Supply a drive letter such as C, C:, or C:\."
        }

        if ($requestedLetter -notin $availableDrives.Letter) {
            throw "Invalid -DataDrive '$RequestedDrive'. Drive $requestedLetter`: must exist and be a ready local fixed drive."
        }

        Write-Host "[OK]      User data drive selected explicitly: $requestedLetter`:"
        return $requestedLetter
    }

    $existingDevRoot = [Environment]::GetEnvironmentVariable("DEV_ROOT", "User")

    if ([string]::IsNullOrWhiteSpace($existingDevRoot)) {
        $existingDevRoot = [Environment]::GetEnvironmentVariable("DEV_ROOT", "Process")
    }

    foreach ($availableDrive in $availableDrives) {
        $candidateDevRoot = "$($availableDrive.Letter):\Users\$env:USERNAME\Dev"

        if (-not [string]::IsNullOrWhiteSpace($existingDevRoot) -and `
            $candidateDevRoot.Equals($existingDevRoot.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "[KEEP]    User data drive preserved from existing DEV_ROOT: $($availableDrive.Letter):"
            return $availableDrive.Letter
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($existingDevRoot)) {
        Write-Host "[CHECK]   Existing DEV_ROOT '$existingDevRoot' does not match the stage-0 storage layout." -ForegroundColor Yellow
    }

    $defaultDrive = if ("D" -in $availableDrives.Letter) {
        "D"
    }
    elseif ("C" -in $availableDrives.Letter) {
        "C"
    }
    else {
        $availableDrives[0].Letter
    }

    Write-Host "User data drive"
    Write-Host ""

    for ($index = 0; $index -lt $availableDrives.Count; $index++) {
        $drive = $availableDrives[$index]
        $label = if ([string]::IsNullOrWhiteSpace($drive.Label)) { "Local disk" } else { $drive.Label }
        $defaultMarker = if ($drive.Letter -eq $defaultDrive) { " [default]" } else { "" }
        Write-Host ("  {0}. {1}:  {2}{3}" -f ($index + 1), $drive.Letter, $label, $defaultMarker)
    }

    Write-Host ""

    while ($true) {
        $selection = Read-Host "Select drive [$defaultDrive]"

        if ([string]::IsNullOrWhiteSpace($selection)) {
            return $defaultDrive
        }

        $selectionNumber = 0

        if ([int]::TryParse($selection, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $availableDrives.Count) {
            return $availableDrives[$selectionNumber - 1].Letter
        }

        $selectedLetter = ConvertTo-DriveLetter -Value $selection

        if ($selectedLetter -and $selectedLetter -in $availableDrives.Letter) {
            return $selectedLetter
        }

        Write-Host "[CHECK]   Select a listed number or ready local fixed-drive letter." -ForegroundColor Yellow
    }
}

function Get-BootstrapBranches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $defaultBranchResult = Invoke-NativeCommand -Command "gh" -Arguments @(
        "repo", "view", $Repository, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"
    )
    $defaultBranch = @($defaultBranchResult.StandardOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -First 1

    if ($defaultBranchResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace("$defaultBranch")) {
        $details = Format-NativeCommandOutput -Output $defaultBranchResult.Output
        throw "Could not determine the default branch for $Repository. $details".Trim()
    }

    $branchResult = Invoke-NativeCommand -Command "gh" -Arguments @(
        "api", "--paginate", "repos/$Repository/branches", "--jq", ".[].name"
    )
    $branchNames = @($branchResult.StandardOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

    if ($branchResult.ExitCode -ne 0 -or $branchNames.Count -eq 0) {
        $details = Format-NativeCommandOutput -Output $branchResult.Output
        throw "Could not retrieve any valid branches for $Repository. $details".Trim()
    }

    $orderedBranches = @("$defaultBranch")

    foreach ($branchName in $branchNames | Sort-Object -Unique) {
        if ("$branchName" -cne "$defaultBranch") {
            $orderedBranches += "$branchName"
        }
    }

    return [pscustomobject]@{
        Default = "$defaultBranch"
        Names = @($orderedBranches)
    }
}

function Resolve-BootstrapBranch {
    param(
        [string]$RequestedBranch,

        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $branchInfo = Get-BootstrapBranches -Repository $Repository

    if (-not [string]::IsNullOrWhiteSpace($RequestedBranch)) {
        $branchCheck = Invoke-NativeCommand -Command "git" -Arguments @("check-ref-format", "--branch", $RequestedBranch)

        if ($branchCheck.ExitCode -ne 0) {
            throw "Invalid Git branch name: $RequestedBranch"
        }

        if (-not ($branchInfo.Names | Where-Object { $_ -ceq $RequestedBranch })) {
            throw "Branch '$RequestedBranch' does not exist in $Repository."
        }

        return $RequestedBranch
    }

    if ($branchInfo.Names.Count -eq 1) {
        return $branchInfo.Names[0]
    }

    Write-Host "Bootstrap branch"
    Write-Host ""

    for ($index = 0; $index -lt $branchInfo.Names.Count; $index++) {
        $branchName = $branchInfo.Names[$index]
        $defaultMarker = if ($branchName -ceq $branchInfo.Default) { " [default]" } else { "" }
        Write-Host ("  {0}. {1}{2}" -f ($index + 1), $branchName, $defaultMarker)
    }

    Write-Host ""

    while ($true) {
        $selection = Read-Host "Select branch [1]"

        if ([string]::IsNullOrWhiteSpace($selection)) {
            return $branchInfo.Default
        }

        $selectionNumber = 0

        if ([int]::TryParse($selection, [ref]$selectionNumber) -and `
            $selectionNumber -ge 1 -and `
            $selectionNumber -le $branchInfo.Names.Count) {
            return $branchInfo.Names[$selectionNumber - 1]
        }

        $exactBranch = $branchInfo.Names | Where-Object { $_ -ceq $selection } | Select-Object -First 1

        if ($exactBranch) {
            return $exactBranch
        }

        Write-Host "[CHECK]   Select a listed number or exact branch name." -ForegroundColor Yellow
    }
}

function Test-GitRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $repositoryCheck = Invoke-NativeCommand -Command "git" -Arguments @("-C", $Path, "rev-parse", "--git-dir")
    return $repositoryCheck.ExitCode -eq 0
}

function Test-PermanentCloneFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    return $Message -match '(?i)(repository not found|permission denied|authentication failed|could not read username|destination path .+ already exists|remote branch .+ not found|invalid reference|does not exist)'
}

function Remove-PartialCloneDestination {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [bool]$CreatedByCurrentAttempt
    )

    if (-not $CreatedByCurrentAttempt -or -not (Test-Path -LiteralPath $Destination)) {
        return $true
    }

    if (-not (Test-MutationAllowed -Description "Would remove partial clone destination: $Destination")) {
        return $false
    }

    if (Test-GitRepository -Path $Destination) {
        Write-Host "[WARNING] Failed clone left a valid Git repository; retaining it: $Destination" -ForegroundColor Yellow
        return $false
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\', '/')
    $resolvedDestination = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $resolvedParent = [System.IO.Path]::GetDirectoryName($resolvedDestination).TrimEnd('\', '/')

    if (-not $resolvedParent.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[WARNING] Partial clone cleanup was not proven safe; retaining: $Destination" -ForegroundColor Yellow
        return $false
    }

    try {
        Remove-Item -LiteralPath $resolvedDestination -Recurse -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "[WARNING] Could not remove partial clone destination '$Destination': $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Invoke-GitHubClone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [string[]]$GitArguments = @()
    )

    if (-not (Test-MutationAllowed -Description "Would clone $Repository`n          -> $Destination")) {
        return $false
    }

    $maximumAttempts = 3

    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        if (Test-Path -LiteralPath $Destination) {
            Write-Host "[WARNING] Clone destination already exists; refusing to overwrite it: $Destination" -ForegroundColor Yellow
            return $false
        }

        $cloneArguments = @("repo", "clone", $Repository, $Destination)

        if ($GitArguments.Count -gt 0) {
            $cloneArguments += "--"
            $cloneArguments += $GitArguments
        }

        $cloneResult = Invoke-NativeCommand -Command "gh" -Arguments $cloneArguments

        if ($cloneResult.ExitCode -eq 0 -and (Test-GitRepository -Path $Destination)) {
            return $true
        }

        $createdByCurrentAttempt = Test-Path -LiteralPath $Destination
        $failureMessage = Format-NativeCommandOutput -Output $cloneResult.Output
        $cleanupSucceeded = Remove-PartialCloneDestination `
            -Destination $Destination `
            -DestinationRoot $DestinationRoot `
            -CreatedByCurrentAttempt $createdByCurrentAttempt

        if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
            Write-Host "[CHECK]   $($failureMessage.Trim())" -ForegroundColor Yellow
        }

        if (-not $cleanupSucceeded -or (Test-PermanentCloneFailure -Message $failureMessage)) {
            break
        }

        if ($attempt -lt $maximumAttempts) {
            $nextAttempt = $attempt + 1
            Write-Host "[RETRY] Clone failed; retrying ($nextAttempt/$maximumAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    Write-Host "[WARNING] Failed to clone $Repository after at most $maximumAttempts attempts." -ForegroundColor Yellow
    return $false
}

$resolvedDataDrive = Resolve-DataDrive -RequestedDrive $DataDrive
$UserDataRoot = "$resolvedDataDrive`:\Users\$env:USERNAME"
$DevRoot = Join-Path $UserDataRoot "Dev"

Write-Host "Windows profile path:"
Write-Host "  $HOME"
Write-Host "User-data root:"
Write-Host "  $UserDataRoot"
Write-Host "DEV_ROOT:"
Write-Host "  $DevRoot"
Write-Host ""

Update-Path

# ------------------------------------------------------------
# WinGet
# ------------------------------------------------------------

if (-not (Test-Command "winget")) {
    if ($DryRun) {
        Write-Host "[WARNING] WinGet is unavailable; prerequisite installations can only be reported." -ForegroundColor Yellow
    }
    else {
        throw "WinGet is not available. Install/update Windows App Installer first."
    }
}
else {
    Write-Host "[OK]      WinGet available."
}

# ------------------------------------------------------------
# Git
# ------------------------------------------------------------

if (-not (Test-Command "git")) {
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would install Git using WinGet." -ForegroundColor Yellow
    }
    else {
        Write-Host "[INSTALL] Git" -ForegroundColor Yellow

        winget install `
            --id Git.Git `
            --exact `
            --source winget `
            --accept-source-agreements `
            --accept-package-agreements

        if ($LASTEXITCODE -ne 0) {
            throw "Git installation failed with exit code $LASTEXITCODE."
        }

        Update-Path
    }
}
else {
    Write-Host "[KEEP]    Git already installed."
}

# ------------------------------------------------------------
# GitHub CLI
# ------------------------------------------------------------

if (-not (Test-Command "gh")) {
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would install GitHub CLI using WinGet." -ForegroundColor Yellow
    }
    else {
        Write-Host "[INSTALL] GitHub CLI" -ForegroundColor Yellow

        winget install `
            --id GitHub.cli `
            --exact `
            --source winget `
            --accept-source-agreements `
            --accept-package-agreements

        if ($LASTEXITCODE -ne 0) {
            throw "GitHub CLI installation failed with exit code $LASTEXITCODE."
        }

        Update-Path
    }
}
else {
    Write-Host "[KEEP]    GitHub CLI already installed."
}

# ------------------------------------------------------------
# GitHub authentication
# ------------------------------------------------------------

$githubAuthenticated = $false

if (Test-Command "gh") {
    $authenticationCheck = Invoke-NativeCommand -Command "gh" -Arguments @("auth", "status", "--hostname", "github.com")

    if ($authenticationCheck.ExitCode -ne 0) {
        if ($DryRun) {
            Write-Host "[DRY-RUN] Would request interactive GitHub authentication." -ForegroundColor Yellow
        }
        else {
            Write-Host ""
            Write-Host "GitHub authentication required." -ForegroundColor Yellow
            Write-Host ""

            gh auth login `
                --hostname github.com `
                --git-protocol https `
                --web

            if ($LASTEXITCODE -ne 0) {
                throw "GitHub authentication failed."
            }

            $githubAuthenticated = $true
        }
    }
    else {
        $githubAuthenticated = $true
        Write-Host "[OK]      GitHub authenticated."
    }
}
elseif ($DryRun) {
    Write-Host "[CHECK]   GitHub authentication cannot be checked until GitHub CLI is installed."
}

$bootstrapRepository = "charsiufan/dev-bootstrap"

if (-not (Test-Command "gh") -or -not $githubAuthenticated) {
    throw "GitHub CLI must be installed and authenticated to resolve the bootstrap branch."
}

$selectedBootstrapBranch = Resolve-BootstrapBranch `
    -RequestedBranch $Branch `
    -Repository $bootstrapRepository

if ($DryRun) {
    Write-Host "[DRY-RUN] Bootstrap branch: $selectedBootstrapBranch" -ForegroundColor Yellow
}
else {
    Write-Host "[OK]      Bootstrap branch: $selectedBootstrapBranch"
}

# ------------------------------------------------------------
# DEV_ROOT
# ------------------------------------------------------------

if ($DryRun) {
    Write-Host "[DRY-RUN] Would set user and process environment variable DEV_ROOT=$DevRoot" -ForegroundColor Yellow
}
else {
    [Environment]::SetEnvironmentVariable("DEV_ROOT", $DevRoot, "User")
    $env:DEV_ROOT = $DevRoot
}

$projectsRoot = Join-Path $DevRoot "projects"
$bootstrapPath = Join-Path $projectsRoot "dev-bootstrap"

if (-not (Test-Path -LiteralPath $projectsRoot -PathType Container)) {
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would create projects directory: $projectsRoot" -ForegroundColor Yellow
    }
    else {
        New-Item -ItemType Directory -Force -Path $projectsRoot | Out-Null
    }
}

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
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would clone $bootstrapRepository branch '$selectedBootstrapBranch'" -ForegroundColor Yellow
        Write-Host "          -> $bootstrapPath" -ForegroundColor Yellow
    }
    else {
        Write-Host "[CLONE]   $bootstrapRepository branch '$selectedBootstrapBranch'" -ForegroundColor Yellow

        $cloneSucceeded = Invoke-GitHubClone `
            -Repository $bootstrapRepository `
            -Destination $bootstrapPath `
            -DestinationRoot $projectsRoot `
            -GitArguments @("--branch", $selectedBootstrapBranch)

        if (-not $cloneSucceeded) {
            throw "Could not clone dev-bootstrap."
        }

        Write-Host "[OK]      dev-bootstrap cloned." -ForegroundColor Green
    }
}

# ------------------------------------------------------------
# Run main bootstrap
# ------------------------------------------------------------

$bootstrapScript = Join-Path $bootstrapPath "windows\bootstrap.ps1"

if (-not (Test-Path $bootstrapScript)) {
    if ($DryRun -and -not (Test-Path (Join-Path $bootstrapPath ".git"))) {
        Write-Host "[CHECK]   Main bootstrap preview requires the repository to exist; stage-0 dry-run complete."
        return
    }

    throw "Main bootstrap script not found: $bootstrapScript"
}

Write-Host ""
Write-Host "Bootstrap branch: $selectedBootstrapBranch"
Write-Host "Starting main bootstrap..." -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    & $bootstrapScript -DryRun -DataDrive $resolvedDataDrive
}
else {
    & $bootstrapScript -DataDrive $resolvedDataDrive
}

if ($LASTEXITCODE -ne 0) {
    throw "Main bootstrap failed."
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
if ($DryRun) {
    Write-Host " Development machine dry-run complete" -ForegroundColor Green
}
else {
    Write-Host " Development machine setup complete" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Green
