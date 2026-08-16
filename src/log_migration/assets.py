import argparse
import hashlib
import json
import mimetypes
import re
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit, urlunsplit
from urllib.request import urlopen


_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_EXPECTED_MIME_PREFIX = {
    "image": "image/",
    "audio": "audio/",
    "video": "video/",
}
_PATH_URL_SAFE = "/:@-._~!$&'()*+,;=%"
_QUERY_URL_SAFE = "/?:@-._~!$&'()*+,;=%"
_GYAZO_PAGE_HOSTS = {"gyazo.com", "www.gyazo.com"}


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
    fetch_url = entry["url"]
    try:
        resolved_url = _resolve_gyazo_url(entry["url"], timeout, max_bytes)
        if resolved_url is not None:
            fetch_url = resolved_url
        with urlopen(_request_url(fetch_url), timeout=timeout) as response:
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

    suffix = _file_suffix(fetch_url, content_type)
    output_path = output_dir / f"{entry['id']}{suffix}"
    output_path.write_bytes(data)
    result = {
        **base_result,
        "status": "downloaded",
        "http_status": status,
        "mime_type": content_type,
        "local_path": output_path.name,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    if fetch_url != entry["url"]:
        result["fetched_url"] = fetch_url
    return result


def _file_suffix(url: str, content_type: str) -> str:
    suffix = Path(urlsplit(url).path).suffix.lower()
    if suffix and len(suffix) <= 10 and re.fullmatch(r"\.[a-z0-9]+", suffix):
        return suffix
    return mimetypes.guess_extension(content_type) or ".bin"


def _request_url(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit(
        (
            parts.scheme,
            parts.netloc,
            quote(parts.path, safe=_PATH_URL_SAFE),
            quote(parts.query, safe=_QUERY_URL_SAFE),
            "",
        )
    )


def _resolve_gyazo_url(
    url: str,
    timeout: float,
    max_bytes: int,
) -> str | None:
    parts = urlsplit(url)
    if parts.hostname not in _GYAZO_PAGE_HOSTS:
        return None

    with urlopen(_request_url(url), timeout=timeout) as response:
        content_type = response.headers.get_content_type()
        content_length = response.headers.get("Content-Length")
        if content_length is not None and int(content_length) > max_bytes:
            raise _AssetFetchError(f"response exceeds {max_bytes} bytes")
        if content_type not in {"text/html", "application/xhtml+xml"}:
            raise _AssetFetchError(
                f"expected text/html Gyazo page, got {content_type}"
            )
        data = response.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise _AssetFetchError(f"response exceeds {max_bytes} bytes")
        charset = response.headers.get_content_charset() or "utf-8"

    parser = _OgImageParser()
    parser.feed(data.decode(charset, errors="replace"))
    image_url = parser.image_url
    if not image_url:
        raise _AssetFetchError("Gyazo page does not contain an og:image URL")
    resolved = urljoin(url, image_url)
    resolved_parts = urlsplit(resolved)
    if resolved_parts.scheme.lower() not in {"http", "https"} or not resolved_parts.netloc:
        raise _AssetFetchError("Gyazo og:image URL is not an HTTP(S) URL")
    return resolved


class _OgImageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.image_url: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "meta" or self.image_url is not None:
            return
        attributes = {
            name.lower(): value
            for name, value in attrs
            if value is not None
        }
        property_name = (
            attributes.get("property") or attributes.get("name") or ""
        ).lower()
        if property_name in {"og:image", "og:image:url"}:
            self.image_url = attributes.get("content")


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
