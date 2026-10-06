# Design: aws.modules.blueprint-microservice-private v1

Status: proposed 2026-10-06. First composed archetype ("L2") in the `aws.modules.*` catalog.

## Why this exists

A platform-level audit of the catalog found that every leaf module (`vpc`, `alb`, `ecs`, `ecs-service`, `iam`, `security-group`, and the rest) is well built and well tested in isolation, and that nothing showed how a product team composes four to six of them into one working private microservice. Doing it by hand meant reading five or more repositories, reconciling output and input shapes across them, and discovering the dependency order and the cross-module failure modes by trial. Every team would rediscover the same things, and some would get the wiring subtly wrong (a target group ARN raced against its listener, a task security group opened to the VPC CIDR instead of the ALB, an execution role granted `secretsmanager:*` because the exact ARN was inconvenient).

This repository is a composition root, not a new primitive. It owns no AWS resource. It calls three leaf modules in order, translates one module's outputs into the next one's inputs, adds two plan-time guards and one advisory check that no single leaf can express, and exposes the handful of inputs a product team actually varies.

## Principles

- **Every resource comes from a leaf.** The only blocks in this repository are `module`, `locals`, `variable`, `output`, `check`, and two `data` reads used as guards. If a resource is missing, the fix belongs in a leaf.
- **Hide the wiring, not the decisions.** An input is exposed when a product team routinely needs a different value for a typical private HTTP service. Everything else is a fixed, documented default.
- **Fail at plan, not at apply.** Inputs are typed objects with `optional()` defaults, `nullable = false`, and validations. Where a leaf would only fail at apply because it cannot see another leaf (cluster region against provider region), the blueprint adds the guard.
- **Pin by commit SHA.** Each leaf is pinned to the commit of a released tag, with the version in a comment, like every other cross-module reference in the fleet.

## Composition decisions

### Step 1: the network is `aws.modules.vpc` v1.1.0, two tiers, no NAT by default

The module was read at `969e78e` (v1.1.0). Its `examples/three-tier-nat` shows the exact convention for a public load-balancer tier and a private workload tier: tiers keyed by name, subnets keyed by stable AZ keys (`az1`, `az2`), sized with `newbits`/`netnum` relative to the VPC CIDR, a public tier routed to the internet gateway with `allow_default_route = true`, and NAT gateways referenced by key. The blueprint follows that convention minus the data tier: public `newbits = 8` (netnum 0..2), private `newbits = 4` (netnum 1..3). For any `/16` to `/19` the public subnets sit inside the first 1/16 of the block, which private netnum 0 would occupy, so the tiers never overlap; at `/19` the public subnets are `/27`, the ALB minimum, which is why the CIDR is validated to that range.

Decisions that were not obvious from the brief:

- **VPC Encryption Control is `monitor`, not the module's `enforce` default.** The vpc module's own `nat-egress` integration suite documents that enforce mode rejects an internet path. An internet-facing ALB needs an internet gateway, so enforce is incompatible with this archetype. `monitor` still reports unencrypted in-VPC traffic.
- **No NAT gateway by default; VPC endpoints instead.** "Private" in the name means the tasks have no internet route at all. A Fargate task can start without one if it can reach `ecr.api`, `ecr.dkr`, `logs`, and S3 (image layers) privately, so the blueprint always declares those endpoints through the vpc module's own `endpoints` input, adds `secretsmanager`/`ssm` when `container.secrets` references them, and lets the application declare more. This is also what `aws.modules.ecs` does for its platform and what `aws.modules.ecs-service`'s `private-platform` example shows. `network.nat_gateway = true` adds one NAT gateway for images outside ECR and third-party APIs; endpoints stay, so image pulls and logs never pay NAT data processing.
- **One NAT gateway, not one per zone.** Per-zone NAT needs one private tier per zone in the vpc module (its `three-tier-nat` README explains why: routes apply to every route table of a tier), which changes the `Tier` tags and the outputs' shape. The single-gateway zone dependency is documented as a failure mode instead. Per-zone NAT is deferred.
- **Flow logs with a created KMS key.** The vpc module warns on every plan while flow logs use AWS-managed encryption. The blueprint always sets `create_kms_key = true` (about $1/month) rather than exposing the choice.

### Step 2: no direct `aws.modules.security-group` call

