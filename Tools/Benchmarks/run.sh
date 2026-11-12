#!/bin/bash
# Before/after microbenchmarks for the optimization pass.
# Usage: Tools/Benchmarks/run.sh <label>
# Writes Tools/Benchmarks/results/<label>-{core,poster,bmp}.json.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
label="${1:-run}"
out="$root/Tools/Benchmarks/results"
mkdir -p "$out" "$root/.bench"

swift build -c release --product LumaWallBenchmarks >/dev/null
core_bin="$(swift build -c release --show-bin-path)/LumaWallBenchmarks"
"$core_bin" --json "$out/$label-core.json" >/dev/null
echo "core:   $out/$label-core.json"

swiftc -O -o "$root/.bench/posterbench" \
    "$root/Tools/Benchmarks/Poster/main.swift" \
    "$root/Sources/LumaWallApp/PosterCache.swift" \
    "$root/Sources/LumaWallApp/Brand.swift" \
    "$root/Sources/LumaWallApp/L10n.swift"
"$root/.bench/posterbench" --json "$out/$label-poster.json" >/dev/null
echo "poster: $out/$label-poster.json"

swiftc -O -o "$root/.bench/bmpbench" \
    "$root/Tools/Benchmarks/BMP/main.swift" \
    "$root/WallpaperExtension/BMPEncoding.swift"
"$root/.bench/bmpbench" --json "$out/$label-bmp.json" >/dev/null
echo "bmp:    $out/$label-bmp.json"

cat "$out/$label-core.json" "$out/$label-poster.json" "$out/$label-bmp.json"
