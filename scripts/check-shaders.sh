#!/usr/bin/env bash
# Generates the Metal source for every built-in effect, preset and example recipe, then (on macOS)
# compiles each one with the offline Metal compiler. The app compiles these at runtime on the phone,
# so this is the only place shader typos are caught before they reach a device.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/shader-check
mkdir -p build

swift build --package-path Packages/ShadeCore -c release --product shadercheck
"$(swift build --package-path Packages/ShadeCore -c release --show-bin-path)/shadercheck" "$OUT" Examples/*.shade

if ! diff -q PROMPT.md "$OUT/PROMPT.md" >/dev/null; then
  echo "::warning::PROMPT.md is out of date. Copy $OUT/PROMPT.md over it."
  diff -u PROMPT.md "$OUT/PROMPT.md" | head -40 || true
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Not on macOS: skipped Metal compilation."
  exit 0
fi

failed=0
for f in "$OUT"/*.metal; do
  if ! xcrun -sdk iphoneos metal -std=metal3.0 -mios-version-min=16.0 -c "$f" -o "${f%.metal}.air" 2> "${f%.metal}.log"; then
    echo "::error::$(basename "$f") failed to compile"
    cat "${f%.metal}.log"
    failed=1
  elif [[ -s "${f%.metal}.log" ]]; then
    echo "warnings in $(basename "$f"):"
    cat "${f%.metal}.log"
  fi
done
exit $failed
