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
from typing import Iterable

import osmium

RO_LAT_MIN, RO_LAT_MAX = 43.4, 48.5
RO_LON_MIN, RO_LON_MAX = 20.0, 30.0
MIN_DISTANCE_METERS = 400.0
STITCH_GAP_METERS = 35.0
DOWNSAMPLE_STEP_METERS = 10.0

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
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))


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


def build_gpx_xml(name: str, desc: str, segments: list[list[tuple[float, float]]]) -> str:
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
        for lon, lat in seg:
            lines.append(f'      <trkpt lat="{lat:.6f}" lon="{lon:.6f}"></trkpt>')
        lines.append("    </trkseg>")
    lines.extend(["  </trk>", "</gpx>", ""])
    return "\n".join(lines)


class RelationCollector(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.relations: list[dict] = []
        self.needed_ways: set[int] = set()

    def relation(self, r: osmium.osm.Relation) -> None:
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


class WayGeometryCollector(osmium.SimpleHandler):
    def __init__(self, needed_ways: set[int]) -> None:
        super().__init__()
        self.needed_ways = needed_ways
        self.ways: dict[int, list[tuple[float, float]]] = {}

    def way(self, w: osmium.osm.Way) -> None:
        wid = int(w.id)
        if wid not in self.needed_ways:
            return
        coords: list[tuple[float, float]] = []
        for n in w.nodes:
            if n.location.valid():
                lat = n.lat
                lon = n.lon
                if RO_LAT_MIN <= lat <= RO_LAT_MAX and RO_LON_MIN <= lon <= RO_LON_MAX:
                    coords.append((lon, lat))
        if len(coords) >= 2:
            self.ways[wid] = coords


def build_trail_record(rel: dict, ways: dict[int, list[tuple[float, float]]]) -> tuple[dict, str] | None:
    rel_id: int = rel["id"]
    tags: dict[str, str] = rel["tags"]
    route_type = tags.get("route", "hiking")

    way_coords = [ways[wid] for wid in rel["way_ids"] if wid in ways]
    if not way_coords:
        return None

    raw_segments = stitch_ways(way_coords)
    segments = [downsample_segment(seg) for seg in raw_segments if len(seg) >= 2]
    if not segments:
        return None

    distance_m = sum(segment_distance(seg) for seg in segments)
    if distance_m < MIN_DISTANCE_METERS:
        return None

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
        difficulty = "moderate" if (distance_m >= 5000.0 or marking is not None) else "easy"

    category_name = "Biking" if route_type == "mtb" else "Hiking"
    speed_kmh = 10.0 if route_type == "mtb" else 3.5
    duration_s = max(60, int(round((distance_m / 1000.0) / speed_kmh * 3600.0)))

    all_pts = [pt for seg in segments for pt in seg]
    lons = [p[0] for p in all_pts]
    lats = [p[1] for p in all_pts]
    start_lon, start_lat = segments[0][0]

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
    if operator:
        desc_parts.append(f"<p><strong>Operator / Întreținere:</strong> {html.escape(operator)}</p>")
    if network in NETWORK_LABELS:
        desc_parts.append(f"<p><strong>Rețea:</strong> {html.escape(NETWORK_LABELS[network])}</p>")
    if tags.get("description:ro") or tags.get("description"):
        raw_desc = (tags.get("description:ro") or tags.get("description") or "").strip()
        desc_parts.append(f"<p>{html.escape(raw_desc[:600])}</p>")
    desc_parts.append(f"<p><small>Sursă: OpenStreetMap (osm:relation:{rel_id})</small></p>")
    description_html = "\n".join(desc_parts)

    plain_desc = f"{marking + ' | ' if marking else ''}{distance_m / 1000.0:.2f} km | osm:relation:{rel_id}"
    gpx_xml = build_gpx_xml(name, plain_desc, segments)

    record = {
        "rel_id": rel_id,
        "name": name,
        "description": description_html,
        "location": location,
        "distance": round(distance_m, 2),
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
        "gpx_rel_path": f"gpx/{rel_id}.gpx",
    }
    return record, gpx_xml


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract Romanian hiking/MTB trails from OSM PBF.")
    parser.add_argument("--pbf", required=True, help="Path to romania-latest.osm.pbf")
    parser.add_argument("--out-dir", required=True, help="Output directory for GPX + manifest")
    parser.add_argument("--tarball", required=False, help="Optional .tar.gz output path")
    args = parser.parse_args()

    pbf_path = Path(args.pbf).resolve()
    out_dir = Path(args.out_dir).resolve()
    gpx_dir = out_dir / "gpx"
    gpx_dir.mkdir(parents=True, exist_ok=True)

    print(f"[Pass 1] Scanning route relations in {pbf_path}...")
    rel_collector = RelationCollector()
    rel_collector.apply_file(str(pbf_path))
    print(f"[Pass 1] Found {len(rel_collector.relations)} candidate relations using {len(rel_collector.needed_ways)} ways.")

    print("[Pass 2] Extracting way node coordinates inside Romania...")
    way_collector = WayGeometryCollector(rel_collector.needed_ways)
    way_collector.apply_file(str(pbf_path), locations=True, idx="flex_mem")
    print(f"[Pass 2] Resolved geometries for {len(way_collector.ways)} ways.")

    manifest_path = out_dir / "manifest.jsonl"
    exported = 0
    skipped = 0

    with manifest_path.open("w", encoding="utf-8") as mf:
        for rel in rel_collector.relations:
            res = build_trail_record(rel, way_collector.ways)
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
