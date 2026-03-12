#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  echo "Error: .env file not found in $(pwd)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${TF_VAR_yacht_admin_password:-}" ]]; then
  echo "Error: TF_VAR_yacht_admin_password is not set. Update .env first." >&2
  exit 1
fi

if ! command -v tofu >/dev/null 2>&1; then
  echo "Error: OpenTofu (tofu) is not installed or not in PATH." >&2
  exit 1
fi

PLAN_FILE="${PLAN_FILE:-tfplan}"
PLAN_JSON_FILE="${PLAN_JSON_FILE:-tfplan.json}"
PLAN_DRAWIO_FILE="${PLAN_DIAGRAM_OUTPUT:-diagrams/plan.drawio}"

tofu plan -out "$PLAN_FILE" "$@"
tofu show -json "$PLAN_FILE" > "$PLAN_JSON_FILE"

if [[ "${SKIP_PLAN_DIAGRAM:-0}" == "1" ]]; then
  echo "Skipping plan diagram generation because SKIP_PLAN_DIAGRAM=1"
else
  if [[ ! -x ./generate_plan_diagram.sh ]]; then
    echo "Error: generate_plan_diagram.sh is missing or not executable." >&2
    exit 1
  fi

  ./generate_plan_diagram.sh \
    --input-state terraform.tfstate \
    --plan-json "$PLAN_JSON_FILE" \
    --output "$PLAN_DRAWIO_FILE" \
    --diagram-name "${PLAN_DIAGRAM_NAME:-Terraform Plan}"

  if [[ "${SKIP_PLAN_EXPORT:-0}" == "1" ]]; then
    echo "Skipping plan diagram exports because SKIP_PLAN_EXPORT=1"
  else
    if [[ ! -x ./export_diagram_assets.sh ]]; then
      echo "Error: export_diagram_assets.sh is missing or not executable." >&2
      exit 1
    fi

    ./export_diagram_assets.sh \
      --input "$PLAN_DRAWIO_FILE" \
      --output-dir "${PLAN_EXPORT_DIR:-diagrams}" \
      --formats "${PLAN_EXPORT_FORMATS:-svg,pdf,png}"
  fi
fi

tofu apply -auto-approve "$PLAN_FILE"

if [[ "${SKIP_POST_APPLY_CHECK:-0}" == "1" ]]; then
  echo "Skipping post-apply checks because SKIP_POST_APPLY_CHECK=1"
  exit 0
fi

if [[ ! -x ./post_apply_check.sh ]]; then
  echo "Error: post_apply_check.sh is missing or not executable." >&2
  exit 1
fi

./post_apply_check.sh
