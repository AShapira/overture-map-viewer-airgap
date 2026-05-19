#!/usr/bin/env bash

set -euo pipefail

RELEASE="${RELEASE:-2026-04-15.0}"
SOURCE_PATH="${SOURCE_PATH:-/input/release}"
OUTPUT="${OUTPUT:-/output}"
THEME="${THEME:?THEME is required}"
S3_REGION="${S3_REGION:-us-west-2}"
PRESERVE_PARQUET="${PRESERVE_PARQUET:-true}"

WORK_DIR="/work"
PLANETILER_INPUT="/data/overture"
PMTILES_OUT="${OUTPUT%/}/tiles/${RELEASE}"
PARQUET_OUT="${OUTPUT%/}/data/release/${RELEASE}"

mkdir -p "$WORK_DIR/data" "$PLANETILER_INPUT" "$PMTILES_OUT" "$PARQUET_OUT"

is_s3_source=false
case "$SOURCE_PATH" in
  s3://*) is_s3_source=true ;;
esac

if [ -n "${BBOX:-}" ]; then
  echo "Filtering ${THEME} to BBOX ${BBOX}"
  if [ "$is_s3_source" = true ]; then
    AWS_REGION="$S3_REGION" s5cmd sync "${SOURCE_PATH%/}/theme=${THEME}/*" "/tmp/overture_source/theme=${THEME}"
    bash /app/bbox.sh "" "$BBOX" "$THEME" "$PLANETILER_INPUT" "" "" /tmp/overture_source
  else
    bash /app/bbox.sh "" "$BBOX" "$THEME" "$PLANETILER_INPUT" "" "" "$SOURCE_PATH"
  fi
else
  echo "Using unfiltered ${THEME} input"
  if [ "$is_s3_source" = true ]; then
    AWS_REGION="$S3_REGION" s5cmd sync "${SOURCE_PATH%/}/theme=${THEME}/*" "${PLANETILER_INPUT}/theme=${THEME}"
  else
    ln -s "${SOURCE_PATH%/}/theme=${THEME}" "${PLANETILER_INPUT}/theme=${THEME}"
  fi
fi

cd "$WORK_DIR"
className="$(tr '[:lower:]' '[:upper:]' <<< "${THEME:0:1}")${THEME:1}"
java -XX:MaxRAMPercentage=70 -cp /app/planetiler.jar "/app/profiles/${className}.java" --data="$PLANETILER_INPUT"

cp "${WORK_DIR}/data/${THEME}.pmtiles" "${PMTILES_OUT}/${THEME}.pmtiles"

if [ "$PRESERVE_PARQUET" = "true" ] && [ -d "${PLANETILER_INPUT}/theme=${THEME}" ]; then
  mkdir -p "$PARQUET_OUT"
  cp -a "${PLANETILER_INPUT}/theme=${THEME}" "$PARQUET_OUT/"
fi

echo "Wrote ${PMTILES_OUT}/${THEME}.pmtiles"
