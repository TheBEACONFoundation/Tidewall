#!/bin/bash
# Measures GPU and CPU cost of wallpaper scenarios. See Benchmarks/main.swift.
#   BENCH_SECONDS=8 BENCH_ROUNDS=3 Scripts/benchmark.sh "idle||" "aurora|Resources/Aurora.mov|"
# Quit Tidewall first so its own wallpaper doesn't skew the numbers.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p .build/tools
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos15" -o .build/tools/benchmark \
    Benchmarks/main.swift \
    Sources/Tidewall/Model/Wallpaper.swift \
    Sources/Tidewall/Engine/FramePipeline.swift \
    Sources/Tidewall/Engine/LoopingPlayer.swift \
    Sources/Tidewall/Engine/Rendition.swift \
    Sources/Tidewall/Engine/DesktopWindow.swift
.build/tools/benchmark "$@"
