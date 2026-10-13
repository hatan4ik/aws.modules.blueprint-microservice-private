#!/usr/bin/env bash
# End-to-end integration run in the caller's own account: create a disposable
# ECS cluster, apply the blueprint against it, prove the service answers
# through the ALB, then destroy everything (also on failure).
#
#   --variant public       (default) stock nginx from ECR Public through a NAT
#                          gateway (tests/integration/e2e). Proves the
#                          composition and the ALB path; the image never
#                          touches the ECR endpoints.
#   --variant private-ecr  no NAT gateway; the same nginx imported into a
#                          private ECR repository through a pull through cache
#                          (tests/integration/private-ecr), pulled by the task
#                          through the ecr.api, ecr.dkr, s3, and logs
#                          endpoints and their policies
#                          (tests/integration/e2e-private-ecr).
#
# Each costs well under a dollar; see tests/integration/README.md. The
# flow-log KMS key lingers pending deletion for 30 days, unusable and free of
# charge.
set -euo pipefail

variant=public
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) variant="${2:-}"; shift 2 ;;
    --variant=*) variant="${1#--variant=}"; shift ;;
    *) echo "usage: $0 [--variant public|private-ecr]" >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
setup="$root/tests/integration/setup"
image_fixture="$root/tests/integration/private-ecr"
case "$variant" in
  public) e2e="$root/tests/integration/e2e" ;;
  private-ecr) e2e="$root/tests/integration/e2e-private-ecr" ;;
  *) echo "error: unknown variant '$variant' (public or private-ecr)" >&2; exit 2 ;;
esac

[ -n "${AWS_REGION:-}${AWS_DEFAULT_REGION:-}" ] || { echo "error: set AWS_REGION (and credentials)" >&2; exit 1; }

# Placeholder values that satisfy every variable's validation, so destroy can
# run even when a step failed before the real values were known.
unused_image="000000000000.dkr.ecr.us-east-1.amazonaws.com/unused@sha256:0000000000000000000000000000000000000000000000000000000000000000"

e2e_vars() {
  local vars=(-var "name=${name:-unused}"
    -var "cluster_arn=${cluster_arn:-arn:aws:ecs:us-east-1:000000000000:cluster/unused}"
    -var "availability_zones=${zones:-[\"unused-1a\",\"unused-1b\"]}")
  [ "$variant" = "private-ecr" ] && vars+=(-var "image=${image:-$unused_image}")
  printf '%s\0' "${vars[@]}"
}

# Prints why every stopped task of the service stopped, and fails when any
# could not pull its image or initialise (the symptoms of a VPC endpoint, an
# endpoint policy, or the execution role refusing the pull). Stopped tasks
# stay visible for about an hour, long enough for both the success path and
# the cleanup after a failed apply.
#
# A failed AWS call (missing CLI, ecs:ListTasks denied, wrong region or
# cluster) is an error, never "no stopped tasks": the gate must not pass
# vacuously. A failure that has already been reported is not reported a second
# time by the cleanup trap, but a check that passed (or found nothing) is NOT
# remembered: tasks can still stop during the later HTTP probe, and the trap
# must then be able to explain why.
stopped_tasks_reported=0
check_stopped_tasks() {
  [ -n "${cluster_arn:-}" ] && [ -n "${name:-}" ] || return 0
  [ "$stopped_tasks_reported" -eq 0 ] || return 0
  local arns reasons errfile
  errfile="$(mktemp)"
  if ! arns="$(aws ecs list-tasks --cluster "$cluster_arn" --service-name "$name" --desired-status STOPPED \
    --query 'taskArns' --output text 2>"$errfile")"; then
    echo "error: could not list stopped tasks of service $name in $cluster_arn:" >&2
    cat "$errfile" >&2
    rm -f "$errfile"
    stopped_tasks_reported=1
    return 1
  fi
  if [ -z "$arns" ] || [ "$arns" = "None" ]; then
    rm -f "$errfile"
    echo "ok: no stopped tasks for service $name"
    return 0
  fi
  # shellcheck disable=SC2086 # one argument per task ARN
  if ! reasons="$(aws ecs describe-tasks --cluster "$cluster_arn" --tasks $arns \
    --query "tasks[].[taskArn, stopCode, stoppedReason, join('; ', containers[].reason)]" --output text 2>"$errfile")"; then
    echo "error: could not describe the stopped tasks of service $name:" >&2
    cat "$errfile" >&2
    rm -f "$errfile"
    stopped_tasks_reported=1
    return 1
  fi
  rm -f "$errfile"
  echo "==> stopped tasks of $name"
  echo "$reasons"
  if grep -Eq 'CannotPullContainerError|ResourceInitializationError' <<<"$reasons"; then
    echo "error: a task could not pull its image or initialise; see the reasons above" >&2
    stopped_tasks_reported=1
    return 1
  fi
}

