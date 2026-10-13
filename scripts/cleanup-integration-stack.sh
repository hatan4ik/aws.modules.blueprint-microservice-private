#!/usr/bin/env bash
# ==============================================================================
# SRE / ConOps Janitor Tool: Integration Stack Emergency Cleanup
# ==============================================================================
# Discovers and deletes orphaned resources of an interrupted integration run.
#
# Selection is the AND of two conditions for every resource type that can carry
# a tag: the resource NAME starts with --prefix, and it carries the tag
# IntegrationTest=aws.modules.blueprint-microservice-private. Types AWS cannot
# tag (ECR pull-through cache rules) and repositories with no tags at all
# (created by the pull-through cache) are selected by the anchored prefix
# alone, and are listed separately so nobody has to guess.
#
# Deletes, in this order, waiting for each stage to finish before the next:
#   ECS services -> ALBs -> target groups -> ECR repositories and pull-through
#   cache rules -> VPC endpoints -> NAT gateways and their Elastic IPs ->
#   ECS cluster.
# It does NOT delete the VPC, subnets, route tables, internet gateway or
# security groups (they are listed so you can see what remains), and never
# touches CloudWatch log groups, task definitions, IAM roles or the flow-log
# KMS key. Use terraform destroy (tests/integration/README.md) for those.
#
# Exit status: 0 everything selected was deleted (or dry run); 1 something
# failed or a cluster survived; 2 usage error or refused to run unattended
# without --yes.
# ==============================================================================
set -euo pipefail

# No default profile: with AWS_PROFILE unset the CLI's own credential chain
# (environment, OIDC, instance role) applies.
profile="${AWS_PROFILE:-}"
region="${AWS_REGION:-us-east-2}"
prefix_filter="bp-e2e-"
tag_key="IntegrationTest"
tag_value="aws.modules.blueprint-microservice-private"
dry_run=false
assume_yes=false
# Polling knobs (seconds). Defaults suit real AWS; tests override them.
poll_seconds="${CLEANUP_POLL_SECONDS:-10}"
poll_timeout="${CLEANUP_POLL_TIMEOUT_SECONDS:-300}"

usage() {
  cat <<'USAGE'
Usage: scripts/cleanup-integration-stack.sh [options]

Discovers and deletes orphan AWS resources from interrupted integration runs.
A resource is selected only when its name starts with the prefix AND (where
AWS supports tags on it) it carries IntegrationTest=aws.modules.blueprint-microservice-private.

Deletes, waiting for each stage to finish:
  ECS services -> ALBs -> target groups -> ECR repositories and pull-through
  cache rules -> VPC endpoints -> NAT gateways and their Elastic IPs ->
  ECS cluster (last).
VPCs, subnets, route tables, internet gateways and security groups are only
listed, never deleted: use terraform destroy (see tests/integration/README.md).

Options:
  --profile NAME       AWS CLI profile (default: AWS_PROFILE; none when unset)
  --region REGION      AWS Region (default: AWS_REGION or us-east-2)
  --prefix PREFIX      Name prefix (default: bp-e2e-); must match
                       ^[a-z0-9][a-z0-9-]{2,}$
  --dry-run            List exactly what would be deleted; delete nothing
  --yes                Delete without the interactive confirmation (required
                       when stdin is not a terminal)
  -h, --help           Show this message

Exit status: 0 done (or dry run); 1 something failed or a cluster survived;
2 usage error, or non-interactive without --yes.
USAGE
}

need_value() {
  # $1 = option name, $2 = number of arguments left including the option
  if [[ "$2" -lt 2 ]]; then
    printf 'error: option %s requires a value\n' "$1" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) need_value "$1" "$#"; profile="$2"; shift 2 ;;
    --region) need_value "$1" "$#"; region="$2"; shift 2 ;;
    --prefix) need_value "$1" "$#"; prefix_filter="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --yes) assume_yes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# The prefix selects what gets deleted: anchored, lowercase, at least three
