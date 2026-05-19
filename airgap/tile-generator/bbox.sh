#!/usr/bin/env bash

set -euo pipefail

RELEASE=$1
BBOX=$2
THEME=$3
OUTPUT_DIR=$4
OVERTURE_RELEASE_BUCKET=$5
OVERTURE_REGION=$6
INPUT_DIR=${7:-}

IFS=',' read -r MIN_LON MIN_LAT MAX_LON MAX_LAT <<< "$BBOX"

case $THEME in
  addresses) TYPES="address" ;;
  base) TYPES="bathymetry infrastructure land land_cover water" ;;
  buildings) TYPES="building building_part" ;;
  divisions) TYPES="division division_area division_boundary" ;;
  places) TYPES="place" ;;
  transportation) TYPES="connector segment" ;;
  *) echo "Unsupported THEME: $THEME" >&2; exit 1 ;;
esac

for TYPE in $TYPES; do
  TYPE_DIR="$OUTPUT_DIR/theme=$THEME/type=$TYPE"
  mkdir -p "$TYPE_DIR"
  OUTPUT_FILE="$TYPE_DIR/filtered.parquet"

  if [ -n "$INPUT_DIR" ]; then
    PARQUET_PATH="$INPUT_DIR/theme=$THEME/type=$TYPE/*.parquet"
    S3_CONFIG=""
  else
    PARQUET_PATH="$OVERTURE_RELEASE_BUCKET/$RELEASE/theme=$THEME/type=$TYPE/*.parquet"
    S3_CONFIG="SET s3_region='$OVERTURE_REGION'; SET s3_url_style='path';"
  fi

  duckdb -c "
  $S3_CONFIG
  COPY (
    SELECT *
    FROM read_parquet('$PARQUET_PATH', union_by_name=true, filename=true, hive_partitioning=false)
    WHERE bbox.xmin <= $MAX_LON
      AND bbox.xmax >= $MIN_LON
      AND bbox.ymin <= $MAX_LAT
      AND bbox.ymax >= $MIN_LAT
  ) TO '$OUTPUT_FILE';
  "

  if [ ! -f "$OUTPUT_FILE" ] || [ ! -s "$OUTPUT_FILE" ]; then
    echo "No features found in bbox for $THEME/$TYPE"
    rm -f "$OUTPUT_FILE"
  fi
done
