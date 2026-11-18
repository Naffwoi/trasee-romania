#!/usr/bin/env python3
"""Extract marked hiking, foot, and MTB trail relations in Romania from an OSM PBF file.

Produces clean GPX 1.1 files (`gpx/<rel_id>.gpx`), a `manifest.jsonl` index with
normalized Romanian tourist markings (`Bandă Roșie`, `Cruce Albastră`, etc.),
and a compressed tarball (`romania_trails_bundle.tar.gz`) ready for import into
Wanderer's PocketBase + Meilisearch backend.
"""

from __future__ import annotations

import argparse
import html
import json
import math
import os
import re
import tarfile
import xml.sax.saxutils as saxutils
from pathlib import Path
from typing import Any, Iterable

try:
    import osmium

    _SimpleHandlerBase: type[Any] = osmium.SimpleHandler
except ImportError:
    osmium = None  # type: ignore[assignment]
    _SimpleHandlerBase = object

from dem_elevation import DemTileCache, enrich_segments_with_elevation

RO_LAT_MIN, RO_LAT_MAX = 43.4, 48.5
RO_LON_MIN, RO_LON_MAX = 20.0, 30.0
MIN_DISTANCE_METERS = 400.0
STITCH_GAP_METERS = 35.0
DOWNSAMPLE_STEP_METERS = 10.0
MAX_RAIL_ACCESS_METERS = 2000.0
GORGE_NAME_RE = re.compile(
    r"\b(cheile|canionul|canion|defileul|vale[ai]\s+cernei|vale[ai]\s+lui\s+stan)\b",
    re.IGNORECASE,
)

IGNORED_MEMBER_ROLES = {"platform", "stop", "guidepost", "marker", "signpost"}

OSMC_COLOR_RO = {
    "red": "Roșu",
    "yellow": "Galben",
    "blue": "Albastru",
    "green": "Verde",
    "black": "Negru",
    "orange": "Portocaliu",
    "white": "Alb",
}

OSMC_COLOR_RO_FEM = {
    "red": "Roșie",
    "yellow": "Galbenă",
    "blue": "Albastră",
    "green": "Verde",
    "black": "Neagră",
    "orange": "Portocalie",
    "white": "Albă",
}

OSMC_SHAPE_MAP = {
    "stripe": ("Bandă", True),
    "bar": ("Bandă", True),
    "cross": ("Cruce", True),
    "triangle": ("Triunghi", False),
    "dot": ("Punct", False),
    "circle": ("Punct", False),
    "disc": ("Punct", False),
}

SAC_DIFFICULTY_MAP = {
    "hiking": "easy",
    "mountain_hiking": "moderate",
    "demanding_mountain_hiking": "difficult",
    "alpine_hiking": "difficult",
    "demanding_alpine_hiking": "difficult",
    "difficult_alpine_hiking": "difficult",
}

NETWORK_LABELS = {
    "iwn": "Traseu Internațional",
    "nwn": "Traseu Național",
    "rwn": "Traseu Regional",
    "lwn": "Traseu Local",
    "icn": "Cicloturism Internațional",
    "ncn": "Cicloturism Național",
    "rcn": "Cicloturism Regional",
    "lcn": "Cicloturism Local",
}


def haversine_meters(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
    r = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2.0) ** 2
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))


def normalize_station_name(raw_name: str) -> str:
    cleaned = re.sub(
        r"^(Gara\s+CFR\s+|Gara\s+|Halta\s+|Stația\s+)",
        "",
        raw_name.strip(),
        flags=re.IGNORECASE,
    ).strip()
    return cleaned or raw_name.strip()


def is_valid_passenger_rail_stop(tags: dict[str, str]) -> bool:
    railway = tags.get("railway", "").strip().lower()
    if railway not in ("station", "halt"):
        return False
    if tags.get("station", "").strip().lower() in ("subway", "light_rail", "monorail"):
        return False
    if tags.get("subway", "").strip().lower() == "yes":
        return False
    if tags.get("usage", "").strip().lower() in ("industrial", "military", "tourism", "freight"):
        return False
    if "disused:railway" in tags or "abandoned:railway" in tags or tags.get("disused") == "yes":
        return False
    return bool((tags.get("name:ro") or tags.get("name") or "").strip())


