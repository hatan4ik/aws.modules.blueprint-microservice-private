#!/usr/bin/env bash
# ==============================================================================
# SRE / ConOps Diagnostic Tool: Blueprint Microservice Private Stack Inspector
# ==============================================================================
# Read-only live inspection of blueprint microservice infrastructure in AWS.
# Used for real-time triage during integration tests, deployment debugging,
# and verifying private VPC endpoint routing, zero-egress routes, and task health.
#
# Exit status: 0 when every section ran and no leak was found; 1 when a section
# errored or came back UNKNOWN (an API call failed) or a route leak was found;
# 2 for usage errors.
# ==============================================================================
set -euo pipefail

# No default profile: with AWS_PROFILE unset the CLI's own credential chain
# (environment, OIDC, instance role) applies, which is what CI relies on.
profile="${AWS_PROFILE:-}"
region="${AWS_REGION:-us-east-2}"
cluster_name=""
prefix_filter="bp-e2e-"
tag_key="IntegrationTest"
tag_value="aws.modules.blueprint-microservice-private"
expect_zero_egress=false

usage() {
  cat <<'USAGE'
Usage: scripts/diagnose-integration-stack.sh [options]

Inspects active AWS infrastructure provisioned by aws.modules.blueprint-microservice-private.
Non-destructive; performs read-only queries against AWS APIs.

Options:
  --profile NAME       AWS CLI profile (default: AWS_PROFILE; none when unset)
  --region REGION      AWS Region (default: AWS_REGION or us-east-2)
  --cluster NAME       Specific ECS cluster to inspect (e.g. bp-e2e-e8f707)
  --prefix PREFIX      Name prefix filter for resources (default: bp-e2e-)
  --expect-zero-egress Treat ANY default route (0.0.0.0/0, ::/0) in a private
                       subnet as a leak and exit non-zero. Use for the
                       private-ecr variant. Without it a default route via a
                       NAT gateway is reported as expected (the public variant
                       has one); a default route via an internet gateway in a
                       private subnet is always a leak.
  -h, --help           Show this message

Exit status: 0 clean; 1 a section errored/UNKNOWN or a route leak was found;
2 usage error.
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
    --cluster) need_value "$1" "$#"; cluster_name="$2"; shift 2 ;;
    --prefix) need_value "$1" "$#"; prefix_filter="$2"; shift 2 ;;
    --expect-zero-egress) expect_zero_egress=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

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

bold=$'\033[1m'
green=$'\033[0;32m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
cyan=$'\033[0;36m'
reset=$'\033[0m'

header() {
  printf '\n%s%s=== %s ===%s\n' "$bold" "$cyan" "$1" "$reset"
}

# Sections record problems here instead of aborting the report.
problem_count=0
problem_list=""
note_problem() {
  problem_count=$((problem_count + 1))
  problem_list="${problem_list}  - $1"$'\n'
}

# aws_try VAR ARGS...: runs the AWS CLI, stores stdout in VAR. On failure it
# prints the AWS error text (never swallows it) and returns 1; the caller
# decides how to mark the section. Callers must test the result explicitly:
# these functions run under set -e, which is not suspended for plain calls.
aws_try() {
  local __var="$1" __out __err
  shift
  __err="$work_dir/aws.err"
  if __out="$(aws_cli "$@" 2>"$__err")"; then
    printf -v "$__var" '%s' "$__out"
    return 0
  fi
  printf '%s  AWS error: %s%s\n' "$red" "$(tr '\n' ' ' <"$__err" | cut -c1-600)" "$reset"
  return 1
}

# chunk_lines JSON KEY SIZE: one line per SIZE-element chunk of JSON[KEY]
# (space-joined); the AWS describe calls cap how many ids they accept.
chunk_lines() {
  python3 -c '
import json, sys
items = json.loads(sys.argv[1]).get(sys.argv[2], [])
size = int(sys.argv[3])
for i in range(0, len(items), size):
    print(" ".join(items[i:i + size]))
' "$1" "$2" "$3"
}

# ------------------------------------------------------------------------------
# 1. Identity & Scope Check
# ------------------------------------------------------------------------------
section_1() {
  header "1. AWS Identity & Region"
  local identity_json account_id caller_arn
  if ! aws_try identity_json sts get-caller-identity --output json; then
    printf '%serror: failed to authenticate with AWS (profile: %s, region: %s)%s\n' \
      "$red" "${profile:-<default credential chain>}" "$region" "$reset" >&2
    exit 1
  fi
  account_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["Account"])' "$identity_json")"
  caller_arn="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["Arn"])' "$identity_json")"
  printf 'Account: %s%s%s | Region: %s%s%s\nCaller:  %s\n' \
    "$bold" "$account_id" "$reset" "$bold" "$region" "$reset" "$caller_arn"
}

