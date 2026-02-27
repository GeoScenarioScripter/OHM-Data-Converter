"""
convert_to_shp.py

Converts OHM country boundary GeoJSON files (one per year) to ESRI Shapefiles.

Added fields per feature:
  oid      - sequential 1-based integer ID within each shapefile
  title    - Chinese name (taken from tags, or machine-translated)
  title_en - English name (taken from tags, or falls back to 'name')

Output:
  output/shp/<year>/countries_<year>.shp

Usage:
  uv run main.py                        # all years (1900-2026)
  uv run main.py --start 1950 --end 2000
"""

import argparse
import json
import re
import time
from pathlib import Path
from typing import Optional

import geopandas as gpd
import pandas as pd
from deep_translator import GoogleTranslator

# ---------------------------------------------------------------------------
# Paths (relative to this script's location)
# ---------------------------------------------------------------------------

_HERE = Path(__file__).parent
INPUT_DIR  = _HERE.parent / "output"
OUTPUT_DIR = _HERE.parent / "output" / "shp"

DEFAULT_START = 1900
DEFAULT_END   = 2026

# ---------------------------------------------------------------------------
# Helpers: Chinese character detection
# ---------------------------------------------------------------------------

# CJK Unified Ideographs + Extension A
_CJK_RE = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf]")

def has_chinese(text: Optional[str]) -> bool:
    return bool(_CJK_RE.search(text or ""))

# ---------------------------------------------------------------------------
# Helpers: extract fields from a row's tags
# ---------------------------------------------------------------------------

def parse_tags(raw) -> dict:
    """
    Tags arrive from geopandas as either a JSON string or a plain dict,
    depending on how pyogrio serialised the nested GeoJSON property.
    """
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            return {}
    return {}


def get_title_en(tags: dict, name: str) -> str:
    """
    English name:
      1. tags['name:en']   (explicit English tag)
      2. name              (may already be in English or at least Latin-script)
    """
    return (tags.get("name:en") or name or "").strip()


def get_title_zh(tags: dict, name: str) -> Optional[str]:
    """
    Chinese name from tags, or None if not present.
    Also returns name directly if it already contains Chinese characters.
    Priority order: name:zh → name:zh-Hans → name:zh-Hant → name:zh-CN
                    → name:zh-TW → name:zh-SG → name (if CJK)
    """
    for key in ("name:zh", "name:zh-Hans", "name:zh-Hant",
                "name:zh-CN", "name:zh-TW", "name:zh-SG"):
        val = (tags.get(key) or "").strip()
        if val:
            return val
    if has_chinese(name):
        return name.strip()
    return None

# ---------------------------------------------------------------------------
# Translation (batched, with a global cross-year cache)
# ---------------------------------------------------------------------------

_cache: dict[str, str] = {}


def prime_translation_cache(names: list[str]) -> None:
    """
    Collect all unique untranslated English names, translate them in batches,
    and populate _cache.  Call this once before processing any shapefiles so
    every year benefits from the same cache without redundant API calls.
    """
    # Deduplicate while preserving order
    unique = list(dict.fromkeys(n for n in names if n and n not in _cache))
    if not unique:
        print("  All Chinese names found in tags — no translation needed.")
        return

    print(f"\nTranslating {len(unique)} unique name(s) to Chinese "
          f"(Google Translate, free tier)...")

    translator = GoogleTranslator(source="auto", target="zh-CN")

    # deep-translator recommends batches ≤50 to stay within the free-tier
    # character limit (~5 000 chars per request).
    BATCH = 50
    for i in range(0, len(unique), BATCH):
        chunk = unique[i : i + BATCH]
        try:
            results = translator.translate_batch(chunk)
            for src, tgt in zip(chunk, results):
                _cache[src] = tgt or src
            time.sleep(0.5)          # polite delay between requests
        except Exception as exc:
            print(f"  Batch translation failed ({exc}); retrying one-by-one …")
            for src in chunk:
                try:
                    _cache[src] = translator.translate(src) or src
                    time.sleep(0.2)
                except Exception as e2:
                    print(f"  Could not translate '{src}': {e2}")
                    _cache[src] = src     # keep English as fallback

    print("  Translation complete.")

