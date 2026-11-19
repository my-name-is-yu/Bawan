#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$repo_dir/scripts/build.sh"
exec /usr/bin/python3 "$repo_dir/scripts/measure-memory.py" "$@"
