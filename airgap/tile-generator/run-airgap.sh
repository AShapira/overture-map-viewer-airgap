#!/usr/bin/env bash

set -euo pipefail

RELEASE="${RELEASE:-2026-04-15.0}"
SOURCE_PATH="${SOURCE_PATH:-/input/release}"
OUTPUT="${OUTPUT:-/output}"
THEMES="${THEMES:-base,buildings,places,divisions,transportation,addresses}"
PMTILES_S3_PATH="${PMTILES_S3_PATH:?PMTILES_S3_PATH is required}"
PMTILES_SCRATCH_ROOT="${PMTILES_SCRATCH_ROOT:-/scratch}"
PMTILES_MIN_FREE_GB="${PMTILES_MIN_FREE_GB:?PMTILES_MIN_FREE_GB is required}"
PMTILES_MAX_SCRATCH_GB="${PMTILES_MAX_SCRATCH_GB:-}"
S3_REGION="${S3_REGION:-us-west-2}"
PRESERVE_PARQUET="${PRESERVE_PARQUET:-false}"

PARQUET_OUT="${OUTPUT%/}/data/release/${RELEASE}"
PUBLICATION_DIR="${OUTPUT%/}/publication"
PUBLICATION_FILE="${PUBLICATION_DIR}/${RELEASE}.json"
PUBLICATION_TMP="${PUBLICATION_FILE}.tmp"
SUPPORTED_THEMES=" addresses base buildings divisions places transportation "

is_s3_source=false
case "$SOURCE_PATH" in
  s3://*) is_s3_source=true ;;
esac

if [[ ! -v PLANETILER_COMPRESS_TEMP ]]; then
  PLANETILER_COMPRESS_TEMP="$is_s3_source"
fi
if [[ ! -v PLANETILER_MMAP_TEMP ]]; then
  if [ "$PLANETILER_COMPRESS_TEMP" = "true" ]; then
    PLANETILER_MMAP_TEMP=false
  else
    PLANETILER_MMAP_TEMP=true
  fi
fi

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ -v THEME ]]; then
  die "THEME is no longer supported; set the comma-separated THEMES value instead"
fi