# ------------------------------------------------------------------------------
# 2. Cluster Discovery
# ------------------------------------------------------------------------------
section_2() {
  header "2. ECS Cluster Discovery"
  if [[ -n "$cluster_name" ]]; then
    printf 'Found Cluster: %s%s%s%s (requested with --cluster)\n' "$green" "$bold" "$cluster_name" "$reset"
    return 0
  fi

  local clusters_json matched line n=0 last=""
  if ! aws_try clusters_json ecs list-clusters --output json; then
    note_problem "2. ECS Cluster Discovery: list-clusters failed (UNKNOWN)"
    return 0
  fi
  # Match on the cluster NAME starting with the prefix (not a substring of the
  # ARN), sorted so the choice is deterministic.
  matched="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
prefix = sys.argv[2]
names = sorted(c.split("/")[-1] for c in data.get("clusterArns", []))
for name in names:
    if name.startswith(prefix):
        print(name)
' "$clusters_json" "$prefix_filter")"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n=$((n + 1))
    last="$line"
  done <<<"$matched"

  if [[ "$n" -eq 0 ]]; then
    printf '%sNo active ECS cluster matching prefix "%s" found in %s.%s\n' "$yellow" "$prefix_filter" "$region" "$reset"
    return 0
  fi
  if [[ "$n" -gt 1 ]]; then
    printf '%s%d clusters match prefix "%s":%s\n' "$yellow" "$n" "$prefix_filter" "$reset"
    while IFS= read -r line; do
      printf '  %s\n' "$line"
    done <<<"$matched"
    printf 'Inspecting the newest by name sort: %s (pass --cluster to choose another)\n' "$last"
  fi
  cluster_name="$last"
  printf 'Found Cluster: %s%s%s%s\n' "$green" "$bold" "$cluster_name" "$reset"
}

# ------------------------------------------------------------------------------
# 3. ECS Services & Tasks Diagnostics
# ------------------------------------------------------------------------------
section_3() {
  header "3. ECS Services & Running Tasks in ${cluster_name}"
  local services_json chunk_line i=0 file chunk_json
  if ! aws_try services_json ecs list-services --cluster "$cluster_name" --output json; then
    note_problem "3. ECS Services: list-services failed (UNKNOWN)"
    printf '%sUNKNOWN: could not list services in cluster %s%s\n' "$yellow" "$cluster_name" "$reset"
    return 0
  fi

  local -a svc_files=()
  local ok=true
  # describe-services accepts at most 10 services per call.
  while IFS= read -r chunk_line; do
    [[ -n "$chunk_line" ]] || continue
    local -a chunk=()
    read -r -a chunk <<<"$chunk_line"
    i=$((i + 1))
    file="$work_dir/services.$i.json"
    if aws_try chunk_json ecs describe-services --cluster "$cluster_name" --services "${chunk[@]}" \
      --query "services[].[serviceName,status,desiredCount,runningCount,taskDefinition]" --output json; then
      printf '%s\n' "$chunk_json" >"$file"
      svc_files+=("$file")
    else
      ok=false
    fi
  done < <(chunk_lines "$services_json" serviceArns 10)

  if [[ "$ok" != true ]]; then
    note_problem "3. ECS Services: describe-services failed (UNKNOWN)"
  fi
  if [[ "${#svc_files[@]}" -eq 0 ]]; then
    if [[ "$ok" == true ]]; then
      printf 'No active ECS services in cluster %s.\n' "$cluster_name"
    fi
    return 0
  fi
  python3 -c '
import json, sys
rows = []
for path in sys.argv[1:]:
    with open(path) as fh:
        rows.extend(json.load(fh))
print("%-40s %-9s %-8s %-8s %s" % ("Service", "Status", "Desired", "Running", "Task Definition"))
print("-" * 100)
for name, status, desired, running, taskdef in rows:
    print("%-40s %-9s %-8s %-8s %s" % (name, status, desired, running, (taskdef or "").split("/")[-1]))
' "${svc_files[@]}" || note_problem "3. ECS Services: could not format the result"
}

