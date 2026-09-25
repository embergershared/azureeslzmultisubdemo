#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$TestBicepDiagnostics = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
. (Join-Path $PSScriptRoot 'bicep-test-helpers.ps1')

$priorLastExitCode = if (Test-Path variable:global:LASTEXITCODE) { $global:LASTEXITCODE } else { $null }
$mockExitCode = 0
$mockOutput = @()
$mockArguments = @()
function az {
    $script:mockArguments = @($args)
    $global:LASTEXITCODE = $script:mockExitCode
    $script:mockOutput
}

try {
    $invocation = @{ Operation = 'build'; File = 'source with spaces.bicep'; OutFile = 'output with spaces.json' }
    $output = @(Invoke-TestBicep @invocation 3>&1)
    if ($output.Count -ne 0) { throw 'A successful build without diagnostics should be silent.' }
    $expectedArguments = @('bicep', 'build', '--file', $invocation.File, '--outfile', $invocation.OutFile)
    if (($mockArguments -join '|') -cne ($expectedArguments -join '|')) { throw 'Build arguments or paths were changed.' }

    $diagnostic = 'module.bicep(1,1) : Warning BCP081: fixture warning'
    $mockOutput = @("WARNING: $diagnostic`r`n`r`n$diagnostic")
    $output = @(Invoke-TestBicep @invocation 3>&1)
    if ($output.Count -ne 1 -or $output[0] -isnot [System.Management.Automation.WarningRecord] -or $output[0].Message -cne $diagnostic) {
        throw 'Duplicate diagnostics or blank lines were emitted for one build.'
    }
    $mockOutput = @("$([char]27)[33m$diagnostic$([char]27)[0m")
    $output = @(& {
        . (Join-Path $PSScriptRoot 'bicep-test-helpers.ps1')
        Invoke-TestBicep @invocation
    } 3>&1)
    if ($output.Count -ne 0) { throw 'Nested validators should share diagnostic deduplication, including ANSI variants.' }

    $mockOutput = @('module.bicep(2,1) : Warning BCP081: fixture warning')
    $output = @(Invoke-TestBicep @invocation 3>&1)
    if ($output.Count -ne 1) { throw 'Distinct warning locations must not be suppressed.' }

    $mockOutput = @('WARNING: module.bicep(3,1) : Warning BCP318: nullable output')
    $output = @(Invoke-TestBicep @invocation -PassThru 3>&1)
    $rawOutput = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
    if ($rawOutput.Count -ne 1 -or $rawOutput[0] -cne $mockOutput[0]) { throw 'PassThru must preserve raw diagnostics for BCP318 assertions.' }
    $output = @(Invoke-TestBicep @invocation -PassThru 3>&1)
    if ($output.Count -ne 1 -or $output[0] -cne $mockOutput[0]) { throw 'Deduplication must not remove PassThru diagnostics.' }

    $invocation.Operation = 'build-params'
    $mockOutput = @()
    Invoke-TestBicep @invocation
    if ($mockArguments[1] -cne 'build-params') { throw 'Parameter builds must use build-params.' }

    $mockExitCode = 23
    $mockOutput = @("WARNING: $diagnostic", 'module.bicep(4,1) : Error BCP123: complete failure detail')
    $failure = $null
    try { Invoke-TestBicep @invocation } catch { $failure = $_ }
    if ($null -eq $failure -or -not $failure.Exception.Message.Contains('exit 23') -or
        -not $failure.Exception.Message.Contains($invocation.File) -or
        -not $failure.Exception.Message.Contains(($mockOutput -join "`n"))) {
        throw 'Build failures must include the input path, exit code, and full output, even for previously seen warnings.'
    }
    Write-Host 'Bicep diagnostic logging validation passed.'
}
finally {
    if ($null -eq $priorLastExitCode) { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    else { $global:LASTEXITCODE = $priorLastExitCode }
}
