param(
  [int]$ViewerPort = 8099,
  [switch]$KeepServices
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$composeFile = Join-Path $repoRoot "docker-compose.local-s3.yml"
$dockerConfig = Join-Path $repoRoot ".docker-local"
$seedParquet = Join-Path $repoRoot "airgap-output\data\release\2026-04-15.0\theme=places\type=place\filtered.parquet"
$validationRoot = Join-Path $repoRoot "airgap-output\runbook-validation"
$generatorOutput = Join-Path $validationRoot "generator-output"
$viewerRoot = Join-Path $validationRoot "viewer-data"
$viewerConfig = Join-Path $validationRoot "viewer-config.json"
$normalizedSeed = Join-Path $validationRoot "part-00000.parquet"

$release = "2026-04-15.0"
$bbox = "34.17,29.45,35.91,33.38"
$sourcePath = "s3://overture-source/release/$release"
$outputBucket = "s3://overture-generated"
$s3Endpoint = "http://minio:9000"
$networkName = "overturemapgeoserver_default"
$viewerName = "overture-runbook-validation-viewer"

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Command,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  Write-Host $Description
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "Failed: $Description"
  }
}

function Invoke-DockerCompose {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$ComposeArgs
  )

  Invoke-Checked -Description "docker compose $($ComposeArgs -join ' ')" -Command {
    & docker --config "$dockerConfig" compose -f "$composeFile" @ComposeArgs
  }
}

