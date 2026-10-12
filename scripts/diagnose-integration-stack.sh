#!/usr/bin/env bash
# ==============================================================================
# SRE / ConOps Diagnostic Tool: Blueprint Microservice Private Stack Inspector
# ==============================================================================
# Read-only live inspection of blueprint microservice infrastructure in AWS.
# Used for real-time triage during integration tests, deployment debugging,
# and verifying private VPC endpoint routing, zero-egress routes, and task health.
# ==============================================================================
set -euo pipefail

profile="${AWS_PROFILE:-AWS-hatan4ik-gmail}"
region="${AWS_REGION:-us-east-2}"
cluster_name=""
prefix_filter="bp-e2e-"
tag_key="IntegrationTest"
tag_value="aws.modules.blueprint-microservice-private"

usage() {
  cat <<'USAGE'
Usage: scripts/diagnose-integration-stack.sh [options]

Inspects active AWS infrastructure provisioned by aws.modules.blueprint-microservice-private.
Non-destructive; performs read-only queries against AWS APIs.

Options:
  --profile NAME       AWS CLI profile (default: AWS_PROFILE or AWS-hatan4ik-gmail)
  --region REGION      AWS Region (default: AWS_REGION or us-east-2)
  --cluster NAME       Specific ECS cluster to inspect (e.g. bp-e2e-e8f707)
  --prefix PREFIX      Name prefix filter for resources (default: bp-e2e-)
  -h, --help           Show this message
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --region) region="$2"; shift 2 ;;
    --cluster) cluster_name="$2"; shift 2 ;;
    --prefix) prefix_filter="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null || { printf 'error: aws CLI is required.\n' >&2; exit 1; }
command -v python3 >/dev/null || { printf 'error: python3 is required.\n' >&2; exit 1; }

aws_cli() {
  command aws --profile "$profile" --region "$region" "$@"
}

bold=$'\033[1m'
green=$'\033[0;32m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
cyan=$'\033[0;36m'
reset=$'\033[0m'

header() {
  printf "\n${bold}${cyan}=== %s ===${reset}\n" "$1"
}

# ------------------------------------------------------------------------------
# 1. Identity & Scope Check
# ------------------------------------------------------------------------------
header "1. AWS Identity & Region"
identity_json="$(aws_cli sts get-caller-identity --output json 2>/dev/null || true)"
if [[ -z "$identity_json" ]]; then
  printf "${red}error: failed to authenticate with AWS using profile '%s' in %s${reset}\n" "$profile" "$region" >&2
  exit 1
fi

account_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["Account"])' "$identity_json")"
caller_arn="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["Arn"])' "$identity_json")"
printf "Account: ${bold}%s${reset} | Region: ${bold}%s${reset}\nCaller:  %s\n" "$account_id" "$region" "$caller_arn"

# ------------------------------------------------------------------------------
# 2. Cluster Discovery
# ------------------------------------------------------------------------------
header "2. ECS Cluster Discovery"
if [[ -z "$cluster_name" ]]; then
  clusters_json="$(aws_cli ecs list-clusters --output json)"
  cluster_name="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
prefix = sys.argv[2]
matched = [c.split("/")[-1] for c in data.get("clusterArns", []) if prefix in c]
print(matched[0] if matched else "")
' "$clusters_json" "$prefix_filter")"
fi

if [[ -z "$cluster_name" ]]; then
  printf "${yellow}No active ECS cluster matching prefix '%s' found in %s.${reset}\n" "$prefix_filter" "$region"
else
  printf "Found Cluster: ${green}${bold}%s${reset}\n" "$cluster_name"
fi

# ------------------------------------------------------------------------------
# 3. ECS Services & Tasks Diagnostics
# ------------------------------------------------------------------------------
if [[ -n "$cluster_name" ]]; then
  header "3. ECS Services & Running Tasks in ${cluster_name}"
  services_json="$(aws_cli ecs list-services --cluster "$cluster_name" --output json)"
  service_arns="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1]).get("serviceArns", [])))' "$services_json")"
  
  if [[ -n "$service_arns" ]]; then
    # shellcheck disable=SC2086
    aws_cli ecs describe-services --cluster "$cluster_name" --services $service_arns \
      --query "services[].[serviceName,status,desiredCount,runningCount,taskDefinition]" \
      --output table
  else
    printf "No active ECS services in cluster %s.\n" "$cluster_name"
  fi

  header "4. Stopped Tasks & Container Failure Reasons"
  stopped_json="$(aws_cli ecs list-tasks --cluster "$cluster_name" --desired-status STOPPED --output json)"
  stopped_arns="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1]).get("taskArns", [])))' "$stopped_json")"
  
  if [[ -n "$stopped_arns" ]]; then
    # shellcheck disable=SC2086
    task_details="$(aws_cli ecs describe-tasks --cluster "$cluster_name" --tasks $stopped_arns \
      --query "tasks[].[taskArn,stopCode,stoppedReason,join('; ', containers[].reason)]" --output json)"
    
    python3 -c '