# characters, so it can neither be empty nor match everything, and it cannot
# carry quotes or other characters that mean something to a query language.
prefix_re='^[a-z0-9][a-z0-9-]{2,}$'
if ! [[ "$prefix_filter" =~ $prefix_re ]]; then
  printf 'error: --prefix %q is not allowed; it must match %s\n' "$prefix_filter" "$prefix_re" >&2
  exit 2
fi
num_re='^[0-9]+$'
if ! [[ "$poll_seconds" =~ $num_re && "$poll_timeout" =~ $num_re ]] || [[ "$poll_seconds" -lt 1 ]]; then
  printf 'error: CLEANUP_POLL_SECONDS must be an integer >= 1 and CLEANUP_POLL_TIMEOUT_SECONDS an integer\n' >&2
  exit 2
fi

command -v aws >/dev/null || { printf 'error: aws CLI is required.\n' >&2; exit 1; }
command -v python3 >/dev/null || { printf 'error: python3 is required.\n' >&2; exit 1; }

aws_cli() {
  if [[ -n "$profile" ]]; then
    command aws --profile "$profile" --region "$region" "$@"
  else
    command aws --region "$region" "$@"
  fi
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
plan_file="$work_dir/plan.tsv"

bold=$'\033[1m'
green=$'\033[0;32m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
cyan=$'\033[0;36m'
reset=$'\033[0m'

header() {
  printf '\n%s%s=== %s ===%s\n' "$bold" "$cyan" "$1" "$reset"
}

# ---------------------------------------------------------------------------
# Failure accounting: nothing is swallowed. Every failed operation is printed
# and recorded, the run continues, and the summary decides the exit status.
# ---------------------------------------------------------------------------
fail_count=0
fail_list=""
ok_count=0
op_ok=true
record_failure() {
  fail_count=$((fail_count + 1))
  fail_list="${fail_list}  - $1"$'\n'
}

first_line() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-300
}

# run_aws DESCRIPTION AWS-ARGS...: runs one deletion/wait. Always returns 0 and
# sets op_ok (true/false) so that set -e never aborts the cleanup half way;
# the failure is printed and recorded instead. Output is left in last_out.
last_out=""
last_err=""
# aws_capture AWS-ARGS...: runs aws with stdout and stderr kept SEPARATE.
# stdout goes to last_out (it is compared and parsed), stderr to last_err (it
# is only ever shown). Merging them would let any CLI warning corrupt a
# comparison such as "status == ACTIVE". Returns the aws exit status.
aws_capture() {
  local errf="$work_dir/aws.err" rc=0
  last_out="$(aws_cli "$@" 2>"$errf")" || rc=$?
  last_err="$(cat "$errf")"
  return "$rc"
}

run_aws() {
  local desc="$1"
  shift
  if aws_capture "$@"; then
    printf '  %sok%s: %s\n' "$green" "$reset" "$desc"
    ok_count=$((ok_count + 1))
    op_ok=true
  else
    printf '  %sFAILED%s: %s\n    %s\n' "$red" "$reset" "$desc" "$(first_line "${last_err:-$last_out}")"
    record_failure "$desc: $(first_line "${last_err:-$last_out}")"
    op_ok=false
  fi
}

# poll_gone DESCRIPTION AWS-ARGS...: re-runs a describe call that prints (as
# text) the ids still present, every poll_seconds, until it prints nothing or
# poll_timeout seconds have passed. Sets op_ok.
poll_gone() {
  local desc="$1" waited=0 remaining
  shift
  while :; do
    if ! aws_capture "$@"; then
      printf '  %sFAILED%s: %s\n    %s\n' "$red" "$reset" "$desc" "$(first_line "${last_err:-$last_out}")"
      record_failure "$desc: $(first_line "${last_err:-$last_out}")"
      op_ok=false
      return 0
    fi
    remaining="$last_out"
    if [[ -z "$remaining" || "$remaining" == "None" ]]; then
      printf '  %sok%s: %s\n' "$green" "$reset" "$desc"
      op_ok=true
      return 0
    fi
    if [[ "$waited" -ge "$poll_timeout" ]]; then
      printf '  %sFAILED%s: %s (still present after %ss: %s)\n' "$red" "$reset" "$desc" "$poll_timeout" "$remaining"
      record_failure "$desc: still present after ${poll_timeout}s: $remaining"
      op_ok=false
      return 0
    fi
    printf '  waiting: %s (still present: %s)\n' "$desc" "$remaining"
    sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
}

