import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import pytest

from log_migration.asset_manifest import stable_url_asset_id
from log_migration.url_metadata import fetch_url_metadata


IMAGE_BYTES = b"\x89PNG\r\n\x1a\nurl-preview"


class _MetadataHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        path = unquote(self.path.split("?", 1)[0])
        if path == "/article":
            body = (
                "<html><head>"
                "<title>Document title</title>"
                '<meta property="og:title" content="Article &amp; title">'
                '<meta property="og:description" content="A useful description">'
                '<meta property="og:image" content="/preview.jpg">'
                "</head></html>"
            ).encode()
            self._send(200, "text/html", body)
            return
        if path == "/preview.jpg":
            self._send(200, "image/jpeg", IMAGE_BYTES)
            return
        if path == "/no-ogp":
            self._send(
                200,
                "text/html",
                b"<html><head><title>Fallback title</title></head></html>",
            )
            return
        if path == "/broken-image":
            body = (
                "<html><head>"
                '<meta property="og:title" content="Broken preview">'
                '<meta property="og:image" content="/not-an-image">'
                "</head></html>"
            ).encode()
            self._send(200, "text/html", body)
            return
        if path == "/not-an-image":
            self._send(200, "text/html", b"<html>not an image</html>")
            return
        if path == "/forbidden":
            self.send_error(403)
            return
        self.send_error(404)

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


@pytest.fixture
def local_metadata_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _MetadataHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def _write_manifest(path: Path, entries: list[dict[str, object]]) -> None:
    path.write_text(
        json.dumps({"assets": entries}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def test_fetch_url_metadata_saves_ogp_image_and_fallbacks(
    tmp_path: Path,
    local_metadata_server: str,
):
    article_url = f"{local_metadata_server}/article"
    manifest_path = tmp_path / "asset-manifest.json"
    _write_manifest(
        manifest_path,
        [
            {
                "id": stable_url_asset_id(article_url),
                "url": article_url,
                "kind": "url",
                "source_post_ids": ["post-a", "post-b"],
            },
            {
                "id": stable_url_asset_id(f"{local_metadata_server}/no-ogp"),
                "url": f"{local_metadata_server}/no-ogp",
                "kind": "url",
                "source_post_ids": ["post-c"],
            },
            {
                "id": stable_url_asset_id(f"{local_metadata_server}/broken-image"),
                "url": f"{local_metadata_server}/broken-image",
                "kind": "url",
                "source_post_ids": ["post-d"],
            },
            {
                "id": stable_url_asset_id(f"{local_metadata_server}/forbidden"),
                "url": f"{local_metadata_server}/forbidden",
                "kind": "url",
                "source_post_ids": ["post-e"],
            },
            {
                "id": stable_url_asset_id(f"{local_metadata_server}/missing"),
                "url": f"{local_metadata_server}/missing",
                "kind": "url",
                "source_post_ids": ["post-f"],
            },
        ],
    )
    before_manifest = manifest_path.read_bytes()
    metadata_path = tmp_path / "url-metadata.json"
    assets_dir = tmp_path / "assets"

    report = fetch_url_metadata(
        manifest_path,
        metadata_path,
        assets_dir,
        tmp_path / "url-metadata-report.json",
    )

    payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata = {entry["id"]: entry for entry in payload["assets"]}
    article = metadata[stable_url_asset_id(article_url)]
    assert article["status"] == "ready"
    assert article["title"] == "Article & title"
    assert article["description"] == "A useful description"
    assert article["source_post_ids"] == ["post-a", "post-b"]
    image = article["image"]
    assert image["url"] == f"{local_metadata_server}/preview.jpg"
    assert image["sha256"] == hashlib.sha256(IMAGE_BYTES).hexdigest()
    assert (assets_dir / image["local_path"]).read_bytes() == IMAGE_BYTES

    no_ogp = metadata[stable_url_asset_id(f"{local_metadata_server}/no-ogp")]
    assert no_ogp["status"] == "fallback"
    assert no_ogp["title"] == "Fallback title"
    assert no_ogp["image"] is None

    broken = metadata[stable_url_asset_id(f"{local_metadata_server}/broken-image")]
    assert broken["status"] == "fallback"
    assert broken["title"] == "Broken preview"
    assert broken["image"] is None
    assert "expected image content" in broken["error"]

    forbidden = metadata[stable_url_asset_id(f"{local_metadata_server}/forbidden")]
    missing = metadata[stable_url_asset_id(f"{local_metadata_server}/missing")]
    assert forbidden["http_status"] == 403
    assert missing["http_status"] == 404
    assert report["ready"] == 1
    assert report["fallback"] == 4
    assert manifest_path.read_bytes() == before_manifest
