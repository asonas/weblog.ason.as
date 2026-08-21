import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import urlopen

from .assets import _AssetFetchError, _file_suffix, _load_manifest, _request_url


_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_SAFE_FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_HTML_CONTENT_TYPES = {"text/html", "application/xhtml+xml"}
_IMAGE_MIME_PREFIX = "image/"
_TEXT_LIMITS = {
    "title": 300,
    "description": 2_000,
}


def fetch_url_metadata(
    manifest_path: Path,
    output_path: Path,
    assets_dir: Path,
    report_path: Path,
    timeout: float = 20.0,
    max_bytes: int = 5 * 1024 * 1024,
) -> dict[str, Any]:
    """Fetch OGP metadata for URL assets without changing the source manifest."""

    if timeout <= 0:
        raise ValueError("timeout must be greater than zero")
    if max_bytes <= 0:
        raise ValueError("max_bytes must be greater than zero")

    entries = _load_url_manifest(Path(manifest_path))
    assets_dir = Path(assets_dir)
    assets_dir.mkdir(parents=True, exist_ok=True)
    results = [
        _fetch_url_entry(entry, assets_dir, timeout, max_bytes)
        for entry in entries
    ]
    payload = {
        "assets": results,
        "version": 1,
    }
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    report = {
        "assets": len(results),
        "fallback": sum(result["status"] == "fallback" for result in results),
        "manifest_path": str(manifest_path),
        "metadata_path": str(output_path),
        "ready": sum(result["status"] == "ready" for result in results),
        "results": results,
        "run_at": datetime.now(timezone.utc).isoformat(),
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def load_url_metadata(path: Path | None) -> dict[str, dict[str, object]]:
    """Load and validate fetched URL metadata for the static renderer."""

    if path is None:
        return {}
    path = Path(path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read URL metadata: {path}") from error

    raw_assets = payload.get("assets") if isinstance(payload, dict) else None
    if not isinstance(raw_assets, list):
        raise ValueError(f"URL metadata is missing assets: {path}")

    metadata: dict[str, dict[str, object]] = {}
    for raw_asset in raw_assets:
        if not isinstance(raw_asset, dict):
            raise ValueError(f"URL metadata entry must be an object: {path}")
        asset_id = raw_asset.get("id")
        url = raw_asset.get("url")
        if not isinstance(asset_id, str) or not _SAFE_ID.fullmatch(asset_id):
            raise ValueError(f"URL metadata has an unsafe asset ID: {asset_id!r}")
        if not isinstance(url, str):
            raise ValueError(f"URL metadata entry is missing URL: {asset_id!r}")
        if asset_id in metadata:
            raise ValueError(f"URL metadata contains duplicate asset ID: {asset_id!r}")
        image = raw_asset.get("image")
        if image is not None:
            if not isinstance(image, dict):
                raise ValueError(f"URL metadata image must be an object: {asset_id!r}")
            local_path = image.get("local_path")
            if not isinstance(local_path, str) or not _SAFE_FILENAME.fullmatch(local_path):
                raise ValueError(
                    f"URL metadata image has an unsafe local path: {asset_id!r}"
                )
        metadata[asset_id] = dict(raw_asset)
    return metadata


def _load_url_manifest(path: Path) -> list[dict[str, object]]:
    entries = _load_manifest(path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read asset manifest: {path}") from error

    raw_assets = payload.get("assets") if isinstance(payload, dict) else None
    raw_by_id = {
        raw_asset.get("id"): raw_asset
        for raw_asset in raw_assets
        if isinstance(raw_asset, dict)
    }
    url_entries: list[dict[str, object]] = []
    for entry in entries:
        if entry["kind"] != "url":
            continue
        raw_asset = raw_by_id[entry["id"]]
        source_post_ids = raw_asset.get("source_post_ids", [])
        if not isinstance(source_post_ids, list) or not all(
            isinstance(post_id, str) for post_id in source_post_ids
        ):
            raise ValueError(
                f"asset manifest source_post_ids must be strings: {entry['id']!r}"
            )
        url_entries.append(
            {
                **entry,
                "source_post_ids": list(source_post_ids),
            }
        )
    return url_entries


def _fetch_url_entry(
    entry: dict[str, object],
    assets_dir: Path,
    timeout: float,
    max_bytes: int,
) -> dict[str, object]:
    asset_id = str(entry["id"])
    url = str(entry["url"])
    result: dict[str, object] = {
        "description": None,
        "domain": _domain(url),
        "id": asset_id,
        "image": None,
        "image_url": None,
        "kind": "url",
        "source_post_ids": list(entry["source_post_ids"]),
        "status": "fallback",
        "title": None,
        "url": url,
    }

    try:
        with urlopen(_request_url(url), timeout=timeout) as response:
            status, content_type, data = _read_response(response, max_bytes)
            if content_type not in _HTML_CONTENT_TYPES:
                raise _AssetFetchError(
                    f"expected text/html content, got {content_type}"
                )
            charset = response.headers.get_content_charset() or "utf-8"
            base_url = response.geturl() if hasattr(response, "geturl") else url
    except HTTPError as error:
        return _failure_result(result, f"HTTP {error.code}: {error.reason}", error.code)
    except (OSError, URLError, ValueError, _AssetFetchError) as error:
        return _failure_result(result, str(error))

    parser = _PageMetadataParser()
    parser.feed(data.decode(charset, errors="replace"))
    result["http_status"] = status
    result["title"] = parser.og_title or parser.document_title
    result["description"] = parser.og_description

    if parser.og_image:
        image_url = urljoin(base_url, parser.og_image)
        image_parts = urlsplit(image_url)
        if image_parts.scheme.lower() not in {"http", "https"} or not image_parts.netloc:
            return _failure_result(
                result,
                "og:image URL is not an HTTP(S) URL",
                keep_metadata=True,
            )
        result["image_url"] = image_url
        try:
            image = _fetch_image(image_url, assets_dir, asset_id, timeout, max_bytes)
        except HTTPError as error:
            return _failure_result(
                result,
                f"og:image HTTP {error.code}: {error.reason}",
                keep_metadata=True,
            )
        except (OSError, URLError, ValueError, _AssetFetchError) as error:
            return _failure_result(result, f"og:image: {error}", keep_metadata=True)
        result["image"] = image
        result["status"] = "ready"
    return result


def _failure_result(
    result: dict[str, object],
    error: str,
    http_status: int | None = None,
    *,
    keep_metadata: bool = False,
) -> dict[str, object]:
    result["status"] = "fallback"
    result["error"] = error
    if http_status is not None:
        result["http_status"] = http_status
    if not keep_metadata:
        result["title"] = None
        result["description"] = None
    return result


def _fetch_image(
    url: str,
    assets_dir: Path,
    asset_id: str,
    timeout: float,
    max_bytes: int,
) -> dict[str, object]:
    with urlopen(_request_url(url), timeout=timeout) as response:
        status, content_type, data = _read_response(response, max_bytes)
        if not content_type.startswith(_IMAGE_MIME_PREFIX):
            raise _AssetFetchError(
                f"expected image content, got {content_type}"
            )

    local_path = f"{asset_id}{_file_suffix(url, content_type)}"
    (assets_dir / local_path).write_bytes(data)
    return {
        "http_status": status,
        "local_path": local_path,
        "mime_type": content_type,
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "url": url,
    }


def _read_response(
    response: Any,
    max_bytes: int,
) -> tuple[int, str, bytes]:
    status = getattr(response, "status", None) or response.getcode()
    content_type = response.headers.get_content_type()
    content_length = response.headers.get("Content-Length")
    if content_length is not None and int(content_length) > max_bytes:
        raise _AssetFetchError(f"response exceeds {max_bytes} bytes")
    data = response.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise _AssetFetchError(f"response exceeds {max_bytes} bytes")
    return status, content_type, data


def _domain(url: str) -> str:
    return urlsplit(url).hostname or urlsplit(url).netloc


def _clean_text(value: str, limit: int) -> str | None:
    value = " ".join(value.split())
    if not value:
        return None
    return value[:limit]


class _PageMetadataParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.og_title: str | None = None
        self.og_description: str | None = None
        self.og_image: str | None = None
        self._document_title_parts: list[str] = []
        self._in_title = False

    @property
    def document_title(self) -> str | None:
        return _clean_text("".join(self._document_title_parts), _TEXT_LIMITS["title"])

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {
            name.lower(): value
            for name, value in attrs
            if value is not None
        }
        if tag.lower() == "meta":
            property_name = (
                attributes.get("property") or attributes.get("name") or ""
            ).lower()
            content = attributes.get("content")
            if not content:
                return
            if property_name == "og:title" and self.og_title is None:
                self.og_title = _clean_text(content, _TEXT_LIMITS["title"])
            elif property_name == "og:description" and self.og_description is None:
                self.og_description = _clean_text(
                    content,
                    _TEXT_LIMITS["description"],
                )
            elif property_name in {"og:image", "og:image:url"} and self.og_image is None:
                self.og_image = content.strip() or None
        elif tag.lower() == "title":
            self._in_title = True

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._document_title_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fetch OGP metadata for URL assets from a manifest"
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--assets", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--max-bytes", type=int, default=5 * 1024 * 1024)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        fetch_url_metadata(
            args.manifest,
            args.output,
            args.assets,
            args.report,
            timeout=args.timeout,
            max_bytes=args.max_bytes,
        )
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