[[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || die "RELEASE contains unsupported characters: $RELEASE"
[[ "$PMTILES_S3_PATH" == s3://* ]] || die "PMTILES_S3_PATH must be an s3:// URI"
[[ "$PMTILES_MIN_FREE_GB" =~ ^[1-9][0-9]*$ ]] || die "PMTILES_MIN_FREE_GB must be a positive integer"
[[ -z "$PMTILES_MAX_SCRATCH_GB" || "$PMTILES_MAX_SCRATCH_GB" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || \
  die "PMTILES_MAX_SCRATCH_GB must be empty or a positive number"
[[ "$PRESERVE_PARQUET" = "true" || "$PRESERVE_PARQUET" = "false" ]] || \
  die "PRESERVE_PARQUET must be true or false"
[[ "$PLANETILER_COMPRESS_TEMP" = "true" || "$PLANETILER_COMPRESS_TEMP" = "false" ]] || \
  die "PLANETILER_COMPRESS_TEMP must be true or false"
[[ "$PLANETILER_MMAP_TEMP" = "true" || "$PLANETILER_MMAP_TEMP" = "false" ]] || \
  die "PLANETILER_MMAP_TEMP must be true or false"
if [ "$PLANETILER_COMPRESS_TEMP" = "true" ] && [ "$PLANETILER_MMAP_TEMP" = "true" ]; then
  die "PLANETILER_MMAP_TEMP must be false when PLANETILER_COMPRESS_TEMP=true"
fi
[[ -d "$PMTILES_SCRATCH_ROOT" ]] || die "Scratch directory does not exist: $PMTILES_SCRATCH_ROOT"

declare -a configured_themes=()
declare -A seen_themes=()
IFS=',' read -r -a raw_themes <<< "$THEMES"
for raw_theme in "${raw_themes[@]}"; do
  theme="${raw_theme//[[:space:]]/}"
  [[ -n "$theme" ]] || die "THEMES contains an empty item"
  [[ "$SUPPORTED_THEMES" == *" $theme "* ]] || die "Unsupported theme in THEMES: $theme"
  [[ -z "${seen_themes[$theme]:-}" ]] || die "Duplicate theme in THEMES: $theme"
  seen_themes[$theme]=1
  configured_themes+=("$theme")
done
(( ${#configured_themes[@]} > 0 )) || die "THEMES must contain at least one supported theme"

min_free_kb=$((PMTILES_MIN_FREE_GB * 1024 * 1024))
if [ -n "$PMTILES_MAX_SCRATCH_GB" ]; then
  max_scratch_kb="$(awk -v gb="$PMTILES_MAX_SCRATCH_GB" 'BEGIN { printf "%.0f", gb * 1024 * 1024 }')"
  ((max_scratch_kb > 0)) || die "PMTILES_MAX_SCRATCH_GB must be greater than zero"
else
  max_scratch_kb=0
fi

available_kb() {
  df -Pk "$PMTILES_SCRATCH_ROOT" | awk 'NR == 2 { print $4 }'
}

check_capacity() {
  local available usage
  available="$(available_kb)"
  if [[ ! "$available" =~ ^[0-9]+$ ]]; then
    capacity_failure_reason="could not determine free space for $PMTILES_SCRATCH_ROOT"
    echo "Scratch capacity check failed: $capacity_failure_reason" >&2
    return 1
  fi
  if ((available < min_free_kb)); then
    capacity_failure_reason="free space crossed the configured ${PMTILES_MIN_FREE_GB} GiB floor"
    echo "Scratch capacity is below the configured ${PMTILES_MIN_FREE_GB} GiB floor: $PMTILES_SCRATCH_ROOT" >&2
    return 1
  fi
  if [ -n "$current_theme_scratch" ] && [ -d "$current_theme_scratch" ]; then
    usage="$(du -sk -- "$current_theme_scratch" | awk '{ print $1 }')"
    if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
      capacity_failure_reason="could not determine usage for $current_theme_scratch"
      echo "Scratch capacity check failed: $capacity_failure_reason" >&2
      return 1
    fi
    if ((usage > peak_scratch_kb)); then
      peak_scratch_kb=$usage
    fi
    if ((max_scratch_kb > 0 && usage >= max_scratch_kb)); then
      capacity_failure_reason="theme scratch reached the configured ${PMTILES_MAX_SCRATCH_GB} GiB ceiling"
      echo "Theme scratch reached the configured ${PMTILES_MAX_SCRATCH_GB} GiB ceiling: $current_theme_scratch" >&2
      return 1
    fi
  fi
}

remote_size() {
  local remote=$1
  AWS_REGION="$S3_REGION" s5cmd head "$remote" \
    | sed -n 's/.*"size":\([0-9][0-9]*\).*/\1/p'
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '%s' "$value"
}

current_theme_scratch=""
current_parquet_stage=""
retain_completed=false
monitored_pid=""
peak_scratch_kb=0
capacity_failure_reason=""

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$monitored_pid" ]; then
    kill -TERM "$monitored_pid" 2>/dev/null || true
  fi
  if ((status != 0)) && [ -n "$current_theme_scratch" ] && [ "$retain_completed" != true ]; then
    rm -rf -- "$current_theme_scratch"
  fi
  if [ -n "$current_parquet_stage" ]; then
    rm -rf -- "$current_parquet_stage"
  fi
  rm -f -- "$PUBLICATION_TMP"
  exit "$status"
}
trap cleanup_on_exit EXIT INT TERM

run_with_capacity_monitor() {
  local label=$1
  shift

  "$@" &
  monitored_pid=$!
  local capacity_exhausted=false
  while kill -0 "$monitored_pid" 2>/dev/null; do
    sleep 1
    if kill -0 "$monitored_pid" 2>/dev/null && ! check_capacity; then
      capacity_exhausted=true
      kill -TERM "$monitored_pid" 2>/dev/null || true
      break
    fi
  done

  set +e
  wait "$monitored_pid"
  local command_status=$?
  set -e
  monitored_pid=""

  if [ "$capacity_exhausted" = true ]; then
    die "Stopped $label because $capacity_failure_reason"
  fi
  ((command_status == 0)) || die "$label failed with status $command_status"
}

promote_preserved_parquet() {
  local staged_theme=$1
  local target_theme="${PARQUET_OUT}/theme=${THEME}"
  local backup_theme="${PARQUET_OUT}/.backup-theme=${THEME}-$$"

  rm -rf -- "$backup_theme"
  if [ -e "$target_theme" ] || [ -L "$target_theme" ]; then
    mv -- "$target_theme" "$backup_theme"
  fi
  if ! mv -- "$staged_theme" "$target_theme"; then
    if [ -e "$backup_theme" ] || [ -L "$backup_theme" ]; then
      mv -- "$backup_theme" "$target_theme"
    fi
    die "Could not promote preserved GeoParquet for $THEME"
  fi
  rm -rf -- "$backup_theme" "$current_parquet_stage"
  current_parquet_stage=""
}

preserve_parquet() {
  rm -rf -- "$current_parquet_stage"
  mkdir -p "$current_parquet_stage"

  if [ "$is_s3_source" = true ]; then
    if [ -n "${BBOX:-}" ]; then
      local source_stage="${current_parquet_stage}/source"
      local filtered_stage="${current_parquet_stage}/filtered"
      mkdir -p "${source_stage}/theme=${THEME}" "$filtered_stage"
      env AWS_REGION="$S3_REGION" s5cmd sync \
        "${SOURCE_PATH%/}/theme=${THEME}/*" "${source_stage}/theme=${THEME}"
      bash /app/bbox.sh "" "$BBOX" "$THEME" "$filtered_stage" "" "" "$source_stage"
      promote_preserved_parquet "${filtered_stage}/theme=${THEME}"
    else
      mkdir -p "${current_parquet_stage}/theme=${THEME}"
      env AWS_REGION="$S3_REGION" s5cmd sync \
        "${SOURCE_PATH%/}/theme=${THEME}/*" "${current_parquet_stage}/theme=${THEME}"
      promote_preserved_parquet "${current_parquet_stage}/theme=${THEME}"
    fi
  else
    cp -aL -- "${PLANETILER_INPUT}/theme=${THEME}" "$current_parquet_stage/"
    promote_preserved_parquet "${current_parquet_stage}/theme=${THEME}"
  fi
}

mkdir -p "$PARQUET_OUT" "$PUBLICATION_DIR"
rm -f -- "$PUBLICATION_FILE" "$PUBLICATION_TMP"

publication_objects=""

for THEME in "${configured_themes[@]}"; do
  check_capacity || die "Refusing to start $THEME generation"

  THEME_SCRATCH="${PMTILES_SCRATCH_ROOT%/}/${RELEASE}/${THEME}"
  WORK_DIR="$THEME_SCRATCH/work"
  PLANETILER_INPUT="$THEME_SCRATCH/input"
  PMTILES_FILE="$THEME_SCRATCH/${THEME}.pmtiles"
  current_theme_scratch="$THEME_SCRATCH"
  retain_completed=false
  peak_scratch_kb=0
  capacity_failure_reason=""

  rm -rf -- "$THEME_SCRATCH"
  mkdir -p "$WORK_DIR/tmp" "$PLANETILER_INPUT"

  if [ "$is_s3_source" = true ]; then
    PLANETILER_DATA="$SOURCE_PATH"
    echo "Range-reading ${THEME} GeoParquet directly from ${SOURCE_PATH%/}/theme=${THEME}"
  elif [ -n "${BBOX:-}" ]; then
    echo "Filtering ${THEME} to BBOX ${BBOX}"
    run_with_capacity_monitor "BBOX filtering for $THEME" \
      bash /app/bbox.sh "" "$BBOX" "$THEME" "$PLANETILER_INPUT" "" "" "$SOURCE_PATH"
    PLANETILER_DATA="$PLANETILER_INPUT"
  else
    echo "Using unfiltered ${THEME} input"
    ln -s "${SOURCE_PATH%/}/theme=${THEME}" "${PLANETILER_INPUT}/theme=${THEME}"
    PLANETILER_DATA="$PLANETILER_INPUT"
  fi

  cd "$WORK_DIR"
  className="$(tr '[:lower:]' '[:upper:]' <<< "${THEME:0:1}")${THEME:1}"
  planetiler_args=(
    --data="$PLANETILER_DATA"
    --output="$PMTILES_FILE"
    --tmpdir="$WORK_DIR/tmp"
    --compress-temp="$PLANETILER_COMPRESS_TEMP"
    --mmap-temp="$PLANETILER_MMAP_TEMP"
  )
  if [ -n "${BBOX:-}" ]; then
    planetiler_args+=(--bounds="$BBOX")
  fi

  run_with_capacity_monitor "Planetiler generation for $THEME" \
    java -XX:MaxRAMPercentage=70 -cp /app/s3-parquet-adapter.jar:/app/planetiler.jar \
      "/app/profiles/${className}.java" "${planetiler_args[@]}"

  check_capacity || die "Refusing to publish $THEME because its scratch ceiling was reached"
  [[ -s "$PMTILES_FILE" ]] || {
    rm -rf -- "$THEME_SCRATCH"
    die "Planetiler did not create a non-empty PMTiles archive for $THEME"
  }

  if [ "$PRESERVE_PARQUET" = "true" ]; then
    echo "Preserving ${THEME} GeoParquet in ${PARQUET_OUT} (explicit local copy requested)"
    current_parquet_stage="${PARQUET_OUT}/.staging-theme=${THEME}-$$"
    run_with_capacity_monitor "GeoParquet preservation for $THEME" preserve_parquet
    current_parquet_stage=""
  fi

  local_size="$(stat -c '%s' "$PMTILES_FILE")"
  remote="${PMTILES_S3_PATH%/}/${THEME}.pmtiles"
  echo "Publishing ${THEME} to ${remote}"
  if ! AWS_REGION="$S3_REGION" s5cmd cp "$PMTILES_FILE" "$remote"; then
    retain_completed=true
    rm -rf -- "$WORK_DIR" "$PLANETILER_INPUT"
    die "Upload failed for $THEME; retained completed archive at $PMTILES_FILE"
  fi

  if ! uploaded_size="$(remote_size "$remote")"; then
    retain_completed=true
    rm -rf -- "$WORK_DIR" "$PLANETILER_INPUT"
    die "Upload verification request failed for $THEME; retained completed archive at $PMTILES_FILE"
  fi
  if [[ ! "$uploaded_size" =~ ^[0-9]+$ || "$uploaded_size" != "$local_size" ]]; then
    retain_completed=true
    rm -rf -- "$WORK_DIR" "$PLANETILER_INPUT"
    die "Upload verification failed for $THEME; retained completed archive at $PMTILES_FILE"
  fi

  if [ -n "$publication_objects" ]; then
    publication_objects+=","
  fi
  remote_json="$(json_escape "$remote")"
  publication_objects+="{\"theme\":\"$THEME\",\"filename\":\"$THEME.pmtiles\",\"uri\":\"$remote_json\",\"size\":$local_size}"

  peak_scratch_gib="$(awk -v kb="$peak_scratch_kb" 'BEGIN { printf "%.2f", kb / 1024 / 1024 }')"
  rm -rf -- "$THEME_SCRATCH"
  current_theme_scratch=""
  echo "Published and removed local archive for ${THEME} (${local_size} bytes; peak scratch ${peak_scratch_gib} GiB)"
done

theme_json=""
for theme in "${configured_themes[@]}"; do
  if [ -n "$theme_json" ]; then
    theme_json+=","
  fi
  theme_json+="\"$theme\""
done

if [ -n "${BBOX:-}" ]; then
  bbox_json="[$BBOX]"
else
  bbox_json="[-180,-90,180,90]"
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"schema_version":1,"release":"%s","generated_at":"%s","bbox":%s,"themes":[%s],"objects":[%s]}\n' \
  "$RELEASE" "$generated_at" "$bbox_json" "$theme_json" "$publication_objects" >"$PUBLICATION_TMP"
mv -f -- "$PUBLICATION_TMP" "$PUBLICATION_FILE"
echo "Published ${#configured_themes[@]} theme(s); wrote $PUBLICATION_FILE"
