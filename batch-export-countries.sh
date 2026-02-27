#!/usr/bin/env bash
# batch-export-countries.sh
# Exports country-level boundary GeoJSON for every year in a range.
#
# Already-exported years are skipped automatically — safe to re-run
# after an interruption without re-processing completed years.
#
# Usage:
#   ./batch-export-countries.sh [START_YEAR [END_YEAR [WORKERS]]]
#
# Arguments (all optional, positional):
#   START_YEAR  First year to export           (default: 1900)
#   END_YEAR    Last year to export, inclusive  (default: current year)
#   WORKERS     Parallel ogr2ogr jobs           (default: 4)
#
# Examples:
#   ./batch-export-countries.sh                   # 1900 to present, 4 workers
#   ./batch-export-countries.sh 1800              # 1800 to present
#   ./batch-export-countries.sh 1900 1950         # 1900–1950 only
#   ./batch-export-countries.sh 1900 2026 8       # 8 parallel workers

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments and validation
# ---------------------------------------------------------------------------

START_YEAR=${1:-1900}
END_YEAR=${2:-$(date +%Y)}
WORKERS=${3:-4}

if ! [[ "$START_YEAR" =~ ^-?[0-9]+$ ]] || ! [[ "$END_YEAR" =~ ^-?[0-9]+$ ]]; then
    echo "Error: START_YEAR and END_YEAR must be integers." >&2
    exit 1
fi

if (( START_YEAR > END_YEAR )); then
    echo "Error: START_YEAR (${START_YEAR}) must be <= END_YEAR (${END_YEAR})." >&2
    exit 1
fi

if (( WORKERS < 1 )); then
    echo "Error: WORKERS must be at least 1." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_SCRIPT="$SCRIPT_DIR/query-countries.sh"
OUTPUT_DIR="$SCRIPT_DIR/output"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Determine which years still need exporting
# ---------------------------------------------------------------------------

TOTAL=$(( END_YEAR - START_YEAR + 1 ))
YEARS_TO_EXPORT=()
SKIP_COUNT=0

for year in $(seq "$START_YEAR" "$END_YEAR"); do
    if [[ -f "$OUTPUT_DIR/countries_${year}.geojson" ]]; then
        SKIP_COUNT=$(( SKIP_COUNT + 1 ))
    else
        YEARS_TO_EXPORT+=("$year")
    fi
done

EXPORT_COUNT=${#YEARS_TO_EXPORT[@]}

echo "==> Batch country boundary export"
echo "    Range   : ${START_YEAR} to ${END_YEAR} (${TOTAL} years total)"
echo "    Export  : ${EXPORT_COUNT} year(s)"
echo "    Skip    : ${SKIP_COUNT} already exist"
echo "    Workers : ${WORKERS} parallel jobs"
echo ""

if [[ "$EXPORT_COUNT" -eq 0 ]]; then
    echo "All files already exist. Nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------
# Run exports in parallel via xargs -P
# Output lines from concurrent jobs may interleave, but each is short enough
# to remain readable.
# ---------------------------------------------------------------------------

START_TS=$SECONDS

printf '%s\n' "${YEARS_TO_EXPORT[@]}" \
    | xargs -P "$WORKERS" -I{} bash "$EXPORT_SCRIPT" {}

ELAPSED=$(( SECONDS - START_TS ))
WRITTEN=$(ls "$OUTPUT_DIR"/countries_*.geojson 2>/dev/null | wc -l)

echo ""
echo "==> Done in ${ELAPSED}s — ${WRITTEN} total file(s) in output/"