import json, sys
tasks = json.loads(sys.argv[1])
red, green, reset = sys.argv[2], sys.argv[3], sys.argv[4]
for t in tasks:
    arn, code, reason, c_reasons = t
    is_pull_err = any(err in (reason or "") or err in (c_reasons or "") for err in ["CannotPullContainerError", "ResourceInitializationError"])
    color = red if is_pull_err else green
    print(f"Task:   {arn.split(\"/\")[-1]}")
    print(f"Code:   {code}")
    print(f"Reason: {color}{reason}{reset}")
    if c_reasons:
        print(f"Containers: {color}{c_reasons}{reset}")
    print("-" * 60)
' "$task_details" "$red" "$green" "$reset"
  else
    printf "${green}✓ No stopped tasks found in cluster %s.${reset}\n" "$cluster_name"
  fi
fi

# ------------------------------------------------------------------------------
# 5. VPC Endpoints Inspection (PrivateLink & S3 Gateway)
# ------------------------------------------------------------------------------
header "5. VPC Endpoints Status"
endpoints_json="$(aws_cli ec2 describe-vpc-endpoints \
  --filters "Name=tag:${tag_key},Values=${tag_value}" \
  --query "VpcEndpoints[].[VpcEndpointId,ServiceName,State,VpcEndpointType]" \
  --output json)"

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
' "$endpoints_json" "$red" "$green" "$yellow" "$reset"

# ------------------------------------------------------------------------------
# 6. Security Group & EC2 Description Character-Set Safety
# ------------------------------------------------------------------------------
header "6. Security Groups & Description Rule Validation"
sgs_json="$(aws_cli ec2 describe-security-groups \
  --filters "Name=tag:${tag_key},Values=${tag_value}" \
  --query "SecurityGroups[].[GroupId,GroupName,Description]" \
  --output json)"

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
' "$sgs_json" "$red" "$green" "$reset"

# ------------------------------------------------------------------------------
# 7. Route Table Zero-Egress Assertion
# ------------------------------------------------------------------------------
header "7. Private Subnet Route Tables (Zero-Egress Check)"
subnets_json="$(aws_cli ec2 describe-subnets \
  --filters "Name=tag:${tag_key},Values=${tag_value}" \
  --query "Subnets[].[SubnetId,CidrBlock,Tags[?Key=='Name'].Value|[0]]" \
  --output json)"

python3 -c '
import json, sys, subprocess
subnets = json.loads(sys.argv[1])
profile = sys.argv[2]
region = sys.argv[3]
red, green, reset = sys.argv[4], sys.argv[5], sys.argv[6]

private_subnets = [s[0] for s in subnets if "private" in (s[2] or "").lower()]

if not private_subnets:
    print("No subnets matching \"private\" found.")
else:
    for s_id in private_subnets:
        cmd = ["aws", "--profile", profile, "--region", region, "ec2", "describe-route-tables",
               "--filters", f"Name=association.subnet-id,Values={s_id}",
               "--query", "RouteTables[].Routes[?DestinationCidrBlock==\"0.0.0.0/0\" || DestinationIpv6CidrBlock==\"::/0\"][]",
               "--output", "json"]
        out = subprocess.check_output(cmd)
        routes = json.loads(out)
        if routes:
            print(f"Subnet {s_id}: {red}LEAK DETECTED - Found default route: {routes}{reset}")
        else:
            print(f"Subnet {s_id}: {green}SECURE (zero default egress routes){reset}")
' "$subnets_json" "$profile" "$region" "$red" "$green" "$reset"

# ------------------------------------------------------------------------------
# 8. Load Balancer & Target Group Probing
# ------------------------------------------------------------------------------
header "8. Application Load Balancer Health & Probing"
albs_json="$(aws_cli elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, '${prefix_filter}')].[DNSName,State.Code,LoadBalancerArn]" --output json 2>/dev/null || echo "[]")"

python3 -c '
import json, sys, urllib.request
albs = json.loads(sys.argv[1])
red, green, reset = sys.argv[2], sys.argv[3], sys.argv[4]

if not albs:
    print("No ALBs matching prefix found.")
else:
    for alb in albs:
        dns, state, arn = alb
        print(f"ALB:   {dns} ({state})")
        url = f"http://{dns}/"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ConOps-Diagnostic-Probe"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                status = resp.status
                print(f"Probe: {green}GET {url} -> HTTP {status}{reset}")
        except Exception as e:
            print(f"Probe: {red}GET {url} failed ({e}){reset}")
' "$albs_json" "$red" "$green" "$reset"

# ------------------------------------------------------------------------------
# 9. ECR Pull-Through Cache Verification
# ------------------------------------------------------------------------------
header "9. ECR Pull-Through Cache & Repositories"
ptc_json="$(aws_cli ecr describe-pull-through-cache-rules --query "pullThroughCacheRules[?contains(ecrRepositoryPrefix, '${prefix_filter}')].[ecrRepositoryPrefix,upstreamRegistryUrl]" --output json 2>/dev/null || echo "[]")"
if [[ -n "$ptc_json" && "$ptc_json" != "[]" ]]; then
  python3 -c '
import json, sys
rules = json.loads(sys.argv[1])
for r in rules:
    print(f"Cache Rule: {r[0]} -> {r[1]}")
' "$ptc_json"
else
  printf "No active pull-through cache rules matching prefix '%s'.\n" "$prefix_filter"
fi

printf "\n${bold}${green}Diagnostic inspection complete.${reset}\n"
