#!/usr/bin/env python3
"""Enrich PocketBase trails that lack real photos using Wikimedia Commons.

Uses Wikimedia Commons geosearch (strictly constrained inside Romania's
bounding box) and free-license validation (CC0, CC BY, CC BY-SA, Public domain)
plus an optional fast-path mapping to the curated local Carpathian dataset in
data/location_photos/manifest.json. Uploading real images to `trails.photos`
causes PocketBase's routeimage hook (`DropPlaceholder`) to remove the grey
placeholder SVG automatically.
"""

from __future__ import annotations

import argparse
import http.client
import json
import math
import os
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

COMMONS_API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "WandererRomaniaTrailEnricher/1.0 (https://trasee.skillfy.ro)"

RO_LAT_MIN = 43.6
RO_LAT_MAX = 48.3
RO_LON_MIN = 20.2
RO_LON_MAX = 29.7

FREE_LICENSE_MARKERS = ("cc0", "cc-by", "cc by", "public domain", "pd")
EXCLUDED_TITLE_TOKENS = (
    ".svg",
    "coat of arms",
    "stema",
    "flag",
    "map",
    "harta",
    "location map",
    "locator",
    "diagram",
    "logo",
    "iss0",
    "view of earth",
    "landsat",
    "sentinel",
)

CARPATHIAN_KEYWORDS: list[tuple[tuple[str, ...], str]] = [
    (("tamina",), "cascada_tamina"),
    (("7 scari", "sapte scari"), "canionul_7_scari"),
    (("piatra mare", "dambu morii", "timisu", "familiar"), "varful_piatra_mare"),
    (("predeal", "clabucet", "fetifoiu", "sipote", "susai", "garbova"), "predeal_clabucet"),
    (("postavaru", "poiana brasov", "tampa", "rasnov", "cristian"), "postavarul"),
    (("ciucas", "bratocea", "muntele rosu", "cheia", "tigailor"), "varful_ciucas"),
    (("piatra craiului", "zarnesti", "prapastiile", "curmatura", "ascutit", "magura"), "piatra_craiului"),
    (("bucegi", "omu", "caraiman", "babele", "busteni", "sinaia", "diham", "malaiesti"), "cabana_carpati"),
]


def is_in_romania_bbox(lat: float, lon: float) -> bool:
    return (
        math.isfinite(lat)
        and math.isfinite(lon)
        and RO_LAT_MIN <= lat <= RO_LAT_MAX
        and RO_LON_MIN <= lon <= RO_LON_MAX
    )


def is_placeholder_photo(name: str | None) -> bool:
    if not name:
        return True
    cleaned = name.strip()
    return not cleaned or "wanderer_route_placeholder" in cleaned


def is_acceptable_commons_title(title: str) -> bool:
    lower = title.strip().lower()
    if not any(lower.endswith(ext) for ext in (".jpg", ".jpeg", ".png", ".webp")):
        return False
    return not any(tok in lower for tok in EXCLUDED_TITLE_TOKENS)


def is_free_license(license_short_name: str | None) -> bool:
    if not license_short_name:
        return False
    lower = license_short_name.strip().lower()
    if "nc" in lower or "nd" in lower or "fair use" in lower or "copyrighted" in lower:
        return False
    return any(marker in lower for marker in FREE_LICENSE_MARKERS)


def fold_diacritics(text: str) -> str:
    return (
        text.lower()
        .replace("ă", "a")
        .replace("â", "a")
        .replace("î", "i")
        .replace("ș", "s")
        .replace("ş", "s")
        .replace("ț", "t")
        .replace("ţ", "t")
    )


def match_curated_slug(name: str, location: str = "") -> str | None:
    haystack = fold_diacritics(f"{name} {location}")
    for keywords, slug in CARPATHIAN_KEYWORDS:
        if any(k in haystack for k in keywords):
            return slug
    return None


def http_get_bytes(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.URLError, ssl.SSLError):
        # Fallback to macOS/system curl (--http1.1 avoids CDN H2 stream resets).
        result = subprocess.run(
            ["/usr/bin/curl", "-fsSL", "--http1.1", "-A", USER_AGENT, "--max-time", str(timeout), url],
            check=True,
            capture_output=True,
        )
        return result.stdout


def http_get_json(url: str, timeout: int = 30) -> dict[str, Any]:
    raw = http_get_bytes(url, timeout=timeout)
    return json.loads(raw.decode("utf-8"))