def find_nearest_rail_stop(
    endpoints: list[tuple[float, float]],
    stops: list[dict[str, Any]],
    max_distance_m: float = MAX_RAIL_ACCESS_METERS,
) -> dict[str, Any] | None:
    if not endpoints or not stops:
        return None
    best: dict[str, Any] | None = None
    best_dist = max_distance_m + 1.0
    for lon, lat in endpoints:
        for st in stops:
            if abs(st["lat"] - lat) > 0.025 or abs(st["lon"] - lon) > 0.035:
                continue
            d = haversine_meters(lon, lat, st["lon"], st["lat"])
            if d <= max_distance_m and d < best_dist:
                best_dist = d
                best = {
                    "name": normalize_station_name(st["name"]),
                    "lat": round(st["lat"], 6),
                    "lon": round(st["lon"], 6),
                    "distance_m": round(d, 1),
                }
    return best


def detect_water_gorge(
    name: str,
    tags: dict[str, str],
    all_pts: list[tuple[float, float]],
    gorge_pts: list[tuple[float, float]],
) -> bool:
    haystack = f"{name} {tags.get('description:ro', '')} {tags.get('description', '')}"
    if GORGE_NAME_RE.search(haystack):
        return True
    if not gorge_pts or not all_pts:
        return False
    hits = 0
    step = max(1, len(all_pts) // 25)
    for lon, lat in all_pts[::step]:
        for glon, glat in gorge_pts:
            if (
                abs(glat - lat) <= 0.0015
                and abs(glon - lon) <= 0.002
                and haversine_meters(lon, lat, glon, glat) <= 90.0
            ):
                hits += 1
                if hits >= 2:
                    return True
                break
    return False


def parse_osmc_marking(osmc: str | None) -> str | None:
    if not osmc:
        return None
    parts = osmc.split(":")
    # Standard OSMC syntax: waycolor:background:foreground[:text[:textcolor]]
    fg = parts[2].strip().lower() if len(parts) >= 3 else osmc.strip().lower()
    if not fg:
        return None
    m = re.match(r"^([a-z]+)_(stripe|bar|cross|triangle|dot|circle|disc)$", fg)
    if not m:
        return None
    color_en, shape_en = m.group(1), m.group(2)
    shape_ro, feminine = OSMC_SHAPE_MAP[shape_en]
    color_ro = (OSMC_COLOR_RO_FEM if feminine else OSMC_COLOR_RO).get(color_en)
    if not color_ro:
        return None
    return f"{shape_ro} {color_ro}"


def stitch_ways(way_coords_list: list[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    segments: list[list[tuple[float, float]]] = []
    single_way_segment = False

    for raw_pts in way_coords_list:
        if len(raw_pts) < 2:
            continue
        pts = list(raw_pts)
        if not segments:
            segments.append(pts)
            single_way_segment = True
            continue

        cur = segments[-1]
        cur_start = cur[0]
        cur_end = cur[-1]
        p_start = pts[0]
        p_end = pts[-1]

        d_end_start = haversine_meters(cur_end[0], cur_end[1], p_start[0], p_start[1])
        d_end_end = haversine_meters(cur_end[0], cur_end[1], p_end[0], p_end[1])

        if d_end_start <= STITCH_GAP_METERS:
            cur.extend(pts[1:] if d_end_start < 1.0 else pts)
            single_way_segment = False
            continue
        if d_end_end <= STITCH_GAP_METERS:
            rev = list(reversed(pts))
            cur.extend(rev[1:] if d_end_end < 1.0 else rev)
            single_way_segment = False
            continue

        if single_way_segment:
            d_start_start = haversine_meters(cur_start[0], cur_start[1], p_start[0], p_start[1])
            d_start_end = haversine_meters(cur_start[0], cur_start[1], p_end[0], p_end[1])
            if d_start_start <= STITCH_GAP_METERS:
                cur.reverse()
                cur.extend(pts[1:] if d_start_start < 1.0 else pts)
                single_way_segment = False
                continue
            if d_start_end <= STITCH_GAP_METERS:
                cur.reverse()
                rev = list(reversed(pts))
                cur.extend(rev[1:] if d_start_end < 1.0 else rev)
                single_way_segment = False
                continue

        segments.append(pts)
        single_way_segment = True

    return segments


def downsample_segment(pts: list[tuple[float, float]], min_step_m: float = DOWNSAMPLE_STEP_METERS) -> list[tuple[float, float]]:
    if len(pts) <= 2:
        return pts
    kept = [pts[0]]
    last_lon, last_lat = pts[0]
    for lon, lat in pts[1:-1]:
        if haversine_meters(last_lon, last_lat, lon, lat) >= min_step_m:
            kept.append((lon, lat))
            last_lon, last_lat = lon, lat
    if pts[-1] != kept[-1]:
        kept.append(pts[-1])
    return kept


def segment_distance(pts: Iterable[tuple[float, float]]) -> float:
    total = 0.0
    prev: tuple[float, float] | None = None
    for pt in pts:
        if prev is not None:
            total += haversine_meters(prev[0], prev[1], pt[0], pt[1])
        prev = pt
    return total


def build_gpx_xml(name: str, desc: str, segments: list[list[tuple[float, float, float | None]]]) -> str:
    safe_name = saxutils.escape(name)
    safe_desc = saxutils.escape(desc)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<gpx version="1.1" creator="Wanderer Romania OSM Extractor" xmlns="http://www.topografix.com/GPX/1/1">',
        "  <metadata>",
        f"    <name>{safe_name}</name>",
        f"    <desc>{safe_desc}</desc>",
        "  </metadata>",
        "  <trk>",
        f"    <name>{safe_name}</name>",
    ]
    for seg in segments:
        lines.append("    <trkseg>")
        for lon, lat, ele in seg:
            if ele is not None:
                lines.append(f'      <trkpt lat="{lat:.6f}" lon="{lon:.6f}"><ele>{ele:.1f}</ele></trkpt>')
            else:
                lines.append(f'      <trkpt lat="{lat:.6f}" lon="{lon:.6f}"></trkpt>')
        lines.append("    </trkseg>")
    lines.extend(["  </trk>", "</gpx>", ""])
    return "\n".join(lines)


class RelationCollector(_SimpleHandlerBase):
    def __init__(self) -> None:
        super().__init__()
        self.relations: list[dict[str, Any]] = []
        self.needed_ways: set[int] = set()

    def relation(self, r: Any) -> None:
        tags = {t.k: t.v for t in r.tags}
        if tags.get("type") != "route":
            return
        route_type = tags.get("route", "")
        if route_type not in ("hiking", "foot", "mtb"):
            return

        way_ids: list[int] = []
        for m in r.members:
            if m.type == "w" and m.role not in IGNORED_MEMBER_ROLES:
                way_ids.append(m.ref)
                self.needed_ways.add(m.ref)

        if way_ids:
            self.relations.append({"id": int(r.id), "tags": tags, "way_ids": way_ids})


class WayGeometryCollector(_SimpleHandlerBase):
    def __init__(self, needed_ways: set[int]) -> None:
        super().__init__()
        self.needed_ways = needed_ways
        self.ways: dict[int, list[tuple[float, float]]] = {}
        self.rail_stops: list[dict[str, Any]] = []
        self.gorge_pts: list[tuple[float, float]] = []

    def node(self, n: Any) -> None:
        if not n.tags or not n.location.valid():
            return
        lat, lon = n.location.lat, n.location.lon
        if not (RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX):
            return
        tags = {t.k: t.v for t in n.tags}
        if is_valid_passenger_rail_stop(tags):
            self.rail_stops.append({
                "name": (tags.get("name:ro") or tags.get("name") or "").strip(),
                "lat": lat,
                "lon": lon,
            })
        elif tags.get("natural") in ("gorge", "canyon"):
            self.gorge_pts.append((lon, lat))

    def way(self, w: Any) -> None:
        wid = int(w.id)
        tags = {t.k: t.v for t in w.tags} if w.tags else {}
        is_rail = is_valid_passenger_rail_stop(tags)
        is_gorge = tags.get("natural") in ("gorge", "canyon")
        if wid not in self.needed_ways and not is_rail and not is_gorge:
            return
        coords: list[tuple[float, float]] = []
        for n in w.nodes:
            if n.location.valid():
                lat = n.lat
                lon = n.lon
                if RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX:
                    coords.append((lon, lat))
        if wid in self.needed_ways and len(coords) >= 2:
            self.ways[wid] = coords
        if is_rail and coords:
            mid = coords[len(coords) // 2]
            self.rail_stops.append({
                "name": (tags.get("name:ro") or tags.get("name") or "").strip(),
                "lat": mid[1],
                "lon": mid[0],
            })
        if is_gorge and coords:
            self.gorge_pts.extend(coords[::max(1, len(coords) // 5)])


def build_trail_record(
    rel: dict[str, Any],
    ways: dict[int, list[tuple[float, float]]],
    dem: DemTileCache,
    rail_stops: list[dict[str, Any]] | None = None,
    gorge_pts: list[tuple[float, float]] | None = None,
) -> tuple[dict[str, Any], str] | None:
    rel_id: int = rel["id"]
    tags: dict[str, str] = rel["tags"]
    route_type = tags.get("route", "hiking")

    way_coords = [ways[wid] for wid in rel["way_ids"] if wid in ways]
    if not way_coords:
        return None

    raw_segments = stitch_ways(way_coords)
    segments_2d = [downsample_segment(seg) for seg in raw_segments if len(seg) >= 2]
    if not segments_2d:
        return None

    distance_m = sum(segment_distance(seg) for seg in segments_2d)
    if distance_m < MIN_DISTANCE_METERS:
        return None

    segments, ele_metrics = enrich_segments_with_elevation(segments_2d, dem)
    elevation_gain = int(ele_metrics["elevation_gain"])
    elevation_loss = int(ele_metrics["elevation_loss"])
    min_ele = int(ele_metrics["min_ele"])
    max_ele = int(ele_metrics["max_ele"])
    start_ele = int(ele_metrics["start_ele"])
    end_ele = int(ele_metrics["end_ele"])

    marking = parse_osmc_marking(tags.get("osmc:symbol"))
    from_tag = tags.get("from", "").strip()
    to_tag = tags.get("to", "").strip()
    ref_tag = tags.get("ref", "").strip()
    name = (tags.get("name:ro") or tags.get("name") or "").strip()
    if not name:
        if from_tag and to_tag:
            name = f"{from_tag} – {to_tag}"
        elif ref_tag and marking:
            name = f"Traseu {ref_tag} ({marking})"
        elif ref_tag:
            name = f"Traseu {ref_tag}"
        else:
            return None

    # Truncate overly long names safely for UI readability
    if len(name) > 180:
        name = name[:177].rstrip() + "..."

    network = tags.get("network", "").strip().lower()
    operator = tags.get("operator", "").strip()
    sac_scale = tags.get("sac_scale", "").strip().lower()
    combined_meta = f"{name} {network} {operator} {tags.get('description', '')}".lower()

    trail_tags: list[str] = ["România"]
    if marking:
        trail_tags.append(marking)
    if "via transilvanica" in combined_meta:
        trail_tags.append("Via Transilvanica")
    if route_type == "mtb":
        trail_tags.append("MTB")
    if network in NETWORK_LABELS:
        trail_tags.append(NETWORK_LABELS[network])

    difficulty = SAC_DIFFICULTY_MAP.get(sac_scale)
    if not difficulty:
        if elevation_gain >= 900 or distance_m >= 18000.0:
            difficulty = "difficult"
        elif elevation_gain >= 250 or distance_m >= 5000.0 or marking is not None:
            difficulty = "moderate"
        else:
            difficulty = "easy"

    category_name = "Biking" if route_type == "mtb" else "Hiking"
    if route_type == "mtb":
        hours = (distance_m / 12000.0) + (elevation_gain / 800.0)
    else:
        hours = (distance_m / 4000.0) + (elevation_gain / 600.0)
    duration_s = max(60, int(round(hours * 3600.0)))

    all_pts = [pt for seg in segments_2d for pt in seg]
    lons = [p[0] for p in all_pts]
    lats = [p[1] for p in all_pts]
    start_lon, start_lat = segments_2d[0][0]
    end_lon, end_lat = segments_2d[-1][-1]

    rail_match = find_nearest_rail_stop(
        [(start_lon, start_lat), (end_lon, end_lat)],
        rail_stops or [],
        MAX_RAIL_ACCESS_METERS,
    )
    if rail_match:
        trail_tags.append("Cu trenul")
    is_water_gorge = detect_water_gorge(name, tags, all_pts, gorge_pts or [])

    location = (
        tags.get("addr:city")
        or tags.get("is_in:county")
        or tags.get("is_in")
        or from_tag
        or "România"
    ).strip()
    if len(location) > 120:
        location = location[:117] + "..."

    desc_parts: list[str] = []
    if marking:
        desc_parts.append(f"<p><strong>Marcaj turistic:</strong> {html.escape(marking)}</p>")
    if from_tag or to_tag:
        route_str = f"{from_tag or '?'} → {to_tag or '?'}"
        desc_parts.append(f"<p><strong>Traseu:</strong> {html.escape(route_str)}</p>")
    desc_parts.append(f"<p><strong>Lungime:</strong> {distance_m / 1000.0:.2f} km</p>")
    if max_ele > 0 or elevation_gain > 0:
        desc_parts.append(
            f"<p><strong>Altitudine:</strong> {start_ele} m → {end_ele} m (Vârf: {max_ele} m)</p>"
        )
        desc_parts.append(
            f"<p><strong>Diferență de nivel:</strong> +{elevation_gain} m / -{elevation_loss} m</p>"
        )
    if operator:
        desc_parts.append(f"<p><strong>Operator / Întreținere:</strong> {html.escape(operator)}</p>")
    if network in NETWORK_LABELS:
        desc_parts.append(f"<p><strong>Rețea:</strong> {html.escape(NETWORK_LABELS[network])}</p>")
    if rail_match:
        desc_parts.append(
            f"<p><strong>Acces cu trenul:</strong> Gara {html.escape(rail_match['name'])} "
            f"({int(round(rail_match['distance_m']))} m)</p>"
        )
    if tags.get("description:ro") or tags.get("description"):
        raw_desc = (tags.get("description:ro") or tags.get("description") or "").strip()
        desc_parts.append(f"<p>{html.escape(raw_desc[:600])}</p>")
    desc_parts.append(f"<p><small>Sursă: OpenStreetMap (osm:relation:{rel_id})</small></p>")
    description_html = "\n".join(desc_parts)

    plain_desc = (
        f"{marking + ' | ' if marking else ''}{distance_m / 1000.0:.2f} km | "
        f"+{elevation_gain}m / -{elevation_loss}m | osm:relation:{rel_id}"
    )
    gpx_xml = build_gpx_xml(name, plain_desc, segments)

    record = {
        "rel_id": rel_id,
        "name": name,
        "description": description_html,
        "location": location,
        "distance": round(distance_m, 2),
        "elevation_gain": elevation_gain,
        "elevation_loss": elevation_loss,
        "min_ele": min_ele,
        "max_ele": max_ele,
        "duration": duration_s,
        "difficulty": difficulty,
        "category": category_name,
        "tags": list(dict.fromkeys(trail_tags)),
        "lat": round(start_lat, 6),
        "lon": round(start_lon, 6),
        "min_lat": round(min(lats), 6),
        "max_lat": round(max(lats), 6),
        "min_lon": round(min(lons), 6),
        "max_lon": round(max(lons), 6),
        "train_accessible": bool(rail_match),
        "rail_station_name": rail_match["name"] if rail_match else "",
        "rail_station_distance_m": int(round(rail_match["distance_m"])) if rail_match else 0,
        "rail_station_lat": rail_match["lat"] if rail_match else 0.0,
        "rail_station_lon": rail_match["lon"] if rail_match else 0.0,
        "is_water_gorge": is_water_gorge,
        "gpx_rel_path": f"gpx/{rel_id}.gpx",
    }
    return record, gpx_xml


def main() -> None:
    if osmium is None:
        raise RuntimeError("pyosmium ('osmium' package) is required to scan .osm.pbf files.")

    parser = argparse.ArgumentParser(description="Extract Romanian hiking/MTB trails from OSM PBF.")
    parser.add_argument("--pbf", required=True, help="Path to romania-latest.osm.pbf")
    parser.add_argument("--out-dir", required=True, help="Output directory for GPX + manifest")
    parser.add_argument("--dem-dir", required=False, help="Cache directory for SRTM .hgt DEM tiles")
    parser.add_argument("--tarball", required=False, help="Optional .tar.gz output path")
    args = parser.parse_args()

    pbf_path = Path(args.pbf).resolve()
    out_dir = Path(args.out_dir).resolve()
    dem_dir = Path(args.dem_dir).resolve() if args.dem_dir else (out_dir.parent / "dem")
    gpx_dir = out_dir / "gpx"
    gpx_dir.mkdir(parents=True, exist_ok=True)

    print(f"[Pass 1] Scanning route relations in {pbf_path}...")
    rel_collector = RelationCollector()
    rel_collector.apply_file(str(pbf_path))
    print(f"[Pass 1] Found {len(rel_collector.relations)} candidate relations using {len(rel_collector.needed_ways)} ways.")

    print("[Pass 2] Extracting way node coordinates, CFR passenger stops, and gorges inside Romania...")
    way_collector = WayGeometryCollector(rel_collector.needed_ways)
    way_collector.apply_file(str(pbf_path), locations=True, idx="flex_mem")
    print(
        f"[Pass 2] Resolved {len(way_collector.ways)} ways, "
        f"{len(way_collector.rail_stops)} passenger rail stops, "
        f"{len(way_collector.gorge_pts)} gorge nodes."
    )

    tiles_needed: set[tuple[int, int]] = set()
    for pts in way_collector.ways.values():
        for lon, lat in pts:
            tiles_needed.add((int(math.floor(lat)), int(math.floor(lon))))
    dem = DemTileCache(dem_dir)
    dem.ensure_tiles(tiles_needed)

    manifest_path = out_dir / "manifest.jsonl"
    exported = 0
    skipped = 0

    with manifest_path.open("w", encoding="utf-8") as mf:
        for rel in rel_collector.relations:
            res = build_trail_record(
                rel,
                way_collector.ways,
                dem,
                way_collector.rail_stops,
                way_collector.gorge_pts,
            )
            if res is None:
                skipped += 1
                continue
            record, gpx_xml = res
            gpx_file = out_dir / record["gpx_rel_path"]
            gpx_file.write_text(gpx_xml, encoding="utf-8")
            mf.write(json.dumps(record, ensure_ascii=False) + "\n")
            exported += 1

    print(f"[Done] Exported {exported} Romanian trails to {out_dir} (skipped {skipped} <400m/unnamed/out-of-bounds).")

    if args.tarball:
        tar_path = Path(args.tarball).resolve()
        tar_path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(tar_path, "w:gz") as tf:
            tf.add(manifest_path, arcname="manifest.jsonl")
            tf.add(gpx_dir, arcname="gpx")
        size_mb = os.path.getsize(tar_path) / (1024 * 1024)
        print(f"[Bundle] Created {tar_path} ({size_mb:.2f} MB)")


if __name__ == "__main__":
    main()
