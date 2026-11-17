#!/usr/bin/env python3
"""Idempotent PocketBase importer for extracted Romanian OSM trails.

Uses Python standard library HTTP/multipart requests so it runs directly on the VPS
host without external Python dependencies.
"""

from __future__ import annotations

import argparse
import http.client
import json
import mimetypes
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


def json_request(
    base_url: str,
    method: str,
    path: str,
    body: dict | None = None,
    token: str | None = None,
) -> dict:
    url = base_url.rstrip("/") + path
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
    if token:
        headers["Authorization"] = token

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} {method} {path}: {err_body}") from exc


def multipart_save_trail(
    base_url: str,
    token: str,
    fields: list[tuple[str, str]],
    gpx_filename: str,
    gpx_bytes: bytes,
    record_id: str | None = None,
) -> dict:
    boundary = "----WandererBoundary" + uuid.uuid4().hex
    parts: list[bytes] = []
    for k, v in fields:
        parts.append(f"--{boundary}\r\n".encode("utf-8"))
        parts.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode("utf-8"))
        parts.append(str(v).encode("utf-8") + b"\r\n")

    mime = mimetypes.guess_type(gpx_filename)[0] or "application/gpx+xml"
    parts.append(f"--{boundary}\r\n".encode("utf-8"))
    parts.append(
        f'Content-Disposition: form-data; name="gpx"; filename="{gpx_filename}"\r\n'
        f"Content-Type: {mime}\r\n\r\n".encode("utf-8")
    )
    parts.append(gpx_bytes + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode("utf-8"))
    body = b"".join(parts)

    method = "PATCH" if record_id else "POST"
    parsed = urllib.parse.urlsplit(base_url)
    conn_cls = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80), timeout=60)
    try:
        headers = {
            "Authorization": token,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
            "Accept": "application/json",
        }
        prefix = parsed.path.rstrip("/")
        path = (
            f"{prefix}/api/collections/trails/records/{record_id}"
            if record_id
            else f"{prefix}/api/collections/trails/records"
        )
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8", errors="replace")
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f"HTTP {resp.status} {method} {path}: {raw}")
        return json.loads(raw) if raw else {}
    finally:
        conn.close()


def ensure_curator_account(base_url: str, secret_file: Path) -> tuple[str, str, str]:
    email = "trasee@skillfy.ro"
    username = "romania"
    display_name = "Trasee România"

    if secret_file.exists():
        password = secret_file.read_text(encoding="utf-8").strip()
    else:
        password = secrets.token_urlsafe(24)
        secret_file.parent.mkdir(parents=True, exist_ok=True)
        old_umask = os.umask(0o077)
        try:
            secret_file.write_text(password + "\n", encoding="utf-8")
        finally:
            os.umask(old_umask)

    try:
        auth = json_request(
            base_url,
            "POST",
            "/api/collections/users/auth-with-password",
            {"identity": email, "password": password},
        )
    except RuntimeError:
        json_request(
            base_url,
            "POST",
            "/api/collections/users/records",
            {
                "username": username,
                "email": email,
                "name": display_name,
                "password": password,
                "passwordConfirm": password,
                "emailVisibility": False,
            },
        )
        auth = json_request(
            base_url,
            "POST",
            "/api/collections/users/auth-with-password",
            {"identity": email, "password": password},
        )

    token = auth["token"]
    user_id = auth["record"]["id"]

    # Resolve ActivityPub actor linked to this user (author field on `trails` references `activitypub_actors`).
    q = urllib.parse.quote(f'user="{user_id}"')
    actors = json_request(
        base_url,
        "GET",
        f"/api/collections/activitypub_actors/records?filter={q}&perPage=1",
        token=token,
    )
    items = actors.get("items", [])
    if not items:
        raise RuntimeError(f"No activitypub_actors record found for user {user_id}")
    actor_id = items[0]["id"]
    return token, user_id, actor_id


def fetch_categories(base_url: str, token: str) -> dict[str, str]:
    res = json_request(base_url, "GET", "/api/collections/categories/records?perPage=100", token=token)
    return {item["name"]: item["id"] for item in res.get("items", []) if item.get("name")}


def ensure_tags(base_url: str, token: str, tag_names: set[str]) -> dict[str, str]:
    tag_map: dict[str, str] = {}
    page = 1
    while True:
        res = json_request(
            base_url,
            "GET",
            f"/api/collections/tags/records?perPage=500&page={page}",
            token=token,
        )
        for item in res.get("items", []):
            if item.get("name"):
                tag_map[item["name"]] = item["id"]
        if page >= res.get("totalPages", 1):
            break
        page += 1

    for name in sorted(tag_names):
        if name not in tag_map:
            created = json_request(
                base_url,
                "POST",
                "/api/collections/tags/records",
                {"name": name},
                token=token,
            )
            tag_map[name] = created["id"]
    return tag_map


