param(
  [switch]$KeepServices
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$composeFile = Join-Path $repoRoot "docker-compose.local-s3.yml"
$dockerConfig = Join-Path $repoRoot ".docker-local"
$seedParquet = Join-Path $repoRoot "airgap-output\data\release\2026-04-15.0\theme=places\type=place\filtered.parquet"
$pmtilesOut = Join-Path $repoRoot "airgap-output\s3-smoke\tiles\2026-04-15.0\places.pmtiles"
$parquetOut = Join-Path $repoRoot "airgap-output\s3-smoke\data\release\2026-04-15.0\theme=places\type=place\filtered.parquet"

function Test-NonEmptyFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path $Path)) {
    throw "Expected file was not created: $Path"
  }

  $file = Get-Item $Path
  if ($file.Length -le 0) {
    throw "Expected file is empty: $Path"
  }
}

function Invoke-DockerCompose {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$ComposeArgs
  )

  & docker --config "$dockerConfig" compose -f "$composeFile" @ComposeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker compose failed: $($ComposeArgs -join ' ')"
  }
}

if (-not (Test-Path $seedParquet)) {
  throw @"
Missing seed parquet:
$seedParquet

Generate the local places smoke output first, then rerun this script.
"@
}

New-Item -ItemType Directory -Force -Path $dockerConfig | Out-Null

& docker --config $dockerConfig image inspect overture-tiles-airgap:local *> $null
if ($LASTEXITCODE -ne 0) {
  throw "Missing Docker image overture-tiles-airgap:local. Build it with: docker --config .docker-local build -t overture-tiles-airgap:local .\airgap\tile-generator"
}

try {
  Write-Host "Starting local MinIO..."
  Invoke-DockerCompose @("up", "-d", "minio")

  Write-Host "Seeding Overture parquet object..."
  Invoke-DockerCompose @("run", "--rm", "-T", "s3-seed")

  Write-Host "Checking exact S3 object key..."
  Invoke-DockerCompose @("run", "--rm", "-T", "s3-key-check")

  Write-Host "Running tile generator from local S3..."
  Invoke-DockerCompose @("run", "--rm", "-T", "tiles-israel-places-s3")

  Test-NonEmptyFile -Path $pmtilesOut
  Test-NonEmptyFile -Path $parquetOut

  Write-Host "Local S3 generator smoke test passed."
  Write-Host "Verified key: s3://overture-local/release/2026-04-15.0/theme=places/type=place/filtered.parquet"
  Write-Host "PMTiles output: $pmtilesOut"
  Write-Host "Parquet output: $parquetOut"
}
finally {
  if (-not $KeepServices) {
    Write-Host "Stopping local S3 services..."
    Invoke-DockerCompose @("down")
  } else {
    Write-Host "Keeping local S3 services running."
  }
}
