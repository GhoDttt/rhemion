#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds Contents/Helpers/rhemion-transcribe: the pinned transcribe.cpp release (used as is: Metal, static,
# arm64) plus our small helper (native/helpers/rhemion-transcribe). Source and build live in native/.transcribe
# (not in git). Prints the binary path. To upgrade, change TAG and
# COMMIT, rebuild, and run the speech checks before shipping.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TAG="v0.4.0"
COMMIT="f1dcd15"
WORK="$ROOT/native/.transcribe"
SRC="$WORK/transcribe.cpp"
BUILD="$WORK/build"
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
  git clone -q --depth 1 --branch "$TAG" https://github.com/handy-computer/transcribe.cpp.git "$SRC" >&2
fi
HEAD="$(git -C "$SRC" rev-parse --short=7 HEAD)"
[ "$HEAD" = "$COMMIT" ] || { echo "transcribe.cpp at $HEAD, expected $COMMIT ($TAG)" >&2; exit 1; }
# transcribe.cpp builds as its own project (static libtranscribe + ggml); the helper is one file linked to it.
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
  -DTRANSCRIBE_BUILD_TOOLS=OFF -DTRANSCRIBE_METAL=ON -DTRANSCRIBE_USE_OPENMP=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 >/dev/null
cmake --build "$BUILD" -j 8 >&2
OUT="$WORK/rhemion-transcribe"
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=15.0 "$ROOT/native/helpers/rhemion-transcribe/main.cpp" \
  -I "$SRC/include" -o "$OUT" \
  "$BUILD/src/libtranscribe.a" "$BUILD/ggml/src/ggml-metal/libggml-metal.a" "$BUILD/ggml/src/libggml-cpu.a" \
  "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-base.a" \
  -framework Metal -framework MetalKit -framework Foundation -framework Accelerate
echo "$OUT"
