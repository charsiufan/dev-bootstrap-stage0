$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$stage0Path = Join-Path (Split-Path -Parent $PSScriptRoot) "stage0.ps1"
$tokens = $null
$parseErrors = $null
$stage0Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $stage0Path,
    [ref]$tokens,
    [ref]$parseErrors
)

Assert-True ($parseErrors.Count -eq 0) "stage0.ps1 contains PowerShell parse errors."
Assert-True ($null -eq ($stage0Ast.ParamBlock.Parameters.Attributes | Where-Object {
    $_.TypeName.FullName -eq "ValidateScript"
})) "The optional Branch parameter must not use ValidateScript."

$parameterBindingScript = [scriptblock]::Create(
    "$($stage0Ast.ParamBlock.Extent.Text)`n`$PSBoundParameters.ContainsKey('Branch')"
)
Assert-True (-not (& $parameterBindingScript)) "Omitting Branch failed parameter binding."
Assert-True (& $parameterBindingScript -Branch "main") "Supplying Branch main failed parameter binding."

$functionNames = @(
    "Assert-BootstrapBranchParameter",
    "ConvertTo-NativeCommandLineArgument",
    "ConvertTo-NativeCommandOutputLines",
    "Invoke-NativeCommand",
    "Invoke-GitHubMetadataCommand",
    "Format-NativeCommandOutput",
    "Get-BootstrapBranches",
    "Resolve-BootstrapBranch"
)

foreach ($functionName in $functionNames) {
    $definition = $stage0Ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)

    Assert-True ($null -ne $definition) "Missing function: $functionName"
    Invoke-Expression $definition.Extent.Text
}

Assert-BootstrapBranchParameter -WasSupplied $false -Value $null
Assert-BootstrapBranchParameter -WasSupplied $true -Value "main"

$emptyBranchRejected = $false
try {
    Assert-BootstrapBranchParameter -WasSupplied $true -Value "   "
}
catch {
    $emptyBranchRejected = $_.Exception.Message -match "non-empty Git branch name"
}

Assert-True $emptyBranchRejected "An explicitly supplied blank Branch was not rejected."

$success = Invoke-NativeCommand -Command "cmd.exe" -Arguments @(
    "/d",
    "/c",
    "echo stdout-success & echo stderr-success 1>&2 & exit /b 0"
)

Assert-True ($success.ExitCode -eq 0) "stderr from a successful native command was treated as failure."
Assert-True (($success.StandardOutput | ForEach-Object { "$($_.Trim())" }) -contains "stdout-success") "Successful native stdout was not preserved."
Assert-True (("$($success.StandardError -join "`n")") -match "stderr-success") "Successful native stderr was not preserved."
Assert-True (("$($success.StandardError -join "`n")") -notmatch "NativeCommandError") "Native stderr was decorated with PowerShell error metadata."

$failure = Invoke-NativeCommand -Command "cmd.exe" -Arguments @(
    "/d",
    "/c",
    "echo stderr-failure 1>&2 & exit /b 23"
)