def commons_geosearch_photo(
    lat: float,
    lon: float,
    radius_m: int = 10000,
) -> dict[str, Any] | None:
    if not is_in_romania_bbox(lat, lon):
        return None
    params = urllib.parse.urlencode(
        {
            "action": "query",
            "list": "geosearch",
            "gscoord": f"{lat:.5f}|{lon:.5f}",
            "gsradius": str(min(10000, max(500, radius_m))),
            "gsnamespace": "6",
            "gslimit": "15",
            "format": "json",
        }
    )
    geo_res = http_get_json(f"{COMMONS_API}?{params}")
    candidates = [
        item
        for item in geo_res.get("query", {}).get("geosearch", [])
        if is_in_romania_bbox(float(item.get("lat", 0.0)), float(item.get("lon", 0.0)))
        and is_acceptable_commons_title(item.get("title", ""))
    ]
    if not candidates:
        return None

    titles = "|".join(item["title"] for item in candidates[:8])
    info_params = urllib.parse.urlencode(
        {
            "action": "query",
            "prop": "imageinfo",
            "titles": titles,
            "iiprop": "url|size|mime|extmetadata",
            "iiurlwidth": "1280",
            "format": "json",
        }
    )
    info_res = http_get_json(f"{COMMONS_API}?{info_params}")
    pages = info_res.get("query", {}).get("pages", {}).values()

    by_title: dict[str, dict[str, Any]] = {}
    for page in pages:
        title = page.get("title", "")
        ii_list = page.get("imageinfo") or []
        if not title or not ii_list:
            continue
        ii = ii_list[0]
        width = int(ii.get("width") or 0)
        height = int(ii.get("height") or 0)
        if width < 640 or height < 400 or height > width * 1.4:
            continue
        meta = ii.get("extmetadata") or {}
        lic = (meta.get("LicenseShortName") or {}).get("value", "")
        if not is_free_license(lic):
            continue
        download_url = ii.get("thumburl") or ii.get("url")
        if not download_url:
            continue
        by_title[title] = {
            "title": title,
            "license": lic,
            "width": width,
            "height": height,
            "download_url": download_url,
            "description_url": ii.get("descriptionurl", ""),
        }

    for item in candidates:
        matched = by_title.get(item.get("title", ""))
        if matched:
            matched["dist_m"] = item.get("dist")
            matched["lat"] = item.get("lat")
            matched["lon"] = item.get("lon")
            return matched
    return None


def load_curated_manifest(manifest_path: Path) -> dict[str, dict[str, Any]]:
    if not manifest_path.exists():
        return {}
    raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    out: dict[str, dict[str, Any]] = {}
    for entry in raw:
        slug = entry.get("slug")
        if slug:
            out[slug] = entry
    return out


def fetch_trails_needing_photos(base_url: str, limit: int = 0) -> list[dict[str, Any]]:
    trails: list[dict[str, Any]] = []
    page = 1
    parsed = urllib.parse.urlsplit(base_url)
    is_local_pb = parsed.hostname in ("127.0.0.1", "localhost") or ":8090" in base_url
    endpoint = "/api/collections/trails/records" if is_local_pb else "/api/v1/trail"
    while True:
        url = (
            f"{base_url.rstrip('/')}{endpoint}"
            f"?perPage=100&page={page}&filter={urllib.parse.quote('public = true')}"
            f"&fields=id,name,location,lat,lon,photos"
        )
        res = http_get_json(url)
        items = res.get("items") or []
        for item in items:
            photos = item.get("photos") or []
            if all(is_placeholder_photo(p) for p in photos):
                trails.append(item)
                if limit > 0 and len(trails) >= limit:
                    return trails
        if page >= int(res.get("totalPages") or 1):
            break
        page += 1
    return trails


def authenticate_pocketbase(
    base_url: str,
    email: str,
    password: str,
) -> str:
    url = f"{base_url.rstrip('/')}/api/collections/users/auth-with-password"
    payload = json.dumps({"identity": email, "password": password}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return str(data["token"])


def upload_trail_photo_pocketbase(
    base_url: str,
    token: str,
    trail_id: str,
    filename: str,
    photo_bytes: bytes,
) -> dict[str, Any]:
    boundary = "----WandererPhotoBoundary" + uuid.uuid4().hex
    parts: list[bytes] = [
        f"--{boundary}\r\n".encode("utf-8"),
        (
            f'Content-Disposition: form-data; name="photos"; filename="{filename}"\r\n'
            "Content-Type: image/jpeg\r\n\r\n"
        ).encode("utf-8"),
        photo_bytes + b"\r\n",
        f"--{boundary}--\r\n".encode("utf-8"),
    ]
    body = b"".join(parts)

    parsed = urllib.parse.urlsplit(base_url)
    conn_cls = (
        http.client.HTTPSConnection
        if parsed.scheme == "https"
        else http.client.HTTPConnection
    )
    conn = conn_cls(
        parsed.hostname,
        parsed.port or (443 if parsed.scheme == "https" else 80),
        timeout=60,
    )
    try:
        prefix = parsed.path.rstrip("/")
        path = f"{prefix}/api/collections/trails/records/{trail_id}"
        conn.request(
            "PATCH",
            path,
            body=body,
            headers={
                "Authorization": token,
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Content-Length": str(len(body)),
                "Accept": "application/json",
            },
        )
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8", errors="replace")
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f"HTTP {resp.status} PATCH {path}: {raw}")
        return json.loads(raw) if raw else {}
    finally:
        conn.close()