# ---------------------------------------------------------------------------
# 1. Identity
# ---------------------------------------------------------------------------
header "1. Target Scope & Identity"
identity_err="$work_dir/sts.err"
if ! identity_json="$(aws_cli sts get-caller-identity --output json 2>"$identity_err")"; then
  printf '%serror: failed to authenticate with AWS (profile: %s, region: %s)%s\n' \
    "$red" "${profile:-<default credential chain>}" "$region" "$reset" >&2
  printf '%s\n' "$(first_line "$(cat "$identity_err")")" >&2
  exit 1
fi
account_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["Account"])' "$identity_json")"
printf 'Account: %s%s%s | Region: %s%s%s | Prefix: %s%s%s | Dry-Run: %s%s%s\n' \
  "$bold" "$account_id" "$reset" "$bold" "$region" "$reset" "$bold" "$prefix_filter" "$reset" "$bold" "$dry_run" "$reset"

# ---------------------------------------------------------------------------
# 2. Discovery (read-only). Writes one tab-separated plan row per resource:
#   cluster NAME | service CLUSTER NAME STATUS | alb ARN NAME | tg ARN NAME |
#   repo NAME tagged|untagged | ptc PREFIX UPSTREAM | endpoint ID NAME STATE |
#   nat ID NAME STATE | eip ALLOC NAME IP | keep TYPE ID NAME |
#   skip TYPE NAME REASON | error STAGE MESSAGE
# ---------------------------------------------------------------------------
header "2. Discovery (read-only)"
python3 - "$profile" "$region" "$prefix_filter" "$tag_key" "$tag_value" "$plan_file" <<'PY'
import json
import subprocess
import sys

profile, region, prefix, key, value, plan_path = sys.argv[1:7]
base = ["aws"] + (["--profile", profile] if profile else []) + ["--region", region]
rows = []


class AwsError(Exception):
    pass