Assert-True ($failure.ExitCode -eq 23) "A nonzero native exit code was not preserved."
Assert-True (("$($failure.StandardError -join "`n")") -match "stderr-failure") "Failed native stderr was not preserved."

$script:metadataCallCount = 0
function Start-Sleep {
    param([int]$Seconds)
}

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)

    $script:metadataCallCount++
    return [pscustomobject]@{
        ExitCode = 0
        StandardOutput = @("main")
        StandardError = @()
        Output = @("main")
    }
}

$metadataResult = Invoke-GitHubMetadataCommand -Description "Test metadata" -Arguments @("api", "repos/owner/repository")
Assert-True ($metadataResult.ExitCode -eq 0) "A successful metadata call did not succeed."
Assert-True ($metadataCallCount -eq 1) "A successful metadata call was retried."

$script:metadataCallCount = 0
function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)

    $script:metadataCallCount++
    if ($metadataCallCount -eq 1) {
        return [pscustomobject]@{
            ExitCode = 1
            StandardOutput = @()
            StandardError = @("HTTP 503")
            Output = @("HTTP 503")
        }
    }

    return [pscustomobject]@{
        ExitCode = 0
        StandardOutput = @("main")
        StandardError = @()
        Output = @("main")
    }
}

$metadataResult = Invoke-GitHubMetadataCommand -Description "Test metadata" -Arguments @("api", "repos/owner/repository")
Assert-True ($metadataResult.ExitCode -eq 0) "A temporary metadata failure did not recover."
Assert-True ($metadataCallCount -eq 2) "A temporary metadata failure did not retry exactly once."

$script:metadataCallCount = 0
function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)

    $script:metadataCallCount++
    return [pscustomobject]@{
        ExitCode = 1
        StandardOutput = @()
        StandardError = @("HTTP 503")
        Output = @("HTTP 503")
    }
}

$metadataResult = Invoke-GitHubMetadataCommand -Description "Test metadata" -Arguments @("api", "repos/owner/repository")
Assert-True ($metadataResult.ExitCode -ne 0) "A repeatedly failing metadata call was treated as success."
Assert-True ($metadataCallCount -eq 3) "A repeatedly failing metadata call did not stop after three attempts."

$script:metadataCallCount = 0
function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)

    $script:metadataCallCount++
    return [pscustomobject]@{
        ExitCode = 1
        StandardOutput = @()
        StandardError = @("HTTP 503 final response")
        Output = @("HTTP 503 final response")
    }
}

$discoveryFailureReported = $false
try {
    Get-BootstrapBranches -Repository "owner/repository"
}
catch {
    $discoveryFailureReported = $_.Exception.Message -match "Could not determine the default branch" -and
        $_.Exception.Message -match "HTTP 503 final response"
}

Assert-True $discoveryFailureReported "Exhausted default branch discovery did not report the final GitHub response."
Assert-True ($metadataCallCount -eq 3) "Default branch discovery did not retry three times."

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)

    if ($Arguments[1] -like "*/branches") {
        return [pscustomobject]@{
            ExitCode = 0
            StandardOutput = @("", "   ", " main ", "")
            StandardError = @()
            Output = @("", "   ", " main ", "")
        }
    }

    return [pscustomobject]@{
        ExitCode = 0
        StandardOutput = @(" main ")
        StandardError = @()
        Output = @(" main ")
    }
}

$branches = Get-BootstrapBranches -Repository "owner/repository"
Assert-True ($branches.Names.Count -eq 1) "Blank branch names were not filtered."
Assert-True ($branches.Names[0] -ceq "main") "The valid branch name was not trimmed."
Assert-True ($branches.Default -ceq "main") "The reported default branch was not parsed."

$requestedBranch = Resolve-BootstrapBranch -RequestedBranch "main" -Repository "owner/repository"
Assert-True ($requestedBranch -ceq "main") "An explicitly supplied valid Branch was not accepted."

function Read-Host {
    throw "A menu was shown for a sole valid branch."
}

$selectedBranch = Resolve-BootstrapBranch -Repository "owner/repository"
Assert-True ($selectedBranch -ceq "main") "The sole valid branch was not selected automatically."

function Get-BootstrapBranches {
    param([string]$Repository)

    return [pscustomobject]@{
        Default = "main"
        Names = @("main", "release")
    }
}

$script:branchSelectionPrompt = $null
function Read-Host {
    param([string]$Prompt)

    $script:branchSelectionPrompt = $Prompt
    return "2"
}

$selectedBranch = Resolve-BootstrapBranch -Repository "owner/repository"
Assert-True ($branchSelectionPrompt -eq "Select branch [1]") "Multiple branches did not display the selection prompt."
Assert-True ($selectedBranch -ceq "release") "Multiple-branch numeric selection did not resolve correctly."

Write-Host "[OK] Stage 0 Windows native-command and branch-selection tests."