function Invoke-TileImage {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$DockerArgs
  )

  & docker --config "$dockerConfig" run --rm `
    --network $networkName `
    -e AWS_ACCESS_KEY_ID=minioadmin `
    -e AWS_SECRET_ACCESS_KEY=minioadmin `
    -e AWS_REGION=us-east-1 `
    -e S3_REGION=us-east-1 `
    -e S3_ENDPOINT_URL=$s3Endpoint `
    @DockerArgs

  if ($LASTEXITCODE -ne 0) {
    throw "Docker tile image command failed: $($DockerArgs -join ' ')"
  }
}

function Test-NonEmptyFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path $Path)) {
    throw "Expected file was not created: $Path"
  }

  if ((Get-Item $Path).Length -le 0) {
    throw "Expected file is empty: $Path"
  }
}

function Test-HttpOk {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri
  )

  $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing
  if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
    throw "Unexpected HTTP status $($response.StatusCode) for $Uri"
  }
}

function Test-HttpRange {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri
  )

  $request = [System.Net.HttpWebRequest]::Create($Uri)
  $request.AddRange(0, 1023)
  $response = $request.GetResponse()
  try {
    $statusCode = [int]$response.StatusCode
    if ($statusCode -ne 206 -and $statusCode -ne 200) {
      throw "Unexpected PMTiles range status: $statusCode"
    }
  }
  finally {
    $response.Close()
  }
}

function Remove-ValidationViewer {
  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & docker --config "$dockerConfig" rm -f $viewerName 2>$null | Out-Null
  }
  finally {
    $ErrorActionPreference = $previousErrorAction
    $global:LASTEXITCODE = 0
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

Invoke-Checked -Description "checking overture-tiles-airgap:local image" -Command {
  & docker --config "$dockerConfig" image inspect overture-tiles-airgap:local *> $null
}

Invoke-Checked -Description "checking overture-explorer-airgap:local image" -Command {
  & docker --config "$dockerConfig" image inspect overture-explorer-airgap:local *> $null
}

if (Test-Path $validationRoot) {
  Remove-Item -LiteralPath $validationRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $generatorOutput, $viewerRoot | Out-Null

$viewerConfigContent = @{
  stacCatalogUrl = "/catalog/catalog.json"
  downloadBaseUrl = "/data/release/$release/"
  releaseId = $release
  geocoderBaseUrl = $null
  features = @{
    search = $false
    download = $true
    externalDocs = $false
  }
  download = @{
    minZoom = 15
  }
} | ConvertTo-Json -Depth 5

Set-Content -Path $viewerConfig -Value $viewerConfigContent -Encoding UTF8

try {
  Invoke-DockerCompose @("up", "-d", "minio")

  Invoke-Checked -Description "normalizing seed GeoParquet" -Command {
    & docker --config "$dockerConfig" run --rm `
      -v "${seedParquet}:/seed/filtered.parquet:ro" `
      -v "${validationRoot}:/validation" `
      --entrypoint duckdb `
      overture-tiles-airgap:local `
      -c "COPY (SELECT * EXCLUDE (filename) FROM read_parquet('/seed/filtered.parquet')) TO '/validation/part-00000.parquet';"
  }

  Test-NonEmptyFile -Path $normalizedSeed

  Invoke-Checked -Description "seeding source GeoParquet bucket" -Command {
    & docker --config "$dockerConfig" run --rm `
      --network $networkName `
      -e AWS_ACCESS_KEY_ID=minioadmin `
      -e AWS_SECRET_ACCESS_KEY=minioadmin `
      -e AWS_REGION=us-east-1 `
      -e S3_ENDPOINT_URL=$s3Endpoint `
      -v "${normalizedSeed}:/seed/part-00000.parquet:ro" `
      --entrypoint bash `
      overture-tiles-airgap:local `
      -c "set -eu; s5cmd mb s3://overture-source >/dev/null 2>&1 || true; s5cmd cp /seed/part-00000.parquet s3://overture-source/release/$release/theme=places/type=place/part-00000.parquet; s5cmd head s3://overture-source/release/$release/theme=places/type=place/part-00000.parquet"
  }

  Invoke-Checked -Description "creating generated output bucket" -Command {
    & docker --config "$dockerConfig" run --rm `
      --network $networkName `
      -e AWS_ACCESS_KEY_ID=minioadmin `
      -e AWS_SECRET_ACCESS_KEY=minioadmin `
      -e AWS_REGION=us-east-1 `
      -e S3_ENDPOINT_URL=$s3Endpoint `
      --entrypoint bash `
      overture-tiles-airgap:local `
      -c "s5cmd mb s3://overture-generated >/dev/null 2>&1 || true; s5cmd ls s3://overture-generated >/dev/null"
  }

  Invoke-TileImage @(
    "-e", "RELEASE=$release",
    "-e", "THEME=places",
    "-e", "BBOX=$bbox",
    "-e", "SOURCE_PATH=$sourcePath",
    "-e", "OUTPUT=/output",
    "-e", "PRESERVE_PARQUET=true",
    "-v", "${generatorOutput}:/output",
    "overture-tiles-airgap:local"
  )

  Test-NonEmptyFile -Path (Join-Path $generatorOutput "tiles\$release\places.pmtiles")
  Test-NonEmptyFile -Path (Join-Path $generatorOutput "data\release\$release\theme=places\type=place\filtered.parquet")

  Invoke-Checked -Description "generating STAC catalog" -Command {
    & node "$repoRoot\scripts\generate-airgap-catalog.mjs" `
      --release $release `
      --tiles-dir "$generatorOutput\tiles\$release" `
      --data-dir "$generatorOutput\data\release\$release" `
      --out-dir "$generatorOutput\catalog" `
      --bbox $bbox `
      --tile-base "/tiles/$release/"
  }

  Test-NonEmptyFile -Path (Join-Path $generatorOutput "catalog\catalog.json")
  Test-NonEmptyFile -Path (Join-Path $generatorOutput "catalog\$release\manifest.geojson")

  Invoke-TileImage @(
    "-v", "${generatorOutput}:/output:ro",
    "--entrypoint", "s5cmd",
    "overture-tiles-airgap:local",
    "sync", "/output/tiles/*", "$outputBucket/tiles/"
  )

  Invoke-TileImage @(
    "-v", "${generatorOutput}:/output:ro",
    "--entrypoint", "s5cmd",
    "overture-tiles-airgap:local",
    "sync", "/output/data/*", "$outputBucket/data/"
  )

  Invoke-TileImage @(
    "-v", "${generatorOutput}:/output:ro",
    "--entrypoint", "s5cmd",
    "overture-tiles-airgap:local",
    "sync", "/output/catalog/*", "$outputBucket/catalog/"
  )

  Invoke-TileImage @(
    "--entrypoint", "s5cmd",
    "overture-tiles-airgap:local",
    "head", "$outputBucket/tiles/$release/places.pmtiles"
  )

  Invoke-TileImage @(
    "-v", "${viewerRoot}:/viewer-data",
    "--entrypoint", "s5cmd",
    "overture-tiles-airgap:local",
    "sync", "$outputBucket/catalog/*", "/viewer-data/catalog/"
  )

  Invoke-TileImage @(
    "-v", "${viewerRoot}:/viewer-data",
    "--entrypoint", "s5cmd",
    "overture-tiles-airgap:local",
    "sync", "$outputBucket/tiles/*", "/viewer-data/tiles/"
  )

  Invoke-TileImage @(
    "-v", "${viewerRoot}:/viewer-data",
    "--entrypoint", "s5cmd",
    "overture-tiles-airgap:local",
    "sync", "$outputBucket/data/*", "/viewer-data/data/"
  )

  Remove-ValidationViewer

  Invoke-Checked -Description "starting validation viewer on port $ViewerPort" -Command {
    & docker --config "$dockerConfig" run -d `
      --name $viewerName `
      --read-only `
      --cap-drop ALL `
      --security-opt no-new-privileges:true `
      -p "${ViewerPort}:8080" `
      -v "${viewerRoot}\catalog:/usr/share/nginx/html/catalog:ro" `
      -v "${viewerRoot}\tiles:/usr/share/nginx/html/tiles:ro" `
      -v "${viewerRoot}\data:/usr/share/nginx/html/data:ro" `
      -v "${viewerConfig}:/usr/share/nginx/html/config/viewer-config.json:ro" `
      --tmpfs /tmp `
      --tmpfs /var/cache/nginx `
      --tmpfs /var/run `
      overture-explorer-airgap:local
  }

  Start-Sleep -Seconds 2

  Test-HttpOk -Uri "http://127.0.0.1:$ViewerPort/config/viewer-config.json"
  Test-HttpOk -Uri "http://127.0.0.1:$ViewerPort/catalog/catalog.json"
  Test-HttpOk -Uri "http://127.0.0.1:$ViewerPort/catalog/$release/manifest.geojson"
  Test-HttpOk -Uri "http://127.0.0.1:$ViewerPort/tiles/$release/places.pmtiles"

  Test-HttpRange -Uri "http://127.0.0.1:$ViewerPort/tiles/$release/places.pmtiles"

  Write-Host "Runbook validation passed."
  Write-Host "Viewer URL: http://127.0.0.1:$ViewerPort"
  Write-Host "Generated output: $generatorOutput"
  Write-Host "Viewer data: $viewerRoot"
}
finally {
  if (-not $KeepServices) {
    Remove-ValidationViewer
    Invoke-DockerCompose @("down")
  } else {
    Write-Host "Keeping validation viewer and MinIO services running."
    Write-Host "Stop viewer with: docker --config .docker-local rm -f $viewerName"
    Write-Host "Stop MinIO with: docker --config .docker-local compose -f docker-compose.local-s3.yml down"
  }
}
