#!/usr/bin/env bash
# query-countries.sh
# Exports country-level boundaries (admin_level=2) active in a given year
# from the ohm PostGIS database to a GeoJSON file.
#
# Usage:
#   ./query-countries.sh <year>
#
# Examples:
#   ./query-countries.sh 1850          # 1850 CE
#   ./query-countries.sh -500          # 500 BCE
#   ./query-countries.sh 0             # 1 BCE / 1 CE boundary
#
# Output:
#   output/countries_<year>.geojson

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <year>" >&2
    echo "  Example: $0 1850   (CE)" >&2
    echo "  Example: $0 -500   (BCE)" >&2
    exit 1
fi

YEAR="$1"

if ! [[ "$YEAR" =~ ^-?[0-9]+$ ]]; then
    echo "Error: year must be an integer (e.g. 1850 or -500)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

OGR2OGR="D:/Softwares/osgeo/bin/ogr2ogr.exe"
PSQL="D:/Softwares/pg/bin/psql.exe"

export PGPASSWORD=20000601
# Use OSGeo4W's PROJ data to avoid conflicts with PostgreSQL's bundled PROJ
export PROJ_DATA="D:/Softwares/osgeo/share/proj"
PG_HOST=localhost
PG_PORT=5432
PG_DB=ohm
PG_USER=postgres

OUTPUT_DIR="output"
OUTPUT_FILE="${OUTPUT_DIR}/countries_${YEAR}.geojson"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# SQL query
# A feature is "active" in YEAR if:
#   start_year <= YEAR  AND  (end_year IS NULL OR end_year >= YEAR)
# Features with no start_year are excluded (insufficient temporal data).
#
# All original OHM tags are preserved in the 'tags' property as a JSON
# object alongside the dedicated metadata columns.
# ---------------------------------------------------------------------------

read -r -d '' SQL << ENDSQL || true
SELECT
  area_id       AS osm_id,
  name,
  start_date,
  end_date,
  start_year,
  end_year,
  tags::text    AS tags,
  geom
FROM ohm_polygons
WHERE tags->>'admin_level' = '2'
  AND start_year <= ${YEAR}
  AND (end_year IS NULL OR end_year >= ${YEAR})
ENDSQL

# ---------------------------------------------------------------------------
# Count matching features first
# ---------------------------------------------------------------------------

COUNT=$("$PSQL" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    -t -A -c "
    SELECT count(*)
    FROM ohm_polygons
    WHERE tags->>'admin_level' = '2'
      AND start_year <= ${YEAR}
      AND (end_year IS NULL OR end_year >= ${YEAR});")

echo "Year ${YEAR}: found ${COUNT} country boundary feature(s)."

if [[ "$COUNT" -eq 0 ]]; then
    echo "Nothing to export."
    exit 0
fi

# ---------------------------------------------------------------------------
# Export to GeoJSON via ogr2ogr
# ---------------------------------------------------------------------------

"$OGR2OGR" \
    -f GeoJSON \
    "$OUTPUT_FILE" \
    PG:"host=${PG_HOST} port=${PG_PORT} dbname=${PG_DB} user=${PG_USER}" \
    -sql "$SQL" \
    -nln "countries_${YEAR}" \
    -lco COORDINATE_PRECISION=6 \
    -lco RFC7946=YES

echo "Written to: ${OUTPUT_FILE}"
