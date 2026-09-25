#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\preflight.ps1')

function Stop-Preflight {
    param([string]$Message)
    throw $Message
}

function az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    if (($Arguments -join ' ') -ceq "rest --method get --url /providers/Microsoft.Authorization/$script:ResourceType/fixture-policy?api-version=2023-04-01 --output json") {
        if ($null -eq $script:VersionsResponse) { throw 'Unexpected versions request' }
        $global:LASTEXITCODE = $script:VersionsExitCode
        $script:VersionsResponse
        return
    }
    if (($Arguments -join ' ') -cne "policy $script:ExpectedCommand show --name fixture-policy --output json") {
        throw "Unexpected Azure command: $($Arguments -join ' ')"
    }
    $global:LASTEXITCODE = $script:MockExitCode
    $script:MockResponse
}

$priorLastExitCode = if (Test-Path variable:global:LASTEXITCODE) { $global:LASTEXITCODE } else { $null }
try {
    foreach ($kind in @('policyDefinition', 'policySetDefinition')) {
        $script:ExpectedCommand = if ($kind -eq 'policySetDefinition') { 'set-definition' } else { 'definition' }
        $script:ResourceType = if ($kind -eq 'policySetDefinition') { 'policySetDefinitions' } else { 'policyDefinitions' }
        foreach ($fixture in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\preflight-policy-version-cases.json') -Raw | ConvertFrom-Json)) {
            $script:MockResponse = $fixture.response
            $script:MockExitCode = if ($fixture.PSObject.Properties['exitCode']) { $fixture.exitCode } else { 0 }
            $script:VersionsResponse = if ($fixture.PSObject.Properties['versionsResponse']) { $fixture.versionsResponse } else { $null }
            $script:VersionsExitCode = if ($fixture.PSObject.Properties['versionsExitCode']) { $fixture.versionsExitCode } else { 0 }
            $failure = ''
            try { Test-BuiltInPolicyVersion -Kind $kind -DefinitionId 'fixture-policy' -MajorVersion '1' }
            catch { $failure = $_.Exception.Message }
            if (($fixture.expected -eq '' -and $failure -ne '') -or
                ($fixture.expected -ne '' -and ($failure -eq '' -or -not $failure.Contains($fixture.expected)))) {
                throw "$kind/$($fixture.name): expected '$($fixture.expected)', got '$failure'."
            }
        }
    }
    Write-Host 'Built-in policy version fixtures passed (PowerShell).'
}
finally {
    if ($null -eq $priorLastExitCode) { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    else { $global:LASTEXITCODE = $priorLastExitCode }
}
