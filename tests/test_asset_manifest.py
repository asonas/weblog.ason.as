import json
from pathlib import Path

from log_migration.asset_manifest import (
    build_asset_manifest,
    canonicalize_url,
    classify_url,
    write_asset_manifest,
)

from support import normalized_result_with_external_urls


def test_manifest_deduplicates_canonical_urls_and_keeps_sources():
    normalized = normalized_result_with_external_urls(
        ("https://gyazo.com/abc#top",),
        ("https://gyazo.com/abc", "https://example.test/voice.mp3"),
    )

    entries = build_asset_manifest(normalized)

    assert len(entries) == 2
    gyazo = next(entry for entry in entries if entry.url == "https://gyazo.com/abc")
    assert gyazo.kind == "image"
    assert gyazo.source_post_ids == ("post-a", "post-b")


def test_url_normalization_and_classification_are_deterministic():
    assert canonicalize_url("HTTPS://EXAMPLE.TEST/image.png#top") == (
        "https://example.test/image.png"
    )
    assert classify_url("https://gyazo.com/abc") == "image"
    assert classify_url("https://example.test/voice.mp3") == "audio"
    assert classify_url("https://example.test/movie.webm") == "video"
    assert classify_url("https://example.test/article") == "url"


def test_write_asset_manifest_is_byte_identical_on_repeated_runs(tmp_path: Path):
    normalized = normalized_result_with_external_urls(
        ("https://example.test/article", "https://example.test/image.png"),
    )

    first_path = write_asset_manifest(tmp_path / "first", normalized)
    second_path = write_asset_manifest(tmp_path / "second", normalized)

    first = json.loads(first_path.read_text(encoding="utf-8"))
    second = json.loads(second_path.read_text(encoding="utf-8"))
    assert first == second
    assert first_path.read_text(encoding="utf-8") == second_path.read_text(encoding="utf-8")
