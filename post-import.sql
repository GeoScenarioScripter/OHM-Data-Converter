-- post-import.sql
-- Run once after osm2pgsql completes.
-- Adds: ohm_year() helper, start_year/end_year generated columns,
--       spatial indexes (GIST), temporal indexes (B-tree), JSONB index (GIN).

-- ---------------------------------------------------------------------------
-- 1. Date parsing helper
-- ---------------------------------------------------------------------------
-- Extracts an integer calendar year from an OHM start_date / end_date tag.
-- Handles all common OHM formats:
--   ISO 8601:        "1850"  "1850-06"  "1850-06-15"
--   Negative years:  "-0500"  "-0500-01-01"        (BCE in ISO 8601)
--   Legacy BCE:      "500 BCE"  "500 BC"  "500 bce"
--   CE explicit:     "500 CE"
--   Approximate:     "~1850"  "~-0500"
--   Returns NULL for NULL input, empty strings, or unparseable values.

CREATE OR REPLACE FUNCTION ohm_year(date_str text)
RETURNS integer
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    s text;
    year_str text;
    y integer;
BEGIN
    s := trim(date_str);
    IF s = '' THEN RETURN NULL; END IF;

    -- Strip leading approximate marker(s)
    s := ltrim(s, '~');
    s := trim(s);
    IF s = '' THEN RETURN NULL; END IF;

    -- "YYYY BCE" / "YYYY BC" / "YYYY bce" (older OHM convention, positive number)
    IF s ~* '\s+bce?$' THEN
        year_str := trim(regexp_replace(s, '\s+bce?$', '', 'i'));
        BEGIN
            y := year_str::integer;
            RETURN -abs(y);
        EXCEPTION WHEN OTHERS THEN RETURN NULL;
        END;
    END IF;

    -- "YYYY CE" explicit
    IF s ~* '\s+ce$' THEN
        year_str := trim(regexp_replace(s, '\s+ce$', '', 'i'));
        BEGIN
            y := year_str::integer;
            RETURN y;
        EXCEPTION WHEN OTHERS THEN RETURN NULL;
        END;
    END IF;

    -- ISO 8601 negative year: "-YYYY", "-YYYY-MM", "-YYYY-MM-DD"
    IF left(s, 1) = '-' THEN
        -- Drop the leading '-', take the first dash-delimited token (the year digits)
        year_str := split_part(substring(s FROM 2), '-', 1);
        BEGIN
            y := year_str::integer;
            RETURN -y;
        EXCEPTION WHEN OTHERS THEN RETURN NULL;
        END;
    END IF;

    -- Standard positive ISO 8601: "YYYY", "YYYY-MM", "YYYY-MM-DD"
    year_str := split_part(s, '-', 1);
    BEGIN
        y := year_str::integer;
        RETURN y;
    EXCEPTION WHEN OTHERS THEN RETURN NULL;
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Generated integer year columns (stored, so they can be indexed)
-- ---------------------------------------------------------------------------
-- These allow simple temporal queries:
--   WHERE start_year <= 1850 AND (end_year IS NULL OR end_year >= 1850)

ALTER TABLE ohm_points
    ADD COLUMN IF NOT EXISTS start_year integer GENERATED ALWAYS AS (ohm_year(start_date)) STORED,
    ADD COLUMN IF NOT EXISTS end_year   integer GENERATED ALWAYS AS (ohm_year(end_date))   STORED;

ALTER TABLE ohm_lines
    ADD COLUMN IF NOT EXISTS start_year integer GENERATED ALWAYS AS (ohm_year(start_date)) STORED,
    ADD COLUMN IF NOT EXISTS end_year   integer GENERATED ALWAYS AS (ohm_year(end_date))   STORED;

ALTER TABLE ohm_polygons
    ADD COLUMN IF NOT EXISTS start_year integer GENERATED ALWAYS AS (ohm_year(start_date)) STORED,
    ADD COLUMN IF NOT EXISTS end_year   integer GENERATED ALWAYS AS (ohm_year(end_date))   STORED;

ALTER TABLE ohm_routes
    ADD COLUMN IF NOT EXISTS start_year integer GENERATED ALWAYS AS (ohm_year(start_date)) STORED,
    ADD COLUMN IF NOT EXISTS end_year   integer GENERATED ALWAYS AS (ohm_year(end_date))   STORED;

-- ---------------------------------------------------------------------------
-- 3. Spatial indexes (GIST)
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ohm_points_geom_idx   ON ohm_points   USING GIST (geom);
CREATE INDEX IF NOT EXISTS ohm_lines_geom_idx    ON ohm_lines    USING GIST (geom);
CREATE INDEX IF NOT EXISTS ohm_polygons_geom_idx ON ohm_polygons USING GIST (geom);
CREATE INDEX IF NOT EXISTS ohm_routes_geom_idx   ON ohm_routes   USING GIST (geom);

-- ---------------------------------------------------------------------------
-- 4. Temporal indexes (B-tree on integer year columns)
-- ---------------------------------------------------------------------------
-- Composite (start_year, end_year) supports range queries efficiently.

CREATE INDEX IF NOT EXISTS ohm_points_years_idx   ON ohm_points   (start_year, end_year);
CREATE INDEX IF NOT EXISTS ohm_lines_years_idx    ON ohm_lines    (start_year, end_year);
CREATE INDEX IF NOT EXISTS ohm_polygons_years_idx ON ohm_polygons (start_year, end_year);
CREATE INDEX IF NOT EXISTS ohm_routes_years_idx   ON ohm_routes   (start_year, end_year);

-- ---------------------------------------------------------------------------
-- 5. JSONB tag index (GIN) — enables fast @>, ?, ?| operators on tags
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ohm_points_tags_idx   ON ohm_points   USING GIN (tags);
CREATE INDEX IF NOT EXISTS ohm_lines_tags_idx    ON ohm_lines    USING GIN (tags);
CREATE INDEX IF NOT EXISTS ohm_polygons_tags_idx ON ohm_polygons USING GIN (tags);
CREATE INDEX IF NOT EXISTS ohm_routes_tags_idx   ON ohm_routes   USING GIN (tags);

-- ---------------------------------------------------------------------------
-- 6. Name text index (for quick name lookups / autocomplete)
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ohm_points_name_idx   ON ohm_points   (name) WHERE name IS NOT NULL;
CREATE INDEX IF NOT EXISTS ohm_lines_name_idx    ON ohm_lines    (name) WHERE name IS NOT NULL;
CREATE INDEX IF NOT EXISTS ohm_polygons_name_idx ON ohm_polygons (name) WHERE name IS NOT NULL;
CREATE INDEX IF NOT EXISTS ohm_routes_name_idx   ON ohm_routes   (name) WHERE name IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 7. Update table statistics
-- ---------------------------------------------------------------------------

ANALYZE ohm_points;
ANALYZE ohm_lines;
ANALYZE ohm_polygons;
ANALYZE ohm_routes;

-- ---------------------------------------------------------------------------
-- Quick sanity check
-- ---------------------------------------------------------------------------
SELECT
    'ohm_points'   AS tbl, count(*) AS rows FROM ohm_points   UNION ALL
SELECT 'ohm_lines',    count(*) FROM ohm_lines    UNION ALL
SELECT 'ohm_polygons', count(*) FROM ohm_polygons UNION ALL
SELECT 'ohm_routes',   count(*) FROM ohm_routes
ORDER BY tbl;
