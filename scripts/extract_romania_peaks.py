#!/usr/bin/env python3
"""Extract named Carpathian mountain peaks & passes in Romania into a compact columnar JSON catalog."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
from pathlib import Path
import re
import ssl
import sys
from typing import Any, Iterable
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

RO_LAT_MIN, RO_LAT_MAX = 43.4, 48.5
RO_LON_MIN, RO_LON_MAX = 20.0, 30.0


@dataclass(frozen=True)
class RawPeakNode:
    osm_id: int
    name: str
    lat: float
    lon: float
    ele: float
    kind: str  # "peak" | "pass"
    prominence_override: float | None = None


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2.0) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2.0) ** 2
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))


def parse_osm_elevation_meters(raw: str | None) -> float | None:
    if not raw:
        return None
    cleaned = raw.strip().lower()
    if not cleaned:
        return None
    # Strip thousands spaces ("1 849 m"), convert decimal comma if followed by 1-2 digits, else strip thousands comma.
    compact = re.sub(r"(?<=\d)\s+(?=\d)", "", cleaned)
    if re.search(r",\d{1,2}(?!\d)", compact):
        compact = compact.replace(",", ".")
    else:
        compact = compact.replace(",", "")
    m = re.search(r"[-+]?\d+(?:\.\d+)?", compact)
    if not m:
        return None
    try:
        val = float(m.group(0))
    except ValueError:
        return None
    if not math.isfinite(val) or val < 0.0 or val > 8900.0:
        return None
    return val


def _estimate_prominence_proxy(sorted_nodes: list[RawPeakNode]) -> list[int]:
    """Computes topographic dominance-derived prominence proxy when OSM prominence=* is absent."""
    n = len(sorted_nodes)
    out = [0] * n
    for i, node in enumerate(sorted_nodes):
        if node.prominence_override is not None and node.prominence_override > 0:
            out[i] = int(round(node.prominence_override))
            continue
        if i == 0:
            out[i] = int(round(min(2000.0, max(500.0, node.ele * 0.75))))
            continue
        min_dist_higher_m = float("inf")
        for j in range(i):
            higher = sorted_nodes[j]
            if higher.ele <= node.ele:
                break
            # Quick degree bounding gate before haversine
            if abs(higher.lat - node.lat) * 111320.0 > min_dist_higher_m:
                continue
            d = haversine_m(node.lat, node.lon, higher.lat, higher.lon)
            if d < min_dist_higher_m:
                min_dist_higher_m = d
        if not math.isfinite(min_dist_higher_m):
            out[i] = 800
        else:
            # Map isolation (0.3 km .. 45 km) onto an effective prominence score [25 .. 1200] m
            prom = min(1200.0, max(20.0, (min_dist_higher_m / 1000.0) * 38.0))
            out[i] = int(round(prom))
    return out


def _peak_stem(name: str) -> str:
    tr = str.maketrans("ăâîșțĂÂÎȘȚşţŞŢ", "aaistAAISTstST")
    s = name.translate(tr).lower().strip()
    s = re.sub(r"\([^)]*\)", " ", s)
    s = re.sub(
        r"^(varful|vf\.?|v\.|saua|pasul|curmatura|trecatoarea|muntele|piscul)\s+",
        "",
        s,
    )
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def build_columnar_catalog(nodes: Iterable[RawPeakNode], min_ele_m: float = 400.0) -> dict[str, Any]:
    filtered: list[RawPeakNode] = []
    seen_grid: set[tuple[str, int, int]] = set()
    spatial_buckets: dict[tuple[int, int], list[RawPeakNode]] = {}
    stem_buckets: dict[str, list[RawPeakNode]] = {}

    candidates = [
        p
        for p in nodes
        if p.name.strip()
        and p.ele >= min_ele_m
        and RO_LAT_MIN <= p.lat <= RO_LAT_MAX
        and RO_LON_MIN <= p.lon <= RO_LON_MAX
    ]
    # Prefer curated/prominence-annotated entries first when deduplicating, then descending elevation
    candidates.sort(key=lambda p: (0 if (1000 <= p.osm_id <= 9999) else 1, -p.ele, p.osm_id))
    for p in candidates:
        norm_name = " ".join(p.name.split())
        if len(norm_name) > 64:
            norm_name = norm_name[:61].rstrip() + "..."
        kind_norm = "pass" if p.kind == "pass" else "peak"
        dedup_key = (norm_name.lower(), int(round(p.lat * 200)), int(round(p.lon * 200)))
        if dedup_key in seen_grid:
            continue

        bi, bj = int(math.floor(p.lat * 200)), int(math.floor(p.lon * 200))
        near_dup = False
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for ex in spatial_buckets.get((bi + di, bj + dj), ()):
                    if ex.kind == kind_norm and haversine_m(p.lat, p.lon, ex.lat, ex.lon) <= 140.0:
                        near_dup = True
                        break
                if near_dup:
                    break
            if near_dup:
                break
        if near_dup:
            continue

        stem = _peak_stem(norm_name)
        if stem:
            for ex in stem_buckets.get(stem, ()):
                if ex.kind == kind_norm and haversine_m(p.lat, p.lon, ex.lat, ex.lon) <= 1500.0:
                    near_dup = True
                    break
        if near_dup:
            continue

        seen_grid.add(dedup_key)
        clean_node = RawPeakNode(
            osm_id=p.osm_id,
            name=norm_name,
            lat=round(p.lat, 5),
            lon=round(p.lon, 5),
            ele=p.ele,
            kind=kind_norm,
            prominence_override=p.prominence_override,
        )
        filtered.append(clean_node)
        spatial_buckets.setdefault((bi, bj), []).append(clean_node)
        if stem:
            stem_buckets.setdefault(stem, []).append(clean_node)

    filtered.sort(key=lambda p: (-p.ele, p.osm_id))
    prominences = _estimate_prominence_proxy(filtered)
    return {
        "version": 1,
        "count": len(filtered),
        "ids": [p.osm_id for p in filtered],
        "names": [p.name for p in filtered],
        "lats": [p.lat for p in filtered],
        "lons": [p.lon for p in filtered],
        "eles": [int(round(p.ele)) for p in filtered],
        "prominences": prominences,
        "kinds": [p.kind for p in filtered],
    }


def curated_carpathian_seed_peaks() -> list[RawPeakNode]:
    """Verified reference summits & passes across major Romanian Carpathian massifs."""
    rows = [
        (1001, "Vârful Moldoveanu", 45.59950, 24.73620, 2544, "peak", 2046),
        (1002, "Vârful Negoiu", 45.58478, 24.55864, 2535, "peak", 425),
        (1003, "Vârful Viștea Mare", 45.60292, 24.73544, 2527, "peak", 40),
        (1004, "Vârful Lespezi", 45.57661, 24.56817, 2517, "peak", 150),
        (1005, "Vârful Parângul Mare", 45.34014, 23.54106, 2519, "peak", 2103),
        (1006, "Vârful Peleaga", 45.36619, 22.89389, 2509, "peak", 1759),
        (1007, "Vârful Păpușa (Retezat)", 45.37008, 22.90814, 2508, "peak", 210),
        (1008, "Vârful Omu", 45.44572, 25.45628, 2505, "peak", 1460),
        (1009, "Vârful Bucura", 45.36369, 22.86869, 2433, "peak", 185),
        (1010, "Vârful Retezat", 45.38228, 22.85294, 2482, "peak", 260),
        (1011, "Vârful Caraiman", 45.41614, 25.48789, 2384, "peak", 145),
        (1012, "Vârful Coștila", 45.42925, 25.48836, 2490, "peak", 170),
        (1013, "Vârful Bucșoiu", 45.45781, 25.46506, 2492, "peak", 160),
        (1014, "Vârful Babele", 45.40669, 25.47169, 2292, "peak", 80),
        (1015, "Vârful Piatra Mare", 45.54986, 25.64589, 1844, "peak", 680),
        (1016, "Vârful Postăvaru", 45.56883, 25.56667, 1799, "peak", 740),
        (1017, "Vârful La Om (Piscul Baciului)", 45.52453, 25.21453, 2238, "peak", 960),
        (1018, "Vârful Ascuțit", 45.54531, 25.23192, 2150, "peak", 140),
        (1019, "Vârful Ciucaș", 45.52108, 25.92703, 1954, "peak", 1040),
        (1020, "Vârful Gropșoarele", 45.50214, 25.96136, 1883, "peak", 260),
        (1021, "Vârful Roșu (Iezer-Păpușa)", 45.50919, 24.94889, 2469, "peak", 690),
        (1022, "Vârful Păpușa (Iezer)", 45.48583, 25.00528, 2391, "peak", 460),
        (1023, "Vârful Cozia (Ciuha Mare)", 45.32100, 24.33700, 1668, "peak", 910),
        (1024, "Vârful Buila", 45.24211, 24.12281, 1849, "peak", 720),
        (1025, "Vârful Godeanu", 45.22250, 22.63361, 2229, "peak", 620),
        (1026, "Vârful Țarcu", 45.28139, 22.53389, 2190, "peak", 980),
        (1027, "Vârful Pietrosul Rodnei", 47.59819, 24.63614, 2303, "peak", 1565),
        (1028, "Vârful Ineu", 47.52556, 24.88389, 2279, "peak", 460),
        (1029, "Vârful Toaca (Ceahlău)", 46.97744, 25.94983, 1904, "peak", 1090),
        (1030, "Vârful Ocolașul Mare", 46.95314, 25.94558, 1907, "peak", 210),
        (1031, "Vârful Pietrosul Călimanilor", 47.11972, 25.18250, 2100, "peak", 1230),
        (1032, "Vârful Giumalău", 47.43500, 25.48361, 1857, "peak", 740),
        (1033, "Vârful Rarău", 47.45194, 25.57472, 1651, "peak", 490),
        (1034, "Vârful Hășmașul Mare", 46.69611, 25.81611, 1792, "peak", 670),
        (1035, "Vârful Harghita-Mădăraș", 46.45611, 25.57667, 1801, "peak", 790),
        (1036, "Vârful Bihorul Mare (Curcubăta Mare)", 46.44097, 22.68858, 1849, "peak", 1470),
        (1037, "Vârful Vlădeasa", 46.75917, 22.79417, 1836, "peak", 520),
        (1038, "Vârful Muntele Mare", 46.49111, 23.22917, 1826, "peak", 490),
        (1039, "Șaua Caprei", 45.60080, 24.62850, 2315, "pass", 90),
        (1040, "Curmătura Brătilei", 45.56800, 24.83900, 2122, "pass", 80),
        (1041, "Vârful Vânătarea lui Buteanu", 45.60417, 24.63056, 2507, "peak", 170),
        (1042, "Vârful Cornul Călțunului", 45.58139, 24.57361, 2505, "peak", 65),
        (1043, "Vârful Dara", 45.58917, 24.82861, 2500, "peak", 220),
        (1044, "Vârful Cindrel", 45.57972, 23.79444, 2244, "peak", 690),
        (1045, "Vârful Șureanu", 45.58250, 23.50722, 2059, "peak", 410),
        (1046, "Vârful Leaota", 45.32472, 25.30889, 2133, "peak", 700),
        (1047, "Vârful Fărcău", 47.89806, 24.45556, 1957, "peak", 880),
        (1048, "Vârful Pietrosul Maramureșului", 47.92194, 24.64611, 1850, "peak", 610),
        (1049, "Vârful Gutâi", 47.70028, 23.84889, 1443, "peak", 720),
        (1050, "Vârful Heniu Mare", 47.27389, 24.73528, 1611, "peak", 660),
        (1051, "Vârful Penteleu", 45.60528, 26.41611, 1772, "peak", 730),
        (1052, "Vârful Semenic", 45.18056, 22.05611, 1447, "peak", 580),
        (1053, "Pasul Urdele", 45.33583, 23.65806, 2145, "pass", 95),
        (1054, "Pasul Prislop", 47.60833, 24.85556, 1416, "pass", 110),
    ]
    return [RawPeakNode(*r) for r in rows]


def fetch_online_qlever_peaks(dem_dir: Path | None) -> list[RawPeakNode]:
    """Fetch real Romania OSM `natural=peak` and `natural=saddle` (`mountain_pass=yes`) via QLever SPARQL."""
    endpoint = "https://qlever.dev/api/osm-planet"
    query = (
        "PREFIX osmkey: <https://www.openstreetmap.org/wiki/Key:>\n"
        "PREFIX osmrel: <https://www.openstreetmap.org/relation/>\n"
        "PREFIX ogc: <http://www.opengis.net/rdf#>\n"
        "PREFIX geo: <http://www.opengis.net/ont/geosparql#>\n"
        "SELECT ?item ?nat ?mp ?name ?namero ?ele ?prom ?wkt WHERE {\n"
        "  {\n"
        '    ?item osmkey:natural ?nat . FILTER(?nat IN ("peak", "saddle"))\n'
        "    ?item osmkey:name ?name . ?item ogc:sfIntersects osmrel:90689 .\n"
        "  } UNION {\n"
        '    ?item osmkey:mountain_pass "yes" . BIND("yes" AS ?mp)\n'
        "    ?item osmkey:name ?name . ?item ogc:sfIntersects osmrel:90689 .\n"
        "  }\n"
        "  OPTIONAL { ?item osmkey:name:ro ?namero . }\n"
        "  OPTIONAL { ?item osmkey:ele ?ele . }\n"
        "  OPTIONAL { ?item osmkey:prominence ?prom . }\n"
        "  ?item geo:hasGeometry/geo:asWKT ?wkt .\n"
        "}"
    )
    req = urllib.request.Request(
        endpoint,
        data=urllib.parse.urlencode({"query": query}).encode("utf-8"),
        headers={
            "Accept": "application/sparql-results+json",
            "User-Agent": "WandererRO-PeaksBuilder/1.0",
        },
    )
    with urllib.request.urlopen(req, timeout=45, context=_SSL_CTX) as resp:
        data = json.loads(resp.read().decode("utf-8"))

    dem = None
    if dem_dir is not None:
        from dem_elevation import DemTileCache

        dem = DemTileCache(dem_dir)

    pending: list[tuple[int, str, float, float, float | None, str, float | None]] = []
    missing_tiles: set[tuple[int, int]] = set()
    seen_ids: set[int] = set()

    for b in data["results"]["bindings"]:
        uri = b["item"]["value"]
        try:
            osm_id = int(uri.rsplit("/", 1)[-1])
        except ValueError:
            continue
        if osm_id in seen_ids:
            continue
        pts = re.findall(r"(-?\d+\.\d+)\s+(-?\d+\.\d+)", b["wkt"]["value"])
        if not pts:
            continue
        lon = sum(float(x) for x, _ in pts) / len(pts)
        lat = sum(float(y) for _, y in pts) / len(pts)
        if not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
            continue
        seen_ids.add(osm_id)

        name = (b["namero"]["value"] if "namero" in b else b["name"]["value"]).strip()
        nat = b["nat"]["value"] if "nat" in b else ""
        is_pass = ("mp" in b) or (nat == "saddle")
        kind = "pass" if is_pass and nat != "peak" else "peak"
        ele = parse_osm_elevation_meters(b["ele"]["value"]) if "ele" in b else None
        prom = parse_osm_elevation_meters(b["prom"]["value"]) if "prom" in b else None
        if ele is None:
            missing_tiles.add((int(math.floor(lat)), int(math.floor(lon))))
        pending.append((osm_id, name, lat, lon, ele, kind, prom))

    if dem is not None and missing_tiles:
        dem.ensure_tiles(missing_tiles)

    out: list[RawPeakNode] = []
    for osm_id, name, lat, lon, ele, kind, prom in pending:
        final_ele = ele
        if final_ele is None and dem is not None:
            final_ele = dem.sample(lat, lon)
        if final_ele is None:
            continue
        out.append(
            RawPeakNode(
                osm_id=osm_id,
                name=name,
                lat=lat,
                lon=lon,
                ele=final_ele,
                kind=kind,
                prominence_override=prom,
            )
        )
    return out


def extract_from_pbf(pbf_path: Path, dem_dir: Path | None) -> list[RawPeakNode]:
    import osmium
    from dem_elevation import DemTileCache

    dem = DemTileCache(dem_dir) if dem_dir is not None else None
    extracted: list[RawPeakNode] = []

    class PeakHandler(osmium.SimpleHandler):
        def node(self, n: osmium.osm.Node) -> None:
            if not n.location.valid():
                return
            tags = n.tags
            nat = tags.get("natural")
            is_pass = tags.get("mountain_pass") == "yes" or nat == "saddle"
            if nat != "peak" and not is_pass:
                return
            name = tags.get("name:ro") or tags.get("name")
            if not name:
                return
            lat = n.location.lat
            lon = n.location.lon
            if not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
                return
            ele = parse_osm_elevation_meters(tags.get("ele"))
            if ele is None and dem is not None:
                ele = dem.sample(lat, lon)
            if ele is None:
                return
            prom = parse_osm_elevation_meters(tags.get("prominence"))
            extracted.append(
                RawPeakNode(
                    osm_id=int(n.id),
                    name=name,
                    lat=lat,
                    lon=lon,
                    ele=ele,
                    kind="pass" if is_pass and nat != "peak" else "peak",
                    prominence_override=prom,
                )
            )

    PeakHandler().apply_file(str(pbf_path), locations=True)
    return extracted


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pbf", type=Path, help="Path to romania-latest.osm.pbf")
    parser.add_argument("--online", action="store_true", help="Fetch real Romania OSM peaks & saddles via QLever")
    parser.add_argument("--dem-dir", type=Path, default=None, help="Optional SRTM .hgt cache directory")
    parser.add_argument("--min-ele", type=float, default=600.0, help="Minimum summit/pass elevation in meters")
    parser.add_argument("--seed-curated", action="store_true", help="Emit curated Carpathian seed catalog")
    parser.add_argument(
        "--out",
        type=Path,
        action="append",
        required=True,
        help="Output JSON file path(s)",
    )
    args = parser.parse_args()

    nodes = curated_carpathian_seed_peaks()
    if args.pbf and args.pbf.exists():
        pbf_nodes = extract_from_pbf(args.pbf, args.dem_dir)
        nodes = nodes + pbf_nodes
    elif args.online:
        try:
            online_nodes = fetch_online_qlever_peaks(args.dem_dir)
            print(f"[peaks] Fetched {len(online_nodes)} Romania OSM peaks & saddles online.")
            nodes = nodes + online_nodes
        except Exception as exc:  # noqa: BLE001
            print(f"[peaks] Warning: online OSM query failed ({exc}); using curated Carpathian catalog.", file=sys.stderr)
            if not args.seed_curated:
                pass
    elif not args.seed_curated:
        raise SystemExit("Pass an existing --pbf, --online, or --seed-curated")

    min_ele = 400.0 if (args.seed_curated and not args.online and not (args.pbf and args.pbf.exists())) else args.min_ele
    catalog = build_columnar_catalog(nodes, min_ele_m=min_ele)
    payload = json.dumps(catalog, ensure_ascii=False, separators=(",", ":"))
    for out_path in args.out:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(payload, encoding="utf-8")
        print(f"[peaks] Wrote {catalog['count']} entries ({len(payload.encode('utf-8'))} bytes) -> {out_path}")


if __name__ == "__main__":
    main()