section_4() {
  header "4. Stopped Tasks & Container Failure Reasons"
  local stopped_json chunk_line i=0 file chunk_json ok=true
  if ! aws_try stopped_json ecs list-tasks --cluster "$cluster_name" --desired-status STOPPED --output json; then
    note_problem "4. Stopped Tasks: list-tasks failed (UNKNOWN)"
    printf '%sUNKNOWN: could not list stopped tasks in cluster %s%s\n' "$yellow" "$cluster_name" "$reset"
    return 0
  fi

  local -a task_files=()
  # describe-tasks accepts at most 100 tasks per call.
  while IFS= read -r chunk_line; do
    [[ -n "$chunk_line" ]] || continue
    local -a chunk=()
    read -r -a chunk <<<"$chunk_line"
    i=$((i + 1))
    file="$work_dir/tasks.$i.json"
    if aws_try chunk_json ecs describe-tasks --cluster "$cluster_name" --tasks "${chunk[@]}" \
      --query "tasks[].[taskArn,stopCode,stoppedReason,join('; ', containers[].reason)]" --output json; then
      printf '%s\n' "$chunk_json" >"$file"
      task_files+=("$file")
    else
      ok=false
    fi
  done < <(chunk_lines "$stopped_json" taskArns 100)

  if [[ "$ok" != true ]]; then
    note_problem "4. Stopped Tasks: describe-tasks failed (UNKNOWN)"
  fi
  if [[ "${#task_files[@]}" -eq 0 ]]; then
    if [[ "$ok" == true ]]; then
      printf '%s✓ No stopped tasks found in cluster %s.%s\n' "$green" "$cluster_name" "$reset"
    fi
    return 0
  fi

  python3 -c '
import json, sys
red, green, reset = sys.argv[1], sys.argv[2], sys.argv[3]
tasks = []
for path in sys.argv[4:]:
    with open(path) as fh:
        tasks.extend(json.load(fh))
for t in tasks:
    arn, code, reason, c_reasons = t
    short = arn.split("/")[-1]
    is_pull_err = any(err in (reason or "") or err in (c_reasons or "") for err in ["CannotPullContainerError", "ResourceInitializationError"])
    color = red if is_pull_err else green
    print(f"Task:   {short}")
    print(f"Code:   {code}")
    print(f"Reason: {color}{reason}{reset}")
    if c_reasons:
        print(f"Containers: {color}{c_reasons}{reset}")
    print("-" * 60)
' "$red" "$green" "$reset" "${task_files[@]}" || note_problem "4. Stopped Tasks: could not format the result"
}

# ------------------------------------------------------------------------------
# 5. VPC Endpoints Inspection (PrivateLink & S3 Gateway)
# ------------------------------------------------------------------------------
section_5() {
  header "5. VPC Endpoints Status"
  local endpoints_json
  if ! aws_try endpoints_json ec2 describe-vpc-endpoints \
    --filters "Name=tag:${tag_key},Values=${tag_value}" \
    --query "VpcEndpoints[].[VpcEndpointId,ServiceName,State,VpcEndpointType]" \
    --output json; then
    note_problem "5. VPC Endpoints: describe-vpc-endpoints failed (UNKNOWN)"
    return 0
  fi

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
red, green, yellow, reset = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

if not data:
    print("No VPC endpoints tagged with IntegrationTest found.")
else:
    print("%-26s %-38s %-12s %s" % ("Endpoint ID", "Service Name", "Type", "State"))
    print("-" * 85)
    for ep in data:
        ep_id, svc, state, ep_type = ep
        state_color = green if state == "available" else (yellow if state in ["pending", "deleting"] else red)
        print("%-26s %-38s %-12s %s%s%s" % (ep_id, svc, ep_type, state_color, state, reset))
' "$endpoints_json" "$red" "$green" "$yellow" "$reset" || note_problem "5. VPC Endpoints: could not format the result"
}

# ------------------------------------------------------------------------------
# 6. Security Group & EC2 Description Character-Set Safety
# ------------------------------------------------------------------------------
section_6() {
  header "6. Security Groups & Description Rule Validation"
  local sgs_json
  if ! aws_try sgs_json ec2 describe-security-groups \
    --filters "Name=tag:${tag_key},Values=${tag_value}" \
    --query "SecurityGroups[].[GroupId,GroupName,Description]" \
    --output json; then
    note_problem "6. Security Groups: describe-security-groups failed (UNKNOWN)"
    return 0
  fi

  python3 -c '
import json, sys, re
data = json.loads(sys.argv[1])
red, green, reset = sys.argv[2], sys.argv[3], sys.argv[4]

# AWS EC2 API allowed characters for security group description: a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*
ec2_allowed_pattern = re.compile(r"^[a-zA-Z0-9. _\-:/()#,@\[\]+=&;{}!$*]+$")

if not data:
    print("No security groups tagged with IntegrationTest found.")
else:
    for sg in data:
        gid, gname, desc = sg
        is_valid = bool(ec2_allowed_pattern.match(desc or "")) and len(desc or "") < 256
        status = f"{green}VALID{reset}" if is_valid else f"{red}INVALID (contains forbidden chars e.g. single quotes){reset}"
        print(f"[{gid}] {gname}")
        print(f"  Description: \"{desc}\" -> {status}")
' "$sgs_json" "$red" "$green" "$reset" || note_problem "6. Security Groups: could not format the result"
}

