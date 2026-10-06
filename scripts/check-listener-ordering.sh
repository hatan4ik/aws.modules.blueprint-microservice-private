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
# working directory.
set -euo pipefail

graph="$(terraform graph)"
status=0

for listener in https http; do
  if ! grep -q "\"module.service.aws_ecs_service.this\" -> \"module.alb.aws_lb_listener.${listener}\"" <<<"$graph"; then
    echo "error: module.service.aws_ecs_service.this does not depend on module.alb.aws_lb_listener.${listener}" >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "ok: the ECS service is created after the ALB listeners"
fi
exit "$status"
