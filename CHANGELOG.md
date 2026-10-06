# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Consumers pin the commit SHA of a release tag; see [Versioning and releases](README.md#versioning-and-releases).

## [Unreleased]

### Added

- Initial blueprint: one private HTTP microservice composed from `aws.modules.vpc` v1.1.0 (public ALB tier, private task tier with no internet route, ECR/logs/S3 endpoints plus secret-store and application endpoints, optional NAT gateway, flow logs under a created key), `aws.modules.alb` v1.0.1 (internet-facing ALB, HTTPS with HTTP redirect or HTTP-only, one `ip` target group), and `aws.modules.ecs-service` v1.0.1 (Fargate service on an existing cluster, digest-pinned single container with a read-only root filesystem and writable paths, task and execution roles from its own `modules/iam`, optional CPU autoscaling), each pinned by commit SHA.
- Inputs `name`, `cluster_arn`, `network`, `container`, `task_role_statements`, `service`, `health_check`, `load_balancer`, `logs`, `tags`, all typed with plan-time validation.
- Glue that gates the service's target group ARN on the ALB's forwarding listener, so ECS never sees a target group without a load balancer, and `scripts/check-listener-ordering.sh` to keep that edge in the dependency graph.
- Plan-time guards that the cluster's account and region match the provider's, and an advisory `http_only_listener` check.
- Contract tests (`mock_provider`, Terraform >= 1.8), a VPC contract suite against the pinned `aws.modules.vpc`, examples `minimal` and `complete`, an end-to-end run (`scripts/integration-e2e.sh`, dispatch-only `integration` workflow), and the fleet's quality pipeline plus a Terraform 1.7.5 validation floor.
