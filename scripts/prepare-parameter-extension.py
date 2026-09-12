"""Download the pinned AWS arm64 extension for Dockerfile.lambda."""

import base64
import hashlib
import io
import json
from pathlib import Path
import subprocess
import urllib.request
import zipfile


LAYER_ARN = "arn:aws:lambda:ap-northeast-1:133490724326:layer:AWS-Parameters-and-Secrets-Lambda-Extension-Arm64:124"
SHA256 = "/PuSRpQv1/SbnaZiITk6CFBXXn2D59MLMSjgp9/C8sE="


def main():
    metadata = json.loads(subprocess.check_output([
        "aws", "lambda", "get-layer-version-by-arn", "--region", "ap-northeast-1",
        "--arn", LAYER_ARN, "--output", "json",
    ]))
    if metadata["Content"]["CodeSha256"] != SHA256:
        raise RuntimeError("Unexpected extension metadata digest")
    try:
        with urllib.request.urlopen(metadata["Content"]["Location"], timeout=30) as response:
            archive = response.read()
    except Exception:
        # Signed download URLs must not appear in build logs.
        raise RuntimeError("Extension download failed") from None
    if base64.b64encode(hashlib.sha256(archive).digest()).decode() != SHA256:
        raise RuntimeError("Extension archive digest mismatch")
    destination = Path(__file__).resolve().parent.parent / "dist/parameter-extension"
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        for member in bundle.infolist():
            path = destination / member.filename
            if not path.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError("Unsafe extension archive path")
            bundle.extract(member, destination)
            if not member.is_dir():
                path.chmod((member.external_attr >> 16) & 0o777 or 0o644)
    binaries = list((destination / "extensions").iterdir())
    if not binaries or not all(path.is_file() and path.stat().st_mode & 0o111 for path in binaries):
        raise RuntimeError("Extension executable is missing")
    print(f"Prepared {LAYER_ARN} (SHA256 verified)")


if __name__ == "__main__":
    main()
