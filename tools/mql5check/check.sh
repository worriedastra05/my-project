#!/usr/bin/env bash
# Static syntax / type check for the MQL5 Expert Advisor using g++.
# Development aid only - MetaEditor remains the authoritative compiler.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="${1:-$ROOT/MQL5/Experts/CrossSectionalMomentum/CrossSectionalMomentumEA.mq5}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "==> source : $SRC"
python3 "$HERE/preprocess.py" "$SRC" "$OUT/ea.cpp"
cp "$HERE/mql5_shim.hpp" "$OUT/"

echo "==> g++ -fsyntax-only"
g++ -std=c++17 -fsyntax-only \
    -Wall -Wextra \
    -Wno-unused-variable -Wno-unused-parameter -Wno-unused-function \
    -Wno-unused-but-set-variable \
    -I "$OUT" "$OUT/ea.cpp"

echo "==> OK: no syntax or type errors"
