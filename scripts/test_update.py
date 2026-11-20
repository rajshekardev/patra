import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tempfile


LATEST_URL = "https://api.github.com/repos/rajshekardev/patra/releases/latest"
DOWNLOAD_ROOT = "https://github.com/rajshekardev/patra/releases/download/v99.0.0/"


def test_update(binary, root):
    asset = "patra-macos-universal" if platform.system() == "Darwin" else {
        "aarch64": "patra-linux-arm64",
        "x86_64": "patra-linux-amd64",
    }[platform.machine()]
    directory = root / "installed programs"
    directory.mkdir()
    executable = directory / "patra"
    shutil.copy2(binary, executable)
    executable.chmod(0o751)
    link = root / "patra"
    link.symlink_to(executable)
    original = executable.read_bytes()
    installed_version = subprocess.check_output([link, "--version"], text=True).strip()[6:]

    payload = b"#!/bin/sh\nprintf 'patra v99.0.0\\n'\n"
    (root / "download").write_bytes(payload)
    curl = root / "curl"
    curl.write_text(
        f"#!{sys.executable}\n"
        "import os, pathlib, sys\n"
        "root = pathlib.Path(os.environ['PATRA_UPDATE_FIXTURE'])\n"
        "url = sys.argv[sys.argv.index('--url') + 1]\n"
        "with (root / 'requests').open('a') as requests:\n"
        "    print(url, file=requests)\n"
        f"if url == {LATEST_URL!r}:\n"
        "    sys.stdout.buffer.write((root / 'release.json').read_bytes())\n"
        f"elif url == {DOWNLOAD_ROOT + asset!r}:\n"
        "    sys.stdout.buffer.write((root / 'download').read_bytes())\n"
        "else:\n"
        "    sys.exit(22)\n"
    )
    curl.chmod(0o755)
    env = dict(os.environ, PATH=f"{root}{os.pathsep}{os.environ['PATH']}", PATRA_UPDATE_FIXTURE=str(root))
    release = {
        "tag_name": installed_version,
        "assets": [
            {"name": "unused", "browser_download_url": DOWNLOAD_ROOT + "unused"},
            {
                "name": asset,
                "browser_download_url": DOWNLOAD_ROOT + asset,
                "digest": "sha256:" + hashlib.sha256(payload).hexdigest(),
                "size": len(payload),
            },
        ],
    }

    def update(expected_requests):
        (root / "requests").unlink(missing_ok=True)
        (root / "release.json").write_text(json.dumps(release))
        result = subprocess.run([link, "--update"], cwd=root, env=env, capture_output=True, text=True, timeout=15)
        assert (root / "requests").read_text().splitlines() == expected_requests
        assert list(directory.iterdir()) == [executable]
        assert link.is_symlink()
        return result

    result = update([LATEST_URL])
    assert result.returncode == 0 and "already up to date" in result.stdout, result
    assert executable.read_bytes() == original

    release["tag_name"] = "v0.0.0"
    result = update([LATEST_URL])
    assert result.returncode == 0 and "already up to date" in result.stdout, result
    assert executable.read_bytes() == original

    release["tag_name"] = "v99.0.0"
    (root / "download").write_bytes(payload[:-1] + b"!")  # Same size, wrong digest.
    result = update([LATEST_URL, DOWNLOAD_ROOT + asset])
    assert result.returncode == 1 and "SHA-256" in result.stderr, result
    assert executable.read_bytes() == original

    (root / "download").write_bytes(payload)
    result = update([LATEST_URL, DOWNLOAD_ROOT + asset])
    assert result.returncode == 0 and "Updated Patra to v99.0.0" in result.stdout, result
    assert stat.S_IMODE(executable.stat().st_mode) == 0o751
    assert subprocess.check_output([link, "--version"], text=True).strip() == "patra v99.0.0"


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        test_update(Path(sys.argv[1]).resolve(), Path(directory))