def main() -> None:
    default_manifest = (
        Path(__file__).resolve().parent.parent
        / "data"
        / "location_photos"
        / "manifest.json"
    )
    parser = argparse.ArgumentParser(
        description="Enrich PocketBase trails with real Wikimedia Commons mountain photography."
    )
    parser.add_argument(
        "--base-url",
        default="https://trasee.skillfy.ro",
        help="Target Wanderer/PocketBase base URL",
    )
    parser.add_argument(
        "--manifest",
        default=str(default_manifest),
        help="Path to local curated location_photos/manifest.json",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Max trails to process (0 = all matching public trails)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Resolve and print photo matches without modifying PocketBase",
    )
    parser.add_argument(
        "--email",
        default="trasee@skillfy.ro",
        help="PocketBase curator account email for authenticated PATCH",
    )
    parser.add_argument(
        "--password",
        default=os.environ.get("WANDERER_CURATOR_PASSWORD", ""),
        help="Curator password (or set WANDERER_CURATOR_PASSWORD / --secret-file)",
    )
    parser.add_argument(
        "--secret-file",
        default="",
        help="Optional path to file containing curator password",
    )
    args = parser.parse_args()

    curated = load_curated_manifest(Path(args.manifest))
    trails = fetch_trails_needing_photos(args.base_url, limit=args.limit)
    print(f"[Scan] Found {len(trails)} public trails without real photos on {args.base_url}")

    token: str | None = None
    if not args.dry_run:
        password = args.password
        if not password and args.secret_file:
            password = Path(args.secret_file).read_text(encoding="utf-8").strip()
        if not password:
            raise RuntimeError(
                "Missing credentials for upload mode. Pass --secret-file, --password, or use --dry-run."
            )
        token = authenticate_pocketbase(args.base_url, args.email, password)

    matched_count = 0
    uploaded_count = 0
    for trail in trails:
        tid = trail["id"]
        name = trail.get("name") or ""
        location = trail.get("location") or ""
        lat = float(trail.get("lat") or 0.0)
        lon = float(trail.get("lon") or 0.0)

        slug = match_curated_slug(name, location)
        local_entry = curated.get(slug) if slug else None
        source_desc: str | None = None
        filename = f"{tid}_commons.jpg"
        photo_bytes: bytes | None = None

        if local_entry and Path(local_entry["file"]).exists():
            source_desc = f"curated:{slug} ({local_entry['license']})"
            filename = f"{slug}_{tid}.jpg"
            if not args.dry_run:
                photo_bytes = Path(local_entry["file"]).read_bytes()
        elif is_in_romania_bbox(lat, lon):
            geo_match = commons_geosearch_photo(lat, lon)
            if geo_match:
                source_desc = (
                    f"commons:{geo_match['title']} ({geo_match['license']}, "
                    f"{round(float(geo_match.get('dist_m') or 0))}m)"
                )
                safe_title = re.sub(r"[^a-zA-Z0-9._-]+", "_", geo_match["title"].replace("File:", ""))
                filename = f"{tid}_{safe_title}"[:80]
                if not args.dry_run:
                    photo_bytes = http_get_bytes(geo_match["download_url"])

        if not source_desc:
            print(f"  - [skip] {tid} | {name} ({lat:.4f}, {lon:.4f})")
            continue

        matched_count += 1
        print(f"  + [match] {tid} | {name} -> {source_desc}")
        if not args.dry_run and token and photo_bytes:
            upload_trail_photo_pocketbase(
                args.base_url,
                token,
                tid,
                filename,
                photo_bytes,
            )
            uploaded_count += 1

    print(
        f"[Done] Processed={len(trails)} Matched={matched_count} Uploaded={uploaded_count}"
    )


if __name__ == "__main__":
    main()
