#!/usr/bin/env python3
"""Extract Romanian telecom cell towers/masts and named mountain landmarks into a compact offline index.

Supports:
1. Full OpenStreetMap PBF scan (`--pbf romania-latest.osm.pbf`) enriched with 1-arcsec SRTM elevation (`DemTileCache`).
2. Live online QLever / Overpass Romania extraction (`--online`) merged with verified Carpathian summit/ridge relays.
3. Optional OpenCelliD Romania (`MCC=226`) CSV.gz merge (`--opencellid-csv 226.csv.gz`) with explicit CC BY-SA 4.0 attribution.
4. Deterministic curated Carpathian seed mode (`--seed-only`) for CI / offline development environments without a local PBF.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import gzip
import json
import math
from pathlib import Path
import re
import ssl
import sys
from typing import Any, Iterable
import urllib.parse
import urllib.request

from dem_elevation import DemTileCache


def _make_ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        for ca_path in ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"):
            if Path(ca_path).exists():
                return ssl.create_default_context(cafile=ca_path)
        return ssl.create_default_context()


_SSL_CTX = _make_ssl_context()

RO_LAT_MIN, RO_LAT_MAX = 43.4, 48.5
RO_LON_MIN, RO_LON_MAX = 20.0, 30.0

CARRIER_ORANGE = 1
CARRIER_VODAFONE = 2
CARRIER_DIGI = 4
CARRIER_TELEKOM = 8
CARRIER_GENERIC = 16

SOURCE_OSM = 1
SOURCE_OCID = 2

EXCLUDED_TOWER_TYPES = {
    "lighting",
    "cooling",
    "observation",
    "bell_tower",
    "watchtower",
    "minaret",
    "pagoda",
    "climbing",
    "hose",
    "radar",
}

LIFECYCLE_PREFIXES = ("disused:", "abandoned:", "demolished:", "razed:", "construction:", "proposed:")

CURATED_CARPATHIAN_SEED: dict[str, list[list[Any]]] = {
    "towers": [
        # [latE5, lonE5, groundEleM, mastHeightM, carrierMask, sourceFlag]
        [4542339, 2548811, 2498, 80, 15, 1],  # Releul Coștila (Bucegi)
        [4536744, 2553912, 1400, 35, 15, 1],  # Cota 1400 Sinaia (Bucegi)
        [4535963, 2549507, 1995, 30, 15, 1],  # Cota 2000 Miorița (Bucegi)
        [4540812, 2547450, 2216, 25, 15, 1],  # Babele (Platoul Bucegi)
        [4556861, 2556750, 1799, 45, 15, 1],  # Postăvaru (Brașov)
        [4548987, 2594494, 1280, 35, 15, 1],  # Muntele Roșu / Cheia (Ciucaș)
        [4560389, 2461639, 2055, 30, 15, 1],  # Bâlea Lac / Paltinu (Făgăraș)
        [4565290, 2393311, 1445, 40, 15, 1],  # Păltiniș / Oncești (Cindrel)
        [4532100, 2433700, 1668, 60, 15, 1],  # Releul Cozia (Vârful Cozia)
        [4529462, 2368387, 1620, 40, 15, 1],  # Rânca / Corneșu (Parâng - Transalpina)
        [4538450, 2347152, 1695, 45, 15, 1],  # Parâng / Cabana Rusu - Parângul Mic
        [4532123, 2323679, 1445, 35, 15, 1],  # Straja (Vâlcan)
        [4535333, 2289222, 1680, 28, 7, 1],   # Râușor (Retezat)
        [4536520, 2246940, 1530, 40, 15, 1],  # Muntele Mic (Țarcu)
        [4518056, 2205611, 1447, 55, 15, 1],  # Releul Semenic
        [4644097, 2268858, 1849, 55, 15, 1],  # Releul Bihor / Curcubăta Mare
        [4675917, 2279417, 1836, 45, 15, 1],  # Releul Vlădeasa
        [4653706, 2331203, 1385, 35, 15, 1],  # Muntele Băișorii / Muntele Mare
        [4773583, 2368056, 1307, 75, 15, 1],  # Releul Igniș / Gutâi (Maramureș)
        [4767450, 2377610, 1240, 45, 15, 1],  # Mogoșa (Gutâi)
        [4760531, 2484375, 1416, 35, 15, 1],  # Pasul Prislop / Borșa (Rodnei)
        [4727389, 2473528, 1611, 65, 15, 1],  # Releul Heniu Mare (Bârgău)
        [4745194, 2557444, 1651, 60, 15, 1],  # Releul Rarău
        [4697722, 2594889, 1897, 45, 15, 1],  # Toaca / Ceahlău
        [4665250, 2529306, 1287, 45, 15, 1],  # Pasul Bucin (Gurghiu)
        [4645611, 2557667, 1801, 40, 15, 1],  # Harghita-Mădăraș
        [4638539, 2563529, 1350, 45, 15, 1],  # Harghita-Băi
        [4594670, 2657890, 620, 35, 15, 1],   # Lepșa (Munții Vrancei)
        [4542390, 2629610, 620, 35, 15, 1],   # Nehoiu / Siriu (Munții Buzăului)
    ],
    "peaks": [
        # [latE5, lonE5, eleM, kind (1=peak, 2=saddle, 3=hut), name]
        [4544583, 2545639, 2505, 1, "Vf. Omu"],
        [4542339, 2548811, 2498, 1, "Vf. Coștila"],
        [4541472, 2549694, 2284, 1, "Crucea Caraiman"],
        [4540812, 2547450, 2216, 3, "Cabana Babele"],
        [4559944, 2473611, 2544, 1, "Vf. Moldoveanu"],
        [4558583, 2456083, 2535, 1, "Vf. Negoiu"],
        [4560050, 2462850, 2315, 2, "Șaua Caprei"],
        [4554028, 2522250, 2238, 1, "Vf. La Om (Piatra Craiului)"],
        [4536611, 2287694, 2482, 1, "Vf. Retezat"],
        [4535944, 2289028, 2509, 1, "Vf. Peleaga"],
        [4534000, 2353917, 2519, 1, "Vf. Parângul Mare"],
        [4532100, 2433700, 1668, 1, "Vf. Cozia"],
        [4556861, 2556750, 1799, 1, "Vf. Postăvaru"],
        [4552108, 2592703, 1954, 1, "Vf. Ciucaș"],
        [4697750, 2595000, 1904, 1, "Vf. Toaca (Ceahlău)"],
        [4745194, 2557444, 1651, 1, "Vf. Rarău"],
        [4759556, 2463472, 2303, 1, "Vf. Pietrosul Rodnei"],
        [4711972, 2518250, 2100, 1, "Vf. Pietrosul Călimanilor"],
        [4727389, 2473528, 1611, 1, "Vf. Heniu Mare"],
        [4773583, 2368056, 1307, 1, "Vf. Igniș"],
        [4645611, 2557667, 1801, 1, "Vf. Harghita-Mădăraș"],
        [4644097, 2268858, 1849, 1, "Vf. Bihorul Mare (Curcubăta Mare)"],
        [4675917, 2279417, 1836, 1, "Vf. Vlădeasa"],
        [4528139, 2253389, 2190, 1, "Vf. Țarcu"],
        [4518056, 2205611, 1447, 1, "Vf. Semenic"],
    ],
}


def haversine_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2.0) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2.0) ** 2
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))


def parse_height_meters(raw: str | None, default_m: int) -> int:
    if not raw:
        return default_m
    m = re.search(r"(-?\d+(?:\.\d+)?)", raw.replace(",", "."))
    if not m:
        return default_m
    val = int(round(float(m.group(1))))
    return max(8, min(120, val))


def parse_elevation_tag(raw: str | None) -> int | None:
    if not raw:
        return None
    m = re.search(r"(-?\d+(?:\.\d+)?)", raw.replace(",", "."))
    if not m:
        return None
    val = int(round(float(m.group(1))))
    return val if -50 <= val <= 3000 else None


def parse_carrier_mask(tags: dict[str, str]) -> int:
    blob = " ".join(tags.get(k, "") for k in ("operator", "brand", "name", "owner")).lower()
    mask = 0
    if "orange" in blob:
        mask |= CARRIER_ORANGE
    if "vodafone" in blob:
        mask |= CARRIER_VODAFONE
    if "digi" in blob or "rcs" in blob or "rds" in blob:
        mask |= CARRIER_DIGI
    if "telekom" in blob or "cosmote" in blob:
        mask |= CARRIER_TELEKOM
    return mask if mask != 0 else CARRIER_GENERIC


def classify_osm_telecom_feature(tags: dict[str, str]) -> tuple[int, int] | None:
    for k in tags:
        kl = k.lower()
        if kl.startswith(LIFECYCLE_PREFIXES) or kl in ("disused", "abandoned", "construction"):
            if tags[k].lower() != "no":
                return None

    if tags.get("communication:mobile_phone", "").strip().lower() == "no":
        return None

    tower_type = tags.get("tower:type", "").strip().lower()
    if tower_type in EXCLUDED_TOWER_TYPES:
        return None

    man_made = tags.get("man_made", "").strip().lower()
    mobile_yes = (
        tags.get("communication:mobile_phone", "").strip().lower() in ("yes", "gsm", "umts", "lte", "5g")
        or tags.get("communication:gsm", "").strip().lower() == "yes"
        or tags.get("communication:umts", "").strip().lower() == "yes"
        or tags.get("communication:lte", "").strip().lower() == "yes"
        or tags.get("communication:nr", "").strip().lower() == "yes"
    )

    matched = False
    default_h = 22
    if man_made == "communications_tower":
        matched = True
        default_h = 35
    elif man_made == "tower" and (tower_type == "communication" or mobile_yes):
        matched = True
        default_h = 28
    elif man_made == "mast" and (tower_type == "communication" or mobile_yes):
        matched = True
        default_h = 22
    elif mobile_yes:
        matched = True
        default_h = 15

    if not matched:
        return None

    height_m = parse_height_meters(tags.get("height") or tags.get("est_height"), default_h)
    return height_m, parse_carrier_mask(tags)


def classify_osm_landmark(tags: dict[str, str]) -> tuple[int, str, int | None] | None:
    name = (tags.get("name:ro") or tags.get("name") or "").strip()
    if not name:
        return None
    if len(name) > 64:
        name = name[:61].rstrip() + "..."

    ele = parse_elevation_tag(tags.get("ele"))
    natural = tags.get("natural", "").strip().lower()
    tourism = tags.get("tourism", "").strip().lower()

    if natural == "peak":
        return 1, name, ele
    if natural == "saddle":
        return 2, name, ele
    if tourism in ("alpine_hut", "wilderness_hut"):
        return 3, name, ele
    return None


def deduplicate_towers(
    raw_towers: Iterable[tuple[float, float, int, int, int, int]],
    osm_merge_m: float = 60.0,
    ocid_merge_m: float = 350.0,
) -> list[list[int]]:
    # Sort OSM physical structures ahead of OpenCelliD estimated centroids
    ordered = sorted(raw_towers, key=lambda item: (item[5], -item[3]))
    kept: list[list[float | int]] = []

    for lat, lon, ele_m, height_m, mask, src in ordered:
        merged = False
        threshold = osm_merge_m if src == SOURCE_OSM else ocid_merge_m
        for existing in kept:
            ex_lat = existing[0] / 1e5
            ex_lon = existing[1] / 1e5
            if abs(lat - ex_lat) > 0.005 or abs(lon - ex_lon) > 0.007:
                continue
            if haversine_meters(lat, lon, ex_lat, ex_lon) <= threshold:
                existing[3] = max(int(existing[3]), height_m)
                existing[4] = int(existing[4]) | mask
                merged = True
                break
        if not merged:
            kept.append([
                int(round(lat * 1e5)),
                int(round(lon * 1e5)),
                int(ele_m),
                int(height_m),
                int(mask),
                int(src),
            ])

    kept.sort(key=lambda r: (r[0], r[1]))
    return [[int(x) for x in row] for row in kept]


def deduplicate_landmarks(rows: Iterable[list[Any]], radius_m: float = 90.0) -> list[list[Any]]:
    ordered = sorted(rows, key=lambda r: (-int(r[2]), int(r[3]), str(r[4])))
    kept: list[list[Any]] = []
    buckets: dict[tuple[int, int], list[list[Any]]] = {}

    for row in ordered:
        lat_e5, lon_e5, ele_m, kind, name = int(row[0]), int(row[1]), int(row[2]), int(row[3]), str(row[4])
        lat = lat_e5 / 1e5
        lon = lon_e5 / 1e5
        bi, bj = int(math.floor(lat * 100)), int(math.floor(lon * 100))
        dup = False
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for ex in buckets.get((bi + di, bj + dj), ()):
                    if int(ex[3]) == kind and haversine_meters(lat, lon, ex[0] / 1e5, ex[1] / 1e5) <= radius_m:
                        dup = True
                        break
                if dup:
                    break
            if dup:
                break
        if not dup:
            clean = [lat_e5, lon_e5, ele_m, kind, name]
            kept.append(clean)
            buckets.setdefault((bi, bj), []).append(clean)

    kept.sort(key=lambda r: (-int(r[2]), str(r[4])))
    return kept


def load_opencellid_romania(csv_gz_path: Path, dem: DemTileCache) -> list[tuple[float, float, int, int, int, int]]:
    mnc_map = {1: CARRIER_VODAFONE, 3: CARRIER_TELEKOM, 5: CARRIER_DIGI, 6: CARRIER_TELEKOM, 10: CARRIER_ORANGE}
    buckets: dict[tuple[int, int, int], list[float]] = {}
    opener = gzip.open if csv_gz_path.suffix == ".gz" else open
    with opener(csv_gz_path, "rt", encoding="utf-8", errors="ignore") as fh:
        reader = csv.reader(fh)
        for row in reader:
            if len(row) < 10 or row[0] == "radio":
                continue
            try:
                mcc = int(row[1])
                if mcc != 226:
                    continue
                radio = row[0].strip().upper()
                if radio not in ("GSM", "UMTS", "LTE", "NR"):
                    continue
                mnc = int(row[2])
                lac = int(row[3])
                lon = float(row[6])
                lat = float(row[7])
                samples = int(row[9])
            except ValueError:
                continue
            if samples < 15 or not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
                continue
            key = (mnc, lac, int(round(lat * 200)) * 100000 + int(round(lon * 200)))
            acc = buckets.get(key)
            if acc is None:
                buckets[key] = [lat * samples, lon * samples, float(samples)]
            else:
                acc[0] += lat * samples
                acc[1] += lon * samples
                acc[2] += samples

    out: list[tuple[float, float, int, int, int, int]] = []
    for (mnc, _, _), (w_lat, w_lon, w_sum) in buckets.items():
        lat = w_lat / w_sum
        lon = w_lon / w_sum
        ele = dem.sample(lat, lon) or 0.0
        if ele < 250.0:
            continue
        out.append((lat, lon, int(round(ele)), 22, mnc_map.get(mnc, CARRIER_GENERIC), SOURCE_OCID))
    return out


def fetch_online_romania_towers_and_landmarks(
    dem: DemTileCache,
) -> tuple[list[tuple[float, float, int, int, int, int]], list[list[Any]]]:
    """Fetch all Romania OSM telecom masts/towers and mountain landmarks via QLever SPARQL (or Overpass)."""
    endpoint = "https://qlever.dev/api/osm-planet"

    def sparql_json(query: str) -> dict[str, Any]:
        req = urllib.request.Request(
            endpoint,
            data=urllib.parse.urlencode({"query": query}).encode("utf-8"),
            headers={
                "Accept": "application/sparql-results+json",
                "User-Agent": "WandererRO-Emergency112Builder/1.0",
            },
        )
        with urllib.request.urlopen(req, timeout=45, context=_SSL_CTX) as resp:
            return json.loads(resp.read().decode("utf-8"))

    # 1. Telecom masts & towers in Romania
    tower_uris_res = sparql_json(
        "PREFIX osmkey: <https://www.openstreetmap.org/wiki/Key:>\n"
        "PREFIX osmrel: <https://www.openstreetmap.org/relation/>\n"
        "PREFIX ogc: <http://www.opengis.net/rdf#>\n"
        "SELECT DISTINCT ?item WHERE {\n"
        '  { ?item osmkey:man_made "communications_tower" . ?item ogc:sfIntersects osmrel:90689 . }\n'
        '  UNION { ?item osmkey:man_made "mast" . ?item osmkey:tower:type "communication" . ?item ogc:sfIntersects osmrel:90689 . }\n'
        '  UNION { ?item osmkey:man_made "tower" . ?item osmkey:tower:type "communication" . ?item ogc:sfIntersects osmrel:90689 . }\n'
        "  UNION { ?item osmkey:communication:mobile_phone ?mp . ?item ogc:sfIntersects osmrel:90689 . }\n"
        "  UNION { ?item osmkey:communication:gsm ?gsm . ?item ogc:sfIntersects osmrel:90689 . }\n"
        "  UNION { ?item osmkey:communication:lte ?lte . ?item ogc:sfIntersects osmrel:90689 . }\n"
        "}"
    )
    tower_uris = sorted({b["item"]["value"] for b in tower_uris_res["results"]["bindings"]})
    tower_records: dict[str, dict[str, Any]] = {
        u: {"lat": None, "lon": None, "tags": {}} for u in tower_uris
    }
    for i in range(0, len(tower_uris), 250):
        vals = " ".join(f"<{u}>" for u in tower_uris[i : i + 250])
        t_res = sparql_json(
            f"SELECT ?item ?p ?o WHERE {{ VALUES ?item {{ {vals} }} ?item ?p ?o . "
            f'FILTER(STRSTARTS(STR(?p), "https://www.openstreetmap.org/wiki/Key:")) }}'
        )
        for b in t_res["results"]["bindings"]:
            u = b["item"]["value"]
            k = b["p"]["value"].split("Key:", 1)[1]
            tower_records[u]["tags"][k] = b["o"]["value"]

        g_res = sparql_json(
            f"PREFIX geo: <http://www.opengis.net/ont/geosparql#>\n"
            f"SELECT ?item ?wkt WHERE {{ VALUES ?item {{ {vals} }} ?item geo:hasGeometry/geo:asWKT ?wkt . }}"
        )
        for b in g_res["results"]["bindings"]:
            u = b["item"]["value"]
            pts = re.findall(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)", b["wkt"]["value"])
            if pts:
                lons = [float(x) for x, _ in pts]
                lats = [float(y) for _, y in pts]
                tower_records[u]["lon"] = sum(lons) / len(lons)
                tower_records[u]["lat"] = sum(lats) / len(lats)

    raw_towers_untyped: list[tuple[float, float, int, int]] = []
    for rec in tower_records.values():
        lat, lon = rec["lat"], rec["lon"]
        if lat is None or lon is None:
            continue
        if not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
            continue
        tc = classify_osm_telecom_feature(rec["tags"])
        if tc is not None:
            raw_towers_untyped.append((float(lat), float(lon), tc[0], tc[1]))

    # 2. Mountain peaks, saddles & alpine/wilderness huts in Romania
    lm_res = sparql_json(
        "PREFIX osmkey: <https://www.openstreetmap.org/wiki/Key:>\n"
        "PREFIX osmrel: <https://www.openstreetmap.org/relation/>\n"
        "PREFIX ogc: <http://www.opengis.net/rdf#>\n"
        "PREFIX geo: <http://www.opengis.net/ont/geosparql#>\n"
        "SELECT ?item ?nat ?tour ?name ?namero ?ele ?wkt WHERE {\n"
        "  {\n"
        '    ?item osmkey:natural ?nat . FILTER(?nat IN ("peak", "saddle"))\n'
        "    ?item osmkey:name ?name . ?item ogc:sfIntersects osmrel:90689 .\n"
        "  } UNION {\n"
        '    ?item osmkey:tourism ?tour . FILTER(?tour IN ("alpine_hut", "wilderness_hut"))\n'
        "    ?item osmkey:name ?name . ?item ogc:sfIntersects osmrel:90689 .\n"
        "  }\n"
        "  OPTIONAL { ?item osmkey:name:ro ?namero . }\n"
        "  OPTIONAL { ?item osmkey:ele ?ele . }\n"
        "  ?item geo:hasGeometry/geo:asWKT ?wkt .\n"
        "}"
    )

    raw_landmarks: list[tuple[float, float, int, str, int | None]] = []
    for b in lm_res["results"]["bindings"]:
        pts = re.findall(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)", b["wkt"]["value"])
        if not pts:
            continue
        lon = sum(float(x) for x, _ in pts) / len(pts)
        lat = sum(float(y) for _, y in pts) / len(pts)
        if not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
            continue
        tags: dict[str, str] = {"name": b["name"]["value"]}
        if "namero" in b:
            tags["name:ro"] = b["namero"]["value"]
        if "nat" in b:
            tags["natural"] = b["nat"]["value"]
        if "tour" in b:
            tags["tourism"] = b["tour"]["value"]
        if "ele" in b:
            tags["ele"] = b["ele"]["value"]
        lm = classify_osm_landmark(tags)
        if lm is not None:
            raw_landmarks.append((lat, lon, lm[0], lm[1], lm[2]))

    tiles = {
        (int(math.floor(lat)), int(math.floor(lon)))
        for lat, lon, *_ in raw_towers_untyped
    } | {
        (int(math.floor(lat)), int(math.floor(lon)))
        for lat, lon, _, _, tag_ele in raw_landmarks
        if tag_ele is None
    }
    dem.ensure_tiles(tiles)

    towers_out: list[tuple[float, float, int, int, int, int]] = []
    for lat, lon, h_m, mask in raw_towers_untyped:
        ele = dem.sample(lat, lon) or 0.0
        towers_out.append((lat, lon, int(round(ele)), h_m, mask, SOURCE_OSM))

    peaks_out: list[list[Any]] = []
    for lat, lon, kind, name, tag_ele in raw_landmarks:
        ele_val = tag_ele if tag_ele is not None else int(round(dem.sample(lat, lon) or 0.0))
        if ele_val >= 650 or kind == 3:
            peaks_out.append([int(round(lat * 1e5)), int(round(lon * 1e5)), ele_val, kind, name])

    return towers_out, peaks_out


def extract_from_pbf(
    pbf_path: Path,
    dem: DemTileCache,
) -> tuple[list[tuple[float, float, int, int, int, int]], list[list[int | str]]]:
    import osmium

    class EmergencyHandler(osmium.SimpleHandler):
        def __init__(self) -> None:
            super().__init__()
            self.raw_towers: list[tuple[float, float, float, int, int]] = []
            self.raw_peaks: list[tuple[float, float, int, str, int | None]] = []

        def node(self, n: osmium.osm.Node) -> None:
            if not n.location.valid() or not n.tags:
                return
            lat, lon = n.location.lat, n.location.lon
            if not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
                return
            tags = {t.k: t.v for t in n.tags}
            tc = classify_osm_telecom_feature(tags)
            if tc is not None:
                self.raw_towers.append((lat, lon, 0.0, tc[0], tc[1]))
            lm = classify_osm_landmark(tags)
            if lm is not None:
                self.raw_peaks.append((lat, lon, lm[0], lm[1], lm[2]))

        def area(self, a: osmium.osm.Area) -> None:
            if not a.tags or a.from_way() is False:
                return
            tags = {t.k: t.v for t in a.tags}
            tc = classify_osm_telecom_feature(tags)
            if tc is None:
                return
            lats: list[float] = []
            lons: list[float] = []
            for ring in a.outer_rings():
                for nd in ring:
                    if nd.location.valid():
                        lats.append(nd.location.lat)
                        lons.append(nd.location.lon)
            if lats and lons:
                clat = sum(lats) / len(lats)
                clon = sum(lons) / len(lons)
                if RO_LAT_MIN <= clat <= RO_LAT_MAX and RO_LON_MIN <= clon <= RO_LON_MAX:
                    self.raw_towers.append((clat, clon, 0.0, tc[0], tc[1]))

    handler = EmergencyHandler()
    handler.apply_file(str(pbf_path), locations=True, idx="flex_mem")

    tiles = {
        (int(math.floor(lat)), int(math.floor(lon)))
        for lat, lon, *_ in handler.raw_towers
    } | {
        (int(math.floor(lat)), int(math.floor(lon)))
        for lat, lon, *_ in handler.raw_peaks
    }
    dem.ensure_tiles(tiles)

    towers_out: list[tuple[float, float, int, int, int, int]] = []
    for lat, lon, _, h_m, mask in handler.raw_towers:
        ele = dem.sample(lat, lon) or 0.0
        towers_out.append((lat, lon, int(round(ele)), h_m, mask, SOURCE_OSM))

    peaks_out: list[list[int | str]] = []
    for lat, lon, kind, name, tag_ele in handler.raw_peaks:
        ele_val = tag_ele if tag_ele is not None else int(round(dem.sample(lat, lon) or 0.0))
        if ele_val >= 350 or kind == 3:
            peaks_out.append([int(round(lat * 1e5)), int(round(lon * 1e5)), ele_val, kind, name])

    peaks_out.sort(key=lambda r: (-int(r[2]), str(r[4])))
    return towers_out, peaks_out


def write_bundle(paths: list[Path], payload: dict[str, Any]) -> None:
    serialized = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    for p in paths:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(serialized, encoding="utf-8")
        print(
            f"[Emergency112] Wrote {len(payload['towers'])} towers & {len(payload['peaks'])} landmarks "
            f"({len(serialized.encode('utf-8'))} bytes) -> {p}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Build offline Romania 112 GSM tower & peak index.")
    parser.add_argument("--pbf", required=False, help="Path to romania-latest.osm.pbf")
    parser.add_argument("--online", action="store_true", help="Fetch live Romania OSM towers & landmarks via QLever")
    parser.add_argument("--opencellid-csv", required=False, help="Optional OpenCelliD 226.csv.gz")
    parser.add_argument("--dem-dir", default="/tmp/wanderer_ro_dem", help="SRTM .hgt cache directory")
    parser.add_argument("--seed-only", action="store_true", help="Write deterministic Carpathian seed")
    parser.add_argument("--out-web", required=True, help="Output path for web/static/data/romania_emergency_112.json")
    parser.add_argument("--out-app", required=False, help="Output path for app/assets/data/romania_emergency_112.json")
    args = parser.parse_args()

    targets = [Path(args.out_web).resolve()]
    if args.out_app:
        targets.append(Path(args.out_app).resolve())

    curated_tower_tuples: list[tuple[float, float, int, int, int, int]] = [
        (r[0] / 1e5, r[1] / 1e5, int(r[2]), int(r[3]), int(r[4]), int(r[5]))
        for r in CURATED_CARPATHIAN_SEED["towers"]
    ]
    curated_peaks: list[list[Any]] = [list(r) for r in CURATED_CARPATHIAN_SEED["peaks"]]

    if args.seed_only or (not args.pbf and not args.online):
        payload = {
            "v": 1,
            "generatedAt": "2026-11-18T00:00:00Z",
            "attribution": "© OpenStreetMap contributors (ODbL)",
            "towers": deduplicate_towers(curated_tower_tuples),
            "peaks": deduplicate_landmarks(curated_peaks),
        }
        write_bundle(targets, payload)
        return

    dem = DemTileCache(Path(args.dem_dir).resolve())
    raw_towers: list[tuple[float, float, int, int, int, int]] = list(curated_tower_tuples)
    raw_peaks: list[list[Any]] = list(curated_peaks)

    if args.pbf and Path(args.pbf).exists():
        pbf_towers, pbf_peaks = extract_from_pbf(Path(args.pbf).resolve(), dem)
        raw_towers.extend(pbf_towers)
        raw_peaks.extend(pbf_peaks)
    elif args.online:
        try:
            online_towers, online_peaks = fetch_online_romania_towers_and_landmarks(dem)
            print(f"[Emergency112] Fetched {len(online_towers)} OSM towers & {len(online_peaks)} mountain landmarks online.")
            raw_towers.extend(online_towers)
            raw_peaks.extend(online_peaks)
        except Exception as exc:  # noqa: BLE001
            print(
                f"[Emergency112] Warning: online OSM query failed ({exc}); using curated Carpathian relays.",
                file=sys.stderr,
            )

    attribution = "© OpenStreetMap contributors (ODbL)"
    if args.opencellid_csv and Path(args.opencellid_csv).exists():
        raw_towers.extend(load_opencellid_romania(Path(args.opencellid_csv).resolve(), dem))
        attribution += " · Cell data © OpenCelliD (CC BY-SA 4.0)"

    deduped_towers = deduplicate_towers(raw_towers)
    deduped_peaks = deduplicate_landmarks(raw_peaks)
    payload = {
        "v": 1,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "attribution": attribution,
        "towers": deduped_towers,
        "peaks": deduped_peaks,
    }
    write_bundle(targets, payload)


if __name__ == "__main__":
    main()
