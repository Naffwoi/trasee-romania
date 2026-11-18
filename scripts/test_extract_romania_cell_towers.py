#!/usr/bin/env python3
from __future__ import annotations

import json
import math
from pathlib import Path
import sys
import unittest

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from extract_romania_cell_towers import (  # noqa: E402
    CARRIER_DIGI,
    CARRIER_GENERIC,
    CARRIER_ORANGE,
    CARRIER_TELEKOM,
    CARRIER_VODAFONE,
    SOURCE_OCID,
    SOURCE_OSM,
    classify_osm_landmark,
    classify_osm_telecom_feature,
    deduplicate_towers,
    haversine_meters,
    parse_height_meters,
)

WEB_EMERGENCY_JSON = REPO_ROOT / "web" / "static" / "data" / "romania_emergency_112.json"
APP_EMERGENCY_JSON = REPO_ROOT / "app" / "assets" / "data" / "romania_emergency_112.json"


class TestExtractRomaniaCellTowers(unittest.TestCase):
    def test_parse_height_meters_handles_units_and_bounds(self) -> None:
        self.assertEqual(parse_height_meters("35 m", default_m=22), 35)
        self.assertEqual(parse_height_meters("42.6m", default_m=22), 43)
        self.assertEqual(parse_height_meters("invalid", default_m=28), 28)
        self.assertEqual(parse_height_meters("400", default_m=22), 120)
        self.assertEqual(parse_height_meters("2", default_m=22), 8)

    def test_classify_osm_telecom_accepts_mobile_masts_and_rejects_disused_or_lighting(self) -> None:
        res = classify_osm_telecom_feature({
            "man_made": "communications_tower",
            "operator": "Orange România; Vodafone",
            "height": "48 m",
        })
        self.assertIsNotNone(res)
        assert res is not None
        h, mask = res
        self.assertEqual(h, 48)
        self.assertEqual(mask, CARRIER_ORANGE | CARRIER_VODAFONE)

        mast = classify_osm_telecom_feature({
            "man_made": "mast",
            "tower:type": "communication",
            "operator": "RCS & RDS Digi Mobil",
        })
        self.assertEqual(mast, (22, CARRIER_DIGI))

        telekom = classify_osm_telecom_feature({
            "communication:mobile_phone": "yes",
            "operator": "Telekom Romania Mobile",
        })
        self.assertEqual(telekom, (15, CARRIER_TELEKOM))

        generic = classify_osm_telecom_feature({
            "man_made": "tower",
            "tower:type": "communication",
        })
        self.assertEqual(generic, (28, CARRIER_GENERIC))

        self.assertIsNone(classify_osm_telecom_feature({
            "man_made": "mast",
            "tower:type": "lighting",
        }))
        self.assertIsNone(classify_osm_telecom_feature({
            "disused:man_made": "mast",
            "communication:mobile_phone": "yes",
        }))
        self.assertIsNone(classify_osm_telecom_feature({
            "man_made": "tower",
            "tower:type": "communication",
            "communication:mobile_phone": "no",
        }))

    def test_classify_osm_landmark_extracts_named_peaks_and_saddles(self) -> None:
        self.assertEqual(
            classify_osm_landmark({"natural": "peak", "name": "Vârful Omu", "ele": "2505"}),
            (1, "Vârful Omu", 2505),
        )
        self.assertEqual(
            classify_osm_landmark({"natural": "saddle", "name:ro": "Șaua Caprei", "ele": "2315 m"}),
            (2, "Șaua Caprei", 2315),
        )
        self.assertIsNone(classify_osm_landmark({"natural": "peak"}))

    def test_deduplicate_towers_prefers_osm_over_opencellid_within_350m(self) -> None:
        raw = [
            # (lat, lon, ele_m, height_m, carrier_mask, source_flag)
            (45.44180, 25.48910, 2495, 80, CARRIER_ORANGE, SOURCE_OSM),
            (45.44185, 25.48915, 2495, 22, CARRIER_VODAFONE, SOURCE_OSM),  # <15m away -> merge mask & max height
            (45.44300, 25.49000, 2480, 22, CARRIER_DIGI, SOURCE_OCID),     # ~150m from OSM -> absorbed
        ]
        deduped = deduplicate_towers(raw)
        self.assertEqual(len(deduped), 1)
        lat_e5, lon_e5, ele_m, h_m, mask, src = deduped[0]
        self.assertEqual((lat_e5, lon_e5, ele_m, h_m, src), (4544180, 2548910, 2495, 80, SOURCE_OSM))
        self.assertEqual(mask, CARRIER_ORANGE | CARRIER_VODAFONE | CARRIER_DIGI)

    def test_generated_emergency_112_bundles_match_and_cover_major_carpathian_relays(self) -> None:
        if not WEB_EMERGENCY_JSON.exists() or not APP_EMERGENCY_JSON.exists():
            self.skipTest("romania_emergency_112.json bundles not yet generated")
        web_bytes = WEB_EMERGENCY_JSON.read_bytes()
        app_bytes = APP_EMERGENCY_JSON.read_bytes()
        self.assertEqual(web_bytes, app_bytes, "web and app romania_emergency_112.json must be byte-identical")

        data = json.loads(web_bytes.decode("utf-8"))
        self.assertEqual(data["v"], 1)
        self.assertGreaterEqual(len(data["towers"]), 25)
        self.assertGreaterEqual(len(data["peaks"]), 25)

        for row in data["towers"]:
            self.assertEqual(len(row), 6)
            lat_e5, lon_e5, ele_m, h_m, mask, src = row
            self.assertTrue(4340000 <= lat_e5 <= 4850000)
            self.assertTrue(2000000 <= lon_e5 <= 3000000)
            self.assertTrue(-50 <= ele_m <= 2600)
            self.assertTrue(8 <= h_m <= 120)
            self.assertGreater(mask, 0)
            self.assertIn(src, (SOURCE_OSM, SOURCE_OCID))

        # Verify key Carpathian relays exist within 3 km of summit coordinates
        expected_relays = [
            ("Coștila", 45.42339, 25.48811),
            ("Cozia", 45.32100, 24.33700),
            ("Parâng", 45.38450, 23.47152),
            ("Rarău", 47.45194, 25.57444),
            ("Semenic", 45.18056, 22.05611),
            ("Vlădeasa", 46.75917, 22.79417),
            ("Postăvaru", 45.56861, 25.56750),
            ("Toaca/Ceahlău", 46.97722, 25.94889),
            ("Babele", 45.40812, 25.47450),
            ("Bâlea", 45.60389, 24.61639),
            ("Păltiniș", 45.65290, 23.93311),
            ("Rânca", 45.29462, 23.68387),
            ("Straja", 45.32123, 23.23679),
            ("Gutâi/Igniș", 47.73583, 23.68056),
            ("Heniu", 47.27389, 24.73528),
            ("Harghita-Mădăraș", 46.45611, 25.57667),
        ]
        for label, rlat, rlon in expected_relays:
            min_d = min(
                haversine_meters(rlat, rlon, t[0] / 1e5, t[1] / 1e5)
                for t in data["towers"]
            )
            self.assertLessEqual(min_d, 3_000.0, f"Missing Carpathian telecom relay near {label} (min_d={min_d:.0f}m)")


if __name__ == "__main__":
    unittest.main()
