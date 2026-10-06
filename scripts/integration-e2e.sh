#!/usr/bin/env bash
# End-to-end integration run in the caller's own account: create a disposable
# ECS cluster, apply the blueprint against it, prove the service answers
# through the ALB, then destroy everything (also on failure).
#
# Costs about 25 minutes of an ALB, one NAT gateway, four interface endpoints
# in two zones, and one Fargate task: well under a dollar. The flow-log KMS key
# lingers pending deletion for 30 days, unusable and free of charge.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
setup="$root/tests/integration/setup"
e2e="$root/tests/integration/e2e"

[ -n "${AWS_REGION:-}${AWS_DEFAULT_REGION:-}" ] || { echo "error: set AWS_REGION (and credentials)" >&2; exit 1; }

cleanup() {
  status=$?
  echo "==> destroy blueprint"
  terraform -chdir="$e2e" destroy -auto-approve -input=false -no-color \
    -var "name=${name:-unused}" -var "cluster_arn=${cluster_arn:-arn:aws:ecs:us-east-1:000000000000:cluster/unused}" \
    -var "availability_zones=${zones:-[\"unused-1a\",\"unused-1b\"]}" || status=1
  echo "==> destroy fixtures"
  terraform -chdir="$setup" destroy -auto-approve -input=false -no-color || status=1
  exit "$status"
}
trap cleanup EXIT

echo "==> fixtures"
terraform -chdir="$setup" init -backend=false -input=false -no-color >/dev/null
terraform -chdir="$setup" apply -auto-approve -input=false -no-color
name="$(terraform -chdir="$setup" output -raw name)"
cluster_arn="$(terraform -chdir="$setup" output -raw cluster_arn)"
zones="$(terraform -chdir="$setup" output -json availability_zones)"

echo "==> blueprint (apply waits for the task to pass ALB health checks)"
terraform -chdir="$e2e" init -backend=false -input=false -no-color >/dev/null
terraform -chdir="$e2e" apply -auto-approve -input=false -no-color \
  -var "name=$name" -var "cluster_arn=$cluster_arn" -var "availability_zones=$zones"

url="$(terraform -chdir="$e2e" output -raw url)"
echo "==> GET $url"
for attempt in $(seq 1 30); do
  if curl -fsS -o /dev/null "$url/"; then
    echo "ok: $url answered 200 through the ALB on attempt $attempt"
    exit 0
  fi
  sleep 10
done
echo "error: $url did not answer within 5 minutes" >&2
exit 1
