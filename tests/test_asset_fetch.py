import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import pytest

from log_migration.assets import fetch_assets


PNG_BYTES = b"\x89PNG\r\n\x1a\nphase-zero"


class _AssetHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        path = unquote(self.path.split("?", 1)[0])
        if path in {"/image.png", "/画像/日本語.png"}:
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG_BYTES)))
            self.end_headers()
            self.wfile.write(PNG_BYTES)
            return
        if self.path == "/html-as-image":
            body = b"<html>not an image</html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def log_message(self, format, *args):
        return


@pytest.fixture
def local_asset_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _AssetHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def _write_manifest(path: Path, entries: list[dict[str, object]]) -> None:
    manifest = {
        "assets": [
            {"source_post_ids": [], **entry}
            for entry in entries
        ]
    }
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def test_fetch_assets_writes_success_and_failure_records(
    tmp_path: Path,
    local_asset_server: str,
):
    manifest_path = tmp_path / "asset-manifest.json"
    _write_manifest(
        manifest_path,
        [
            {
                "id": "asset-image",
                "url": f"{local_asset_server}/image.png",
                "kind": "image",
            },
            {
                "id": "asset-missing",
                "url": f"{local_asset_server}/missing",
                "kind": "url",
            },
        ],
    )
    before_manifest = manifest_path.read_bytes()

    report = fetch_assets(
        manifest_path,
        tmp_path / "assets",
        tmp_path / "fetch.json",
    )

    assert report["downloaded"] == 1
    assert report["failed"] == 1
    assert (tmp_path / "assets" / "asset-image.png").read_bytes() == PNG_BYTES
    result = next(item for item in report["results"] if item["id"] == "asset-image")
    assert result["sha256"] == hashlib.sha256(PNG_BYTES).hexdigest()
    assert manifest_path.read_bytes() == before_manifest
    assert (tmp_path / "fetch.json").is_file()


def test_fetch_assets_rejects_image_content_type_mismatch(
    tmp_path: Path,
    local_asset_server: str,
):
    manifest_path = tmp_path / "asset-manifest.json"
    _write_manifest(
        manifest_path,
        [
            {
                "id": "asset-html",
                "url": f"{local_asset_server}/html-as-image",
                "kind": "image",
            },
        ],
    )

    report = fetch_assets(
        manifest_path,
        tmp_path / "assets",
        tmp_path / "fetch.json",
    )

    assert report["downloaded"] == 0
    assert report["failed"] == 1
    assert not (tmp_path / "assets" / "asset-html.html").exists()


def test_fetch_assets_encodes_non_ascii_request_urls(
    tmp_path: Path,
    local_asset_server: str,
):
    manifest_path = tmp_path / "asset-manifest.json"
    _write_manifest(
        manifest_path,
        [
            {
                "id": "asset-unicode",
                "url": f"{local_asset_server}/画像/日本語.png",
                "kind": "image",
            },
        ],
    )

    report = fetch_assets(
        manifest_path,
        tmp_path / "assets",
        tmp_path / "fetch.json",
    )

    assert report["downloaded"] == 1
    assert report["failed"] == 0
    assert (tmp_path / "assets" / "asset-unicode.png").read_bytes() == PNG_BYTES
