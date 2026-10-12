#!/usr/bin/env sh
set -eu

CLI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$CLI_DIR"
odin build . -out:patra
