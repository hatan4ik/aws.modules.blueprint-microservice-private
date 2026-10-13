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
    --run-id) need_value "$1" "$#"; run_id="$2"; shift 2 ;;
    --watch) watch_mode=true; shift ;;
    --limit) need_value "$1" "$#"; limit="$2"; shift 2 ;;
    --repo) need_value "$1" "$#"; repo="$2"; shift 2 ;;
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
  printf '\n%s%s=== %s ===%s\n' "$bold" "$cyan" "$1" "$reset"
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

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
# 4. Step Breakdown & Root-Cause Failure Extraction (every job of the run)
# ------------------------------------------------------------------------------
header "Job Steps & Diagnostics"
jobs_tsv="$work_dir/jobs.tsv"
python3 -c '
import json, sys
data = json.loads(sys.argv[1])
for job in data.get("jobs") or []:
    print("%s\t%s" % (job["databaseId"], str(job.get("name", "")).replace("\t", " ")))
' "$run_meta" >"$jobs_tsv"

triage_errors=0
if [[ ! -s "$jobs_tsv" ]]; then
  printf 'No jobs reported for run %s.\n' "$run_id"
fi

while IFS=$'\t' read -r -u 3 job_id job_name; do
  [[ -n "$job_id" ]] || continue
  printf '\n%sJob: %s (%s)%s\n' "$bold" "$job_name" "$job_id" "$reset"
  # A failed lookup of one job must not abort the triage of the others.
  job_detail_err="$work_dir/job-${job_id}.detail.err"
  if ! job_detail="$(gh api "repos/${repo}/actions/jobs/${job_id}" 2>"$job_detail_err")"; then
    printf '%serror: could not read job %s: %s%s\n' \
      "$red" "$job_id" "$(tr '\n' ' ' <"$job_detail_err" | cut -c1-300)" "$reset" >&2
    triage_errors=$((triage_errors + 1))
    continue
  fi

  # The breakdown and the FAILED STEP banner go straight to the terminal. The
  # outcome is the program's exit status: 0 = every step passed, 10 = a failed,
  # timed-out or cancelled step or job, 11 = the job has no conclusion yet (no
  # verdict is possible). Any other status is a bug in the program.
  step_rc=0
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
red, green, yellow, reset, bold = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]

# GitHub reports a job that exceeds timeout-minutes, or one that was cancelled,
# as "cancelled": that is not a pass, so it is treated like a failure here.
BAD = ("failure", "timed_out", "cancelled", "action_required", "startup_failure")
failed_steps = []
for s in data.get("steps") or []:
    name = s["name"]
    conc = s.get("conclusion") or s.get("status") or "running"
    s_color = green if conc == "success" else (red if conc in BAD else yellow)
    print(f"  • {name:<45} [{s_color}{conc}{reset}]")
    if conc in BAD:
        failed_steps.append((name, conc))

job_conc = data.get("conclusion") or ""
print("")
for name, conc in failed_steps:
    label = "CANCELLED STEP" if conc == "cancelled" else "FAILED STEP"
    print(f"{bold}{red}{label}: {name}{reset}")
if not failed_steps and job_conc in BAD:
    print(f"{bold}{red}FAILED JOB: conclusion {job_conc} but no step reports a problem{reset}")
if failed_steps or job_conc in BAD:
    sys.exit(10)
if not job_conc:
    job_status = data.get("status") or "unknown"
    print(f"{bold}{yellow}JOB NOT FINISHED (status {job_status}): no verdict yet{reset}")
    sys.exit(11)
