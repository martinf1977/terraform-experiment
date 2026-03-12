#!/usr/bin/env bash
set -euo pipefail

INPUT_STATE="${INPUT_STATE:-terraform.tfstate}"
INPUT_PLAN_JSON="${INPUT_PLAN_JSON:-}"
OUTPUT_DIAGRAM="${OUTPUT_DIAGRAM:-diagrams/plan.drawio}"
DIAGRAM_NAME="${DIAGRAM_NAME:-Terraform Plan}"
GROUPING_MODE="${GROUPING_MODE:-module-vpc-subnet}"
EDGE_MODE="${EDGE_MODE:-all}"

usage() {
  cat <<'USAGE'
Usage: ./generate_plan_diagram.sh [options]

Options:
  -i, --input-state <file>   Terraform state file path (default: terraform.tfstate)
      --plan-json <file>     Optional Terraform plan JSON path (tofu show -json)
  -o, --output <file>        Output drawio path (default: diagrams/plan.drawio)
      --diagram-name <name>  Draw.io tab name (default: Terraform Plan)
      --grouping <mode>      Grouping mode: none|module|module-vpc-subnet
      --edge-mode <mode>     Edge mode: all|depends-only|inferred-only
  -h, --help                 Show this help
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--input-state)
        INPUT_STATE="$2"
        shift
        ;;
      --plan-json)
        INPUT_PLAN_JSON="$2"
        shift
        ;;
      -o|--output)
        OUTPUT_DIAGRAM="$2"
        shift
        ;;
      --diagram-name)
        DIAGRAM_NAME="$2"
        shift
        ;;
      --grouping)
        GROUPING_MODE="$2"
        shift
        ;;
      --edge-mode)
        EDGE_MODE="$2"
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

main() {
  parse_args "$@"
  require_cmd docker

  if [[ ! -f "$INPUT_STATE" ]]; then
    echo "Error: state file '$INPUT_STATE' not found." >&2
    exit 1
  fi

  if [[ -n "$INPUT_PLAN_JSON" && ! -f "$INPUT_PLAN_JSON" ]]; then
    echo "Error: plan JSON file '$INPUT_PLAN_JSON' not found." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$OUTPUT_DIAGRAM")"

  local cmd=(
    docker run --rm
    -v "$PWD:/work"
    -w /work
    martinf1977/tfstate-drawio:latest
    -i "$INPUT_STATE"
    -o "$OUTPUT_DIAGRAM"
    --diagram-name "$DIAGRAM_NAME"
    --grouping "$GROUPING_MODE"
    --edge-mode "$EDGE_MODE"
  )

  if [[ -n "$INPUT_PLAN_JSON" ]]; then
    cmd+=(--plan "$INPUT_PLAN_JSON")
  fi

  "${cmd[@]}"
  fix_ownership "$OUTPUT_DIAGRAM"

  echo "Generated diagram: $OUTPUT_DIAGRAM"
}

main "$@"