def aws(*args):
    proc = subprocess.run(base + list(args) + ["--output", "json"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise AwsError((proc.stderr or "aws exited %d" % proc.returncode).strip().replace("\n", " ")[:500])
    try:
        return json.loads(proc.stdout) if proc.stdout.strip() else None
    except ValueError as exc:
        raise AwsError("unparseable output: %s" % exc)


def emit(*cols):
    rows.append("\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in cols))


def chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def tag_value_of(tags, wanted):
    for t in tags or []:
        if t.get("Key", t.get("key")) == wanted:
            return t.get("Value", t.get("value"))
    return None


def has_tag(tags):
    return tag_value_of(tags, key) == value


def name_of(tags):
    return tag_value_of(tags, "Name") or ""


def stage(name, fn, *args):
    try:
        return fn(*args)
    except AwsError as exc:
        emit("error", name, exc)
        return None


def skip(kind, name, reason):
    emit("skip", kind, name, reason)


def missing_tag():
    return "name matches the prefix but the %s=%s tag is missing or different" % (key, value)


def clusters():
    arns = aws("ecs", "list-clusters", "--query", "clusterArns") or []
    found = []
    for part in chunks([a for a in arns if a.split("/")[-1].startswith(prefix)], 100):
        res = aws("ecs", "describe-clusters", "--clusters", *part, "--include", "TAGS",
                  "--query", "clusters[].[clusterName,status,tags]") or []
        for name, status, tags in res:
            if not name.startswith(prefix):
                continue
            if status != "ACTIVE":
                skip("ECS cluster", name, "status is %s" % status)
            elif has_tag(tags):
                emit("cluster", name)
                found.append(name)
            else:
                skip("ECS cluster", name, missing_tag())
    return found


def services(cluster):
    arns = aws("ecs", "list-services", "--cluster", cluster, "--query", "serviceArns") or []
    for part in chunks(arns, 10):
        res = aws("ecs", "describe-services", "--cluster", cluster, "--services", *part, "--include", "TAGS",
                  "--query", "services[].[serviceName,status,tags]") or []
        for name, status, tags in res:
            if status not in ("ACTIVE", "DRAINING"):
                continue
            if name.startswith(prefix) and has_tag(tags):
                emit("service", cluster, name, status)
            else:
                skip("ECS service", cluster + "/" + name,
                     "name does not start with the prefix or the %s=%s tag is missing; the cluster delete will fail while it exists" % (key, value))


def elb_tags(arns):
    out = {}
    for part in chunks(arns, 20):
        res = aws("elbv2", "describe-tags", "--resource-arns", *part,
                  "--query", "TagDescriptions[].[ResourceArn,Tags]") or []
        for arn, tags in res:
            out[arn] = tags
    return out


def load_balancers():
    res = aws("elbv2", "describe-load-balancers", "--query", "LoadBalancers[].[LoadBalancerName,LoadBalancerArn]") or []
    cand = [(n, a) for n, a in res if n.startswith(prefix)]
    tags = elb_tags([a for _, a in cand])
    for name, arn in cand:
        if has_tag(tags.get(arn)):
            emit("alb", arn, name)
        else:
            skip("load balancer", name, missing_tag())


def target_groups():
    res = aws("elbv2", "describe-target-groups", "--query", "TargetGroups[].[TargetGroupName,TargetGroupArn]") or []
    cand = [(n, a) for n, a in res if n.startswith(prefix)]
    tags = elb_tags([a for _, a in cand])
    for name, arn in cand:
        if has_tag(tags.get(arn)):
            emit("tg", arn, name)
        else:
            skip("target group", name, missing_tag())


def repositories():
    res = aws("ecr", "describe-repositories", "--query", "repositories[].[repositoryName,repositoryArn]") or []
    for name, arn in res:
        if not name.startswith(prefix):
            continue
        try:
            tags = aws("ecr", "list-tags-for-resource", "--resource-arn", arn, "--query", "tags") or []
        except AwsError as exc:
            emit("error", "ECR repository tags " + name, exc)
            continue
        if has_tag(tags):
            emit("repo", name, "tagged")
        elif not tags:
            # No tags at all: what a pull-through cache creates on first pull.
            emit("repo", name, "untagged")
        else:
            skip("ECR repository", name, "has tags but not %s=%s" % (key, value))


def pull_through_rules():
    res = aws("ecr", "describe-pull-through-cache-rules",
              "--query", "pullThroughCacheRules[].[ecrRepositoryPrefix,upstreamRegistryUrl]") or []
    for rule_prefix, upstream in res:
        if rule_prefix.startswith(prefix):
            emit("ptc", rule_prefix, upstream)


def tagged_ec2(kind, args, query, id_kind, with_state, skip_states=()):
    res = aws("ec2", *args, "--query", query) or []
    for row in res:
        rid, tags = row[0], row[-1]
        state = row[1] if with_state else ""
        if state in skip_states:
            continue
        name = name_of(tags)
        if has_tag(tags) and name.startswith(prefix):
            extra = [state] if with_state else []
            if id_kind == "eip":
                extra = [row[1]]
            emit(id_kind, rid, name, *extra)
        else:
            skip(kind, rid, "tagged %s=%s but its Name tag %r does not start with the prefix" % (key, value, name))


flt = "Name=tag:%s,Values=%s" % (key, value)


def print_only(kind, args, query):
    res = aws("ec2", *args, "--filters", flt, "--query", query) or []
    for rid, tags in res:
        name = name_of(tags)
        if has_tag(tags) and name.startswith(prefix):
            emit("keep", kind, rid, name)


names = stage("ECS clusters", clusters) or []
for c in names:
    stage("ECS services in " + c, services, c)
stage("load balancers", load_balancers)
stage("target groups", target_groups)
stage("ECR repositories", repositories)
stage("ECR pull-through cache rules", pull_through_rules)
stage("VPC endpoints", tagged_ec2, "VPC endpoint",
      ["describe-vpc-endpoints", "--filters", flt],
      "VpcEndpoints[].[VpcEndpointId,State,Tags]", "endpoint", True, ("deleted",))
stage("NAT gateways", tagged_ec2, "NAT gateway",
      ["describe-nat-gateways", "--filter", flt],
      "NatGateways[].[NatGatewayId,State,Tags]", "nat", True, ("deleted",))
stage("Elastic IPs", tagged_ec2, "Elastic IP",
      ["describe-addresses", "--filters", flt],
      "Addresses[].[AllocationId,PublicIp,Tags]", "eip", False)
stage("VPCs", print_only, "VPC", ["describe-vpcs"], "Vpcs[].[VpcId,Tags]")
stage("subnets", print_only, "subnet", ["describe-subnets"], "Subnets[].[SubnetId,Tags]")
stage("route tables", print_only, "route table", ["describe-route-tables"], "RouteTables[].[RouteTableId,Tags]")
stage("internet gateways", print_only, "internet gateway", ["describe-internet-gateways"],
      "InternetGateways[].[InternetGatewayId,Tags]")
stage("security groups", print_only, "security group", ["describe-security-groups"], "SecurityGroups[].[GroupId,Tags]")

with open(plan_path, "w") as fh:
    fh.write("\n".join(rows) + ("\n" if rows else ""))
PY

plan_rows() { # KIND [COLUMN2]
  awk -F'\t' -v k="$1" -v c="${2:-}" '$1 == k && (c == "" || $2 == c)' "$plan_file"
}
plan_count() {
  awk -F'\t' -v k="$1" '$1 == k { n++ } END { print n + 0 }' "$plan_file"
}

# Discovery failures are failures: what could not be listed is not "absent".
while IFS=$'\t' read -r _ stage_name message; do
  printf '  %sFAILED%s: could not list %s\n    %s\n' "$red" "$reset" "$stage_name" "$message"
  record_failure "discovery of $stage_name: $message"
done < <(plan_rows error)

n_cluster="$(plan_count cluster)"
n_service="$(plan_count service)"
n_alb="$(plan_count alb)"
n_tg="$(plan_count tg)"
n_repo="$(plan_count repo)"
n_ptc="$(plan_count ptc)"
n_endpoint="$(plan_count endpoint)"
n_nat="$(plan_count nat)"
n_eip="$(plan_count eip)"
n_total=$((n_cluster + n_service + n_alb + n_tg + n_repo + n_ptc + n_endpoint + n_nat + n_eip))

# ---------------------------------------------------------------------------
# 3. The plan: exactly what will be deleted
# ---------------------------------------------------------------------------
header "3. Deletion plan"
printf 'Selected: name starts with "%s" AND tag %s=%s (where AWS can tag the type)\n' "$prefix_filter" "$tag_key" "$tag_value"
if [[ "$n_total" -eq 0 ]]; then
  printf 'Nothing matches the selection.\n'
else
  printf 'Would delete, in this order:\n'
  while IFS=$'\t' read -r _ cluster name status; do
    printf '  1. ECS service: %s/%s (%s; scale to 0, delete, wait until inactive)\n' "$cluster" "$name" "$status"
  done < <(plan_rows service)
  while IFS=$'\t' read -r _ _ name; do
    printf '  2. Application Load Balancer: %s (then wait until deleted)\n' "$name"
  done < <(plan_rows alb)
  while IFS=$'\t' read -r _ _ name; do
    printf '  3. Target group: %s\n' "$name"
  done < <(plan_rows tg)
  while IFS=$'\t' read -r _ name basis; do
    if [[ "$basis" == tagged ]]; then
      printf '  4. ECR repository: %s (tagged)\n' "$name"
    fi
  done < <(plan_rows repo)
  while IFS=$'\t' read -r _ id name state; do
    printf '  5. VPC endpoint: %s (%s, %s; poll until gone, up to %ss)\n' "$id" "$name" "$state" "$poll_timeout"
  done < <(plan_rows endpoint)
  while IFS=$'\t' read -r _ id name state; do
    printf '  6. NAT gateway: %s (%s, %s; wait until deleted)\n' "$id" "$name" "$state"
  done < <(plan_rows nat)
  while IFS=$'\t' read -r _ alloc name ip; do
    printf '  6. Elastic IP: %s %s (%s; released after its NAT gateway is gone)\n' "$alloc" "$ip" "$name"
  done < <(plan_rows eip)
  while IFS=$'\t' read -r _ name; do
    printf '  7. ECS cluster: %s (last)\n' "$name"
  done < <(plan_rows cluster)

  if [[ "$n_repo" -gt 0 || "$n_ptc" -gt 0 ]]; then
    printf '\n%sUNTAGGED: selected by the name prefix alone (AWS cannot tag these, or they carry no tags):%s\n' "$yellow" "$reset"
    while IFS=$'\t' read -r _ name basis; do
      if [[ "$basis" == untagged ]]; then
        printf '  4. ECR repository: %s (no tags; created by the pull-through cache)\n' "$name"
      fi
    done < <(plan_rows repo)
    while IFS=$'\t' read -r _ rule upstream; do
      printf '  4. ECR pull-through cache rule: %s -> %s (rules cannot be tagged)\n' "$rule" "$upstream"
    done < <(plan_rows ptc)
  fi
fi

if [[ "$(plan_count skip)" -gt 0 ]]; then
  printf '\nSkipped (matched part of the selection, left alone):\n'
  while IFS=$'\t' read -r _ kind name reason; do
    printf '  - %s %s: %s\n' "$kind" "$name" "$reason"
  done < <(plan_rows skip)
fi

if [[ "$(plan_count keep)" -gt 0 ]]; then
  printf '\nNOT deleted by this script (VPC-level resources; listed so you can see what remains):\n'
  while IFS=$'\t' read -r _ kind id name; do
    printf '  - %s %s (%s)\n' "$kind" "$id" "$name"
  done < <(plan_rows keep)
  printf '  Remove them with terraform destroy against the original state (tests/integration/README.md),\n'
  printf '  or review and delete them by hand in dependency order (subnets, route tables, IGW, SGs, VPC).\n'
fi

# ---------------------------------------------------------------------------
# Dry run and confirmation
# ---------------------------------------------------------------------------
finish() {
  # finish: prints the failure summary and exits with the right status.
  if [[ "$fail_count" -gt 0 ]]; then
    printf '\n%s%s%d operation(s) failed:%s\n' "$bold" "$red" "$fail_count" "$reset"
    printf '%s' "$fail_list"
    if [[ "$dry_run" == true ]]; then
      printf '%s%sDry run INCOMPLETE: some resource types could not be listed, so the plan above may be missing resources.%s\n' "$bold" "$red" "$reset"
    else
      printf '%s%sCleanup INCOMPLETE: rerun after fixing the cause; resources listed above may still exist.%s\n' "$bold" "$red" "$reset"
    fi
    exit 1
  fi
  exit 0
}

if [[ "$dry_run" == true ]]; then
  printf '\n%sDry run: nothing was deleted.%s\n' "$bold" "$reset"
  finish
fi

if [[ "$n_total" -eq 0 ]]; then
  printf '\n%s%sNothing to delete.%s\n' "$bold" "$green" "$reset"
  finish
fi

if [[ "$assume_yes" != true ]]; then
  if [[ -t 0 ]]; then
    printf '\n%sThe %d resource(s) listed above will be PERMANENTLY deleted from account %s in %s.%s\n' \
      "$bold" "$n_total" "$account_id" "$region" "$reset"
    answer=""
    read -r -p "Type 'delete' to continue: " answer || answer=""
    if [[ "$answer" != "delete" ]]; then
      printf 'Aborted: nothing was deleted.\n'
      exit 1
    fi
  else
    printf '\n%serror: refusing to delete without --yes when stdin is not a terminal. Nothing was deleted.%s\n' "$red" "$reset" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# 4. Deletion, in dependency order, waiting between stages
# ---------------------------------------------------------------------------
header "4. ECS services"
while IFS=$'\t' read -r _ cluster; do
  wait_names=()
  while IFS=$'\t' read -r _ _ svc status; do
    if [[ "$status" == ACTIVE ]]; then
      run_aws "scale ECS service $cluster/$svc to 0" ecs update-service --cluster "$cluster" --service "$svc" --desired-count 0
      if [[ "$op_ok" == true ]]; then
        run_aws "delete ECS service $cluster/$svc" ecs delete-service --cluster "$cluster" --service "$svc" --force
      fi
      if [[ "$op_ok" == true ]]; then
        wait_names+=("$svc")
      fi
    else
      printf '  %s/%s is already %s; waiting for it to become inactive\n' "$cluster" "$svc" "$status"
      wait_names+=("$svc")
    fi
  done < <(plan_rows service "$cluster")

  # services-inactive accepts at most 10 services per call.
  i=0
  while [[ "$i" -lt "${#wait_names[@]}" ]]; do
    chunk=("${wait_names[@]:i:10}")
    run_aws "wait until ECS services are inactive in $cluster (${chunk[*]})" \
      ecs wait services-inactive --cluster "$cluster" --services "${chunk[@]}"
    i=$((i + 10))
  done
done < <(plan_rows cluster)

header "5. Application Load Balancers"
deleted_albs=()
while IFS=$'\t' read -r _ arn name; do
  run_aws "delete ALB $name" elbv2 delete-load-balancer --load-balancer-arn "$arn"
  if [[ "$op_ok" == true ]]; then
    deleted_albs+=("$arn")
  fi
done < <(plan_rows alb)
i=0
while [[ "$i" -lt "${#deleted_albs[@]}" ]]; do
  chunk=("${deleted_albs[@]:i:20}")
  run_aws "wait until ${#chunk[@]} load balancer(s) are deleted" elbv2 wait load-balancers-deleted --load-balancer-arns "${chunk[@]}"
  i=$((i + 20))
done

header "6. Target groups"
while IFS=$'\t' read -r _ arn name; do
  run_aws "delete target group $name" elbv2 delete-target-group --target-group-arn "$arn"
done < <(plan_rows tg)

header "7. ECR repositories and pull-through cache rules"
while IFS=$'\t' read -r _ name basis; do
  run_aws "delete ECR repository $name ($basis)" ecr delete-repository --repository-name "$name" --force
done < <(plan_rows repo)
while IFS=$'\t' read -r _ rule _; do
  run_aws "delete pull-through cache rule $rule" ecr delete-pull-through-cache-rule --ecr-repository-prefix "$rule"
done < <(plan_rows ptc)

header "8. VPC endpoints"
endpoint_ids=()
while IFS=$'\t' read -r _ id _ state; do
  if [[ "$state" != deleting ]]; then
    endpoint_ids+=("$id")
  fi
done < <(plan_rows endpoint)
i=0
while [[ "$i" -lt "${#endpoint_ids[@]}" ]]; do
  chunk=("${endpoint_ids[@]:i:20}")
  run_aws "delete VPC endpoints ${chunk[*]}" ec2 delete-vpc-endpoints --vpc-endpoint-ids "${chunk[@]}" \
    --query "Unsuccessful[].[ResourceId,Error.Message]" --output text
  # delete-vpc-endpoints exits 0 and lists per-endpoint errors in Unsuccessful.
  if [[ "$op_ok" == true && -n "$last_out" && "$last_out" != "None" ]]; then
    printf '  %sFAILED%s: endpoints not deleted: %s\n' "$red" "$reset" "$(first_line "$last_out")"
    record_failure "delete VPC endpoints: $(first_line "$last_out")"
  fi
  i=$((i + 20))
done
if [[ "$n_endpoint" -gt 0 ]]; then
  all_endpoints=""
  while IFS=$'\t' read -r _ id _; do
    all_endpoints="${all_endpoints}${all_endpoints:+,}$id"
  done < <(plan_rows endpoint)
  poll_gone "VPC endpoints are gone" ec2 describe-vpc-endpoints \
    --filters "Name=vpc-endpoint-id,Values=${all_endpoints}" \
    --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" --output text
fi

header "9. NAT gateways and Elastic IPs"
nat_ids=""
while IFS=$'\t' read -r _ id _ state; do
  nat_ids="${nat_ids}${nat_ids:+,}$id"
  if [[ "$state" != deleting ]]; then
    run_aws "delete NAT gateway $id" ec2 delete-nat-gateway --nat-gateway-id "$id"
  fi
done < <(plan_rows nat)
if [[ -n "$nat_ids" ]]; then
  poll_gone "NAT gateways are deleted" ec2 describe-nat-gateways \
    --filter "Name=nat-gateway-id,Values=${nat_ids}" \
    --query "NatGateways[?State!='deleted'].NatGatewayId" --output text
fi
while IFS=$'\t' read -r _ alloc _ ip; do
  run_aws "release Elastic IP $alloc ($ip)" ec2 release-address --allocation-id "$alloc"
done < <(plan_rows eip)

header "10. ECS clusters (last)"
while IFS=$'\t' read -r _ cluster; do
  attempt=1
  while :; do
    if aws_capture ecs delete-cluster --cluster "$cluster" --query cluster.status --output text; then
      if [[ "$last_out" == "ACTIVE" ]]; then
        printf '  %sFAILED%s: cluster %s is still ACTIVE after delete-cluster\n' "$red" "$reset" "$cluster"
        record_failure "ECS cluster $cluster survived: still ACTIVE after delete-cluster"
      else
        printf '  %sok%s: delete ECS cluster %s (%s)\n' "$green" "$reset" "$cluster" "$last_out"
        ok_count=$((ok_count + 1))
      fi
      break
    fi
    # Tasks of just-deleted services can take a moment to disappear; that is
    # the only failure worth retrying.
    if [[ "$last_err$last_out" == *ClusterContains* && "$attempt" -lt 6 ]]; then
      printf '  waiting: cluster %s still has services or tasks (attempt %d)\n' "$cluster" "$attempt"
      sleep "$poll_seconds"
      attempt=$((attempt + 1))
      continue
    fi
    printf '  %sFAILED%s: delete ECS cluster %s\n    %s\n' "$red" "$reset" "$cluster" "$(first_line "${last_err:-$last_out}")"
    record_failure "ECS cluster $cluster survived: $(first_line "${last_err:-$last_out}")"
    break
  done
done < <(plan_rows cluster)

header "11. Summary"
printf '%d operation(s) succeeded, %d failed.\n' "$ok_count" "$fail_count"
if [[ "$(plan_count keep)" -gt 0 ]]; then
  printf '%sNote:%s the VPC-level resources listed in the plan still exist; this script does not delete them.\n' "$yellow" "$reset"
fi
if [[ "$fail_count" -eq 0 ]]; then
  printf '%s%sCleanup complete: every selected resource was deleted.%s\n' "$bold" "$green" "$reset"
fi
finish