print(f"{bold}{green}ALL STEPS PASSED{reset}")
' "$job_detail" "$red" "$green" "$yellow" "$reset" "$bold" || step_rc=$?

  if [[ "$step_rc" -eq 0 ]]; then
    continue
  fi
  if [[ "$step_rc" -eq 11 ]]; then
    triage_errors=$((triage_errors + 1))
    continue
  fi
  if [[ "$step_rc" -ne 10 ]]; then
    printf '%serror: could not read the step list of job %s (exit %s)%s\n' "$red" "$job_id" "$step_rc" "$reset" >&2
    triage_errors=$((triage_errors + 1))
    continue
  fi

  header "Root Cause Log Analysis: ${job_name}"
  printf 'Extracting failed logs from job %s...\n\n' "$job_id"
  log_file="$work_dir/job-${job_id}.log"
  err_file="$work_dir/job-${job_id}.err"
  # No '|| true': a log that cannot be fetched (still running, expired, no
  # permission) must say so instead of looking like a failure with no errors.
  if ! gh run view --job="$job_id" --log-failed -R "$repo" >"$log_file" 2>"$err_file"; then
    printf '%serror: could not fetch the failed log of job %s: %s%s\n' \
      "$red" "$job_id" "$(tr '\n' ' ' <"$err_file" | cut -c1-300)" "$reset" >&2
    triage_errors=$((triage_errors + 1))
    continue
  fi

  # The log goes to python as a file, never as an argument (a single argv
  # element is capped at 128 KiB on Linux and a terraform log is bigger).
  python3 -c '
import re, sys

path, red, yellow, reset, bold = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(path, errors="replace") as fh:
    lines = fh.read().splitlines()

# integration-e2e.sh runs apply, assertions and teardown inside ONE step; its
# EXIT trap announces teardown with "==> destroy". Split there so a teardown
# error is never mistaken for the root cause of the failed apply.
marker = None
for idx, line in enumerate(lines):
    if "==> destroy" in line:
        marker = idx
        break
apply_part = lines if marker is None else lines[:marker]
teardown_part = [] if marker is None else lines[marker:]

patterns = [re.compile(p) for p in (
    r"(Error:.*)",
    r"(api error [A-Za-z0-9]+: .*)",
    r"(Could not assume role with OIDC: .*)",
    r"(CannotPullContainerError.*)",
    r"(ResourceInitializationError.*)",
    r"(InvalidParameterValue: .*)",
    r"(?:^|\s)(error: .+)",
)]


def findings(part):
    found = []
    for line in part:
        hits = [m for m in (p.search(line) for p in patterns) if m]
        if hits:
            # one finding per line: the earliest, then the longest, match
            best = min(hits, key=lambda m: (m.start(1), -m.end(1)))
            found.append(best.group(1).strip())
    return list(dict.fromkeys(found))  # de-duplicated, in log order


noise = ("Refreshing state...", "Destruction complete", "Destroying...")
apply_found = findings(apply_part)
teardown_found = findings(teardown_part)

if not lines:
    print("The failed log is empty.")
if marker is None:
    print("(no \"==> destroy\" marker in the log: treated as one block)")
if apply_found:
    print(f"{bold}{red}>>> Root Cause Findings (apply and assertions) <<<{reset}")
    for item in apply_found:
        print(f"  ✖ {red}{item}{reset}")
else:
    print("No known error pattern in the apply part. Surfacing failure excerpt:")
    excerpt = [l for l in apply_part if not any(skip in l for skip in noise)]
    for l in excerpt[-25:]:
        print(f"  {l}")

if teardown_found:
    print("")
    print(f"{bold}{yellow}>>> Teardown findings (after \"==> destroy\"; reported separately, not the root cause) <<<{reset}")
    for item in teardown_found:
        print(f"  ! {yellow}{item}{reset}")
' "$log_file" "$red" "$yellow" "$reset" "$bold"
done 3<"$jobs_tsv"

if [[ "$triage_errors" -gt 0 ]]; then
  printf '\n%s%sTriage incomplete: %d job(s) could not be analysed.%s\n' "$bold" "$red" "$triage_errors" "$reset"
  exit 1
fi
printf '\n%s%sTriage complete.%s\n' "$bold" "$green" "$reset"
