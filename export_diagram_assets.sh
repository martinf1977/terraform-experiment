#!/usr/bin/env bash
set -euo pipefail

INPUT_DIAGRAM="${INPUT_DIAGRAM:-diagrams/plan.drawio}"
OUTPUT_DIR="${OUTPUT_DIR:-diagrams}"
EXPORT_FORMATS="${EXPORT_FORMATS:-svg,pdf,png}"
DRAWIO_IMAGE="${DRAWIO_IMAGE:-rlespinasse/drawio-desktop-headless:latest}"

usage() {
  cat <<'USAGE'
Usage: ./export_diagram_assets.sh [options]

Options:
  -i, --input <file>      Input .drawio file (default: diagrams/plan.drawio)
  -d, --output-dir <dir>  Output directory (default: diagrams)
  -f, --formats <list>    Comma-separated formats (default: svg,pdf,png)
      --image <name>      Draw.io container image
  -h, --help              Show this help
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--input)
        INPUT_DIAGRAM="$2"
        shift
        ;;
      -d|--output-dir)
        OUTPUT_DIR="$2"
        shift
        ;;
      -f|--formats)
        EXPORT_FORMATS="$2"
        shift
        ;;
      --image)
        DRAWIO_IMAGE="$2"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Error: unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH." >&2
    exit 1
  fi
}

fix_ownership() {
  local file_path="$1"
  docker run --rm \
    -v "$PWD:/work" \
    -w /work \
    alpine:3.20 \
    sh -lc "chown $(id -u):$(id -g) '$file_path'" >/dev/null 2>&1 || true
}

is_supported_format() {
  local fmt="$1"
  case "$fmt" in
    svg|pdf|png|jpg|xml)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

main() {
  parse_args "$@"
  require_cmd docker

  if [[ ! -f "$INPUT_DIAGRAM" ]]; then
    echo "Error: diagram file '$INPUT_DIAGRAM' not found." >&2
    exit 1
  fi

  mkdir -p "$OUTPUT_DIR"

  local base_name
  base_name="$(basename "$INPUT_DIAGRAM" .drawio)"

  IFS=',' read -r -a formats <<< "$EXPORT_FORMATS"

  local fmt
  for fmt in "${formats[@]}"; do
    fmt="${fmt// /}"

    if [[ -z "$fmt" ]]; then
      continue
    fi

    if ! is_supported_format "$fmt"; then
      echo "Error: unsupported format '$fmt'. Supported formats: svg,pdf,png,jpg,xml" >&2
      exit 1
    fi

    local output_file
    output_file="$OUTPUT_DIR/$base_name.$fmt"

    docker run --rm \
      -v "$PWD:/work" \
      -w /work \
      "$DRAWIO_IMAGE" \
      -x \
      -f "$fmt" \
      -o "$output_file" \
      "$INPUT_DIAGRAM"

    fix_ownership "$output_file"

    echo "Exported: $output_file"
  done
}

main "$@"