# ------------------------------------------------------------------------------
# 7. Route Table Zero-Egress Assertion
# ------------------------------------------------------------------------------
section_7() {
  header "7. Private Subnet Route Tables (Zero-Egress Check)"
  local subnets_json rc=0
  if ! aws_try subnets_json ec2 describe-subnets \
    --filters "Name=tag:${tag_key},Values=${tag_value}" \
    --query "Subnets[].[SubnetId,CidrBlock,Tags[?Key=='Name'].Value|[0],VpcId,Tags[?Key=='Tier'].Value|[0]]" \
    --output json; then
    note_problem "7. Route Tables: describe-subnets failed (UNKNOWN)"
    return 0
  fi

  # Exit code bits from the program: 1 = an AWS call failed (UNKNOWN),
  # 2 = a leak was found (always for an igw-* default route; for any default
  # route when --expect-zero-egress is set).
  python3 -c '
import json, subprocess, sys

subnets = json.loads(sys.argv[1])
profile, region = sys.argv[2], sys.argv[3]
red, green, yellow, reset = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
expect_zero = sys.argv[8] == "true"

base = ["aws"] + (["--profile", profile] if profile else []) + ["--region", region]

# JMESPath string literals are raw strings in SINGLE quotes; double quotes
# would be parsed as identifiers (a field lookup that is always null, which
# made the IPv6 half of the test true for every route). This program sits
# inside a bash single-quoted string, so the quote is spelled \x27.
QUERY = ("RouteTables[].[RouteTableId, Routes[?DestinationCidrBlock==\x270.0.0.0/0\x27"
         " || DestinationIpv6CidrBlock==\x27::/0\x27]]")
TARGET_KEYS = ["NatGatewayId", "GatewayId", "EgressOnlyInternetGatewayId", "TransitGatewayId",
               "VpcPeeringConnectionId", "NetworkInterfaceId", "InstanceId", "VpcEndpointId",
               "LocalGatewayId", "CarrierGatewayId", "CoreNetworkArn"]


class AwsError(Exception):
    pass


def route_tables(filters):
    cmd = base + ["ec2", "describe-route-tables", "--filters"] + filters + ["--query", QUERY, "--output", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AwsError((proc.stderr or "aws exited %d" % proc.returncode).strip().replace("\n", " ")[:600])
    return json.loads(proc.stdout or "[]")


def target(route):
    for key in TARGET_KEYS:
        if route.get(key):
            return route[key]
    return "unknown-target"


def dest(route):
    return route.get("DestinationCidrBlock") or route.get("DestinationIpv6CidrBlock") or "?"


private = [s for s in subnets
           if "private" in (s[2] or "").lower() or (len(s) > 4 and (s[4] or "").lower() == "private")]
rc = 0
if not private:
    print("No subnets matching \"private\" found.")
for s in private:
    s_id, vpc_id, s_name = s[0], s[3], s[2] or "-"
    label = "Subnet %s (%s)" % (s_id, s_name)
    try:
        tables = route_tables(["Name=association.subnet-id,Values=" + s_id])
        via = "its route table"
        if not tables:
            # No explicit association: the subnet uses the VPC main route table.
            if not vpc_id:
                raise AwsError("subnet has no explicit route table association and no VpcId to find the main route table")
            tables = route_tables(["Name=association.main,Values=true", "Name=vpc-id,Values=" + vpc_id])
            via = "the VPC main route table (no explicit association)"
        if not tables:
            raise AwsError("no route table found for the subnet or its VPC main route table")
    except AwsError as exc:
        print("%s: %sUNKNOWN - %s%s" % (label, yellow, exc, reset))
        rc |= 1
        continue

    for rt_id, defaults in tables:
        where = "%s via %s %s" % (label, via, rt_id)
        if not defaults:
            print("%s: %sSECURE (zero default egress routes)%s" % (where, green, reset))
            continue
        for r in defaults:
            t = target(r)
            if t.startswith("igw-"):
                print("%s: %sLEAK - default route %s via internet gateway %s in a private subnet%s" % (where, red, dest(r), t, reset))
                rc |= 2
            elif expect_zero:
                print("%s: %sLEAK - default route %s via %s (--expect-zero-egress)%s" % (where, red, dest(r), t, reset))
                rc |= 2
            elif t.startswith("nat-"):
                print("%s: %sdefault route %s via NAT %s (expected for the public variant)%s" % (where, yellow, dest(r), t, reset))
            else:
                print("%s: %sdefault route %s via %s (not a NAT or internet gateway; review)%s" % (where, yellow, dest(r), t, reset))
sys.exit(rc)
' "$subnets_json" "$profile" "$region" "$red" "$green" "$yellow" "$reset" "$expect_zero_egress" || rc=$?

  if (( rc & 1 )); then
    note_problem "7. Route Tables: a route table lookup failed (UNKNOWN)"
  fi
  if (( rc & 2 )); then
    note_problem "7. Route Tables: LEAK - private subnet has a default route that is not allowed"
  fi
  if (( rc > 3 )); then
    note_problem "7. Route Tables: the checker itself failed (exit $rc)"
  fi
}

# ------------------------------------------------------------------------------
# 8. Load Balancer & Target Group Probing
# ------------------------------------------------------------------------------
section_8() {
  header "8. Application Load Balancer Health & Probing"
  local albs_json
  # No '2>/dev/null || echo []' here: an AccessDenied or throttled call must
  # not read as "no ALBs".
  if ! aws_try albs_json elbv2 describe-load-balancers \
    --query "LoadBalancers[].[LoadBalancerName,DNSName,State.Code,Scheme]" --output json; then
    printf '%sUNKNOWN: could not list load balancers (see the AWS error above)%s\n' "$yellow" "$reset"
    note_problem "8. Load Balancers: describe-load-balancers failed (UNKNOWN)"
    return 0
  fi

  python3 -c '
import json, sys, urllib.request
albs = json.loads(sys.argv[1])
red, green, reset = sys.argv[2], sys.argv[3], sys.argv[4]
prefix = sys.argv[5]

albs = [a for a in albs if (a[0] or "").startswith(prefix)]
if not albs:
    print("No ALBs matching prefix \"%s\" found." % prefix)
else:
    for name, dns, state, scheme in albs:
        print(f"ALB:   {name} {dns} ({state}, {scheme})")
        if scheme == "internal":
            print("Probe: internal ALB, not reachable from this host (expected for the private variant)")
            continue
        url = f"http://{dns}/"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ConOps-Diagnostic-Probe"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                status = resp.status
                print(f"Probe: {green}GET {url} -> HTTP {status}{reset}")
        except Exception as e:
            print(f"Probe: {red}GET {url} failed ({e}){reset}")
' "$albs_json" "$red" "$green" "$reset" "$prefix_filter" || note_problem "8. Load Balancers: could not format the result"
}

# ------------------------------------------------------------------------------
# 9. ECR Pull-Through Cache Verification
# ------------------------------------------------------------------------------
section_9() {
  header "9. ECR Pull-Through Cache & Repositories"
  local ptc_json
  if ! aws_try ptc_json ecr describe-pull-through-cache-rules \
    --query "pullThroughCacheRules[].[ecrRepositoryPrefix,upstreamRegistryUrl]" --output json; then
    printf '%sUNKNOWN: could not list pull-through cache rules (see the AWS error above)%s\n' "$yellow" "$reset"
    note_problem "9. ECR Pull-Through Cache: describe-pull-through-cache-rules failed (UNKNOWN)"
    return 0
  fi

  python3 -c '
import json, sys
rules = [r for r in json.loads(sys.argv[1]) if (r[0] or "").startswith(sys.argv[2])]
if not rules:
    print("No active pull-through cache rules matching prefix \"%s\"." % sys.argv[2])
for r in rules:
    print(f"Cache Rule: {r[0]} -> {r[1]}")
' "$ptc_json" "$prefix_filter" || note_problem "9. ECR Pull-Through Cache: could not format the result"
}

section_1
section_2
if [[ -n "$cluster_name" ]]; then
  section_3
  section_4
fi
section_5
section_6
section_7
section_8
section_9

if [[ "$problem_count" -gt 0 ]]; then
  printf '\n%s%s%d problem(s) found; the report above is incomplete or contains a failure:%s\n' "$bold" "$red" "$problem_count" "$reset"
  printf '%s' "$problem_list"
  exit 1
fi
printf '\n%s%sDiagnostic inspection complete.%s\n' "$bold" "$green" "$reset"
