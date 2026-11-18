"""SRTM / Mapzen Skadi 1-arcsecond DEM elevation sampler and GPX metrics helper."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
import gzip
import math
from pathlib import Path
import ssl
import struct
import urllib.error
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


_SSL_CONTEXT = _make_ssl_context()

SKADI_URL_TEMPLATE = (
    "https://s3.amazonaws.com/elevation-tiles-prod/skadi/"
    "{ns}{lat:02d}/{ns}{lat:02d}{ew}{lon:03d}.hgt.gz"
)


def tile_name(lat_sw: int, lon_sw: int) -> str:
    ns = "N" if lat_sw >= 0 else "S"
    ew = "E" if lon_sw >= 0 else "W"
    return f"{ns}{abs(lat_sw):02d}{ew}{abs(lon_sw):03d}"


def tile_url(lat_sw: int, lon_sw: int) -> str:
    ns = "N" if lat_sw >= 0 else "S"
    ew = "E" if lon_sw >= 0 else "W"
    lat_abs = abs(lat_sw)
    lon_abs = abs(lon_sw)
    return (
        f"https://s3.amazonaws.com/elevation-tiles-prod/skadi/"
        f"{ns}{lat_abs:02d}/{ns}{lat_abs:02d}{ew}{lon_abs:03d}.hgt.gz"
    )


class DemTileCache:
    """Downloads, caches, and bilinearly interpolates 1x1 deg SRTM .hgt tiles."""

    def __init__(self, dem_dir: Path) -> None:
        self.dem_dir = dem_dir
        self.dem_dir.mkdir(parents=True, exist_ok=True)
        self._tiles: dict[tuple[int, int], tuple[bytes, int] | None] = {}

    def _hgt_path(self, lat_sw: int, lon_sw: int) -> Path:
        return self.dem_dir / f"{tile_name(lat_sw, lon_sw)}.hgt"

    def _download_tile(self, key: tuple[int, int]) -> tuple[tuple[int, int], Path | None]:
        lat_sw, lon_sw = key
        hgt_path = self._hgt_path(lat_sw, lon_sw)
        if hgt_path.exists() and hgt_path.stat().st_size > 0:
            return key, hgt_path

        url = tile_url(lat_sw, lon_sw)
        tmp_path = hgt_path.with_suffix(".hgt.tmp")
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "Wanderer-RO-DEM/1.0"})
                with urllib.request.urlopen(req, timeout=45, context=_SSL_CONTEXT) as resp:
                    compressed = resp.read()
                raw = gzip.decompress(compressed)
                tmp_path.write_bytes(raw)
                tmp_path.replace(hgt_path)
                return key, hgt_path
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    return key, None
                if attempt == 2:
                    raise RuntimeError(f"Failed downloading DEM tile {url}: HTTP {exc.code}") from exc
            except Exception as exc:  # noqa: BLE001
                if attempt == 2:
                    raise RuntimeError(f"Failed downloading DEM tile {url}: {exc}") from exc
        return key, None

    def ensure_tiles(self, tiles: set[tuple[int, int]]) -> None:
        missing_to_load: list[tuple[int, int]] = []
        for key in sorted(tiles):
            if key in self._tiles:
                continue
            hgt_path = self._hgt_path(*key)
            if hgt_path.exists() and hgt_path.stat().st_size > 0:
                self._load_file(key, hgt_path)
            else:
                missing_to_load.append(key)

        if not missing_to_load:
            return

        print(f"[DEM] Downloading {len(missing_to_load)} missing 1x1 deg SRTM tiles...")
        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(self._download_tile, key) for key in missing_to_load]
            for idx, fut in enumerate(as_completed(futures), 1):
                key, path = fut.result()
                if path is not None and path.exists():
                    self._load_file(key, path)
                else:
                    self._tiles[key] = None
                if idx % 10 == 0 or idx == len(missing_to_load):
                    print(f"[DEM] Fetched {idx}/{len(missing_to_load)} tiles")

    def _load_file(self, key: tuple[int, int], path: Path) -> None:
        buf = path.read_bytes()
        n = int(round(math.sqrt(len(buf) // 2)))
        if n * n * 2 != len(buf) or n < 2:
            raise ValueError(f"Invalid HGT file size for {path}: {len(buf)} bytes")
        self._tiles[key] = (buf, n)

    def _get_tile(self, lat_sw: int, lon_sw: int) -> tuple[bytes, int] | None:
        key = (lat_sw, lon_sw)
        if key not in self._tiles:
            _, path = self._download_tile(key)
            if path is not None:
                self._load_file(key, path)
            else:
                self._tiles[key] = None
        return self._tiles[key]

    def sample(self, lat: float, lon: float) -> float | None:
        lat_sw = int(math.floor(lat))
        lon_sw = int(math.floor(lon))
        entry = self._get_tile(lat_sw, lon_sw)
        if entry is None:
            return None
        buf, n = entry

        r = max(0.0, min(n - 1.000001, (1.0 - (lat - lat_sw)) * (n - 1)))
        c = max(0.0, min(n - 1.000001, (lon - lon_sw) * (n - 1)))

        r0 = int(math.floor(r))
        c0 = int(math.floor(c))
        r1 = min(n - 1, r0 + 1)
        c1 = min(n - 1, c0 + 1)
        dr = r - r0
        dc = c - c0

        z00 = struct.unpack_from(">h", buf, (r0 * n + c0) * 2)[0]
        z01 = struct.unpack_from(">h", buf, (r0 * n + c1) * 2)[0]
        z10 = struct.unpack_from(">h", buf, (r1 * n + c0) * 2)[0]
        z11 = struct.unpack_from(">h", buf, (r1 * n + c1) * 2)[0]

        weights = [
            ((1.0 - dr) * (1.0 - dc), z00),
            ((1.0 - dr) * dc, z01),
            (dr * (1.0 - dc), z10),
            (dr * dc, z11),
        ]
        valid = [(w, z) for w, z in weights if z > -1000]
        if not valid:
            return None
        w_sum = sum(w for w, _ in valid)
        if w_sum <= 0:
            return float(valid[0][1])
        return sum(w * z for w, z in valid) / w_sum


def _smooth_segment_elevations(raw_eles: list[float]) -> list[float]:
    n = len(raw_eles)
    if n < 3:
        return list(raw_eles)
    weights = (1.0, 2.0, 3.0, 2.0, 1.0)
    smoothed: list[float] = []
    for i in range(n):
        total = 0.0
        w_sum = 0.0
        for offset, w in zip((-2, -1, 0, 1, 2), weights):
            j = min(n - 1, max(0, i + offset))
            total += raw_eles[j] * w
            w_sum += w
        smoothed.append(total / w_sum)
    return smoothed


def enrich_segments_with_elevation(
    segments: list[list[tuple[float, float]]],
    dem: DemTileCache,
    threshold_z_m: float = 5.0,
) -> tuple[list[list[tuple[float, float, float | None]]], dict[str, float]]:
    """Attach smoothed DEM elevations to segments and compute elevation metrics."""
    enriched_segments: list[list[tuple[float, float, float | None]]] = []
    all_eles: list[float] = []

    for seg in segments:
        sampled = [dem.sample(lat, lon) for lon, lat in seg]
        # Fill any isolated void from nearest valid neighbor in segment.
        valid_indices = [i for i, e in enumerate(sampled) if e is not None]
        if not valid_indices:
            enriched_segments.append([(lon, lat, None) for lon, lat in seg])
            continue

        filled: list[float] = []
        last_valid = sampled[valid_indices[0]]
        assert last_valid is not None
        for idx, e in enumerate(sampled):
            if e is None:
                filled.append(last_valid)
            else:
                filled.append(e)
                last_valid = e

        smoothed = _smooth_segment_elevations(filled)
        all_eles.extend(smoothed)
        enriched_segments.append([
            (lon, lat, round(ele, 1)) for (lon, lat), ele in zip(seg, smoothed)
        ])

    if not all_eles:
        return enriched_segments, {
            "elevation_gain": 0.0,
            "elevation_loss": 0.0,
            "min_ele": 0.0,
            "max_ele": 0.0,
            "start_ele": 0.0,
            "end_ele": 0.0,
        }

    # Hysteresis accumulation per segment matching Wanderer's 5m noise filter.
    gain = 0.0
    loss = 0.0
    for seg in enriched_segments:
        anchor: float | None = None
        for _, _, ele in seg:
            if ele is None:
                continue
            if anchor is None:
                anchor = ele
                continue
            diff = ele - anchor
            if diff >= threshold_z_m:
                gain += diff
                anchor = ele
            elif diff <= -threshold_z_m:
                loss += -diff
                anchor = ele

    return enriched_segments, {
        "elevation_gain": round(gain),
        "elevation_loss": round(loss),
        "min_ele": round(min(all_eles)),
        "max_ele": round(max(all_eles)),
        "start_ele": round(all_eles[0]),
        "end_ele": round(all_eles[-1]),
    }
