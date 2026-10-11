# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Consumers pin the commit SHA of a release tag; see [Versioning and releases](README.md#versioning-and-releases).

## [Unreleased]

## [2.0.0] - 2026-10-11

Security hardening. This is a major release because configurations that 1.x
accepted now fail at plan, and a running service can lose access it had:
Semantic Versioning treats both as incompatible changes to the public
interface, and the README's versioning rule requires a major release for them.

### Upgrading from 1.x

Full notes: [docs/UPGRADE-2.0.0.md](docs/UPGRADE-2.0.0.md).

- If you relied on the HTTP default (no `load_balancer.certificate_arn`), set
  `load_balancer.allow_plain_http = true`. Without it the plan now fails.
- Remove or move any `container.writable_paths` entry the plan now rejects
  (see below).
- If the service reads S3 buckets owned by another account in the same region,
  that access is now denied by the S3 gateway endpoint's policy.
- Applying the upgrade updates the VPC endpoints' policies in place; no
  resource is replaced.

### Changed

- **Breaking:** plain HTTP is no longer the default. `load_balancer` gains
  `allow_plain_http` (default `false`), and a precondition on
  `data.aws_caller_identity.current` fails the plan when `certificate_arn` is
  null without it. The `http_only_listener` check now warns only when the
  opt-in is in effect.
- **Breaking:** `container.writable_paths` rejects un-normalised paths (`//`,
  `.` or `..` segments), paths under `/etc`, `/usr`, `/bin`, `/sbin`, `/lib`,
  `/lib32`, `/lib64`, `/libx32`, `/root`, `/proc`, `/sys`, `/dev`, or `/boot`,
  `/var` and `/var/lib` themselves, nested paths, and paths whose derived
  volume names collide. Application directories (`/tmp`, `/run`,
  `/var/cache/<app>`, `/var/log/<app>`, `/var/lib/<app>`, `/var/tmp`, `/home`,
  `/app`) remain accepted.
- **Breaking:** the VPC endpoints carry least-privilege policies instead of the
  default full-access policy. `ecr.api`, `ecr.dkr`, `logs`, `secretsmanager`,
  `ssm`, and a `dynamodb` gateway allow only principals of the provider's
  account (`aws:PrincipalAccount`). The `s3` gateway allows `s3:GetObject` on
  the region's ECR layer bucket (`prod-<region>-starport-layer-bucket`) and
  anything on buckets this account owns (`aws:ResourceAccount`).
  Caller-declared interface endpoints keep the default policy.

### Fixed

- Two `container.writable_paths` entries that derived the same volume name
  (for example `/var/cache-app` and `/var/cache/app`) failed with a
  duplicate-key error; they are now rejected by a validation that names the
  cause.

## [1.0.2] - 2026-10-06

### Fixed

- Run release-gate contract tests on Terraform 1.8.5, matching the root quality
  job and its `override_module` test semantics.

## [1.0.0] - 2026-10-06

### Added

- Initial blueprint: one private HTTP microservice composed from `aws.modules.vpc` v1.1.0 (public ALB tier, private task tier with no internet route, ECR/logs/S3 endpoints plus secret-store and application endpoints, optional NAT gateway, flow logs under a created key), `aws.modules.alb` v1.0.1 (internet-facing ALB, HTTPS with HTTP redirect or HTTP-only, one `ip` target group), and `aws.modules.ecs-service` v1.0.1 (Fargate service on an existing cluster, digest-pinned single container with a read-only root filesystem and writable paths, task and execution roles from its own `modules/iam`, optional CPU autoscaling), each pinned by commit SHA.
- Inputs `name`, `cluster_arn`, `network`, `container`, `task_role_statements`, `service`, `health_check`, `load_balancer`, `logs`, `tags`, all typed with plan-time validation.
- Glue that gates the service's target group ARN on the ALB's forwarding listener, so ECS never sees a target group without a load balancer, and `scripts/check-listener-ordering.sh` to keep that edge in the dependency graph.
- Plan-time guards that the cluster's account and region match the provider's, and an advisory `http_only_listener` check.
- Contract tests (`mock_provider`, Terraform >= 1.8), a VPC contract suite against the pinned `aws.modules.vpc`, examples `minimal` and `complete`, an end-to-end run (`scripts/integration-e2e.sh`, dispatch-only `integration` workflow), and the fleet's quality pipeline plus a Terraform 1.7.5 validation floor.
