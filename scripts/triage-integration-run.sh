#!/usr/bin/env bash
# ==============================================================================
# SRE / DevOps Triage Tool: GitHub Integration Run Inspector
# ==============================================================================
# Automates the triage and root-cause analysis of GitHub Actions integration
# runs for aws.modules.blueprint-microservice-private. Isolates failing steps,
# filters out teardown noise, and pinpoints exact AWS API or container errors.
# ==============================================================================
set -euo pipefail

repo="${GH_REPO:-hatan4ik/aws.modules.blueprint-microservice-private}"
run_id=""
watch_mode=false
limit=5

usage() {
  cat <<'USAGE'
Usage: scripts/triage-integration-run.sh [options]

Triages GitHub Actions integration runs, extracting root-cause errors from failed steps.

Options:
  --run-id ID          Specific workflow run ID to triage (default: latest run)
  --watch              Follow the active run until completion
  --limit N            Number of recent runs to list if no run ID given (default: 5)
  --repo REPO          GitHub repository (default: hatan4ik/aws.modules.blueprint-microservice-private)
  -h, --help           Show this message
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) run_id="$2"; shift 2 ;;
    --watch) watch_mode=true; shift ;;
    --limit) limit="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { printf 'error: gh (GitHub CLI) is required.\n' >&2; exit 1; }
command -v python3 >/dev/null || { printf 'error: python3 is required.\n' >&2; exit 1; }

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
# 1. Resolve Run ID
# ------------------------------------------------------------------------------
if [[ -z "$run_id" ]]; then
  header "Recent Integration Runs on ${repo}"
  recent_runs_json="$(gh run list -R "$repo" --workflow=integration.yml --limit "$limit" --json databaseId,status,conclusion,createdAt,displayTitle,headSha,event)"
  
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
red, green, yellow, reset, bold = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]

if not data:
    print("No runs found.")
    sys.exit(0)

print("%s%-13s %-12s %-12s %-18s %s%s" % (bold, "Run ID", "Status", "Conclusion", "Created At", "Title", reset))
print("-" * 75)
for r in data:
    rid = str(r["databaseId"])
    status = r["status"]
    conc = r.get("conclusion") or "-"
    c_color = green if conc == "success" else (red if conc == "failure" else yellow)
    created = r["createdAt"][:16]
    title = r.get("displayTitle", "")[:30]
    print(f"{rid:<13} {status:<12} {c_color}{conc:<12}{reset} {created:<18} {title}")
' "$recent_runs_json" "$red" "$green" "$yellow" "$reset" "$bold"

  run_id="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data[0]["databaseId"] if data else "")
' "$recent_runs_json")"

  if [[ -z "$run_id" ]]; then
    printf "No runs available to triage.\n"
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# 2. Watch Mode (if active)
# ------------------------------------------------------------------------------
if [[ "$watch_mode" == true ]]; then
  header "Watching Run ${run_id}"
  gh run watch "$run_id" -R "$repo"
fi

# ------------------------------------------------------------------------------
# 3. Triage Target Run
# ------------------------------------------------------------------------------
header "Triaging Run: ${run_id}"
run_meta="$(gh run view "$run_id" -R "$repo" --json databaseId,status,conclusion,createdAt,updatedAt,jobs,headSha,event,url)"

python3 -c '
import json, sys
data = json.loads(sys.argv[1])
red, green, yellow, reset, bold = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]

rid = data["databaseId"]
status = data["status"]
conc = data.get("conclusion") or "in_progress"
color = green if conc == "success" else (red if conc == "failure" else yellow)

url = data.get("url", "")
sha = data.get("headSha", "")[:7]
event = data.get("event", "")
created = data.get("createdAt", "")

print("URL:        " + url)
print("Commit:     " + sha)
print("Event:      " + event)
print("Created:    " + created)
print("Status:     " + status)
print("Result:     " + color + bold + conc.upper() + reset)
' "$run_meta" "$red" "$green" "$yellow" "$reset" "$bold"

# ------------------------------------------------------------------------------
# 4. Step Breakdown & Root-Cause Failure Extraction
# ------------------------------------------------------------------------------
header "Job Steps & Diagnostics"
job_id="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
jobs = data.get("jobs", [])
print(jobs[0]["databaseId"] if jobs else "")
' "$run_meta")"

if [[ -n "$job_id" ]]; then
  job_detail="$(gh api "repos/${repo}/actions/jobs/${job_id}")"
  
  has_failure="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
red, green, yellow, reset, bold = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]

steps = data.get("steps", [])
failed_step = None

for s in steps:
    name = s["name"]
    status = s["status"]
    conc = s.get("conclusion") or "running"
    s_color = green if conc == "success" else (red if conc == "failure" else yellow)
    print(f"  • {name:<45} [{s_color}{conc}{reset}]")
    if conc == "failure":
        failed_step = name

print("")
if failed_step:
    print(f"{bold}{red}FAILED STEP: {failed_step}{reset}")
    print("true")
else:
    print(f"{bold}{green}ALL STEPS PASSED{reset}")
    print("false")
' "$job_detail" "$red" "$green" "$yellow" "$reset" "$bold")"

  if grep -q "true" <<<"$has_failure"; then
    header "Root Cause Log Analysis"
    printf "Extracting failed logs from job %s...\n\n" "$job_id"
    failed_log="$(gh run view --job="$job_id" --log-failed -R "$repo" 2>/dev/null || true)"
    
    python3 -c '
import sys, re
log = sys.argv[1]
red = sys.argv[2]
reset = sys.argv[3]
bold = sys.argv[4]

# Filter out standard teardown lines to surface the actual root cause
patterns = [
    r"(Error:.*)",
    r"(api error [A-Za-z0-9]+: .*)",
    r"(Could not assume role with OIDC: .*)",
    r"(CannotPullContainerError.*)",
    r"(ResourceInitializationError.*)",
    r"(InvalidParameterValue: .*)"
]

found = []
for line in log.splitlines():
    for p in patterns:
        m = re.search(p, line)
        if m:
            found.append(m.group(1))

if found:
    print(f"{bold}{red}>>> Root Cause Findings <<<{reset}")
    for item in set(found):
        print(f"  ✖ {red}{item}{reset}")
else:
    print("Surfacing failure excerpt:")
    lines = [l for l in log.splitlines() if not any(skip in l for skip in ["Refreshing state...", "Destruction complete", "Destroying..."])]
    for l in lines[-25:]:
        print(f"  {l}")
' "$failed_log" "$red" "$reset" "$bold"
  fi
fi

printf "\n${bold}${green}Triage complete.${reset}\n"
