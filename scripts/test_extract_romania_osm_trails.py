#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from extract_romania_osm_trails import (  # noqa: E402
    build_trail_record,
    detect_water_gorge,
    find_nearest_rail_stop,
    is_valid_passenger_rail_stop,
    normalize_station_name,
)
from import_trails_pocketbase import build_trail_multipart_fields  # noqa: E402


class TestRomaniaRailAndGorgeExtraction(unittest.TestCase):
    def test_passenger_rail_stop_filtering(self) -> None:
        self.assertTrue(is_valid_passenger_rail_stop({"railway": "station", "name": "Gara Bușteni"}))
        self.assertTrue(is_valid_passenger_rail_stop({"railway": "halt", "name": "Halta Timișu de Sus"}))
        self.assertFalse(is_valid_passenger_rail_stop({"railway": "station", "station": "subway", "name": "Piața Unirii"}))
        self.assertFalse(is_valid_passenger_rail_stop({"railway": "station", "subway": "yes", "name": "Eroilor"}))
        self.assertFalse(is_valid_passenger_rail_stop({"railway": "station", "usage": "industrial", "name": "Triaj"}))
        self.assertFalse(is_valid_passenger_rail_stop({"railway": "station", "disused:railway": "station", "name": "Veche"}))
        self.assertFalse(is_valid_passenger_rail_stop({"railway": "abandoned", "name": "Cale Ferată Veche"}))
        self.assertEqual(normalize_station_name("Gara CFR Sinaia"), "Sinaia")
        self.assertEqual(normalize_station_name("Halta Timișu de Sus"), "Timișu de Sus")

    def test_nearest_rail_stop_matches_trailhead_within_2km(self) -> None:
        stops = [
            {"name": "Bușteni", "lat": 45.4119, "lon": 25.5378},
            {"name": "Brașov", "lat": 45.6606, "lon": 25.6136},
        ]
        # Jepii Mici trailhead ~450m from Gara Bușteni
        match = find_nearest_rail_stop([(25.5325, 45.4130), (25.4710, 45.4080)], stops, max_distance_m=2000.0)
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match["name"], "Bușteni")
        self.assertLess(match["distance_m"], 700.0)

        # Remote Retezat trailhead >20km from stations
        far = find_nearest_rail_stop([(22.8750, 45.3670), (22.8900, 45.3500)], stops, max_distance_m=2000.0)
        self.assertIsNone(far)

    def test_water_gorge_detection_and_build_trail_record(self) -> None:
        self.assertTrue(detect_water_gorge("Traseu Cheile Nerei – La Tunele", {}, [(21.78, 44.89)], []))
        self.assertTrue(
            detect_water_gorge(
                "Poteca Stâncoasă",
                {},
                [(23.6900, 46.5600), (23.6905, 46.5604), (23.6910, 46.5608)],
                [(23.6901, 46.5601), (23.6909, 46.5607)],
            )
        )
        self.assertFalse(detect_water_gorge("Vârful Omu pe Culmea Bucșoiu", {}, [(25.45, 45.44)], []))

        dem = MagicMock()
        dem.sample.return_value = 920.0
        ways = {
            101: [(25.5350, 45.4120), (25.5280, 45.4125), (25.5200, 45.4130)],
        }
        rel = {
            "id": 99901,
            "tags": {
                "type": "route",
                "route": "hiking",
                "name": "Bușteni – Cascada Urlătoarea",
                "osmc:symbol": "red:white:red_dot",
            },
            "way_ids": [101],
        }
        stops = [{"name": "Gara Bușteni", "lat": 45.4119, "lon": 25.5378}]
        res = build_trail_record(rel, ways, dem, rail_stops=stops, gorge_pts=[])
        self.assertIsNotNone(res)
        assert res is not None
        rec, _ = res
        self.assertTrue(rec["train_accessible"])
        self.assertEqual(rec["rail_station_name"], "Bușteni")
        self.assertGreater(rec["rail_station_distance_m"], 0)
        self.assertAlmostEqual(rec["rail_station_lat"], 45.4119, places=4)
        self.assertAlmostEqual(rec["rail_station_lon"], 25.5378, places=4)
        self.assertFalse(rec["is_water_gorge"])
        self.assertIn("Cu trenul", rec["tags"])
        self.assertIn("Gara Bușteni", rec["description"])

        # Verify PocketBase importer field mapping preserves rail & gorge attributes
        pb_fields = dict(
            build_trail_multipart_fields(
                rec,
                actor_id="actor123",
                cat_id="cat_hike",
                tag_map={"România": "t1", "Cu trenul": "t2"},
                existing_record_id=None,
            )
        )
        self.assertEqual(pb_fields["train_accessible"], "true")
        self.assertEqual(pb_fields["rail_station_name"], "Bușteni")
        self.assertEqual(pb_fields["rail_station_distance_m"], str(rec["rail_station_distance_m"]))
        self.assertEqual(pb_fields["rail_station_lat"], "45.4119")
        self.assertEqual(pb_fields["rail_station_lon"], "25.5378")
        self.assertEqual(pb_fields["is_water_gorge"], "false")


if __name__ == "__main__":
    unittest.main()
