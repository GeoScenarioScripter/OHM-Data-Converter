# OHM Planet → PostGIS Pipeline

Imports the full-planet [OpenHistoricalMap](https://www.openhistoricalmap.org/) (OHM) PBF dump into a local PostgreSQL/PostGIS database, preserving the temporal dimension (`start_date` / `end_date`) that distinguishes OHM from OpenStreetMap.

---

## Background

OHM is a crowdsourced historical mapping project built on OSM technology. Every feature carries `start_date` and `end_date` tags (ISO 8601) recording the real-world period during which it existed. A single planet file therefore spans all of recorded history — from roughly 5000 BCE to the present — with time expressed through feature-level attributes rather than separate files.

The planet file used here (`planet-260226_0301.osm.pbf`, generated 2026-02-26) is approximately 1 GB compressed. In terms of data volume it is comparable to OSM data for a mid-sized country.

---

## Prerequisites

| Tool | Version used | Location |
|---|---|---|
| PostgreSQL | 17.5 | `D:\Softwares\pg\` |
| PostGIS | 3.5.3 | (extension, bundled with PostgreSQL) |
| osm2pgsql | 2.2.0 | `D:\Softwares\osm2pgsql-bin\` |

---

## Files

```
historical-map-data/
├── data/                        # Planet / extract files — gitignored, not in version control
│   └── planet-260226_0301.osm.pbf
├── ohm-flex.lua                 # osm2pgsql flex output style
├── post-import.sql              # Post-import indexes, functions, generated columns
└── README.md                   # This file
```

### `ohm-flex.lua`

An osm2pgsql [flex output](https://osm2pgsql.org/doc/manual.html#the-flex-output) Lua script that defines how the PBF data maps to PostgreSQL tables. Key design decisions:

- **SRID 4326 (WGS84)** is used for all geometry columns. This is appropriate for planet-wide historical data spanning all latitudes and time periods.
- **`start_date` and `end_date`** are stored as raw `text` columns, preserving the original OHM tag values exactly (e.g. `"1850"`, `"-0500"`, `"~1250 BCE"`).
- **`tags`** holds all tags as `jsonb`, enabling rich querying with PostgreSQL JSON operators.
- **`name`** is extracted as a dedicated `text` column for convenient filtering without touching jsonb.
- OSM relations are distributed by geometry type rather than stored in a separate relations table (see [Relation handling](#relation-handling) below).

### `post-import.sql`

Runs once after the osm2pgsql import. Adds:

1. **`ohm_year(text) → integer`** — an `IMMUTABLE` function that parses OHM date strings to a signed integer year (negative = BCE).
2. **`start_year` / `end_year`** — stored generated columns on all four tables, computed from `ohm_year()`. These are indexable and make temporal queries cheap.
3. **Indexes** — see [Index summary](#index-summary) below.

---

## Setup

### 1. Create the database

```sql
-- Run as the postgres superuser
CREATE DATABASE ohm;
\c ohm
CREATE EXTENSION postgis;
```

Or from the shell:

```bash
PGPASSWORD=<password> psql -U postgres -c "CREATE DATABASE ohm;"
PGPASSWORD=<password> psql -U postgres -d ohm -c "CREATE EXTENSION postgis;"
```

### 2. Run the import

```bash
PGPASSWORD=<password> "D:/Softwares/osm2pgsql-bin/osm2pgsql.exe" \
  --slim \
  --drop \
  --output=flex \
  --style="D:/work/historical-map-data/ohm-flex.lua" \
  --host=localhost \
  --port=5432 \
  --database=ohm \
  --user=postgres \
  --number-processes=4 \
  --cache=2000 \
  "D:/work/historical-map-data/data/planet-260226_0301.osm.pbf"
```

**Flag notes:**
- `--slim` — stores intermediate node/way/relation data in temporary PostgreSQL tables instead of RAM, required for planet-sized files.
- `--drop` — removes the slim tables after import (saves ~several GB). Omit if you plan to do incremental updates later.
- `--cache=2000` — 2 GB node location cache. Increase if you have more RAM available.
- `--number-processes=4` — parallel geometry processing threads. Match to your CPU core count.

Import time on the test machine: **~11 minutes 33 seconds**.

### 3. Run post-import SQL

```bash
PGPASSWORD=<password> psql -U postgres -d ohm \
  -f "D:/work/historical-map-data/post-import.sql"
```

This step adds the temporal year columns and all secondary indexes. It is safe to re-run (`IF NOT EXISTS` guards are in place for all indexes).

---

## Database schema

All four tables reside in the `public` schema of the `ohm` database.

### Common columns

Every table shares this structure:

| Column | Type | Notes |
|---|---|---|
| `way_id` / `node_id` / `area_id` / `relation_id` | `bigint` | OSM element ID. In `ohm_polygons`, positive = from a way, negative = from a relation (the relation ID is stored as its negation). |
| `start_date` | `text` | Raw OHM tag value, e.g. `"1850"`, `"-0500-01-01"`, `"~1250 BCE"` |
| `end_date` | `text` | Raw OHM tag value. `NULL` means the feature has no documented end. |
| `name` | `text` | Extracted from the `name` tag for convenience. |
| `tags` | `jsonb` | All tags, including `start_date`, `end_date`, `name`, and all others. |
| `geom` | `geometry` (SRID 4326) | PostGIS geometry in WGS84. |
| `start_year` | `integer` GENERATED | Integer year parsed from `start_date` by `ohm_year()`. Negative = BCE. |
| `end_year` | `integer` GENERATED | Integer year parsed from `end_date` by `ohm_year()`. |

### Tables

#### `ohm_points`
Tagged OSM nodes. Settlements, landmarks, historical sites, etc.
- Geometry type: `POINT`
- Row count: **5,499,544**
- Disk size: **958 MB** (including indexes)

#### `ohm_lines`
OSM ways that are not areas — roads, rivers, coastlines, walls, railways, trade routes mapped as ways.
- Geometry type: `LINESTRING`
- Row count: **2,985,688**
- Disk size: **2,750 MB** (including indexes)

#### `ohm_polygons`
Closed ways with area semantics, plus `type=multipolygon` and `type=boundary` relations. Territories, administrative units, buildings, landuse, water bodies, etc.
- Geometry type: `GEOMETRY` (either `POLYGON` or `MULTIPOLYGON`)
- Row count: **1,525,606** (1,412,476 from ways + 113,130 from relations)
- Disk size: **6,083 MB** (including indexes)

#### `ohm_routes`
OSM `type=route` relations — historical road networks, pilgrimage routes, railway lines, shipping lanes, etc.
- Geometry type: `MULTILINESTRING`
- Row count: **5,819**
- Disk size: **106 MB** (including indexes)

### Relation handling

The 153,076 OSM relations in the source file are distributed as follows:

| Relation type | Destination |
|---|---|
| `type=multipolygon` | `ohm_polygons` (113,130 rows, `area_id < 0`) |
| `type=boundary` | `ohm_polygons` (included in the 113,130 above) |
| `type=route` | `ohm_routes` (5,819 rows) |
| Other types (`public_transport`, `restriction`, …) | Not imported — no geographic shape |

To identify whether an `ohm_polygons` row came from a way or a relation:

```sql
-- From a relation (area_id is negative; the OSM relation ID is abs(area_id))
SELECT name, abs(area_id) AS relation_id FROM ohm_polygons WHERE area_id < 0 LIMIT 5;

-- From a way
SELECT name, area_id AS way_id FROM ohm_polygons WHERE area_id > 0 LIMIT 5;
```

### Index summary

Each table has four indexes:

| Index type | Column(s) | Purpose |
|---|---|---|
| GIST | `geom` | Spatial queries (bounding box, intersection, containment) |
| B-tree | `(start_year, end_year)` | Temporal range queries |
| GIN | `tags` | JSONB key/value queries (`?`, `@>`, `?|`) |
| B-tree (partial) | `name WHERE name IS NOT NULL` | Name lookups and autocomplete |

---

## The `ohm_year()` function

Parses the wide variety of date formats found in OHM data into a signed integer year. Returns `NULL` for unparseable or empty values.

| Input | Output | Notes |
|---|---|---|
| `'1850'` | `1850` | Year only |
| `'1850-06'` | `1850` | Year-month |
| `'1850-06-15'` | `1850` | Full date |
| `'-0500'` | `-500` | ISO 8601 negative year (BCE) |
| `'-0500-01-01'` | `-500` | ISO 8601 negative date (BCE) |
| `'500 BCE'` | `-500` | Legacy OHM convention |
| `'500 BC'` | `-500` | Legacy OHM convention |
| `'~1850'` | `1850` | Approximate date (marker stripped) |
| `NULL` or `''` | `NULL` | No date |
| `'present'` | `NULL` | Unparseable text |

---

## Example queries

### Snapshot query — all features active in a given year

```sql
-- Everything that existed in 1850
SELECT name, tags->>'historic' AS type, start_date, end_date
FROM ohm_polygons
WHERE start_year <= 1850
  AND (end_year IS NULL OR end_year >= 1850)
ORDER BY ST_Area(geom::geography) DESC
LIMIT 20;
```

### Spatial + temporal — features in a bounding box at a point in time

```sql
-- Historical features in the region around Rome, active in 100 CE
SELECT name, tags->>'historic' AS type, start_year, end_year
FROM ohm_polygons
WHERE ST_Intersects(geom, ST_MakeEnvelope(11.0, 40.5, 14.0, 43.0, 4326))
  AND start_year <= 100
  AND (end_year IS NULL OR end_year >= 100);
```

### JSONB tag filter — all features tagged with a specific key

```sql
-- All mapped battlefields, across all time periods
SELECT name, start_year, end_year, ST_AsText(geom) AS location
FROM ohm_points
WHERE tags @> '{"historic": "battlefield"}'
ORDER BY start_year NULLS LAST;
```

### Name search across all time

```sql
-- Find anything with "Rome" in the name from any table
SELECT 'points'   AS tbl, name, start_year, end_year FROM ohm_points   WHERE name ILIKE '%rome%'
UNION ALL
SELECT 'polygons', name, start_year, end_year FROM ohm_polygons WHERE name ILIKE '%rome%'
UNION ALL
SELECT 'lines',    name, start_year, end_year FROM ohm_lines    WHERE name ILIKE '%rome%'
ORDER BY start_year NULLS LAST;
```

### Identify source of an `ohm_polygons` row

```sql
-- Was this row created from a way or a relation?
SELECT
  name,
  CASE WHEN area_id > 0 THEN 'way ' || area_id
       ELSE 'relation ' || abs(area_id)
  END AS osm_source
FROM ohm_polygons
WHERE name = 'Roman Empire';
```

---

## Temporal data coverage

Of the 10,016,657 total features:
- **2,377,069** have a parseable `start_year`
- **586,994** have a parseable `end_year`
- The bulk of features (especially nodes used purely as way geometry) carry no temporal tags at all

The realistic date span of meaningfully dated features is roughly **5000 BCE to 2100 CE**. A small number of features contain clearly erroneous dates far outside this range; `ohm_year()` will parse them faithfully, so filter with `WHERE start_year BETWEEN -5000 AND 2100` when you need a clean temporal window.

---

## Re-running the import

To refresh the data with a new planet file:

```bash
# Drop and recreate the database
PGPASSWORD=<password> psql -U postgres -c "DROP DATABASE ohm; CREATE DATABASE ohm;"
PGPASSWORD=<password> psql -U postgres -d ohm -c "CREATE EXTENSION postgis;"

# Re-run steps 2 and 3 from Setup above
```
