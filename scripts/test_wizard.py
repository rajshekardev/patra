import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import termios
import time


def run_wizard(binary, directory, actions, expected_status):
    master, slave = pty.openpty()
    try:
        original_mode = termios.tcgetattr(slave)
        with subprocess.Popen(
            [binary, "--new"], cwd=directory, stdin=slave, stdout=slave, stderr=slave,
        ) as process:
            try:
                for expected, keys in actions:
                    output = b""
                    deadline = time.monotonic() + 5
                    while expected not in output:
                        remaining = max(0, deadline - time.monotonic())
                        if not select.select([master], [], [], remaining)[0]:
                            raise AssertionError(f"Expected {expected!r}, got {output!r}")
                        output += os.read(master, 4096)
                    os.write(master, keys)

                status = process.wait(timeout=5)
                assert status == expected_status, status
                assert termios.tcgetattr(slave) == original_mode
            finally:
                if process.poll() is None:
                    process.kill()
    finally:
        os.close(master)
        os.close(slave)


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        name = "Café Project"
        run_wizard(binary, root, [
            (b"Project name: ", b"../outside\n"),
            (b"Project name: ", b"NUL.txt\n"),
            (b"Project name: ", name.encode() + b"\n"),
            (b"  [ ] Website", b"\n"),
            (b"Select at least one platform.", b"\x1b[A "),
            (b"> [x] Website", b"\x1b[A \x1b[A\x1b[A "),
            (b"> [x] Linux", b"\x1b[B  \n"),
        ], 0)
        project = root / name
        assert list(project.iterdir()) == [project / "config.json"]
        config = json.loads((project / "config.json").read_text(encoding="utf-8"))
        assert config == {"name": name, "platforms": ["linux", "server", "website"]}, config

        run_wizard(binary, root, [
            (b"Project name: ", b"Cancelled\n"),
            (b"  [ ] Website", b" \x03"),
        ], 130)
        assert not (root / "Cancelled").exists()

        run_wizard(binary, root, [
            (b"Project name: ", name.encode() + b"\n"),
            (b"  [ ] Website", b" \n"),
        ], 1)
        assert json.loads((project / "config.json").read_text(encoding="utf-8")) == config

        redirected = subprocess.run(
            [binary, "--new"], cwd=root, input="", capture_output=True, text=True, timeout=5,
        )
        assert redirected.returncode == 1
        assert "requires an interactive terminal" in redirected.stderr


if __name__ == "__main__":
    main()
