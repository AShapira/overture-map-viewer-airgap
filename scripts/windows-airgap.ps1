[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Generate', 'Catalog', 'Viewer')][string]$Action = 'Preflight',
    [string]$EnvFile = '.env.windows-airgap',
    [switch]$DryRun,
    [switch]$EstimatePilot,
    [string]$Report,
    [string]$Calibration,
    [string[]]$ComposeOverride = @(),
    [string]$ProjectName = 'overture-airgap',
    [double]$HostReserveGiB = 100,
    [string[]]$MonitorDrives = @('C', 'D')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$HostCapacity = @{}
$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($DryRun -and $EstimatePilot) { throw 'DryRun and EstimatePilot are mutually exclusive.' }
if (($DryRun -or $EstimatePilot) -and $Action -ne 'Generate') { throw 'Estimate modes require -Action Generate.' }
if ($HostReserveGiB -le 0) { throw 'HostReserveGiB must be positive.' }
$Podman = (Get-Command podman.exe -ErrorAction Stop).Source
$provider = $env:PODMAN_COMPOSE_PROVIDER
if (-not $provider) {
    $command = Get-Command podman-compose.exe -ErrorAction SilentlyContinue
    if ($command) { $provider = $command.Source }
}
if (-not $provider -or -not (Test-Path -LiteralPath $provider -PathType Leaf)) {
    throw 'Set PODMAN_COMPOSE_PROVIDER to the full path of the native podman-compose.exe. See the Windows Podman runbook.'
}
if ([IO.Path]::GetFileName($provider) -ne 'podman-compose.exe') { throw 'The supported provider is podman-compose.exe.' }
$env:PODMAN_COMPOSE_PROVIDER = $provider
if (-not [IO.Path]::IsPathRooted($EnvFile)) { $EnvFile = Join-Path $RepoRoot $EnvFile }
$EnvFile = (Resolve-Path -LiteralPath $EnvFile).Path
$env:AIRGAP_ENV_FILE = $EnvFile
$compose = @('compose', '--env-file', $EnvFile, '-p', $ProjectName, '-f', (Join-Path $RepoRoot 'compose.windows-airgap.yml'))
foreach ($override in $ComposeOverride) {
    if (-not [IO.Path]::IsPathRooted($override)) { $override = Join-Path $RepoRoot $override }
    $compose += @('-f', (Resolve-Path -LiteralPath $override).Path)
}

function Quote-NativeArgument([string]$Value) {
    # Windows CommandLineToArgvW quoting, including quotes and trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Start-Podman([string[]]$Arguments, [string]$OutputFile, [string]$ErrorFile) {
    $parameters = @{FilePath=$Podman; ArgumentList=(($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '); WorkingDirectory=$RepoRoot; NoNewWindow=$true; PassThru=$true}
    if ($OutputFile) { $parameters.RedirectStandardOutput = $OutputFile; $parameters.RedirectStandardError = $ErrorFile }
    $process = Start-Process @parameters
    $null = $process.Handle
    return $process
}
function Read-Podman([string[]]$Arguments) {
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $process = Start-Podman $Arguments $outFile $errFile
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Podman exited with $($process.ExitCode): $(Get-Content -Raw $errFile)" }
        return Get-Content -Raw $outFile
    } finally { Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue }
}
function Assert-HostCapacity {
    foreach ($drive in $MonitorDrives) {
        $volume = Get-Volume -DriveLetter $drive -ErrorAction Stop
        $free = [long]$volume.SizeRemaining
        if (-not $HostCapacity.ContainsKey($drive)) {
            $HostCapacity[$drive] = @{initial_free_bytes=$free; minimum_free_bytes=$free; final_free_bytes=$free}
        }
        $HostCapacity[$drive].minimum_free_bytes = [math]::Min($HostCapacity[$drive].minimum_free_bytes, $free)
        $HostCapacity[$drive].final_free_bytes = $free
        if ($volume.SizeRemaining -lt ($HostReserveGiB * 1GB)) {
            throw "Drive ${drive}: crossed the $HostReserveGiB GiB host reserve."
        }
    }
}
function Invoke-Operation([string[]]$Arguments, [string]$ContainerName = '') {
    Assert-HostCapacity
    $process = Start-Podman $Arguments '' ''
    try {
        while (-not $process.WaitForExit(1000)) { Assert-HostCapacity }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Podman operation failed with exit code $($process.ExitCode)." }
        Assert-HostCapacity
    } catch {
        if ($ContainerName -and -not $process.HasExited) {
            try { Read-Podman @('stop', '--time', '10', $ContainerName) | Out-Null } catch { Write-Warning 'Could not confirm generator shutdown.' }
        }
        throw
    } finally {
        Write-Host ('Host capacity: ' + ($HostCapacity | ConvertTo-Json -Compress))
    }
}

# JSON includes secrets; parse in memory and never print rendered environment.
$configText = Read-Podman ($compose + @('--profile', 'generate', 'config'))
$composePython = Join-Path (Split-Path -Parent $provider) 'python.exe'
if (-not (Test-Path -LiteralPath $composePython)) { throw 'Install podman-compose in a native Python virtual environment; its python.exe must be beside podman-compose.exe.' }
$convert = New-Object System.Diagnostics.Process
$convert.StartInfo.FileName = $composePython
$convert.StartInfo.Arguments = '-c "import json,sys,yaml; json.dump(yaml.safe_load(sys.stdin),sys.stdout)"'
$convert.StartInfo.UseShellExecute = $false
$convert.StartInfo.RedirectStandardInput = $true
$convert.StartInfo.RedirectStandardOutput = $true
$convert.Start() | Out-Null
$convert.StandardInput.Write($configText)
$convert.StandardInput.Close()
$config = $convert.StandardOutput.ReadToEnd() | ConvertFrom-Json
$convert.WaitForExit()
if ($convert.ExitCode -ne 0) { throw 'Could not parse the provider-rendered Compose configuration.' }
$info = (Read-Podman @('info', '--format', 'json')) | ConvertFrom-Json
$generator = $config.services.'tiles-generator'
foreach ($service in @('tiles-generator', 'catalog', 'viewer')) {
    Read-Podman @('image', 'inspect', '--format', '{{.Id}}', $config.services.$service.image) | Out-Null
}
$env:GENERATOR_IMAGE_ID = (Read-Podman @('image', 'inspect', '--format', '{{.Id}}', $generator.image)).Trim()
foreach ($mount in $generator.volumes) {
    if ($mount.type -eq 'bind' -and -not (Test-Path -LiteralPath $mount.source -PathType Container)) {
        throw "Create the configured directory before running: $($mount.source)"
    }
}
# Separate Windows binds can expose the same host files under different Linux
# device IDs. Count the enclosing bind once when scratch and output overlap.
$accountingPaths = @{}
foreach ($mount in $generator.volumes) {
    if ($mount.type -eq 'bind' -and $mount.target -in @('/scratch', '/output')) {
        $accountingPaths[$mount.target] = [IO.Path]::GetFullPath($mount.source).TrimEnd('\', '/')
    }
}
$env:PMTILES_ACCOUNTING_ROOT = ''
foreach ($target in @('/scratch', '/output')) {
    $other = if ($target -eq '/scratch') { '/output' } else { '/scratch' }
    $parent = $accountingPaths[$target]
    $child = $accountingPaths[$other]
    if ($child.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or $child.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $env:PMTILES_ACCOUNTING_ROOT = $target
        break
    }
}
Write-Host "Podman rootless=$($info.host.security.rootless), CPUs=$($info.host.cpus), memory=$([math]::Round($info.host.memTotal / 1GB, 1)) GiB"
Write-Host "Compose provider: $provider"
Assert-HostCapacity
switch ($Action) {
    'Preflight' { Write-Host 'Preflight passed; images, directories, provider and host reserves verified.' }
    'Generate' {
        $name = "$ProjectName-generator-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
        $arguments = $compose + @('--profile', 'generate', 'run', '--rm', '--no-deps', '-T', '--name', $name, 'tiles-generator')
        if ($DryRun) { $arguments += '--dry-run' }
        if ($EstimatePilot) { $arguments += '--estimate-pilot' }
        if ($Report) { $arguments += @('--report', $Report) }
        if ($Calibration) { $arguments += @('--calibration', $Calibration) }
        Invoke-Operation $arguments $name
    }
    'Catalog' { Invoke-Operation ($compose + @('run', '--rm', '--no-deps', '-T', 'catalog')) }
    'Viewer' {
        Invoke-Operation ($compose + @('run', '--rm', '--no-deps', '-T', 'catalog'))
        Invoke-Operation ($compose + @('up', '-d', '--no-deps', 'viewer'))
    }
}
