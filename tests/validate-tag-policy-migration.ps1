[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$TempDir = Join-Path $ProjectDir ".test-artifacts/tag-migration-ps1-$PID"
$MockBin = Join-Path $TempDir 'mockbin'
$CallLog = Join-Path $TempDir 'az-calls.log'
$MigrationScript = Join-Path $ProjectDir 'scripts/migrate-legacy-rg-tags.ps1'

function Stop-Test {
    param([string]$Message)
    throw $Message
}

$oldPath = $env:PATH
$oldCallLog = $env:AZ_CALL_LOG
$oldScenario = $env:AZ_MOCK_SCENARIO
$oldConfirmation = $env:ESLZ_TAG_MIGRATION_CONFIRMATION

try {
    New-Item -ItemType Directory -Path $MockBin -Force | Out-Null
    $parameterFile = Join-Path $TempDir 'parameters.json'
    @'
{
  "parameters": {
    "tenantRootManagementGroupId": { "value": "tenant-root" },
    "namePrefix": { "value": "eslz-demo" },
    "workloadArchetype": { "value": "corp" },
    "connectivitySubscriptionId": { "value": "11111111-1111-1111-1111-111111111111" },
    "workloadSubscriptionId": { "value": "22222222-2222-2222-2222-222222222222" }
  }
}
'@ | Set-Content -LiteralPath $parameterFile

    $mockAzPath = Join-Path $MockBin 'az.ps1'
    @'
Add-Content -LiteralPath $env:AZ_CALL_LOG -Value ($args -join ' ')
$scenario = $env:AZ_MOCK_SCENARIO
$command = ($args | Where-Object { $_ -notin '--output', 'json' }) -join ' '
$demo = '/providers/Microsoft.Management/managementGroups/eslz-demo'
$landing = "$demo-landingzones"
$workload = "$demo-corp"
$legacyDefinition = "$demo/providers/Microsoft.Authorization/policyDefinitions/eslz-demo-require-workload-rg-tags"
$initiative = "$demo/providers/Microsoft.Authorization/policySetDefinitions/eslz-demo-required-rg-tags"
$builtIn = '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'
$references = [ordered]@{
    'require-cost-center' = 'CostCenter'
    'require-application-name' = 'ApplicationName'
    'require-owner' = 'Owner'
    'require-environment' = 'Environment'
    'require-data-classification' = 'DataClassification'
    'require-ssp-id' = 'SSP-ID'
}

if ($command -eq 'account show') {
    $subscription = if ($scenario -eq 'wrong-active-subscription') { '99999999-9999-9999-9999-999999999999' } else { '11111111-1111-1111-1111-111111111111' }
    $result = @{ tenantId = 'tenant-a'; id = $subscription; state = 'Enabled' }
}
elseif ($command.StartsWith('account show --subscription ')) {
    $subscription = ($command -split ' ')[-1]
    $tenant = if ($scenario -eq 'wrong-subscription-tenant' -and $subscription -eq '22222222-2222-2222-2222-222222222222') { 'tenant-b' } else { 'tenant-a' }
    $state = if ($scenario -eq 'disabled-subscription' -and $subscription.StartsWith('2222')) { 'Disabled' } else { 'Enabled' }
    $result = @{ tenantId = $tenant; id = $subscription; state = $state }
}
elseif ($command -eq 'account management-group show --name tenant-root') {
    $result = @{ id = '/providers/Microsoft.Management/managementGroups/tenant-root' }
}
elseif ($command -eq 'account management-group show --name eslz-demo') {
    $result = @{ id = $demo; details = @{ parent = @{ id = '/providers/Microsoft.Management/managementGroups/tenant-root' } } }
}
elseif ($command -eq 'account management-group show --name eslz-demo-landingzones') {
    $result = @{ id = $landing; details = @{ parent = @{ id = $demo } } }
}
elseif ($command -eq 'account management-group show --name eslz-demo-corp') {
    $parent = if ($scenario -eq 'wrong-ancestry') { $demo } else { $landing }
    $result = @{ id = $workload; details = @{ parent = @{ id = $parent } } }
}
elseif ($command -eq 'policy set-definition show --name eslz-demo-required-rg-tags --management-group eslz-demo') {
    if ($scenario -eq 'replacement-missing') {
        Write-Error 'ERROR: (ResourceNotFound) replacement missing' -ErrorAction Continue
        exit 3
    }
    $policyReferences = @(foreach ($reference in $references.GetEnumerator()) {
        $referenceId = $reference.Key
        if ($scenario -eq 'replacement-reference-missing' -and $referenceId -eq 'require-ssp-id') { continue }
        @{
            policyDefinitionId = if ($scenario -eq 'replacement-definition-wrong' -and $referenceId -eq 'require-owner') { "$demo/providers/Microsoft.Authorization/policyDefinitions/unrelated" } else { $builtIn }
            definitionVersion = if ($scenario -eq 'replacement-version-missing' -and $referenceId -eq 'require-owner') { $null } elseif ($scenario -eq 'replacement-version-wrong' -and $referenceId -eq 'require-owner') { '2.*.*' } else { '1.*.*' }
            policyDefinitionReferenceId = $referenceId
            parameters = @{ tagName = @{ value = if ($scenario -eq 'replacement-tag-renamed' -and $referenceId -eq 'require-application-name') { 'Application' } else { $reference.Value } } }
        }
    })
    $result = @{ id = $initiative; properties = @{ policyDefinitions = $policyReferences } }
}
elseif ($command -eq "policy assignment show --name demo-require-rg-tags --scope $landing") {
    if ($scenario -eq 'replacement-assignment-missing') {
        Write-Error 'ERROR: (PolicyAssignmentNotFound) replacement assignment missing' -ErrorAction Continue
        exit 3
    }
    $replacementLink = if ($scenario -eq 'replacement-link-wrong') { "$demo/providers/Microsoft.Authorization/policySetDefinitions/unrelated" } else { $initiative }
    $properties = @{ policyDefinitionId = $replacementLink }
    if ($scenario -eq 'replacement-assignment-excluded') { $properties.notScopes = @($workload) }
    if ($scenario -eq 'replacement-assignment-selected') { $properties.resourceSelectors = @(@{ name = 'limited'; selectors = @(@{ kind = 'resourceLocation'; in = @('eastus') }) }) }
    $result = @{ id = "$landing/providers/Microsoft.Authorization/policyAssignments/demo-require-rg-tags"; properties = $properties }
}
elseif ($command -eq "policy assignment show --name demo-require-rg-tags --scope $workload") {
    if ($scenario -in 'assignment-absent', 'both-absent') {
        Write-Error 'ERROR: (PolicyAssignmentNotFound) legacy assignment absent' -ErrorAction Continue
        exit 3
    }
    if ($scenario -eq 'assignment-read-error') {
        Write-Error 'ERROR: (AuthorizationFailed) access denied' -ErrorAction Continue
        exit 3
    }
    $definitionId = if ($scenario -eq 'wrong-link') { "$demo/providers/Microsoft.Authorization/policyDefinitions/unrelated" } else { $legacyDefinition }
    $result = @{ id = "$workload/providers/Microsoft.Authorization/policyAssignments/demo-require-rg-tags"; properties = @{ policyDefinitionId = $definitionId } }
}
elseif ($command -eq 'policy definition show --name eslz-demo-require-workload-rg-tags --management-group eslz-demo') {
    if ($scenario -in 'definition-absent', 'both-absent') {
        Write-Error 'ERROR: (PolicyDefinitionNotFound) legacy definition absent' -ErrorAction Continue
        exit 3
    }
    if ($scenario -eq 'definition-read-error') {
        Write-Error 'ERROR: (AuthorizationFailed) access denied' -ErrorAction Continue
        exit 3
    }
    $result = @{ id = $legacyDefinition }
}
elseif (" $command " -match ' delete ') {
    exit 0
}
else {
    Write-Error "ERROR: unexpected command: $command" -ErrorAction Continue
    exit 4
}
$result | ConvertTo-Json -Depth 20 -Compress
exit 0
'@ | Set-Content -LiteralPath $mockAzPath

    $wrapperScript = Join-Path $TempDir 'invoke-migration-with-mock-check.ps1'
    @'
param(
    [Parameter(Mandatory = $true)][string]$ParameterFile,
    [Parameter(Mandatory = $true)][string]$ExpectedMockDir,
    [Parameter(Mandatory = $true)][string]$MigrationScript,
    [AllowEmptyString()][string]$TypedConfirmation = '',
    [switch]$Execute
)
$azCommand = Get-Command az -ErrorAction SilentlyContinue
$resolvedSource = if ($azCommand) { $azCommand.Source } else { $null }
if (-not $resolvedSource -or -not $resolvedSource.StartsWith($ExpectedMockDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "az resolved to '$resolvedSource' instead of the temporary mock directory '$ExpectedMockDir'."
    exit 1
}
$global:FixtureMigrationConfirmation = $TypedConfirmation
function global:Read-Host { param([string]$Prompt) $global:FixtureMigrationConfirmation }
if ($Execute) {
    & $MigrationScript -ParameterFile $ParameterFile -Execute
} else {
    & $MigrationScript -ParameterFile $ParameterFile
}
if (-not $?) { exit 1 }
'@ | Set-Content -LiteralPath $wrapperScript

    $env:PATH = "$MockBin$([IO.Path]::PathSeparator)$oldPath"
    $env:AZ_CALL_LOG = $CallLog

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    $resolvedSource = if ($azCommand) { $azCommand.Source } else { $null }
    if (-not $resolvedSource -or -not $resolvedSource.StartsWith($MockBin, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Test "az resolved to '$resolvedSource' instead of the isolated mock directory before migration tests."
    }

    function Invoke-MigrationCase {
        param([string]$Scenario, [string]$TypedConfirmation, [string]$Approval, [switch]$Execute)
        Set-Content -LiteralPath $CallLog -Value '' -NoNewline
        $env:AZ_MOCK_SCENARIO = $Scenario
        $env:ESLZ_TAG_MIGRATION_CONFIRMATION = $Approval
        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $wrapperScript,
            '-ParameterFile', $parameterFile,
            '-ExpectedMockDir', $MockBin,
            '-MigrationScript', $MigrationScript,
            '-TypedConfirmation', $TypedConfirmation
        )
        if ($Execute) { $arguments += '-Execute' }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.StandardInput.Close()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $script:caseOutput = "$standardOutput$standardError"
        $script:caseExitCode = $process.ExitCode
        $script:caseCalls = @(
            Get-Content -LiteralPath $CallLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    Invoke-MigrationCase -Scenario present -TypedConfirmation '' -Approval ''
    if ($caseExitCode -ne 0 -or $caseCalls.Count -ne 0 -or $caseOutput -notmatch 'Dry run only\.') {
        Stop-Test 'PowerShell migration preview must succeed without resolving or invoking Azure CLI.'
    }

    Invoke-MigrationCase -Scenario present -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval '' -Execute
    if ($caseExitCode -eq 0 -or -not ($caseCalls -match 'policy definition show') -or ($caseCalls -match ' delete ')) {
        Stop-Test "PowerShell migration must complete all reads, then reject missing approval without a delete. Exit=$caseExitCode Calls=$($caseCalls -join ' | ') Output=$caseOutput"
    }

    foreach ($confirmation in @('', 'wrong-confirmation', 'TENANT-A/eslz-demo-corp')) {
        Invoke-MigrationCase -Scenario present -TypedConfirmation $confirmation -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
        if ($caseExitCode -eq 0 -or ($caseCalls -match ' delete ') -or $caseOutput -notmatch 'Confirmation did not match; migration cancelled\.') {
            Stop-Test "PowerShell migration must reject an empty, incorrect, or wrong-case typed confirmation without a delete. Output=$caseOutput"
        }
    }

    Invoke-MigrationCase -Scenario present -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
    if ($caseExitCode -ne 0) { Stop-Test 'PowerShell migration failed with validated context and exact approval.' }
    $expectedDeletes = @(
        'policy assignment delete --name demo-require-rg-tags --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp'
        'policy definition delete --name eslz-demo-require-workload-rg-tags --management-group eslz-demo'
    )
    $actualDeletes = @($caseCalls | Where-Object { $_ -match ' delete ' })
    if (Compare-Object -ReferenceObject $expectedDeletes -DifferenceObject $actualDeletes -CaseSensitive) {
        Stop-Test 'PowerShell migration invoked a delete outside the two exact legacy artifacts.'
    }

    Invoke-MigrationCase -Scenario assignment-absent -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
    $actualDeletes = @($caseCalls | Where-Object { $_ -match ' delete ' })
    if ($caseExitCode -ne 0 -or $actualDeletes.Count -ne 1 -or $actualDeletes[0] -cne $expectedDeletes[1]) {
        Stop-Test 'PowerShell migration must continue definition cleanup when the legacy assignment is verified absent.'
    }
    Invoke-MigrationCase -Scenario definition-absent -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
    $actualDeletes = @($caseCalls | Where-Object { $_ -match ' delete ' })
    if ($caseExitCode -ne 0 -or $actualDeletes.Count -ne 1 -or $actualDeletes[0] -cne $expectedDeletes[0]) {
        Stop-Test 'PowerShell migration must continue assignment cleanup when the obsolete definition is verified absent.'
    }
    Invoke-MigrationCase -Scenario both-absent -TypedConfirmation '' -Approval '' -Execute
    if ($caseExitCode -ne 0 -or ($caseCalls -match ' delete ')) {
        Stop-Test 'PowerShell migration must report completion without approval when both exact legacy artifacts are verified absent.'
    }

    foreach ($scenario in @(
        'wrong-active-subscription', 'wrong-subscription-tenant', 'disabled-subscription', 'wrong-ancestry',
        'replacement-missing', 'replacement-assignment-missing', 'replacement-link-wrong',
        'replacement-reference-missing', 'replacement-tag-renamed',
        'replacement-version-missing', 'replacement-version-wrong', 'replacement-definition-wrong',
        'replacement-assignment-excluded', 'replacement-assignment-selected',
        'wrong-link', 'assignment-read-error', 'definition-read-error'
    )) {
        Invoke-MigrationCase -Scenario $scenario -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
        if ($caseExitCode -eq 0 -or ($caseCalls -match ' delete ')) {
            Stop-Test "PowerShell migration did not fail closed for $scenario."
        }
    }

    foreach ($automaticScript in @('deploy.sh', 'deploy.ps1', 'what-if.sh', 'what-if.ps1', 'teardown.sh', 'teardown.ps1')) {
        if ((Get-Content -LiteralPath (Join-Path $ProjectDir "scripts/$automaticScript") -Raw) -match 'migrate-legacy-rg-tags') {
            Stop-Test 'Legacy tag migration must never run automatically from another lifecycle script.'
        }
    }

    Write-Host 'Tag policy migration PowerShell validation passed.'
}
finally {
    $env:PATH = $oldPath
    $env:AZ_CALL_LOG = $oldCallLog
    $env:AZ_MOCK_SCENARIO = $oldScenario
    $env:ESLZ_TAG_MIGRATION_CONFIRMATION = $oldConfirmation
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    $artifactsParent = Join-Path $ProjectDir '.test-artifacts'
    if ((Test-Path -LiteralPath $artifactsParent) -and
        @(Get-ChildItem -LiteralPath $artifactsParent -Force).Count -eq 0) {
        Remove-Item -LiteralPath $artifactsParent -Force -ErrorAction SilentlyContinue
    }
}
