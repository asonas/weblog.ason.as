import argparse
import hashlib
import json
import mimetypes
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import urlopen


_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_EXPECTED_MIME_PREFIX = {
    "image": "image/",
    "audio": "audio/",
    "video": "video/",
}


def fetch_assets(
    manifest_path: Path,
    output_dir: Path,
    report_path: Path,
    timeout: float = 20.0,
    max_bytes: int = 50 * 1024 * 1024,
) -> dict[str, Any]:
    if timeout <= 0:
        raise ValueError("timeout must be greater than zero")
    if max_bytes <= 0:
        raise ValueError("max_bytes must be greater than zero")

    entries = _load_manifest(Path(manifest_path))
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    results = [
        _fetch_entry(entry, output_dir, timeout, max_bytes)
        for entry in entries
    ]
    report = {
        "manifest_path": str(manifest_path),
        "run_at": datetime.now(timezone.utc).isoformat(),
        "downloaded": sum(result["status"] == "downloaded" for result in results),
        "failed": sum(result["status"] == "failed" for result in results),
        "results": results,
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def _load_manifest(path: Path) -> list[dict[str, str]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read asset manifest: {path}") from error
    raw_assets = payload.get("assets") if isinstance(payload, dict) else None
    if not isinstance(raw_assets, list):
        raise ValueError(f"asset manifest is missing assets: {path}")

    entries: list[dict[str, str]] = []
    for raw_asset in raw_assets:
        if not isinstance(raw_asset, dict):
            raise ValueError(f"asset manifest entry must be an object: {path}")
        asset_id = raw_asset.get("id")
        url = raw_asset.get("url")
        kind = raw_asset.get("kind")
        if not all(isinstance(value, str) for value in (asset_id, url, kind)):
            raise ValueError(f"asset manifest entry is missing id, url, or kind: {path}")
        if not _SAFE_ID.fullmatch(asset_id):
            raise ValueError(f"asset ID is not a safe filename: {asset_id!r}")
        if kind not in {"image", "audio", "video", "url"}:
            raise ValueError(f"unsupported asset kind: {kind!r}")
        parsed = urlsplit(url)
        if parsed.scheme.lower() not in {"http", "https"} or not parsed.netloc:
            raise ValueError(f"unsupported asset URL: {url!r}")
        entries.append({"id": asset_id, "url": url, "kind": kind})
    return entries


def _fetch_entry(
    entry: dict[str, str],
    output_dir: Path,
    timeout: float,
    max_bytes: int,
) -> dict[str, Any]:
    base_result: dict[str, Any] = {
        "id": entry["id"],
        "url": entry["url"],
        "kind": entry["kind"],
    }
    try:
        with urlopen(entry["url"], timeout=timeout) as response:
            status = getattr(response, "status", None) or response.getcode()
            content_type = response.headers.get_content_type()
            content_length = response.headers.get("Content-Length")
            if content_length is not None and int(content_length) > max_bytes:
                raise _AssetFetchError(f"response exceeds {max_bytes} bytes")
            expected_prefix = _EXPECTED_MIME_PREFIX.get(entry["kind"])
            if expected_prefix and not content_type.startswith(expected_prefix):
                raise _AssetFetchError(
                    f"expected {expected_prefix[:-1]} content, got {content_type}"
                )
            data = response.read(max_bytes + 1)
            if len(data) > max_bytes:
                raise _AssetFetchError(f"response exceeds {max_bytes} bytes")
    except HTTPError as error:
        return {
            **base_result,
            "status": "failed",
            "http_status": error.code,
            "error": f"HTTP {error.code}: {error.reason}",
        }
    except (OSError, URLError, ValueError, _AssetFetchError) as error:
        return {
            **base_result,
            "status": "failed",
            "error": str(error),
        }

    suffix = _file_suffix(entry["url"], content_type)
    output_path = output_dir / f"{entry['id']}{suffix}"
    output_path.write_bytes(data)
    return {
        **base_result,
        "status": "downloaded",
        "http_status": status,
        "mime_type": content_type,
        "local_path": output_path.name,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def _file_suffix(url: str, content_type: str) -> str:
    suffix = Path(urlsplit(url).path).suffix.lower()
    if suffix and len(suffix) <= 10 and re.fullmatch(r"\.[a-z0-9]+", suffix):
        return suffix
    return mimetypes.guess_extension(content_type) or ".bin"


class _AssetFetchError(Exception):
    pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Fetch URL assets from a manifest")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--max-bytes", type=int, default=50 * 1024 * 1024)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        fetch_assets(
            args.manifest,
            args.output,
            args.report,
            timeout=args.timeout,
            max_bytes=args.max_bytes,
        )
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
