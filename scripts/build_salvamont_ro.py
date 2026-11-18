#!/usr/bin/env python3
"""Build verified offline Salvamont Romania dataset (`salvamont_ro.json`).

Merges ANSMR official County/Local Salvamont services & curated mountain bases
with OpenStreetMap (`--pbf romania-latest.osm.pbf` or `--online` QLever/Overpass),
deduplicating overlapping geometries within 60 m and strictly validating E.164 phones.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import ssl
import sys
from typing import Any
import urllib.parse
import urllib.request


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

E164_RO_RE = re.compile(r"^\+40[237]\d{8}$")
NATIONAL_DISPATCH_E164 = "+40725826668"
RO_LAT_MIN, RO_LAT_MAX = 43.5, 48.3
RO_LON_MIN, RO_LON_MAX = 20.2, 29.8

EXCLUDED_AMENITIES = {
    "parking",
    "parking_entrance",
    "parking_space",
    "drinking_water",
    "bench",
    "waste_basket",
    "waste_disposal",
    "toilets",
    "restaurant",
    "cafe",
    "fast_food",
    "bar",
    "pharmacy",
    "fuel",
    "fountain",
}

LIFECYCLE_PREFIXES = ("disused:", "abandoned:", "demolished:", "razed:", "construction:", "proposed:")


def haversine_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2.0) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2.0) ** 2
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))


def normalize_ro_phone(raw: str | None) -> str | None:
    """Normalize a raw phone tag to strict +40[237]XXXXXXXX (12 chars) or None."""
    if not raw:
        return None
    for chunk in re.split(r"[;,/|]+", raw):
        token = chunk.strip()
        if not token:
            continue

        # Strip vanity word so digits inside e.g. "0-SALVAMONT (0725826668)" aren't prefixed with an extra '0'
        stripped_vanity = re.sub(r"0?\s*[-–]?\s*SALVAMONT", " ", token, flags=re.IGNORECASE)
        cleaned = re.sub(r"[^\d+]", "", stripped_vanity)
        if cleaned in ("112", "+112", "911"):
            continue
        if cleaned.startswith("0040"):
            cleaned = "+40" + cleaned[4:]
        elif cleaned.startswith("40") and len(cleaned) == 11:
            cleaned = "+" + cleaned
        elif cleaned.startswith("0") and len(cleaned) == 10:
            cleaned = "+40" + cleaned[1:]

        if E164_RO_RE.match(cleaned):
            return cleaned

        upper = re.sub(r"[^A-Z0-9+]", "", token.upper())
        if "0SALVAMONT" in upper and not cleaned:
            return NATIONAL_DISPATCH_E164
    return None


def classify_osm_element(tags: dict[str, str]) -> tuple[str, str] | None:
    """Return `(kind, permanence)` for physical Salvamont bases/refuges, or `None` for noise."""
    if not tags:
        return None
    for k, v in tags.items():
        kl = k.lower()
        if (kl.startswith(LIFECYCLE_PREFIXES) or kl in ("disused", "abandoned")) and str(v).lower() != "no":
            return None
    if tags.get("type") in ("route", "superroute", "boundary", "site") or "route" in tags:
        return None
    if tags.get("tourism") == "information" or tags.get("information") in (
        "guidepost",
        "board",
        "map",
        "route_marker",
        "audioguide",
        "stele",
    ):
        return None
    if tags.get("emergency") in ("landing_site", "defibrillator", "phone", "fire_hydrant") or "aeroway" in tags:
        return None
    if "piste:type" in tags or "aerialway" in tags or "public_transport" in tags or "waterway" in tags:
        return None
    if tags.get("highway") == "bus_stop":
        return None
    if "highway" in tags and not any(
        k in tags for k in ("emergency", "building", "tourism", "amenity", "office")
    ):
        return None
    if tags.get("amenity") in EXCLUDED_AMENITIES and tags.get("emergency") != "mountain_rescue":
        return None
    if (
        "natural" in tags
        and tags.get("emergency") != "mountain_rescue"
        and tags.get("amenity") != "shelter"
        and tags.get("tourism") != "wilderness_hut"
    ):
        return None
    if (
        tags.get("man_made") in ("survey_point", "cairn", "cross", "monitoring_station", "mast", "tower")
        and tags.get("emergency") != "mountain_rescue"
    ):
        return None

    name_l = tags.get("name", "").lower()
    op_l = tags.get("operator", "").lower()
    is_salvamont_refuge = (
        tags.get("amenity") == "shelter"
        or tags.get("tourism") == "wilderness_hut"
        or tags.get("shelter_type") in ("basic_hut", "weather_shelter")
        or ("refugi" in name_l and tags.get("emergency") != "mountain_rescue")
        or "menedék" in name_l
    )
    if is_salvamont_refuge:
        if "salvamont" in name_l or "salvamont" in op_l or tags.get("emergency") == "mountain_rescue":
            return ("refuge", "shelter_unmanned")
        return None

    if (
        tags.get("emergency") == "mountain_rescue"
        or "salvamont" in name_l
        or "salvamont" in op_l
    ):
        if "dispecerat" in name_l:
            return ("dispatch_hq", "24_7")
        if "punct" in name_l or "post" in name_l:
            return ("post", "seasonal")
        return ("base", "24_7")

    return None


def parse_ele(raw: str | None) -> int | None:
    if not raw:
        return None
    m = re.search(r"-?\d+(?:\.\d+)?", raw)
    return int(round(float(m.group(0)))) if m else None


def slugify(text: str) -> str:
    tr = str.maketrans("ăâîșțĂÂÎȘȚşţŞŢ", "aaistAAISTstST")
    s = text.translate(tr).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s or "salvamont-poi"


def deduplicate_points(points: list[dict[str, Any]], merge_radius_m: float = 60.0) -> list[dict[str, Any]]:
    """Cluster & merge co-located OSM nodes/ways within `merge_radius_m`."""
    clusters: list[dict[str, Any]] = []
    # Prefer rich, named items first so cluster centroids & names stay deterministic.
    ordered = sorted(
        points,
        key=lambda p: (
            0 if p.get("name") and p["name"].lower() not in ("salvamont", "112") else 1,
            0 if p.get("kind") == "base" else 1,
            p.get("osm_type", ""),
            str(p.get("osm_id", "")),
        ),
    )
    for pt in ordered:
        osm_ref = f"{pt['osm_type']}/{pt['osm_id']}"
        matched = None
        for cl in clusters:
            if haversine_meters(pt["lat"], pt["lon"], cl["lat"], cl["lon"]) <= merge_radius_m:
                matched = cl
                break
        if matched is None:
            clusters.append(
                {
                    "lat": pt["lat"],
                    "lon": pt["lon"],
                    "name": pt.get("name", "").strip(),
                    "operator": pt.get("operator", "").strip(),
                    "kind": pt["kind"],
                    "permanence": pt["permanence"],
                    "ele": pt.get("ele"),
                    "osm_phone": pt.get("osm_phone"),
                    "osmIds": [osm_ref],
                }
            )
        else:
            if osm_ref not in matched["osmIds"]:
                matched["osmIds"].append(osm_ref)
            if (not matched["name"] or matched["name"].lower() in ("salvamont", "112")) and pt.get("name"):
                cand = pt["name"].strip()
                if cand.lower() != "112":
                    matched["name"] = cand
            if not matched.get("operator") and pt.get("operator"):
                matched["operator"] = pt["operator"].strip()
            if matched["ele"] is None and pt.get("ele") is not None:
                matched["ele"] = pt["ele"]
            if matched["osm_phone"] is None and pt.get("osm_phone") is not None:
                matched["osm_phone"] = pt["osm_phone"]
    return clusters


def fetch_online_qlever_osm() -> list[dict[str, Any]]:
    """Fetch Romania Salvamont / mountain_rescue OSM elements via QLever SPARQL (or Overpass fallback)."""
    endpoints = (
        "https://qlever.dev/api/osm-planet",
        "https://qlever.cs.uni-freiburg.de/api/osm-planet",
    )

    last_err: Exception | None = None
    for endpoint in endpoints:
        try:
            def sparql_json(query: str, ep: str = endpoint) -> dict[str, Any]:
                req = urllib.request.Request(
                    ep,
                    data=urllib.parse.urlencode({"query": query}).encode("utf-8"),
                    headers={
                        "Accept": "application/sparql-results+json",
                        "User-Agent": "WandererRO-SalvamontBuilder/1.0",
                    },
                )
                with urllib.request.urlopen(req, timeout=25, context=_SSL_CTX) as resp:
                    return json.loads(resp.read().decode("utf-8"))

            uris: set[str] = set()
            for clause in (
                '?item osmkey:emergency "mountain_rescue" . ?item ogc:sfIntersects osmrel:90689 .',
                '?item osmkey:name ?n . FILTER(REGEX(?n, "salvamont", "i")) ?item ogc:sfIntersects osmrel:90689 .',
                '?item osmkey:operator ?op . FILTER(REGEX(?op, "salvamont", "i")) ?item ogc:sfIntersects osmrel:90689 .',
            ):
                res = sparql_json(
                    f"PREFIX osmkey: <https://www.openstreetmap.org/wiki/Key:>\n"
                    f"PREFIX osmrel: <https://www.openstreetmap.org/relation/>\n"
                    f"PREFIX ogc: <http://www.opengis.net/rdf#>\n"
                    f"SELECT DISTINCT ?item WHERE {{ {clause} }}"
                )
                for b in res["results"]["bindings"]:
                    uris.add(b["item"]["value"])

            sorted_uris = sorted(uris)
            records: dict[str, dict[str, Any]] = {
                u: {"type": u.rsplit("/", 2)[-2], "id": u.rsplit("/", 1)[-1], "lat": None, "lon": None, "tags": {}}
                for u in sorted_uris
            }
            for i in range(0, len(sorted_uris), 100):
                vals = " ".join(f"<{u}>" for u in sorted_uris[i : i + 100])
                tags_res = sparql_json(
                    f"SELECT ?item ?p ?o WHERE {{ VALUES ?item {{ {vals} }} ?item ?p ?o . "
                    f'FILTER(STRSTARTS(STR(?p), "https://www.openstreetmap.org/wiki/Key:")) }}'
                )
                for b in tags_res["results"]["bindings"]:
                    u = b["item"]["value"]
                    k = b["p"]["value"].split("Key:", 1)[1]
                    records[u]["tags"][k] = b["o"]["value"]

                geom_res = sparql_json(
                    f"PREFIX geo: <http://www.opengis.net/ont/geosparql#>\n"
                    f"SELECT ?item ?wkt WHERE {{ VALUES ?item {{ {vals} }} ?item geo:hasGeometry/geo:asWKT ?wkt . }}"
                )
                for b in geom_res["results"]["bindings"]:
                    u = b["item"]["value"]
                    pts = re.findall(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)", b["wkt"]["value"])
                    if pts:
                        lons = [float(x) for x, _ in pts]
                        lats = [float(y) for _, y in pts]
                        records[u]["lon"] = sum(lons) / len(lons)
                        records[u]["lat"] = sum(lats) / len(lats)

            return [
                r
                for r in records.values()
                if r["lat"] is not None
                and r["lon"] is not None
                and RO_LAT_MIN <= float(r["lat"]) <= RO_LAT_MAX
                and RO_LON_MIN <= float(r["lon"]) <= RO_LON_MAX
            ]
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            continue

    # Fallback to Overpass API
    overpass_query = (
        '[out:json][timeout:45];area["ISO3166-1"="RO"][admin_level=2]->.ro;('
        'nwr["emergency"="mountain_rescue"](area.ro);'
        'nwr["name"~"salvamont",i](area.ro);'
        'nwr["operator"~"salvamont",i](area.ro);'
        ");out center tags;"
    )
    try:
        req = urllib.request.Request(
            "https://overpass-api.de/api/interpreter",
            data=urllib.parse.urlencode({"data": overpass_query}).encode("utf-8"),
            headers={"User-Agent": "WandererRO-SalvamontBuilder/1.0"},
        )
        with urllib.request.urlopen(req, timeout=50, context=_SSL_CTX) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        out: list[dict[str, Any]] = []
        for el in payload.get("elements", []):
            lat = el.get("lat") or (el.get("center") or {}).get("lat")
            lon = el.get("lon") or (el.get("center") or {}).get("lon")
            if lat is not None and lon is not None:
                out.append(
                    {
                        "type": el.get("type", "node"),
                        "id": str(el["id"]),
                        "lat": float(lat),
                        "lon": float(lon),
                        "tags": el.get("tags") or {},
                    }
                )
        return out
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"Online QLever and Overpass queries failed: {last_err}; {exc}") from exc


def extract_from_pbf(pbf_path: Path) -> list[dict[str, Any]]:
    import osmium

    class SalvamontHandler(osmium.SimpleHandler):
        def __init__(self) -> None:
            super().__init__()
            self.items: list[dict[str, Any]] = []

        def _check(self, osm_type: str, oid: int, tags_obj: Any, lat: float, lon: float) -> None:
            if not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
                return
            tags = {t.k: t.v for t in tags_obj}
            if classify_osm_element(tags) is not None:
                self.items.append({"type": osm_type, "id": oid, "lat": lat, "lon": lon, "tags": tags})

        def node(self, n: osmium.osm.Node) -> None:
            if n.location.valid():
                self._check("node", int(n.id), n.tags, n.location.lat, n.location.lon)

        def way(self, w: osmium.osm.Way) -> None:
            coords = [(nd.lon, nd.lat) for nd in w.nodes if nd.location.valid()]
            if coords:
                lon = sum(c[0] for c in coords) / len(coords)
                lat = sum(c[1] for c in coords) / len(coords)
                self._check("way", int(w.id), w.tags, lat, lon)

    handler = SalvamontHandler()
    handler.apply_file(str(pbf_path), locations=True, idx="flex_mem")
    return handler.items


def _resolve_osm_service(
    osm_pt: dict[str, Any],
    services: list[dict[str, Any]],
    curated_points: list[dict[str, Any]],
) -> dict[str, Any]:
    operational = [s for s in services if s["level"] in ("local", "county")]
    by_id = {s["id"]: s for s in operational}
    blob = f"{osm_pt.get('name', '')} {osm_pt.get('operator', '')}".lower()
    tr = str.maketrans("ăâîșțşţ", "aaistst")
    blob_ascii = blob.translate(tr)

    # 1. Explicit service/locality/county mention in OSM name or operator
    explicit_keywords = (
        ("poiana brasov", "ro-bv-poiana"),
        ("bran", "ro-bv-bran"),
        ("rasnov", "ro-bv-rasnov"),
        ("zarnesti", "ro-bv-zarnesti"),
        ("sacele", "ro-bv-sacele"),
        ("sinaia", "ro-ph-sinaia"),
        ("busteni", "ro-ph-busteni"),
        ("cisnadie", "ro-sb-cisnadie"),
        ("brezoi", "ro-vl-brezoi"),
        ("olanesti", "ro-vl-olanesti"),
        ("voineasa", "ro-vl-voineasa"),
        ("lupeni", "ro-hd-lupeni"),
        ("straja", "ro-hd-lupeni"),
        ("petrosani", "ro-hd-petrosani"),
        ("uricani", "ro-hd-uricani"),
        ("vatra dornei", "ro-sv-vatra-dornei"),
        ("alba", "ro-ab-spj"),
        ("arad", "ro-ar-spj"),
        ("arges", "ro-ag-spj"),
        ("bacau", "ro-bc-spj"),
        ("bihor", "ro-bh-spj"),
        ("bistrita", "ro-bn-spj"),
        ("brasov", "ro-bv-spj"),
        ("caras", "ro-cs-spj"),
        ("cluj", "ro-cj-spj"),
        ("covasna", "ro-cv-spj"),
        ("dambovita", "ro-db-spj"),
        ("gorj", "ro-gj-spj"),
        ("harghita", "ro-hr-spj"),
        ("hunedoara", "ro-hd-spj"),
        ("maramures", "ro-mm-spj"),
        ("borsa", "ro-mm-spj"),
        ("mehedinti", "ro-mh-spj"),
        ("mures", "ro-ms-spj"),
        ("neamt", "ro-nt-spj"),
        ("prahova", "ro-ph-spj"),
        ("satu mare", "ro-sm-spj"),
        ("sibiu", "ro-sb-spj"),
        ("suceava", "ro-sv-spj"),
        ("timis", "ro-tm-spj"),
        ("valcea", "ro-vl-spj"),
        ("vrancea", "ro-vn-spj"),
    )
    for kw, sid in explicit_keywords:
        if re.search(rf"\b{re.escape(kw)}\b", blob_ascii) and sid in by_id:
            return by_id[sid]

    # 2. Nearest curated operational base/post (captures multi-hub counties like MM Borșa vs Gutâi)
    lat, lon = osm_pt["lat"], osm_pt["lon"]
    op_curated = [cp for cp in curated_points if cp["serviceId"] in by_id and cp.get("kind") != "dispatch_hq"]
    if op_curated:
        nearest_cp = min(op_curated, key=lambda cp: haversine_meters(lat, lon, float(cp["lat"]), float(cp["lon"])))
        d_cp = haversine_meters(lat, lon, float(nearest_cp["lat"]), float(nearest_cp["lon"]))
        nearest_hub = min(operational, key=lambda s: haversine_meters(lat, lon, s["hubLat"], s["hubLon"]))
        d_hub = haversine_meters(lat, lon, nearest_hub["hubLat"], nearest_hub["hubLon"])
        if d_cp <= d_hub:
            return by_id[nearest_cp["serviceId"]]
        return nearest_hub

    return min(operational, key=lambda s: haversine_meters(lat, lon, s["hubLat"], s["hubLon"]))


def build_dataset(
    curated_path: Path,
    raw_osm_elements: list[dict[str, Any]],
    dem_dir: Path | None = None,
) -> dict[str, Any]:
    curated = json.loads(curated_path.read_text(encoding="utf-8"))
    raw_services: list[dict[str, Any]] = curated["services"]

    services_map: dict[str, dict[str, Any]] = {}
    county_spj_by_code: dict[str, str] = {}
    for s in raw_services:
        p_phone = normalize_ro_phone(s["primaryPhone"])
        if not p_phone:
            raise ValueError(f"Invalid curated primaryPhone on service {s['id']}: {s['primaryPhone']}")
        sec_phones = [
            sp for sp in (normalize_ro_phone(x) for x in s.get("secondaryPhones", [])) if sp and sp != p_phone
        ]
        if s["level"] == "county":
            county_spj_by_code[s["countyCode"]] = s["id"]
        entry: dict[str, Any] = {
            "id": s["id"],
            "name": s["name"],
            "shortName": s["shortName"],
            "level": s["level"],
            "countyCode": s["countyCode"],
            "ansmrId": s["ansmrId"],
            "primaryPhone": p_phone,
            "secondaryPhones": sec_phones,
            "phoneRoleRo": s["phoneRoleRo"],
            "massifs": s["massifs"],
        }
        if s.get("website"):
            entry["website"] = s["website"]
        services_map[s["id"]] = entry

    # Prepare curated points first (authoritative coordinates, names & service mappings).
    final_points: list[dict[str, Any]] = []
    for cp in curated.get("curatedPoints", []):
        pt_rec: dict[str, Any] = {
            "id": cp["id"],
            "name": cp["name"],
            "kind": cp["kind"],
            "permanence": cp["permanence"],
            "lat": round(float(cp["lat"]), 5),
            "lon": round(float(cp["lon"]), 5),
            "ele": int(cp["ele"]),
            "massif": cp["massif"],
            "countyCode": cp["countyCode"],
            "serviceId": cp["serviceId"],
            "osmIds": list(cp.get("osmIds", [])),
            "source": "ansmr_curated",
        }
        if cp.get("backupCountyServiceId"):
            pt_rec["backupCountyServiceId"] = cp["backupCountyServiceId"]
        elif services_map[cp["serviceId"]]["level"] == "local":
            parent_spj = county_spj_by_code.get(cp["countyCode"])
            if parent_spj:
                pt_rec["backupCountyServiceId"] = parent_spj
        if cp.get("directBasePhone"):
            valid_direct = normalize_ro_phone(cp["directBasePhone"])
            if valid_direct:
                pt_rec["directBasePhone"] = valid_direct
        final_points.append(pt_rec)

    # Filter & deduplicate incoming OSM elements.
    osm_candidates: list[dict[str, Any]] = []
    for el in raw_osm_elements:
        tags = el.get("tags") or {}
        cls = classify_osm_element(tags)
        if cls is None:
            continue
        kind, permanence = cls
        raw_ph = (
            tags.get("phone")
            or tags.get("contact:phone")
            or tags.get("emergency:phone")
            or tags.get("mobile")
        )
        valid_ph = normalize_ro_phone(raw_ph)
        if valid_ph == NATIONAL_DISPATCH_E164:
            valid_ph = None  # National dispatch is already surfaced globally; keep only true local phones.
        osm_candidates.append(
            {
                "osm_type": el["type"],
                "osm_id": str(el["id"]),
                "lat": float(el["lat"]),
                "lon": float(el["lon"]),
                "name": (tags.get("name:ro") or tags.get("name") or "").strip(),
                "operator": (tags.get("operator") or "").strip(),
                "kind": kind,
                "permanence": permanence,
                "ele": parse_ele(tags.get("ele")),
                "osm_phone": valid_ph,
            }
        )

    deduped_osm = deduplicate_points(osm_candidates, merge_radius_m=60.0)

    dem = None
    if dem_dir is not None:
        from dem_elevation import DemTileCache

        dem = DemTileCache(dem_dir)
        tiles_needed = {
            (int(math.floor(pt["lat"])), int(math.floor(pt["lon"])))
            for pt in deduped_osm
            if pt.get("ele") is None
        }
        if tiles_needed:
            dem.ensure_tiles(tiles_needed)

    curated_pts_raw: list[dict[str, Any]] = curated.get("curatedPoints", [])
    used_ids = {p["id"] for p in final_points}
    for osm_pt in deduped_osm:
        # Match against curated points within 350 m so curated names & verified phones win while preserving osmIds!
        nearest_cur = min(
            final_points,
            key=lambda fp: haversine_meters(osm_pt["lat"], osm_pt["lon"], fp["lat"], fp["lon"]),
            default=None,
        )
        if nearest_cur and haversine_meters(
            osm_pt["lat"], osm_pt["lon"], nearest_cur["lat"], nearest_cur["lon"]
        ) <= 350.0:
            for oid in osm_pt["osmIds"]:
                if oid not in nearest_cur["osmIds"]:
                    nearest_cur["osmIds"].append(oid)
            nearest_cur["source"] = "osm+ansmr"
            if "directBasePhone" not in nearest_cur and osm_pt["osm_phone"]:
                nearest_cur["directBasePhone"] = osm_pt["osm_phone"]
            continue

        svc_raw = _resolve_osm_service(osm_pt, raw_services, curated_pts_raw)
        # Skip spurious urban/lowland OSM mentions >75 km from any Carpathian Salvamont hub
        if haversine_meters(osm_pt["lat"], osm_pt["lon"], svc_raw["hubLat"], svc_raw["hubLon"]) > 85_000.0:
            continue

        svc_id = svc_raw["id"]
        massif_label = f"Munții {svc_raw['massifs'][0]}" if svc_raw.get("massifs") else "Zona Montană"
        raw_name = osm_pt["name"].rstrip(".")
        if not raw_name or raw_name.lower() in ("salvamont", "112", "salvamont rescue"):
            prefix = "Refugiul Salvamont" if osm_pt["kind"] == "refuge" else "Post Salvamont"
            display_name = f"{prefix} ({svc_raw['shortName'].replace('Salvamont ', '')})"
        else:
            display_name = raw_name

        ele_val = osm_pt["ele"]
        if ele_val is None and dem is not None:
            sampled = dem.sample(osm_pt["lat"], osm_pt["lon"])
            if sampled is not None:
                ele_val = int(round(sampled))
        if ele_val is None:
            ele_val = 0

        base_slug = slugify(f"{display_name}-{osm_pt['osmIds'][0].replace('/', '-')}")
        uid = base_slug
        idx = 2
        while uid in used_ids:
            uid = f"{base_slug}-{idx}"
            idx += 1
        used_ids.add(uid)

        new_pt: dict[str, Any] = {
            "id": uid,
            "name": display_name,
            "kind": osm_pt["kind"],
            "permanence": osm_pt["permanence"],
            "lat": round(osm_pt["lat"], 5),
            "lon": round(osm_pt["lon"], 5),
            "ele": ele_val,
            "massif": massif_label,
            "countyCode": svc_raw["countyCode"],
            "serviceId": svc_id,
            "osmIds": osm_pt["osmIds"],
            "source": "osm+ansmr",
        }
        if svc_raw["level"] == "local":
            parent_spj = county_spj_by_code.get(svc_raw["countyCode"])
            if parent_spj:
                new_pt["backupCountyServiceId"] = parent_spj
        if osm_pt["osm_phone"]:
            new_pt["directBasePhone"] = osm_pt["osm_phone"]
        final_points.append(new_pt)

    final_points.sort(key=lambda p: (p["countyCode"], p["name"], p["id"]))

    return {
        "version": 1,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "emergency112": "112",
        "nationalDispatchPhone": NATIONAL_DISPATCH_E164,
        "nationalDispatchLabel": "0-SALVAMONT (0725 826 668)",
        "services": services_map,
        "points": final_points,
    }


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Build shared salvamont_ro.json for Web and Flutter.")
    parser.add_argument("--pbf", type=Path, help="Optional path to romania-latest.osm.pbf")
    parser.add_argument("--online", action="store_true", help="Fetch live Romania OSM points via QLever/Overpass")
    parser.add_argument("--dem-dir", type=Path, help="Optional SRTM .hgt cache dir for missing elevations")
    parser.add_argument(
        "--curated",
        type=Path,
        default=Path(__file__).resolve().parent / "salvamont_curated_directory.json",
    )
    parser.add_argument(
        "--out-web",
        type=Path,
        default=repo_root / "web" / "src" / "lib" / "data" / "salvamont_ro.json",
    )
    parser.add_argument(
        "--out-app",
        type=Path,
        default=repo_root / "app" / "assets" / "data" / "salvamont_ro.json",
    )
    args = parser.parse_args()

    raw_osm: list[dict[str, Any]] = []
    if args.pbf and args.pbf.exists():
        raw_osm = extract_from_pbf(args.pbf.resolve())
    elif args.online:
        try:
            raw_osm = fetch_online_qlever_osm()
            print(f"[Salvamont] Fetched {len(raw_osm)} raw Romania OSM elements online.")
        except Exception as exc:  # noqa: BLE001
            print(f"[Salvamont] Warning: online OSM unreachable ({exc}); falling back to curated directory.", file=sys.stderr)

    dataset = build_dataset(args.curated.resolve(), raw_osm, args.dem_dir.resolve() if args.dem_dir else None)
    serialized = json.dumps(dataset, ensure_ascii=False, indent=2) + "\n"

    for target in (args.out_web, args.out_app):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(serialized, encoding="utf-8")
        print(f"[Salvamont] Wrote {len(dataset['points'])} points & {len(dataset['services'])} services -> {target}")


if __name__ == "__main__":
    main()
