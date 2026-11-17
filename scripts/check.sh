#!/bin/sh
#   ./scripts/check.sh             warnings-as-errors build + CTest
#   ./scripts/check.sh --sanitize  same, with ASan and UBSan
# Extra arguments are passed to the CMake configure step. Set
# BAWAN_CHECK_BUILD_DIR to build somewhere other than ./build-check.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="${BAWAN_CHECK_BUILD_DIR:-$repo_dir/build-check}"
sanitize=OFF
build_type=Release
if [ "${1:-}" = --sanitize ]; then
    sanitize=ON
    build_type=RelWithDebInfo
    build_dir="$build_dir-sanitize"
    shift
fi
cmake -S "$repo_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE="$build_type" \
    -DBAWAN_BUILD_TESTS=ON -DBAWAN_WARNINGS_AS_ERRORS=ON -DBAWAN_ENABLE_SANITIZERS="$sanitize" "$@"
cmake --build "$build_dir" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-3}"
ctest --test-dir "$build_dir" --output-on-failure