# Set once the matching `terraform init` has completed; destroy only runs for
# roots that were initialised, so an early failure does not add init/provider
# errors from destroying a root that was never set up.
setup_inited=0
image_inited=0
e2e_inited=0

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    # Diagnostic only: the run already failed, and the check reports its own errors.
    check_stopped_tasks || true
  fi
  if [ "$e2e_inited" -eq 1 ]; then
    echo "==> destroy blueprint"
    local vars=()
    while IFS= read -r -d '' arg; do vars+=("$arg"); done < <(e2e_vars)
    terraform -chdir="$e2e" destroy -auto-approve -input=false -no-color "${vars[@]}" || status=1
  fi
  if [ "$variant" = "private-ecr" ] && [ "$image_inited" -eq 1 ]; then
    echo "==> destroy private ECR image"
    terraform -chdir="$image_fixture" destroy -auto-approve -input=false -no-color -var "name=${name:-unused}" || status=1
  fi
  if [ "$setup_inited" -eq 1 ]; then
    echo "==> destroy fixtures"
    terraform -chdir="$setup" destroy -auto-approve -input=false -no-color || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

echo "==> fixtures (variant: $variant)"
terraform -chdir="$setup" init -backend=false -input=false -no-color >/dev/null
setup_inited=1
terraform -chdir="$setup" apply -auto-approve -input=false -no-color
name="$(terraform -chdir="$setup" output -raw name)"
cluster_arn="$(terraform -chdir="$setup" output -raw cluster_arn)"
zones="$(terraform -chdir="$setup" output -json availability_zones)"

if [ "$variant" = "private-ecr" ]; then
  echo "==> private ECR image (pull through cache from ECR Public, imported without docker)"
  terraform -chdir="$image_fixture" init -backend=false -input=false -no-color >/dev/null
  image_inited=1
  terraform -chdir="$image_fixture" apply -auto-approve -input=false -no-color -var "name=$name"
  image="$(terraform -chdir="$image_fixture" output -raw image)"
fi

echo "==> blueprint (apply waits for the task to pass ALB health checks)"
vars=()
while IFS= read -r -d '' arg; do vars+=("$arg"); done < <(e2e_vars)
terraform -chdir="$e2e" init -backend=false -input=false -no-color >/dev/null
e2e_inited=1
terraform -chdir="$e2e" apply -auto-approve -input=false -no-color "${vars[@]}"

if [ "$variant" = "private-ecr" ]; then
  echo "==> the private subnets have no way out of the VPC"
  nat_ips="$(terraform -chdir="$e2e" output -json nat_gateway_public_ips)"
  [ "$nat_ips" = "{}" ] || { echo "error: expected no NAT gateway, got $nat_ips" >&2; exit 1; }
  subnets="$(terraform -chdir="$e2e" output -json private_subnet_ids | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).values()))')"
  routes="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnets" \
    --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0' || DestinationIpv6CidrBlock=='::/0'][]" --output json)"
  [ "$routes" = "[]" ] || { echo "error: a private route table has a default route: $routes" >&2; exit 1; }
  echo "ok: no NAT gateway and no default route in the private subnets ($subnets)"
fi

echo "==> no task failed to pull its image"
check_stopped_tasks

url="$(terraform -chdir="$e2e" output -raw url)"
echo "==> GET $url"
# Each attempt is bounded by curl's own timeouts, and the loop also stops once
# five minutes have passed, so a hanging connect cannot stretch the probe.
deadline=$((SECONDS + 300))
for attempt in $(seq 1 30); do
  if curl -fsS --connect-timeout 5 --max-time 15 -o /dev/null "$url/"; then
    echo "ok: $url answered 200 through the ALB on attempt $attempt (variant: $variant)"
    exit 0
  fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 10
done
echo "error: $url did not answer within 5 minutes" >&2
exit 1