def fetch_existing_osm_relations(base_url: str, token: str) -> dict[int, str]:
    existing: dict[int, str] = {}
    page = 1
    pattern = re.compile(r"osm:relation:(\d+)")
    while True:
        res = json_request(
            base_url,
            "GET",
            f"/api/collections/trails/records?perPage=500&page={page}&fields=id,description",
            token=token,
        )
        for item in res.get("items", []):
            desc = item.get("description") or ""
            m = pattern.search(desc)
            if m:
                existing[int(m.group(1))] = item["id"]
        if page >= res.get("totalPages", 1):
            break
        page += 1
    return existing


def main() -> None:
    parser = argparse.ArgumentParser(description="Import Romanian trail manifest into PocketBase.")
    parser.add_argument("--pb-url", default="http://127.0.0.1:8090", help="PocketBase base URL")
    parser.add_argument("--bundle-dir", required=True, help="Extracted directory containing manifest.jsonl and gpx/")
    parser.add_argument(
        "--secret-file",
        default="/var/www/maps.skillfy.ro/.curator_secret",
        help="Path storing curator account password",
    )
    parser.add_argument("--limit", type=int, default=0, help="Optional cap for test imports (0 = all)")
    parser.add_argument(
        "--update-existing",
        action="store_true",
        help="PATCH already-imported OSM trails in place (updating GPX, elevation gain/loss, duration, description)",
    )
    args = parser.parse_args()

    bundle_dir = Path(args.bundle_dir).resolve()
    manifest_path = bundle_dir / "manifest.jsonl"
    if not manifest_path.exists():
        raise FileNotFoundError(f"Manifest not found: {manifest_path}")

    records = [
        json.loads(line)
        for line in manifest_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if args.limit > 0:
        records = records[: args.limit]

    token, user_id, actor_id = ensure_curator_account(args.pb_url, Path(args.secret_file))
    print(f"[Auth] Curator user={user_id} actor={actor_id}")

    categories = fetch_categories(args.pb_url, token)
    all_tag_names = {t for rec in records for t in rec.get("tags", [])}
    tag_map = ensure_tags(args.pb_url, token, all_tag_names)
    existing_rels = fetch_existing_osm_relations(args.pb_url, token)
    print(f"[State] Found {len(existing_rels)} already imported OSM relations; {len(tag_map)} tags ready.")

    imported = 0
    updated = 0
    skipped = 0
    failed = 0

    for idx, rec in enumerate(records, 1):
        rel_id = int(rec["rel_id"])
        existing_record_id = existing_rels.get(rel_id)
        if existing_record_id and not args.update_existing:
            skipped += 1
            continue

        gpx_path = bundle_dir / rec["gpx_rel_path"]
        if not gpx_path.exists():
            print(f"[Warn] Missing GPX for relation {rel_id}: {gpx_path}", file=sys.stderr)
            failed += 1
            continue

        cat_id = categories.get(rec.get("category", "Hiking")) or categories.get("Hiking", "")
        fields: list[tuple[str, str]] = [
            ("name", rec["name"]),
            ("description", rec["description"]),
            ("location", rec["location"]),
            ("public", "true"),
            ("completed", "false"),
            ("distance", str(rec["distance"])),
            ("elevation_gain", str(rec.get("elevation_gain", 0))),
            ("elevation_loss", str(rec.get("elevation_loss", 0))),
            ("duration", str(rec["duration"])),
            ("difficulty", rec["difficulty"]),
            ("lat", str(rec["lat"])),
            ("lon", str(rec["lon"])),
            ("min_lat", str(rec["min_lat"])),
            ("max_lat", str(rec["max_lat"])),
            ("min_lon", str(rec["min_lon"])),
            ("max_lon", str(rec["max_lon"])),
        ]
        # PocketBase trails.updateRule enforces `@request.body.author:changed = false`,
        # so `author` must only be included when creating a new trail.
        if not existing_record_id:
            fields.append(("author", actor_id))
        if cat_id:
            fields.append(("category", cat_id))
        for t in rec.get("tags", []):
            tid = tag_map.get(t)
            if tid:
                fields.append(("tags", tid))

        try:
            saved = multipart_save_trail(
                args.pb_url,
                token,
                fields,
                f"{rel_id}.gpx",
                gpx_path.read_bytes(),
                record_id=existing_record_id,
            )
            if existing_record_id:
                updated += 1
            else:
                imported += 1
                if saved.get("id"):
                    existing_rels[rel_id] = saved["id"]
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"[Error] rel={rel_id} ({rec['name']}): {exc}", file=sys.stderr)
            if failed >= 5 and (imported + updated) == 0:
                raise RuntimeError("Aborting after 5 consecutive initial failures.") from exc

        total_ok = imported + updated
        if total_ok % 50 == 0 and total_ok > 0:
            print(
                f"[Progress] Imported={imported}, Updated={updated} "
                f"(processed {idx}/{len(records)}, skipped={skipped}, failed={failed})"
            )
        if idx % 20 == 0:
            time.sleep(0.015)

    print(f"[Done] Imported={imported}, Updated={updated}, Skipped={skipped}, Failed={failed}")
    if (imported + updated) == 0 and failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
