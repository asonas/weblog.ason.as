import hashlib
import json
import mimetypes
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from .normalize import NormalizationResult


_IMAGE_HOSTS = {"gyazo.com", "i.gyazo.com"}


@dataclass(frozen=True)
class AssetManifestEntry:
    id: str
    url: str
    kind: str
    source_post_ids: tuple[str, ...]

    def as_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "url": self.url,
            "kind": self.kind,
            "source_post_ids": list(self.source_post_ids),
        }


def canonicalize_url(url: str) -> str:
    parsed = urlsplit(url.strip())
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"unsupported external URL: {url!r}")
    return urlunsplit(
        (
            parsed.scheme.lower(),
            parsed.netloc.lower(),
            parsed.path,
            parsed.query,
            "",
        )
    )


def stable_url_asset_id(url: str) -> str:
    canonical_url = canonicalize_url(url)
    digest = hashlib.sha256(canonical_url.encode("utf-8")).hexdigest()[:16]
    return f"asset_{digest}"


def classify_url(url: str) -> str:
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    if host in _IMAGE_HOSTS:
        return "image"

    mime_type, _ = mimetypes.guess_type(parsed.path)
    if mime_type is None:
        return "url"
    if mime_type.startswith("image/"):
        return "image"
    if mime_type.startswith("audio/"):
        return "audio"
    if mime_type.startswith("video/"):
        return "video"
    return "url"


def build_asset_manifest(
    normalized: NormalizationResult,
) -> tuple[AssetManifestEntry, ...]:
    sources: dict[str, set[str]] = {}
    kinds: dict[str, str] = {}
    for post in normalized.posts:
        for raw_url in post.external_urls:
            try:
                canonical_url = canonicalize_url(raw_url)
            except ValueError:
                continue
            sources.setdefault(canonical_url, set()).add(post.id)
            kinds.setdefault(canonical_url, classify_url(canonical_url))

    entries = tuple(
        AssetManifestEntry(
            id=stable_url_asset_id(url),
            url=url,
            kind=kinds[url],
            source_post_ids=tuple(sorted(sources[url])),
        )
        for url in sorted(sources)
    )
    return tuple(sorted(entries, key=lambda entry: entry.id))


def write_asset_manifest(
    output_dir: Path,
    normalized: NormalizationResult,
) -> Path:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "asset-manifest.json"
    payload = {
        "assets": [entry.as_dict() for entry in build_asset_manifest(normalized)]
    }
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path