Both leaves that need security groups already create them through `aws.modules.security-group`: `aws.modules.alb` v1.0.1 in `security_group.tf` (pinned to security-group v1.1.0, with `create_before_destroy_group = true`), and `aws.modules.ecs-service` v1.0.1 in `main.tf` (also v1.1.0). The ALB's group is complete on its own (listener ingress from `ingress_cidrs`, egress to the VPC CIDR). The task group takes declarative ingress and egress rule maps, so the blueprint only supplies rules: ingress on `container.port` from `module.alb.security_group_id`, egress on 443 to `module.vpc.endpoint_security_group_id` and to each gateway endpoint's prefix list from `module.vpc.gateway_endpoint_prefix_list_ids`, and 443 to `0.0.0.0/0` only with a NAT gateway. Calling the security-group module again would create a third group with nothing to attach it to.

Referencing the endpoint security group rather than the VPC CIDR (which `ecs-service`'s `private-platform` example uses) means the tasks can reach the endpoints and nothing else listening on 443 inside the VPC.

### Step 3: the ALB is `aws.modules.alb` v1.0.1, one `ip` target group keyed `app`

`target_groups` is keyed by a short name and `target_group_arns` is keyed identically, documented and tested (`tests/target_group_arns.tftest.hcl`) as the contract with `ecs-service`'s `load_balancers` map. The blueprint uses one key, `app`, for both the target group and the load-balancer attachment, and one container named `app`.

- **HTTPS or HTTP-only, derived from one input.** The module requires exactly one of `certificate_arn` or `create_http_only = true` (a precondition). The blueprint sets `create_http_only = certificate_arn == null`, so a caller supplies a certificate or nothing, and the blueprint's `http_only_listener` check warns on every plan in the second case.
- **The service waits for the listener.** The leaf's `target_group_arns` output depends only on `aws_lb_target_group`, not on the listener that attaches it to the ALB, and ECS rejects `CreateService` for a target group with no load balancer. The blueprint passes `local.forwarding_listener_arn == null ? null : module.alb.target_group_arns["app"]`, which adds the listener as a dependency of the service and of nothing else. A module-level `depends_on = [module.alb]` would also work but would serialise the roles, log group, and task definition behind the ALB's multi-minute creation and hide the real reason. `scripts/check-listener-ordering.sh` asserts the edge in `terraform graph`, since mocked tests cannot see ordering.
- **Health check defaults.** Interval 15 s, timeout 5 s, 2 to healthy, 3 to unhealthy, so a healthy task is in service about 30 s after it answers and a broken one is out in 45 s. Path `/` and matcher `200-399` are the defaults most likely to pass for an arbitrary application (a root redirect counts as healthy); both are inputs because they are the most common reason a service never stabilises. The ALB module's default interval (30 s) would double time-to-healthy on every deployment.
- **The released version, not `main`.** `aws.modules.alb` `main` carries an unreleased `listener_rule_arns` output and a commit message marked "TEMPORARY security-group pin". The blueprint pins the released v1.0.1 and needs neither.

### Step 4: the task role comes from `aws.modules.ecs-service`'s own `modules/iam`

`aws.modules.cloudformation//modules/service-role` was read and rejected: its trust policy is hard-coded to `cloudformation.amazonaws.com` (it exists to stop CloudFormation stack roles from defaulting to `AdministratorAccess`), so it cannot be assumed by ECS tasks. `aws.modules.iam` was also checked; it manages the sandbox delivery account's roles and state-bucket policies, not general workload roles.

`aws.modules.ecs-service` already composes `modules/iam` internally and creates both roles by default. Its trust policy admits only `ecs-tasks.amazonaws.com` with `aws:SourceAccount` and `aws:SourceArn` conditions derived from `cluster_arn`. The execution role's inline policy is derived from the secrets the containers reference (Secrets Manager ARNs reduced to the secret itself, SSM parameter ARNs as-is) and from `task_execution_role_kms_key_arns`. The task role carries only `task_role_statements`. The blueprint therefore calls no IAM module itself; it passes `container.secrets` into the container definition (from which the leaf derives the policy), `container.secrets_kms_key_arns` into `task_execution_role_kms_key_arns`, and `task_role_statements` through. Calling `modules/iam` separately would create a second pair of roles.

The blueprint adds two things the leaf cannot: an `Allow` statement may not use `*` as an action or resource (validated), and the cluster's account and region must equal the provider's (data-source postconditions), because the trust conditions are derived from the cluster ARN while everything else lands wherever the provider points.

### Step 5: the cluster is shared, not owned

`aws.modules.ecs` v1.0.0 states its scope as "the ECS platform foundation for one private, single-account environment": a cluster, a KMS key shared by the platform's encrypted data, an application log group, VPC endpoints, a registry, and a session store, explicitly creating "no task, no application". `aws.modules.ecs-service` takes `cluster_arn` and never creates a cluster. The live roots split network, platform, and workload into separate states. A cluster per microservice would duplicate the platform layer per service, so the blueprint takes `cluster_arn` as a required input and does not call `aws.modules.ecs`.

The examples take `cluster_arn` as a variable, and the README shows reading it from the platform root's state. They do not call `aws.modules.ecs` themselves: that module also requires a VPC for its endpoint security group, and creating a platform inside one service's VPC would invert the ownership the blueprint is meant to teach.

Two consequences, both handled: a Fargate cluster is not tied to a VPC, so the shared cluster runs this service's tasks in this blueprint's subnets; and the platform's KMS key, if used for the service's logs (`logs.kms_key_arn`), must already admit the service's log group ARN through `aws.modules.ecs`'s `additional_cloudwatch_log_group_arns`.

### Step 6: the service is `aws.modules.ecs-service` v1.0.1

One container named `app`, Fargate, private subnets, no public IP, `load_balancers.app` as above, `health_check_grace_period_seconds` from `health_check.grace_period_seconds`. Defaults the blueprint changes from the leaf's:

| Leaf input | Leaf default | Blueprint | Why |
| --- | --- | --- | --- |
| `desired_count` | 1 | 2 | One task per zone; a single task is a single point of failure behind a multi-zone ALB. |
| `wait_for_steady_state` | false | true | Without it, `terraform apply` reports success while the service crash-loops behind a failing health check. Exposed so a pipeline that deploys asynchronously can turn it off. |
| `health_check_grace_period_seconds` | null | 60 | Without a grace period a slow-starting application is killed by the first failing ALB check. |
| `volumes` / `mount_points` | none | one ephemeral volume per `container.writable_paths` entry | The leaf's read-only root filesystem default is kept; this is the supported way to make specific paths writable. |
| autoscaling `policies` | CPU at 60 % when omitted | CPU at `cpu_target_percent` (default 60) | Same behaviour, with the one tunable exposed. |

## Inputs deliberately not exposed

| Leaf input(s) | Fixed at | Why not exposed |
| --- | --- | --- |
| vpc `ipam`, `secondary_cidr_blocks`, `instance_tenancy`, DNS flags, `vpc_encryption_control`, `flow_logs.*`, tier layout, `route_tables` | `cidr_block`, two tiers, `monitor`, flow logs with a created key | The layout is the point of the blueprint. IPAM is a platform-network concern (bring-your-own network is deferred, below). |
| vpc endpoint policies, `private_dns_enabled`, endpoint security group settings | leaf defaults | Endpoint policies are an organisation-wide control, not a per-service one. |
| alb `internal`, `idle_timeout`, `drop_invalid_header_fields`, `redirect_http_to_https`, `additional_certificate_arns`, `listener_rules`, multiple `target_groups` | internet-facing, 60 s, true, true, none, none, one | One service, one target group, one hostname. Path-based routing across services belongs to a shared-ALB archetype. |
| target group protocol, `target_type`, `deregistration_delay`, health-check interval/timeout/thresholds | HTTP, `ip`, 30 s, 15/5/2/3 | Fargate requires `ip`; TLS to the task needs certificates in the container, out of scope for v1. The remaining knobs rarely need changing and are easy to misconfigure (timeout must be below interval). |
| ecs-service `require_image_digest` | true | Digest pinning is a platform guarantee, not a preference. |
| ecs-service container fields beyond `image`, `command`, `environment`, `secrets`, port, writable paths (entrypoint, user, sidecars, `linux_parameters`, `ulimits`, `health_check`, FireLens, `readonly_root_filesystem`) | leaf defaults, one container | A blueprint with the leaf's full container schema is the leaf. Teams needing sidecars use `aws.modules.ecs-service` directly. |
| ecs-service `capacity_provider_strategy`, `platform_version`, deployment percentages, `deployment_configuration` (blue/green, canary), `alarms`, `deployment_controller_type`, `ignore_task_definition_changes` | FARGATE, LATEST, 100/200, rolling with circuit-breaker rollback | Rolling with rollback is the safe default; the others are release-engineering choices for a later archetype. |
| ecs-service `service_registries`, `service_connect_configuration`, `vpc_lattice_configurations` | none | Service-to-service networking is a separate archetype. |
| ecs-service `enable_execute_command` | false | ECS Exec needs an `ssmmessages` endpoint and a break-glass access policy; deferred. |
| ecs-service bring-your-own roles, security groups, log group; role names, paths, boundaries, managed policy ARNs | created, `<name>-task`, `<name>-execution`, `/` | The blueprint exists to create correctly scoped ones. Managed policies are deliberately absent (they are the shortcut to over-broad access). |
| ecs-service `security_group_ingress_rules` / `egress_rules` | derived | The rules are the wiring. |

## Deferred to v2

- **Bring-your-own network.** Take `vpc_id` and subnet IDs from a platform network root instead of creating a VPC per service, for platforms that run many services per VPC. The blueprint's endpoint set would then become a requirement on the network rather than something it creates.
- **Internal ALB variant.** `aws.modules.alb` supports `internal = true`; an internal archetype would drop the internet gateway, allow `enforce` encryption control, and take client CIDRs instead of `0.0.0.0/0`.
- **DNS.** An alias record through `aws.modules.route53` and a certificate through `aws.modules.acm` for a given hostname. v1 outputs `alb_dns_name` and `alb_zone_id` for the caller to do this.
- **Dependencies inside the VPC.** Egress to a database or cache on non-HTTPS ports. v1 outputs `task_security_group_id` so a data store's group can admit the service, but the task group's egress is HTTPS-only.
- **Per-zone NAT gateways**, ECS Exec, request-count autoscaling (needs the target group's ARN suffix, which `aws.modules.alb` does not output), alarms-driven rollback, Service Connect.
- **Changing `container.port` in place.** Needs `aws.modules.alb` to name target groups with a prefix or a port suffix so `create_before_destroy` does not collide on the name.

## Testing strategy

Contract tests use `mock_provider` and assert the blueprint's glue: locals (the subnet layout, endpoint set, rule maps, load-balancer attachment, container definition), leaf outputs after a mocked apply (target group ARN, security group IDs, the execution role's derived policy), the guards, and every validation. Two Terraform limitations shaped the suite, and both are worth knowing for any future composed archetype:

1. **A nested module's `check` warning fails a `terraform test` run, and `expect_failures` cannot name it** ("You cannot expect failures from module.vpc.check"). This is true for plan and apply runs on Terraform 1.7, 1.8, and 1.9. `aws.modules.vpc`'s `internet_path_declared` check always warns in this blueprint, so no run can include the real vpc module as a child.
2. **`override_module` is not honoured by Terraform 1.7.5**: the overridden module is still planned with unknown inputs and fails on `count`/`for_each`. It works on 1.8.

So the suites replace `module.vpc` with fixed outputs (`override_module`, Terraform >= 1.8), and `tests/vpc_contract.tftest.hcl` runs the downloaded, pinned vpc module as the run's root module (`./.terraform/modules/vpc`) with the exact layout the blueprint builds, where its check is a root object that `expect_failures` can name. The module itself still supports Terraform 1.7: CI validates the root on 1.7.5 separately.

For the same reason the end-to-end run is a plain `terraform apply` of `tests/integration/e2e` driven by `scripts/integration-e2e.sh`, not a `terraform test` suite. A leaf-side option to acknowledge the internet path (for example an `internet_path_acknowledged` input on `aws.modules.vpc`) would let a future version move both back into `terraform test`.

## Compatibility

Terraform `>= 1.7.0, < 2.0.0` for consumers; `>= 1.8` to run the contract tests. AWS provider `>= 6.35.0, < 7.0.0`, the same floor as every leaf. Upgrading a pinned leaf is a blueprint release, reviewed for changes in what gets created.
