#!/usr/bin/env bash
# ==============================================================================
# SRE / ConOps Janitor Tool: Integration Stack Emergency Cleanup
# ==============================================================================
# Safely discovers and tears down orphan or interrupted integration test
# resources tagged with Disposable=true and IntegrationTest=aws.modules.blueprint-microservice-private.
# Tears down in strict dependency order to avoid cloud bill accumulation.
# ==============================================================================
set -euo pipefail

profile="${AWS_PROFILE:-AWS-hatan4ik-gmail}"
region="${AWS_REGION:-us-east-2}"
prefix_filter="bp-e2e-"
tag_key="IntegrationTest"
tag_value="aws.modules.blueprint-microservice-private"
dry_run=false

usage() {
  cat <<'USAGE'
Usage: scripts/cleanup-integration-stack.sh [options]

Discovers and deletes orphan AWS resources from interrupted integration runs.
Deletes in strict dependency order: ECS -> ALB -> ECR -> Endpoints -> SGs -> VPC -> Cluster.

Options:
  --profile NAME       AWS CLI profile (default: AWS_PROFILE or AWS-hatan4ik-gmail)
  --region REGION      AWS Region (default: AWS_REGION or us-east-2)
  --prefix PREFIX      Name prefix filter (default: bp-e2e-)
  --dry-run            Show what would be deleted without executing deletions
  -h, --help           Show this message
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --region) region="$2"; shift 2 ;;
    --prefix) prefix_filter="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
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

header "1. Target Scope & Identity"
identity_json="$(aws_cli sts get-caller-identity --output json 2>/dev/null || true)"
if [[ -z "$identity_json" ]]; then
  printf "${red}error: failed to authenticate with AWS using profile '%s' in %s${reset}\n" "$profile" "$region" >&2
  exit 1
fi
account_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["Account"])' "$identity_json")"
printf "Account: ${bold}%s${reset} | Region: ${bold}%s${reset} | Dry-Run: ${bold}%s${reset}\n" "$account_id" "$region" "$dry_run"

# ------------------------------------------------------------------------------
# 2. ECS Services & Clusters
# ------------------------------------------------------------------------------
header "2. ECS Clusters & Services"
clusters_json="$(aws_cli ecs list-clusters --output json)"
clusters="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
prefix = sys.argv[2]
matched = [c.split("/")[-1] for c in data.get("clusterArns", []) if prefix in c]
print(" ".join(matched))
' "$clusters_json" "$prefix_filter")"

for c in $clusters; do
  printf "Found cluster: %s\n" "$c"
  services_json="$(aws_cli ecs list-services --cluster "$c" --output json)"
  services="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1]).get("serviceArns", [])))' "$services_json")"
  for s in $services; do
    s_name="${s##*/}"
    printf "  -> Service: %s (stopping & deleting)\n" "$s_name"
    if [[ "$dry_run" == false ]]; then
      aws_cli ecs update-service --cluster "$c" --service "$s_name" --desired-count 0 >/dev/null || true
      aws_cli ecs delete-service --cluster "$c" --service "$s_name" --force >/dev/null || true
    fi
  done
  if [[ "$dry_run" == false ]]; then
    printf "  -> Deleting cluster: %s\n" "$c"
    aws_cli ecs delete-cluster --cluster "$c" >/dev/null || true
  fi
done

# ------------------------------------------------------------------------------
# 3. Application Load Balancers & Target Groups
# ------------------------------------------------------------------------------
header "3. Application Load Balancers"
albs_json="$(aws_cli elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, '${prefix_filter}')].LoadBalancerArn" --output json 2>/dev/null || echo "[]")"
albs="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1])))' "$albs_json")"

for alb_arn in $albs; do
  printf "Deleting ALB: %s\n" "$alb_arn"
  if [[ "$dry_run" == false ]]; then
    aws_cli elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" || true
  fi
done

# ------------------------------------------------------------------------------
# 4. ECR Pull-Through Cache & Repositories
# ------------------------------------------------------------------------------
header "4. ECR Pull-Through Cache & Repositories"
repos_json="$(aws_cli ecr describe-repositories --query "repositories[?contains(repositoryName, '${prefix_filter}')].repositoryName" --output json 2>/dev/null || echo "[]")"
repos="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1])))' "$repos_json")"

for r in $repos; do
  printf "Deleting ECR Repository: %s\n" "$r"
  if [[ "$dry_run" == false ]]; then
    aws_cli ecr delete-repository --repository-name "$r" --force >/dev/null || true
  fi
done

rules_json="$(aws_cli ecr describe-pull-through-cache-rules --query "pullThroughCacheRules[?contains(ecrRepositoryPrefix, '${prefix_filter}')].ecrRepositoryPrefix" --output json 2>/dev/null || echo "[]")"
rules="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1])))' "$rules_json")"

for r in $rules; do
  printf "Deleting Pull-Through Cache Rule: %s\n" "$r"
  if [[ "$dry_run" == false ]]; then
    aws_cli ecr delete-pull-through-cache-rule --ecr-repository-prefix "$r" >/dev/null || true
  fi
done

# ------------------------------------------------------------------------------
# 5. VPC Endpoints
# ------------------------------------------------------------------------------
header "5. VPC Endpoints"
ep_json="$(aws_cli ec2 describe-vpc-endpoints --filters "Name=tag:${tag_key},Values=${tag_value}" --query "VpcEndpoints[].VpcEndpointId" --output json)"
eps="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1])))' "$ep_json")"

if [[ -n "$eps" ]]; then
  printf "Deleting VPC Endpoints: %s\n" "$eps"
  if [[ "$dry_run" == false ]]; then
    # shellcheck disable=SC2086
    aws_cli ec2 delete-vpc-endpoints --vpc-endpoint-ids $eps >/dev/null || true
  fi
else
  printf "No orphan VPC endpoints found.\n"
fi

# ------------------------------------------------------------------------------
# 6. VPCs & Security Groups
# ------------------------------------------------------------------------------
header "6. Security Groups & VPCs"
vpcs_json="$(aws_cli ec2 describe-vpcs --filters "Name=tag:${tag_key},Values=${tag_value}" --query "Vpcs[].VpcId" --output json)"
vpcs="$(python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1])))' "$vpcs_json")"

if [[ -z "$vpcs" ]]; then
  printf "No orphan integration VPCs found.\n"
else
  printf "Found VPCs: %s (Note: if subnets or SGs are attached, use terraform destroy in tests/integration/ roots for clean cascade)\n" "$vpcs"
fi

printf "\n${bold}${green}Cleanup scan complete.${reset}\n"
