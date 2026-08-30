#!/usr/bin/env bash

set -euo pipefail

RELEASE="${RELEASE:-2026-04-15.0}"
SOURCE_PATH="${SOURCE_PATH:-/input/release}"
OUTPUT="${OUTPUT:-/output}"
THEMES="${THEMES:-base,buildings,places,divisions,transportation,addresses}"
PMTILES_S3_PATH="${PMTILES_S3_PATH:?PMTILES_S3_PATH is required}"
PMTILES_SCRATCH_ROOT="${PMTILES_SCRATCH_ROOT:-/scratch}"
PMTILES_MIN_FREE_GB="${PMTILES_MIN_FREE_GB:?PMTILES_MIN_FREE_GB is required}"
S3_REGION="${S3_REGION:-us-west-2}"
PRESERVE_PARQUET="${PRESERVE_PARQUET:-true}"
CAPACITY_CHECK_SECONDS=5

PARQUET_OUT="${OUTPUT%/}/data/release/${RELEASE}"
PUBLICATION_DIR="${OUTPUT%/}/publication"
PUBLICATION_FILE="${PUBLICATION_DIR}/${RELEASE}.json"
PUBLICATION_TMP="${PUBLICATION_FILE}.tmp"
SUPPORTED_THEMES=" addresses base buildings divisions places transportation "

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

available_kb() {
  df -Pk "$PMTILES_SCRATCH_ROOT" | awk 'NR == 2 { print $4 }'
}

check_capacity() {
  local available
  available="$(available_kb)"
  [[ "$available" =~ ^[0-9]+$ ]] || die "Could not determine free space for $PMTILES_SCRATCH_ROOT"
  if ((available < min_free_kb)); then
    echo "Scratch capacity is below the configured ${PMTILES_MIN_FREE_GB} GiB floor: $PMTILES_SCRATCH_ROOT" >&2
    return 1
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
retain_completed=false
monitored_pid=""

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$monitored_pid" ]; then
    kill -TERM "$monitored_pid" 2>/dev/null || true
  fi
  if ((status != 0)) && [ -n "$current_theme_scratch" ] && [ "$retain_completed" != true ]; then
    rm -rf -- "$current_theme_scratch"
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
  local elapsed_seconds=0
  while kill -0 "$monitored_pid" 2>/dev/null; do
    sleep 1
    ((elapsed_seconds += 1))
    if ((elapsed_seconds >= CAPACITY_CHECK_SECONDS)) && kill -0 "$monitored_pid" 2>/dev/null && ! check_capacity; then
      capacity_exhausted=true
      kill -TERM "$monitored_pid" 2>/dev/null || true
      break
    fi
    if ((elapsed_seconds >= CAPACITY_CHECK_SECONDS)); then
      elapsed_seconds=0
    fi
  done

  set +e
  wait "$monitored_pid"
  local command_status=$?
  set -e
  monitored_pid=""

  if [ "$capacity_exhausted" = true ]; then
    die "Stopped $label because scratch free space crossed the configured floor"
  fi
  ((command_status == 0)) || die "$label failed with status $command_status"
}

mkdir -p "$PARQUET_OUT" "$PUBLICATION_DIR"
rm -f -- "$PUBLICATION_FILE" "$PUBLICATION_TMP"

publication_objects=""

is_s3_source=false
case "$SOURCE_PATH" in
  s3://*) is_s3_source=true ;;
esac

