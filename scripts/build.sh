#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'Lore.appのビルドにはApple SiliconのMacが必要です。' >&2
    exit 1
fi
cmake -S "$repo_dir" -B "$repo_dir/build" -DCMAKE_BUILD_TYPE=Release "$@"
cmake --build "$repo_dir/build" --target Lore --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-3}"
printf '\n%s\n' "$repo_dir/build/Lore.app"
