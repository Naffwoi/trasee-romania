#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from extract_romania_peaks import (  # noqa: E402
    RawPeakNode,
    build_columnar_catalog,
    curated_carpathian_seed_peaks,
    parse_osm_elevation_meters,
)

WEB_PEAKS_JSON = REPO_ROOT / "web" / "static" / "data" / "romania_peaks_v1.json"
APP_PEAKS_JSON = REPO_ROOT / "app" / "assets" / "data" / "romania_peaks_v1.json"


class ExtractRomaniaPeaksTest(unittest.TestCase):
    def test_parse_osm_elevation_handles_units_commas_and_invalid_strings(self) -> None:
        self.assertAlmostEqual(parse_osm_elevation_meters("2544") or 0.0, 2544.0)
        self.assertAlmostEqual(parse_osm_elevation_meters("2,505.4 m") or 0.0, 2505.4)
        self.assertAlmostEqual(parse_osm_elevation_meters("1 849 m n.m.") or 0.0, 1849.0)
        self.assertIsNone(parse_osm_elevation_meters(""))
        self.assertIsNone(parse_osm_elevation_meters("unknown"))
        self.assertIsNone(parse_osm_elevation_meters("-500"))
        self.assertIsNone(parse_osm_elevation_meters("9200"))

    def test_build_columnar_catalog_filters_low_hills_deduplicates_and_computes_prominence(self) -> None:
        raw = [
            RawPeakNode(osm_id=1, name="Vârful Moldoveanu", lat=45.5995, lon=24.7362, ele=2544.0, kind="peak"),
            RawPeakNode(osm_id=2, name="Vârful Viștea Mare", lat=45.6029, lon=24.7354, ele=2527.0, kind="peak"),
            RawPeakNode(osm_id=3, name="Dealul Mic", lat=44.4300, lon=26.1000, ele=120.0, kind="peak"),
            RawPeakNode(osm_id=4, name="Șaua Caprei", lat=45.6008, lon=24.6285, ele=2315.0, kind="pass"),
        ]
        catalog = build_columnar_catalog(raw, min_ele_m=400.0)
        self.assertEqual(catalog["version"], 1)
        self.assertEqual(catalog["count"], 3)
        self.assertEqual(catalog["names"][0], "Vârful Moldoveanu")
        self.assertEqual(catalog["eles"][0], 2544)
        # Moldoveanu is highest in catalog -> high prominence proxy; Viștea Mare (~380 m away) gets lower local dominance
        self.assertGreater(catalog["prominences"][0], catalog["prominences"][1])
        self.assertIn("pass", catalog["kinds"])

    def test_curated_seed_contains_major_romanian_summits_and_serializes_compactly(self) -> None:
        seed = curated_carpathian_seed_peaks()
        catalog = build_columnar_catalog(seed, min_ele_m=400.0)
        names = set(catalog["names"])
        self.assertIn("Vârful Omu", names)
        self.assertIn("Vârful Moldoveanu", names)
        self.assertIn("Vârful Negoiu", names)
        self.assertIn("Vârful Parângul Mare", names)
        self.assertIn("Vârful Pietrosul Rodnei", names)
        encoded = json.dumps(catalog, ensure_ascii=False, separators=(",", ":"))
        self.assertLess(len(encoded.encode("utf-8")), 250_000)

    def test_generated_romania_peaks_v1_bundles_match_and_satisfy_columnar_schema(self) -> None:
        if not WEB_PEAKS_JSON.exists() or not APP_PEAKS_JSON.exists():
            self.skipTest("romania_peaks_v1.json bundles not yet generated")
        web_bytes = WEB_PEAKS_JSON.read_bytes()
        app_bytes = APP_PEAKS_JSON.read_bytes()
        self.assertEqual(web_bytes, app_bytes, "web and app romania_peaks_v1.json must be byte-identical")

        cat = json.loads(web_bytes.decode("utf-8"))
        self.assertEqual(cat["version"], 1)
        n = cat["count"]
        self.assertGreaterEqual(n, 40)
        for col in ("ids", "names", "lats", "lons", "eles", "prominences", "kinds"):
            self.assertEqual(len(cat[col]), n, f"Column {col} length mismatch")
        self.assertTrue(all(k in ("peak", "pass") for k in cat["kinds"]))
        self.assertIn("peak", cat["kinds"])
        self.assertIn("pass", cat["kinds"])

        names = set(cat["names"])
        for must_have in (
            "Vârful Moldoveanu",
            "Vârful Negoiu",
            "Vârful Omu",
            "Vârful Parângul Mare",
            "Vârful Pietrosul Rodnei",
        ):
            self.assertIn(must_have, names)


if __name__ == "__main__":
    unittest.main()