for THEME in "${configured_themes[@]}"; do
  check_capacity || die "Refusing to start $THEME generation"

  THEME_SCRATCH="${PMTILES_SCRATCH_ROOT%/}/${RELEASE}/${THEME}"
  WORK_DIR="$THEME_SCRATCH/work"
  PLANETILER_INPUT="$THEME_SCRATCH/input"
  SOURCE_STAGE="$THEME_SCRATCH/source"
  PMTILES_FILE="$THEME_SCRATCH/${THEME}.pmtiles"
  current_theme_scratch="$THEME_SCRATCH"
  retain_completed=false

  rm -rf -- "$THEME_SCRATCH"
  mkdir -p "$WORK_DIR/tmp" "$PLANETILER_INPUT" "$SOURCE_STAGE"

  if [ -n "${BBOX:-}" ]; then
    echo "Filtering ${THEME} to BBOX ${BBOX}"
    if [ "$is_s3_source" = true ]; then
      run_with_capacity_monitor "source download for $THEME" \
        env AWS_REGION="$S3_REGION" s5cmd sync "${SOURCE_PATH%/}/theme=${THEME}/*" "$SOURCE_STAGE/theme=${THEME}"
      run_with_capacity_monitor "BBOX filtering for $THEME" \
        bash /app/bbox.sh "" "$BBOX" "$THEME" "$PLANETILER_INPUT" "" "" "$SOURCE_STAGE"
      rm -rf -- "$SOURCE_STAGE"
    else
      run_with_capacity_monitor "BBOX filtering for $THEME" \
        bash /app/bbox.sh "" "$BBOX" "$THEME" "$PLANETILER_INPUT" "" "" "$SOURCE_PATH"
    fi
  else
    echo "Using unfiltered ${THEME} input"
    if [ "$is_s3_source" = true ]; then
      run_with_capacity_monitor "source download for $THEME" \
        env AWS_REGION="$S3_REGION" s5cmd sync "${SOURCE_PATH%/}/theme=${THEME}/*" "${PLANETILER_INPUT}/theme=${THEME}"
    else
      ln -s "${SOURCE_PATH%/}/theme=${THEME}" "${PLANETILER_INPUT}/theme=${THEME}"
    fi
  fi

  cd "$WORK_DIR"
  className="$(tr '[:lower:]' '[:upper:]' <<< "${THEME:0:1}")${THEME:1}"
  planetiler_args=(
    --data="$PLANETILER_INPUT"
    --output="$PMTILES_FILE"
    --tmpdir="$WORK_DIR/tmp"
  )
  if [ -n "${BBOX:-}" ]; then
    planetiler_args+=(--bounds="$BBOX")
  fi

  run_with_capacity_monitor "Planetiler generation for $THEME" \
    java -XX:MaxRAMPercentage=70 -cp /app/planetiler.jar "/app/profiles/${className}.java" "${planetiler_args[@]}"

  [[ -s "$PMTILES_FILE" ]] || {
    rm -rf -- "$THEME_SCRATCH"
    die "Planetiler did not create a non-empty PMTiles archive for $THEME"
  }

  if [ "$PRESERVE_PARQUET" = "true" ] && [ -d "${PLANETILER_INPUT}/theme=${THEME}" ]; then
    mkdir -p "$PARQUET_OUT"
    cp -a "${PLANETILER_INPUT}/theme=${THEME}" "$PARQUET_OUT/"
  fi

  local_size="$(stat -c '%s' "$PMTILES_FILE")"
  remote="${PMTILES_S3_PATH%/}/${THEME}.pmtiles"
  echo "Publishing ${THEME} to ${remote}"
  if ! AWS_REGION="$S3_REGION" s5cmd cp "$PMTILES_FILE" "$remote"; then
    retain_completed=true
    rm -rf -- "$WORK_DIR" "$PLANETILER_INPUT" "$SOURCE_STAGE"
    die "Upload failed for $THEME; retained completed archive at $PMTILES_FILE"
  fi

  if ! uploaded_size="$(remote_size "$remote")"; then
    retain_completed=true
    rm -rf -- "$WORK_DIR" "$PLANETILER_INPUT" "$SOURCE_STAGE"
    die "Upload verification request failed for $THEME; retained completed archive at $PMTILES_FILE"
  fi
  if [[ ! "$uploaded_size" =~ ^[0-9]+$ || "$uploaded_size" != "$local_size" ]]; then
    retain_completed=true
    rm -rf -- "$WORK_DIR" "$PLANETILER_INPUT" "$SOURCE_STAGE"
    die "Upload verification failed for $THEME; retained completed archive at $PMTILES_FILE"
  fi

  if [ -n "$publication_objects" ]; then
    publication_objects+=","
  fi
  remote_json="$(json_escape "$remote")"
  publication_objects+="{\"theme\":\"$THEME\",\"filename\":\"$THEME.pmtiles\",\"uri\":\"$remote_json\",\"size\":$local_size}"

  rm -rf -- "$THEME_SCRATCH"
  current_theme_scratch=""
  echo "Published and removed local archive for ${THEME} (${local_size} bytes)"
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
