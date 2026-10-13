#!/usr/bin/env bash
# Fails unless the ECS service depends on the ALB listeners in Terraform's
# dependency graph.
#
# ECS rejects CreateService while the target group is not yet attached to a
# load balancer, and aws.modules.alb's target_group_arns output depends only on
# the target group, not the listener. locals.tf gates the ARN on the listener
# so the service is created after it; a refactor that passes
# module.alb.target_group_arns straight through would still plan and pass
# every mocked test, then fail intermittently on a real first apply. This
# check reads the edge from `terraform graph` instead. Requires an initialised
# working directory (`terraform init -backend=false`).
#
# aws.modules.ecs-service declares the service twice (aws_ecs_service.this and
# aws_ecs_service.ignore_task_definition, count-gated), so every variant that
# exists in the graph is checked, and at least one must exist.
#
# Terraform >= 1.7 transitively reduces the graph: if the service reaches a
# listener only through another resource, the direct edge is dropped even
# though apply ordering is still correct. A missing direct edge is therefore
# accepted when the graph still has a path from the service to the listener
# (the shortest one is printed), and fails only when there is none.
set -euo pipefail

service_variants=(
  module.service.aws_ecs_service.this
  module.service.aws_ecs_service.ignore_task_definition
)
listeners=(
  module.alb.aws_lb_listener.https
  module.alb.aws_lb_listener.http
)

if ! command -v terraform >/dev/null 2>&1; then
  echo "error: terraform is not on PATH" >&2
  exit 1
fi

errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT
if ! graph="$(terraform graph 2>"$errfile")"; then
  echo "error: 'terraform graph' failed; is the working directory initialised (terraform init -backend=false)?" >&2
  cat "$errfile" >&2
  exit 1
fi

# Prints the shortest dependency path "src -> ... -> dst" over the graph's
# `"a" -> "b"` edge lines (a depends on b), or nothing and exit 1 if none.
shortest_path() {
  printf '%s\n' "$graph" | awk -v src="$1" -v dst="$2" '
    BEGIN { FS = "\"" }
    $3 == " -> " { n = ++cnt[$2]; adj[$2, n] = $4 }
    END {
      head = 1; tail = 1; queue[1] = src; seen[src] = 1
      while (head <= tail) {
        cur = queue[head++]
        for (i = 1; i <= cnt[cur]; i++) {
          nxt = adj[cur, i]
          if (nxt in seen) { continue }
          seen[nxt] = 1; prev[nxt] = cur; queue[++tail] = nxt
          if (nxt == dst) {
            path = dst
            for (p = prev[dst]; p != src; p = prev[p]) { path = p " -> " path }
            print src " -> " path
            exit 0
          }
        }
      }
      exit 1
    }'
}

status=0
checked=0

for service in "${service_variants[@]}"; do
  # Quoted, fixed-string match: the node name appears as "<address>" in the graph.
  if ! grep -qF "\"${service}\"" <<<"$graph"; then
    continue
  fi
  checked=$((checked + 1))
  for listener in "${listeners[@]}"; do
    if grep -qF "\"${service}\" -> \"${listener}\"" <<<"$graph"; then
      continue
    fi
    if path="$(shortest_path "$service" "$listener")"; then
      echo "ok: $service has no direct edge to $listener but is ordered after it through: $path"
      continue
    fi
    echo "error: $service does not depend on $listener" >&2
    echo "       no direct edge and no path through other resources in 'terraform graph'; the graph is" >&2
    echo "       transitively reduced, so an indirect dependency would have shown up as a path." >&2
    status=1
  done
done

if [ "$checked" -eq 0 ]; then
  echo "error: no aws_ecs_service node (${service_variants[*]}) found in 'terraform graph'; was the module renamed?" >&2
  exit 1
fi

if [ "$status" -eq 0 ]; then
  echo "ok: the ECS service is created after the ALB listeners"
fi
exit "$status"
