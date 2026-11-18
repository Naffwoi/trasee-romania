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

from build_salvamont_ro import (  # noqa: E402
    E164_RO_RE,
    build_dataset,
    classify_osm_element,
    deduplicate_points,
    haversine_meters,
    normalize_ro_phone,
)

CURATED_PATH = SCRIPTS_DIR / "salvamont_curated_directory.json"
WEB_SALVAMONT_JSON = REPO_ROOT / "web" / "src" / "lib" / "data" / "salvamont_ro.json"
APP_SALVAMONT_JSON = REPO_ROOT / "app" / "assets" / "data" / "salvamont_ro.json"


class BuildSalvamontRoTests(unittest.TestCase):
    def test_normalize_ro_phone_handles_valid_and_rejects_broken_osm_values(self) -> None:
        # Valid national & international formats
        self.assertEqual(normalize_ro_phone("0269 216 477"), "+40269216477")
        self.assertEqual(normalize_ro_phone("+40 728 770 627"), "+40728770627")
        self.assertEqual(normalize_ro_phone("0040-371-493-333"), "+40371493333")
        self.assertEqual(normalize_ro_phone("0741074884; 0SALVAMONT"), "+40741074884")
        # Vanity national dispatch (e.g. Arad 0SALVAMONT)
        self.assertEqual(normalize_ro_phone("0SALVAMONT"), "+40725826668")
        self.assertEqual(normalize_ro_phone("0-SALVAMONT (0725826668)"), "+40725826668")
        # Broken 9-digit OSM typo on way/1242742629 (Salvamont Voineasa) MUST be rejected!
        self.assertIsNone(normalize_ro_phone("072582668"))
        # Generic 112 is NOT a local Salvamont service phone
        self.assertIsNone(normalize_ro_phone("112"))
        self.assertIsNone(normalize_ro_phone(""))
        self.assertIsNone(normalize_ro_phone(None))

    def test_classify_osm_element_excludes_guideposts_routes_and_streets(self) -> None:
        self.assertIsNone(
            classify_osm_element({"tourism": "information", "information": "guidepost", "operator": "Salvamont"})
        )
        self.assertIsNone(
            classify_osm_element({"type": "route", "route": "hiking", "operator": "Salvamont Sibiu"})
        )
        self.assertIsNone(
            classify_osm_element({"highway": "residential", "name": "Strada Salvamont"})
        )
        self.assertEqual(
            classify_osm_element({"emergency": "mountain_rescue", "name": "Baza Salvamont Cota 1400"}),
            ("base", "24_7"),
        )
        self.assertEqual(
            classify_osm_element(
                {"amenity": "shelter", "shelter_type": "basic_hut", "name": "Refugiul Salvamont Mălăiești"}
            ),
            ("refuge", "shelter_unmanned"),
        )

    def test_deduplicate_points_collapses_glavoi_four_overlapping_osm_features(self) -> None:
        raw_glavoi = [
            {
                "osm_type": "node",
                "osm_id": "11292538119",
                "lat": 46.57774,
                "lon": 22.70443,
                "name": "Salvamont Glăvoi",
                "kind": "base",
                "permanence": "24_7",
                "ele": 1085,
                "osm_phone": None,
            },
            {
                "osm_type": "way",
                "osm_id": "301242103",
                "lat": 46.57779,
                "lon": 22.70443,
                "name": "Salvamont Glăvoi",
                "kind": "base",
                "permanence": "24_7",
                "ele": None,
                "osm_phone": None,
            },
            {
                "osm_type": "way",
                "osm_id": "301242104",
                "lat": 46.57773,
                "lon": 22.70451,
                "name": "Refugiul Salvamont - Salvaspeo Glăvoi",
                "kind": "base",
                "permanence": "24_7",
                "ele": None,
                "osm_phone": None,
            },
            {
                "osm_type": "way",
                "osm_id": "1163803257",
                "lat": 46.57784,
                "lon": 22.70457,
                "name": "",
                "kind": "base",
                "permanence": "24_7",
                "ele": None,
                "osm_phone": None,
            },
        ]
        merged = deduplicate_points(raw_glavoi, merge_radius_m=60.0)
        self.assertEqual(len(merged), 1)
        self.assertEqual(len(merged[0]["osmIds"]), 4)
        self.assertEqual(merged[0]["ele"], 1085)

    def test_build_dataset_validates_all_41_services_and_attaches_valid_e164_to_every_point(self) -> None:
        sample_osm = [
            {
                "type": "way",
                "id": 1242742629,
                "lat": 45.40081,
                "lon": 23.69584,
                "tags": {
                    "emergency": "mountain_rescue",
                    "name": "Salvamont Voineasa",
                    "phone": "072582668",  # Real broken 9-digit OSM value
                },
            },
            {
                "type": "node",
                "id": 888888,
                "lat": 46.46419,
                "lon": 22.26335,
                "tags": {
                    "emergency": "mountain_rescue",
                    "name": "Salvamont Arad Moneasa",
                    "phone": "0SALVAMONT",  # Real Arad vanity OSM value
                },
            },
            {
                "type": "tourism_guidepost_noise",
                "id": 999999,
                "lat": 45.41,
                "lon": 25.45,
                "tags": {"tourism": "information", "information": "guidepost", "operator": "Salvamont"},
            },
        ]
        dataset = build_dataset(CURATED_PATH, sample_osm, dem_dir=None)
        self.assertEqual(dataset["version"], 1)
        self.assertEqual(dataset["emergency112"], "112")
        self.assertEqual(dataset["nationalDispatchPhone"], "+40725826668")

        ansmr_services = [
            svc for svc in dataset["services"].values() if svc["level"] in ("county", "local")
        ]
        self.assertEqual(len(ansmr_services), 41)
        self.assertGreaterEqual(len(dataset["services"]), 42)
        self.assertGreaterEqual(len(dataset["points"]), 55)

        for sid, svc in dataset["services"].items():
            self.assertRegex(svc["primaryPhone"], E164_RO_RE, f"Invalid primaryPhone on {sid}")
            for sec in svc["secondaryPhones"]:
                self.assertRegex(sec, E164_RO_RE, f"Invalid secondaryPhone on {sid}")

        voineasa_pts = [p for p in dataset["points"] if "Voineasa" in p["name"]]
        self.assertTrue(len(voineasa_pts) >= 1)
        for pt in dataset["points"]:
            self.assertIn(pt["serviceId"], dataset["services"])
            if pt.get("directBasePhone"):
                self.assertRegex(pt["directBasePhone"], E164_RO_RE)
                self.assertNotEqual(pt["directBasePhone"], "+4072582668")

    def test_generated_web_and_app_bundles_match_and_satisfy_resolver_invariants(self) -> None:
        if not WEB_SALVAMONT_JSON.exists() or not APP_SALVAMONT_JSON.exists():
            self.skipTest("Generated salvamont_ro.json bundles not yet built")
        web_bytes = WEB_SALVAMONT_JSON.read_bytes()
        app_bytes = APP_SALVAMONT_JSON.read_bytes()
        self.assertEqual(web_bytes, app_bytes, "web and app salvamont_ro.json must be byte-identical")

        ds = json.loads(web_bytes.decode("utf-8"))
        self.assertGreaterEqual(len(ds["points"]), 55)

        # Verify Făgăraș Șaua Caprei (45.6005, 24.6285) nearest refuge contains "Fereastra Zmeilor"
        refuges = [p for p in ds["points"] if p["kind"] == "refuge"]
        nearest_refuge = min(
            refuges, key=lambda p: haversine_meters(45.6005, 24.6285, p["lat"], p["lon"])
        )
        self.assertIn("Fereastra Zmeilor", nearest_refuge["name"])

        # Verify Munții Măcin (45.2060, 28.1950) is > 35 km from operational Carpathian bases
        operational = [p for p in ds["points"] if p["kind"] != "refuge"]
        min_macin_m = min(haversine_meters(45.2060, 28.1950, p["lat"], p["lon"]) for p in operational)
        self.assertGreater(min_macin_m, 35_000.0)

        # Verify Păltiniș (45.6530, 23.9332) resolves cleanly to ro-sb-spj without false border split
        paltinis_sorted = sorted(
            operational, key=lambda p: haversine_meters(45.6530, 23.9332, p["lat"], p["lon"])
        )
        self.assertEqual(paltinis_sorted[0]["serviceId"], "ro-sb-spj")
        d1 = haversine_meters(45.6530, 23.9332, paltinis_sorted[0]["lat"], paltinis_sorted[0]["lon"])
        self.assertLess(d1, 150.0)
        for cand in paltinis_sorted[1:]:
            if cand["serviceId"] != "ro-sb-spj":
                d_other = haversine_meters(45.6530, 23.9332, cand["lat"], cand["lon"])
                self.assertGreater(d_other - d1, 3_500.0)
                break


if __name__ == "__main__":
    unittest.main()
