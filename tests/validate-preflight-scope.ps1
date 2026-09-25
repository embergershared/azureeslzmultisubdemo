#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot '..\scripts\preflight.ps1')

function Stop-Preflight {
    param([string]$Message)
    throw $Message
}

function az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    if (($Arguments -join ' ') -cne $script:ExpectedCommand) {
        throw "Unexpected Azure command: $($Arguments -join ' ')"
    }
    $script:CallCount++
    # Use native stderr and exit codes, including with native error promotion enabled.
    & pwsh -NoProfile -NonInteractive -Command $script:CliCommand
    $global:LASTEXITCODE = $LASTEXITCODE
}

$checks = @(
    @{
        Command = 'account management-group show --name fixture-root --output none'
        Run = { Test-TenantRootAccess -TenantRoot 'fixture-root' -SignedInTenant 'fixture-tenant' }
        Scope = ''
        Diagnostic = "Cannot read tenant-root management group 'fixture-root' in active tenant 'fixture-tenant'"
        Permission = 'Microsoft.Management/managementGroups/read'
    }
)
foreach ($scope in @(
    '/providers/Microsoft.Management/managementGroups/fixture-root',
    '/subscriptions/11111111-1111-1111-1111-111111111111',
    '/subscriptions/22222222-2222-2222-2222-222222222222'
)) {
    $checks += @{
        Command = "role assignment list --scope $scope --include-inherited --fill-principal-name false --fill-role-definition-name false --output none"
        Run = { param($Scope) Test-ScopeAccess -Scope $Scope -Label 'fixture' }
        Scope = $scope
        Diagnostic = "Cannot read effective role assignments at fixture scope $scope"
        Permission = 'Microsoft.Authorization/roleAssignments/read'
    }
}
$cases = @(
    @{ Name = 'readable'; Code = 0; Detail = ''; Command = 'exit 0' },
    @{ Name = 'warning-only'; Code = 0; Detail = ''; Command = '[Console]::Error.WriteLine("WARNING: preview command"); exit 0' },
    @{ Name = 'forbidden'; Code = 3; Detail = 'AuthorizationFailed: fixture denied'; Command = '[Console]::Error.WriteLine("AuthorizationFailed: fixture denied"); exit 3' },
    @{ Name = 'not-found'; Code = 3; Detail = 'NotFound: fixture missing'; Command = '[Console]::Error.WriteLine("NotFound: fixture missing"); exit 3' },
    @{ Name = 'cli-error'; Code = 1; Detail = 'unrecognized arguments: --output'; Command = '[Console]::Error.WriteLine("unrecognized arguments: --output"); exit 1' },
    @{ Name = 'network-error'; Code = 1; Detail = 'ConnectionError: fixture proxy'; Command = '[Console]::Error.WriteLine("ConnectionError: fixture proxy"); exit 1' },
    @{ Name = 'empty-error'; Code = 2; Detail = 'Azure CLI returned no diagnostic output.'; Command = 'exit 2' }
)
foreach ($check in $checks) {
    foreach ($case in $cases) {
        $script:ExpectedCommand = $check.Command
        $script:CallCount = 0
        $script:CliCommand = $case.Command
        $failure = ''
        try { & $check.Run $check.Scope }
        catch { $failure = $_.Exception.Message }
        if ($script:CallCount -ne 1) { throw "$($case.Name): expected exactly one read-only Azure call." }
        if ($case.Code -eq 0) {
            if ($failure) { throw "$($case.Name): unexpected failure: $failure" }
        }
        else {
            foreach ($expected in @(
                $check.Diagnostic,
                "Azure CLI exit code $($case.Code)",
                $case.Detail,
                $check.Permission,
                'Preflight remains read-only'
            )) {
                if (-not $failure.Contains($expected)) {
                    throw "$($case.Name): missing diagnostic '$expected'. Actual: $failure"
                }
            }
        }
    }
}
Write-Host 'Preflight management-group and role-assignment diagnostics fixtures passed.'