# ---------------------------------------------------------------------------
# Per-year shapefile generation
# ---------------------------------------------------------------------------

def process_year(year: int) -> bool:
    src     = INPUT_DIR / f"countries_{year}.geojson"
    dst_dir = OUTPUT_DIR / str(year)
    dst     = dst_dir / f"countries_{year}.shp"

    if not src.exists():
        print(f"[{year}] {src.name} not found, skipping.")
        return False

    dst_dir.mkdir(parents=True, exist_ok=True)

    gdf = gpd.read_file(src)

    # -- parse tags column --------------------------------------------------
    tags_series = (
        gdf["tags"].apply(parse_tags) if "tags" in gdf.columns
        else pd.Series([{}] * len(gdf))
    )

    # -- title_en -----------------------------------------------------------
    gdf["title_en"] = [
        get_title_en(tags, str(row.get("name") or ""))
        for tags, (_, row) in zip(tags_series, gdf.iterrows())
    ]

    # -- title (Chinese) ----------------------------------------------------
    # Use a pre-populated tag value when available; otherwise look up _cache.
    titles = []
    for tags, (_, row) in zip(tags_series, gdf.iterrows()):
        zh = get_title_zh(tags, str(row.get("name") or ""))
        if zh:
            titles.append(zh)
        else:
            en = row["title_en"]
            titles.append(_cache.get(en, en))   # fallback: English name
    gdf["title"] = titles

    # -- oid ----------------------------------------------------------------
    gdf = gdf.reset_index(drop=True)
    gdf["oid"] = gdf.index + 1

    # -- write shapefile (UTF-8 for Chinese characters) ---------------------
    out = gdf[["oid", "title", "title_en", "geometry"]].copy()
    out.to_file(dst, driver="ESRI Shapefile", encoding="utf-8")

    print(f"[{year}] {len(out):>3} features → {dst.relative_to(_HERE.parent)}")
    return True

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert OHM country GeoJSON files to shapefiles "
                    "with Chinese (title) and English (title_en) name fields."
    )
    parser.add_argument("--start", type=int, default=DEFAULT_START,
                        metavar="YEAR", help="First year to process (default: 1900)")
    parser.add_argument("--end",   type=int, default=DEFAULT_END,
                        metavar="YEAR", help="Last year to process  (default: 2026)")
    args = parser.parse_args()

    if args.start > args.end:
        print(f"Error: --start ({args.start}) must be <= --end ({args.end})")
        raise SystemExit(1)

    years = list(range(args.start, args.end + 1))

    # -----------------------------------------------------------------------
    # Phase 1 — scan every GeoJSON to find names that need translation
    # -----------------------------------------------------------------------
    print(f"Phase 1: scanning {len(years)} GeoJSON file(s) for "
          f"names without a Chinese tag …")

    needs_translation: list[str] = []
    for year in years:
        src = INPUT_DIR / f"countries_{year}.geojson"
        if not src.exists():
            continue
        gdf = gpd.read_file(src)
        for _, row in gdf.iterrows():
            tags = parse_tags(row.get("tags"))
            if not get_title_zh(tags, str(row.get("name") or "")):
                en = get_title_en(tags, str(row.get("name") or ""))
                if en:
                    needs_translation.append(en)

    # -----------------------------------------------------------------------
    # Phase 2 — batch-translate all missing names (one API round-trip set)
    # -----------------------------------------------------------------------
    print(f"Phase 2: translating …")
    prime_translation_cache(needs_translation)

    # -----------------------------------------------------------------------
    # Phase 3 — write one shapefile per year
    # -----------------------------------------------------------------------
    print(f"\nPhase 3: writing shapefiles …\n")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    written = sum(process_year(y) for y in years)
    print(f"\nDone — {written}/{len(years)} shapefile(s) written to {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
