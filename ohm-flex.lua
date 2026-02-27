-- ohm-flex.lua
-- osm2pgsql 2.x flex output for OpenHistoricalMap (OHM)
--
-- Produces four tables:
--   ohm_points    -- tagged nodes
--   ohm_lines     -- non-area ways (roads, rivers, railways, …)
--   ohm_polygons  -- area ways + multipolygon/boundary relations
--   ohm_routes    -- route relations as multilinestrings
--
-- Every table carries start_date / end_date as dedicated text columns
-- (raw OHM tag values, e.g. "1850", "-0500", "1850-06-15", "~1250 BCE")
-- alongside a jsonb column holding all tags and a PostGIS geometry column.
--
-- Post-import SQL (post-import.sql) adds integer start_year / end_year
-- generated columns and all indexes.
--
-- SRID 4326 (WGS84) is used throughout; appropriate for planet-wide
-- historical data that spans all time periods and latitudes.

local srid = 4326
local tables = {}

-- ---------------------------------------------------------------------------
-- Table definitions
-- ---------------------------------------------------------------------------

-- Helper: build a column list with the shared temporal + tags + geom columns
local function temporal_cols(geom_type)
    return {
        { column = 'start_date', type = 'text' },
        { column = 'end_date',   type = 'text' },
        { column = 'name',       type = 'text' },
        { column = 'tags',       type = 'jsonb' },
        { column = 'geom',       type = geom_type, projection = srid, not_null = true },
    }
end

-- Tagged nodes
tables.points = osm2pgsql.define_node_table('ohm_points',
    temporal_cols('point'))

-- Non-area ways (open ways + closed ways without area semantics)
tables.lines = osm2pgsql.define_way_table('ohm_lines',
    temporal_cols('linestring'))

-- Area ways + multipolygon/boundary relations
-- define_area_table handles both closed ways (positive osm_id) and
-- multipolygon/boundary relations (negative osm_id) transparently.
tables.polygons = osm2pgsql.define_area_table('ohm_polygons',
    temporal_cols('geometry'))   -- 'geometry' accepts both POLYGON and MULTIPOLYGON

-- Route relations
tables.routes = osm2pgsql.define_relation_table('ohm_routes',
    temporal_cols('multilinestring'))

-- ---------------------------------------------------------------------------
-- Tag helpers
-- ---------------------------------------------------------------------------

-- Tags that indicate a closed way represents an area rather than a linear loop.
-- Follows OSM/OHM convention; area=yes/no takes precedence.
local function has_area_tags(tags)
    if tags.area == 'yes' then return true  end
    if tags.area == 'no'  then return false end

    return tags.aeroway
        or tags.amenity
        or tags.boundary
        or tags.building
        or tags['building:part']
        or tags.harbour
        or tags.historic
        or tags.landuse
        or tags.leisure
        or tags.man_made
        or tags.military
        or tags.natural
        or tags.office
        or tags.place
        or tags.power
        or tags.public_transport
        or tags.shop
        or tags.sport
        or tags.tourism
        or tags.water
        or tags.waterway
        or tags.wetland
        or tags['abandoned:aeroway']
        or tags['abandoned:amenity']
        or tags['abandoned:building']
        or tags['abandoned:landuse']
        or tags['abandoned:power']
        or tags['area:highway']
end

-- Build the common row fields from an OSM object.
-- The 'type' tag on relations is preserved in tags so it stays in jsonb.
local function make_row(object)
    local t = object.tags
    return {
        start_date = t.start_date,
        end_date   = t.end_date,
        name       = t.name,
        tags       = t,
        -- geom is set by the caller
    }
end

-- ---------------------------------------------------------------------------
-- Processing functions
-- ---------------------------------------------------------------------------

function osm2pgsql.process_node(object)
    -- Skip completely untagged nodes (geometry-only nodes for ways)
    if not next(object.tags) then return end

    local r = make_row(object)
    r.geom = object:as_point()
    tables.points:insert(r)
end

function osm2pgsql.process_way(object)
    if not next(object.tags) then return end

    local r = make_row(object)

    if object.is_closed and has_area_tags(object.tags) then
        r.geom = object:as_polygon()
        tables.polygons:insert(r)
    else
        r.geom = object:as_linestring()
        tables.lines:insert(r)
    end
end

function osm2pgsql.process_relation(object)
    -- Read type tag without removing it (we want it in the jsonb column)
    local rel_type = object.tags['type']
    if not next(object.tags) then return end

    local r = make_row(object)

    if rel_type == 'multipolygon' then
        r.geom = object:as_multipolygon()
        tables.polygons:insert(r)

    elseif rel_type == 'boundary' then
        -- Territorial/political boundaries: store as multipolygon so spatial
        -- containment and area queries work directly.
        -- osm2pgsql will warn and skip if the member ways don't close properly.
        r.geom = object:as_multipolygon()
        tables.polygons:insert(r)

    elseif rel_type == 'route' then
        r.geom = object:as_multilinestring()
        tables.routes:insert(r)
    end
    -- Other relation types (public_transport, restriction, etc.) are ignored.
end
