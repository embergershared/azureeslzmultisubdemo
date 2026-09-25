if (-not (Get-Variable -Name TestBicepDiagnostics -ErrorAction SilentlyContinue)) {
    # Nested validators share the current run's diagnostics; standalone runs start fresh.
    $TestBicepDiagnostics = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
}

function Invoke-TestBicep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('build', 'build-params')]
        [string]$Operation,
        [Parameter(Mandatory = $true)]
        [string]$File,
        [Parameter(Mandatory = $true)]
        [string]$OutFile,
        [switch]$PassThru
    )

    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& az bicep $Operation --file $File --outfile $OutFile 2>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 0) {
        throw "Bicep $Operation failed for '$File' (exit $exitCode).`n$outputText"
    }

    foreach ($line in ($outputText -split '\r?\n')) {
        $diagnostic = ($line -replace '\x1b\[[0-9;]*[A-Za-z]', '' -replace '^WARNING:\s*', '').Trim()
        if ($diagnostic -and $TestBicepDiagnostics.Add($diagnostic)) {
            Write-Warning $diagnostic
        }
    }
    if ($PassThru) { $output }
}
