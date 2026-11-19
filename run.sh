#!/bin/bash
# Starts a golden image build: builds the build container (if needed), then
# runs build.sh on the given image inside a privileged container.
# Usage: ./run.sh <input.img> <output.img> [strip-list]
#
# E.g.: ./run.sh base-images/raspios-lite-arm64.img \
#         golden-images/raspios-lite-arm64-k3s.img
set -euo pipefail
[ $# -ge 2 ] || { echo "Usage: $0 <input.img> <output.img> [strip-list]"; exit 1; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT_IMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT_DIR="$(cd "$(dirname "$2")" && pwd)"
OUTPUT_NAME="$(basename "$2")"
STRIP_LIST_ARG="${3:-$SELF_DIR/strip-packages.list}"
STRIP_LIST="$(cd "$(dirname "$STRIP_LIST_ARG")" && pwd)/$(basename "$STRIP_LIST_ARG")"

[ -f "$INPUT_IMG" ] || { echo "No such file: $INPUT_IMG"; exit 1; }

docker build -t golden-image-builder "$SELF_DIR"

docker run --rm --privileged \
  -v "$INPUT_IMG:/work/input.img:ro" \
  -v "$OUTPUT_DIR:/work/out" \
  -v "$STRIP_LIST:/work/strip-packages.list:ro" \
  golden-image-builder /work/input.img "/work/out/$OUTPUT_NAME" /work/strip-packages.list
