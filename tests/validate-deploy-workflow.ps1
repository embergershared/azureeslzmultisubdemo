#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent $PSScriptRoot
$TempDir = Join-Path ([IO.Path]::GetTempPath()) ('eslz-workflow-' + [guid]::NewGuid().ToString('N'))
$priorEnvironment = @{}
foreach ($name in @('ESLZ_DEPLOY_CONFIRMATION', 'ESLZ_WORKFLOW_LOG', 'PREFLIGHT_EXIT')) {
    $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $scripts = Join-Path $TempDir 'scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectDir 'scripts\deploy.ps1'), (Join-Path $ProjectDir 'scripts\what-if.ps1') -Destination $scripts
    @'
param([string]$ParameterFile)
Add-Content -LiteralPath $env:ESLZ_WORKFLOW_LOG -Value 'preflight'
exit ([int]$env:PREFLIGHT_EXIT)
'@ | Set-Content -LiteralPath (Join-Path $scripts 'preflight.ps1')
    $parameters = Join-Path $TempDir 'parameters.json'
    '{"parameters":{"namePrefix":{"value":"workflow-demo"},"connectivitySubscriptionId":{"value":"connectivity-fixture"},"workloadSubscriptionId":{"value":"workload-fixture"},"deploymentLocation":{"value":"eastus"}}}' |
        Set-Content -LiteralPath $parameters
    $env:ESLZ_WORKFLOW_LOG = Join-Path $TempDir 'calls.log'
    function az {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
        Add-Content -LiteralPath $env:ESLZ_WORKFLOW_LOG -Value ($Arguments -join ' ')
        switch ($Arguments[2]) {
            'what-if' { $global:LASTEXITCODE = $case.Preview }
            'create' { $global:LASTEXITCODE = $case.Create }
            default { throw 'Unexpected Azure command' }
        }
    }
    function Read-Host { param([string]$Prompt) return $case.Input }
    foreach ($case in @(
        @{ Name = 'standalone-preview'; Script = 'what-if'; Lock = ''; Input = ''; Preflight = 0; Preview = 0; Create = 0; Exit = 0; Events = 'preflight,what-if' },
        @{ Name = 'locked'; Script = 'deploy'; Lock = ''; Input = 'workflow-demo'; Preflight = 0; Preview = 0; Create = 0; Exit = 2; Events = 'preflight,what-if' },
        @{ Name = 'mismatch'; Script = 'deploy'; Lock = 'DEPLOY-ESLZ-DEMO'; Input = 'wrong-root'; Preflight = 0; Preview = 0; Create = 0; Exit = 2; Events = 'preflight,what-if' },
        @{ Name = 'confirmed'; Script = 'deploy'; Lock = 'DEPLOY-ESLZ-DEMO'; Input = 'workflow-demo'; Preflight = 0; Preview = 0; Create = 0; Exit = 0; Events = 'preflight,what-if,create' },
        @{ Name = 'preflight-failure'; Script = 'deploy'; Lock = 'DEPLOY-ESLZ-DEMO'; Input = 'workflow-demo'; Preflight = 17; Preview = 0; Create = 0; Exit = 17; Events = 'preflight' },
        @{ Name = 'preview-failure'; Script = 'deploy'; Lock = 'DEPLOY-ESLZ-DEMO'; Input = 'workflow-demo'; Preflight = 0; Preview = 18; Create = 0; Exit = 18; Events = 'preflight,what-if' },
        @{ Name = 'create-failure'; Script = 'deploy'; Lock = 'DEPLOY-ESLZ-DEMO'; Input = 'workflow-demo'; Preflight = 0; Preview = 0; Create = 19; Exit = 19; Events = 'preflight,what-if,create' }
    )) {
        $env:ESLZ_DEPLOY_CONFIRMATION = $case.Lock
        $env:PREFLIGHT_EXIT = [string]$case.Preflight
        Set-Content -LiteralPath $env:ESLZ_WORKFLOW_LOG -Value '' -NoNewline
        $global:LASTEXITCODE = 0
        & (Join-Path $scripts ($case.Script + '.ps1')) -ParameterFile $parameters *> (Join-Path $TempDir 'output.log')
        if ($LASTEXITCODE -ne $case.Exit) {
            throw "$($case.Name) returned $LASTEXITCODE, expected $($case.Exit): $(Get-Content (Join-Path $TempDir 'output.log') -Raw)"
        }
        $calls = @(Get-Content -LiteralPath $env:ESLZ_WORKFLOW_LOG)
        $events = ($calls -replace '^deployment tenant (\S+).*', '$1') -join ','
        if ($events -ne $case.Events) { throw "$($case.Name) executed $events, expected $($case.Events)" }
        if ($case.Events.Contains('what-if')) {
            $preview = $calls | Where-Object { $_.StartsWith('deployment tenant what-if ') }
            if (-not $preview.Contains('--result-format FullResourcePayloads --exclude-change-types NoChange')) {
                throw 'Preview must retain full change details and omit only NoChange entries.'
            }
        }
    }
    $global:LASTEXITCODE = 0
    Write-Host 'PowerShell deploy workflow fixtures passed (single preflight, preview detail, confirmations, failure propagation).'
}
finally {
    foreach ($name in $priorEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $priorEnvironment[$name])
    }
    Remove-Item -LiteralPath $TempDir -Recurse -Force
}
