# aws.modules.blueprint-microservice-private

The golden path for one private HTTP microservice on AWS Fargate: a VPC whose tasks have no internet route, an internet-facing Application Load Balancer, a Fargate service registered with it, and task and execution roles scoped to exactly what you declare, wired together end to end. It is the platform's first composed archetype: it creates no resource of its own, only calls three leaf modules (`aws.modules.vpc`, `aws.modules.alb`, `aws.modules.ecs-service`) in the right order with the right glue, onto an ECS cluster your platform already runs. Requires Terraform >= 1.7 and the AWS provider >= 6.35, < 7.

You should not need to read the leaf modules' documentation to deploy a service with this one. This README describes everything that gets created, why, how the pieces connect, and how the whole thing fails.

## Quick start

```hcl
module "orders" {
  source = "git::https://github.com/hatan4ik/aws.modules.blueprint-microservice-private.git?ref=<commit-sha>" # vX.Y.Z

  name        = "orders"
  cluster_arn = "arn:aws:ecs:us-east-2:123456789012:cluster/platform" # the environment's shared cluster

  network = {
    cidr_block         = "10.40.0.0/16"
    availability_zones = ["us-east-2a", "us-east-2b"]
  }

  container = {
    image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:<64 hex>"
    port  = 8080
  }

  load_balancer = {
    certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/<uuid>"
  }
}
```

After `terraform apply` returns, two tasks are running in private subnets and passing the load balancer's health check, and `module.orders.url` answers. If the tasks never become healthy, the apply fails instead of reporting success (see [Failure modes](#failure-modes-of-the-composition)).

What you must bring:

| You provide | Why the blueprint does not create it |
| --- | --- |
| `cluster_arn`: an existing ECS cluster in the provider's account and region, normally the `cluster_arn` output of the environment's `aws.modules.ecs` call. | One cluster per environment serves many services; see [Why the cluster is an input](#why-the-cluster-is-an-input). |
| `container.image`: an image pinned to a digest, in ECR in the same region (or anywhere, with `network.nat_gateway = true`). | Images are built by the service's CI, not by infrastructure. |
| `load_balancer.certificate_arn`: an ACM certificate in the same region (for example from `aws.modules.acm`). Without one the ALB serves plain HTTP and a check warns. | Certificates belong to a DNS zone and its owner. |
| Secrets, KMS keys, tables, queues, and other data the application uses, referenced by ARN. | They outlive any one deployment of the service. |

A container that works with this blueprint listens on `container.port` on all interfaces (not only `127.0.0.1`), answers `GET <health_check.path>` with a status in `health_check.matcher` without authentication within 5 seconds, and writes to disk only under `container.writable_paths`.

## What gets created, and why

In dependency order. Names assume `name = "orders"`, `cluster_arn` naming a cluster called `platform`, and two Availability Zones.

### 1. The network (`aws.modules.vpc` v1.1.0)

| Resource | Shape | Why |
| --- | --- | --- |
| VPC `orders` | `network.cidr_block`, DNS support and hostnames on, VPC Encryption Control in `monitor` mode, the default security group emptied and managed as `orders-default-deny-all`. | One network boundary per service. `monitor`, not the module's default `enforce`, because enforce mode rejects the internet gateway an internet-facing ALB needs. |
| Public subnets `orders-public-az1`, `-az2` | `cidr_block` + 8 bits (a `/24` of a `/16`), one per zone, routed to an internet gateway. No public IP on launch. | Only the ALB's network interfaces live here. |
| Private subnets `orders-private-az1`, `-az2` | `cidr_block` + 4 bits (a `/20` of a `/16`), one per zone, one route table each, **no default route**. | The tasks live here, unreachable from the internet and unable to reach it. |
| Interface endpoints `ecr.api`, `ecr.dkr`, `logs` in the private subnets, with one security group admitting HTTPS from the VPC | Private DNS on. | What a Fargate task needs to start with no internet path: image manifest and registry auth, and the `awslogs` driver. |
| Gateway endpoint `s3` on the private route tables | | ECR stores image layers in S3. |
| Interface endpoints `secretsmanager` and/or `ssm` | Added automatically when `container.secrets` references them. | ECS fetches secrets from inside the task's network at start. |
| Any endpoints in `network.interface_endpoint_services` / `gateway_endpoint_services` | For example `sqs`, `kms`, `dynamodb`. | What the application itself calls. Without a NAT gateway there is no other way to reach an AWS API. |
| A NAT gateway in `public/az1` and a private default route through it | Only when `network.nat_gateway = true`. | For images outside ECR and calls to third-party APIs. |
| VPC flow logs | All traffic, 60-second aggregation, a log group `/aws/vpc/orders/flow-logs` kept 365 days, encrypted with a new rotated KMS key `alias/orders-flow-logs`. | Network evidence for every service, on by default. |

### 2. The edge (`aws.modules.alb` v1.0.1)

| Resource | Shape | Why |
| --- | --- | --- |
| ALB `orders` | Internet-facing, in the public subnets, deletion protection on, invalid header fields dropped, idle timeout 60 s. | The only way in. |
| Security group `orders-alb` | Ingress on the active listener ports from `load_balancer.ingress_cidrs` (default `0.0.0.0/0`); egress to the VPC CIDR only. | Created by `aws.modules.alb` through `aws.modules.security-group`; the blueprint does not hand-roll it. |
| HTTPS listener on 443 (TLS 1.3/1.2 policy) forwarding to the target group, and an HTTP listener on 80 that only redirects to HTTPS | When `load_balancer.certificate_arn` is set. Without it, a single HTTP listener on 80 forwards instead. | |
| Target group `orders-app` | `ip` targets (Fargate `awsvpc`), HTTP on `container.port`, health check on `health_check.path` every 15 s with a 5 s timeout, 2 passes to healthy, 3 failures to unhealthy, matcher `health_check.matcher`, 30 s deregistration delay. | The contract between the ALB and the service: its ARN is the one value that must cross from one module to the other intact. |
| WAFv2 association, access logs | Only when `load_balancer.web_acl_arn` / `access_logs_bucket` are set. | |

### 3. The service (`aws.modules.ecs-service` v1.0.1)

| Resource | Shape | Why |
| --- | --- | --- |
| Task definition `orders` | Fargate, `container.cpu`/`memory` (validated as a supported pair), one essential container `app` with a read-only root filesystem, a port mapping `http` on `container.port`, `environment`, `secrets`, and one ephemeral volume per `container.writable_paths` entry. The image must be digest-pinned. | Reproducible, rollback-exact deployments. |
| ECS service `orders` on the given cluster | `desired_count` tasks (default 2) in the private subnets, no public IP, registered with the target group, a 60 s health-check grace period, rolling deployment with the circuit breaker and automatic rollback, and `wait_for_steady_state` on. | |
| Security group `orders` (the tasks') | Ingress: `container.port` from the ALB's security group only. Egress: HTTPS to the interface endpoints' security group, HTTPS to each gateway endpoint's prefix list, and HTTPS to `0.0.0.0/0` only with a NAT gateway. | Nothing but the ALB can reach a task, and a task can reach only the AWS APIs you declared. DNS needs no rule: security groups do not filter the VPC resolver. |
| Execution role `orders-execution` | `AmazonECSTaskExecutionRolePolicy`, plus a derived inline policy granting `secretsmanager:GetSecretValue` / `ssm:GetParameters` on exactly the declared secret ARNs and `kms:Decrypt` on exactly `container.secrets_kms_key_arns`. | ECS uses it to pull the image, write logs, and inject secrets. |
| Task role `orders-task` | Exactly `task_role_statements`; nothing when empty. | The identity the application's AWS SDK calls run as. |
| Both roles' trust policy | `ecs-tasks.amazonaws.com`, conditioned on `aws:SourceAccount` = the cluster's account and `aws:SourceArn` like `arn:aws:ecs:<cluster region>:<account>:*`. | Confused-deputy protection. The blueprint fails the plan if the cluster's account or region differs from the provider's, so the trust can never name the wrong account. |
| Log group `/aws/ecs/platform/orders` | `logs.retention_in_days` (default 365), optional customer-managed key. | |
| Application Auto Scaling target and a CPU target-tracking policy | Only when `service.autoscaling` is set. | |

Nothing else. No cluster, no DNS record, no certificate, no data store.

## How the pieces connect

```text
                    internet
                       │ 443 (80 redirects)          load_balancer.ingress_cidrs
            ┌──────────▼───────────┐
            │ ALB orders           │  public subnets, SG orders-alb
            │ listener ──► TG app  │  (egress: VPC CIDR only)
            └──────────┬───────────┘
                       │ container.port, health check on health_check.path
            ┌──────────▼───────────┐
            │ Fargate tasks        │  private subnets, SG orders
            │ (service orders on   │  ingress: container.port from SG orders-alb only
            │  cluster_arn)        │
            └──┬────────────┬──────┘
   HTTPS to    │            │ HTTPS to prefix list
   endpoint SG ▼            ▼
   ecr.api ecr.dkr logs   s3 (+ dynamodb)       (+ 0.0.0.0/0:443 via NAT, if enabled)
   (+ secretsmanager, ssm, your services)
```

The values that cross module boundaries, each asserted by a test in `tests/wiring.tftest.hcl`:

| From | To | Glue |
| --- | --- | --- |
| `module.vpc.subnet_ids_by_tier.public` | `module.alb.public_subnet_ids` | values of the map |
| `module.vpc.subnet_ids_by_tier.private` | `module.service.subnet_ids` | values of the map |
| `module.alb.target_group_arns.app` | `module.service.load_balancers.app.target_group_arn` | gated on the forwarding listener's ARN (below) |
| `container.port` | the target group port, the container's port mapping, `load_balancers.app.container_port`, and the task ingress rule | one input, four places |
| `module.alb.security_group_id` | the task security group's only ingress source | |
| `module.vpc.endpoint_security_group_id` and `gateway_endpoint_prefix_list_ids` | the task security group's egress destinations | |
| `container.secrets` | the secret-store endpoints, the container's secrets, and the execution role's derived policy | |
| `cluster_arn` | the service's cluster, the roles' trust conditions, the log group name | guarded against the provider's account and region |

**Ordering.** ECS rejects `CreateService` while the target group is not yet attached to a load balancer, and `aws.modules.alb`'s `target_group_arns` output depends only on the target group, not on its listener. Passed straight through, Terraform would create the service in parallel with the listener and the first apply would fail intermittently. The blueprint routes the ARN through the forwarding listener's ARN, so the service waits for the listener and nothing else waits for the ALB. `scripts/check-listener-ordering.sh` (CI job `listener-ordering`, `make ordering`) fails if that edge ever disappears from `terraform graph`.

## Failure modes of the composition

Each leaf module documents its own failure modes. These are the ones that only appear when the pieces are put together.

**The health check never passes.** A new task registers with the target group; the ALB probes `health_check.path` on `container.port` every 15 s and marks the task unhealthy after 3 failures. ECS ignores those failures for `health_check.grace_period_seconds` (60 s) after the task starts, then stops the unhealthy task and starts another. After 3 failed tasks (half of `desired_count`, never fewer than 3) the deployment circuit breaker marks the deployment failed and rolls back to the last healthy deployment; on the very first deployment there is nothing to roll back to, and the service stays at zero healthy tasks. Because `service.wait_for_steady_state` is `true`, `terraform apply` does not report success in either case: it fails when the deployment fails or the wait times out. The usual causes, in order:

1. The application does not answer `health_check.path` (default `/`) with a status in `health_check.matcher` (default `200-399`), or requires authentication or a specific `Host` header on it.
2. It listens on a different port than `container.port`, or only on `127.0.0.1`.
3. It takes longer than `grace_period_seconds` to start answering.
4. It crashes at start because the root filesystem is read-only: add the paths it writes to (`/tmp`, a cache directory) to `container.writable_paths`.
5. The image's architecture does not match `container.cpu_architecture` (the task exits immediately with `exec format error`).
6. The task never starts: see the next two items. ECS reports these as stopped-task reasons, not as health-check failures.

**The image cannot be pulled.** The private subnets reach only ECR in the same region. An image on Docker Hub, ECR Public, GHCR, or ECR in another region fails with `CannotPullContainerError` unless `network.nat_gateway = true`. A cross-account ECR image also needs a repository policy that admits the execution role.

**Secrets cannot be read.** A secret encrypted with a customer-managed key fails at task start with an access-denied error unless that key is in `container.secrets_kms_key_arns` and its key policy admits the account. The blueprint adds the Secrets Manager or SSM endpoint automatically; a secret in another region is not reachable through it.

**The application's own AWS calls hang.** Without a NAT gateway, a call to any AWS service that has no endpoint in `network.interface_endpoint_services` / `gateway_endpoint_services` does not fail fast: the connection times out after the SDK's connect timeout. Declare every AWS service the application calls (the task security group is opened to the endpoints automatically). Third-party APIs need `nat_gateway = true`.

**The log group cannot be created with a customer-managed key.** `logs.kms_key_arn` must name a key whose policy admits CloudWatch Logs for `/aws/ecs/<cluster>/<name>`. With `aws.modules.ecs`'s shared key, add that log group's ARN to the platform's `additional_cloudwatch_log_group_arns` first.

**Changing `container.port` after the first apply fails.** The port is part of the target group's identity, so a change replaces `orders-app`. `aws.modules.alb` creates the replacement before destroying the original, under the same name, and AWS rejects the duplicate name. Change the port by deploying a new service (a new `name`), or temporarily remove the service, apply, and add it back.

**Changing `service.desired_count` after the first apply has no effect.** `aws.modules.ecs-service` ignores drift on the desired count, because autoscaling and deployments change it. Scale with `service.autoscaling` or through ECS.

**Destroying takes two applies.** The ALB has deletion protection on by default. Set `load_balancer.deletion_protection = false`, apply, then destroy. Expect the destroy to pause on the task security group and the private subnets for a few minutes while Fargate releases the tasks' network interfaces.

**One NAT gateway is one zone.** With `nat_gateway = true` all internet egress leaves through `az1`. Tasks in other zones still start during an `az1` outage (image pulls, logs, and secrets use the endpoints), but their internet calls fail.

**Region and account mismatches fail at plan.** The cluster's region names the endpoint services and the roles' trust; a cluster in another region or account would produce a service that cannot start. `data.aws_region.current` and `data.aws_caller_identity.current` carry postconditions that stop the plan instead.

**Warnings on every plan are expected.** `aws.modules.vpc`'s `internet_path_declared` always warns here (the ALB needs the internet gateway); `aws.modules.alb`'s `public_without_waf` warns until `load_balancer.web_acl_arn` is set; the blueprint's `http_only_listener` warns until `load_balancer.certificate_arn` is set. None of them blocks.

**Cost floor.** Before traffic, in us-east-2 prices: the ALB (about $16/month plus capacity units), three interface endpoints in two zones (about $44/month; each extra endpoint about $15/month in two zones), two 0.25 vCPU / 0.5 GB tasks (about $18/month), one KMS key ($1/month), and, with `nat_gateway`, one NAT gateway (about $33/month plus data processing). A third zone adds an endpoint ENI per interface endpoint.

## Why the cluster is an input

`aws.modules.ecs` describes itself as the platform foundation "for one private, single-account environment": one cluster, one shared KMS key, one application log group, shared registry and session store, many services. `aws.modules.ecs-service`, in turn, takes `cluster_arn` and never creates a cluster. A blueprint that created a cluster per microservice would duplicate the platform layer for every service, multiply Container Insights and ECS Exec configuration, and break the network/platform/workload ownership split the live roots use. So the cluster is the one placement fact the blueprint is given, and it is checked against the provider at plan time. Get it from the platform root's state:

```hcl
data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = { bucket = "<state bucket>", key = "<platform state key>", region = "us-east-2" }
}

module "orders" {
  source      = "git::https://github.com/hatan4ik/aws.modules.blueprint-microservice-private.git?ref=<commit-sha>"
  cluster_arn = data.terraform_remote_state.platform.outputs.cluster_arn # aws.modules.ecs output
  # ...
}
```

A Fargate cluster is not tied to a VPC, so the shared cluster runs this service's tasks in this blueprint's private subnets. The rest of the composition reasoning (which leaf supplies the task role, why the security groups are not wired by hand, which leaf inputs are deliberately hidden) is in [docs/DESIGN.md](docs/DESIGN.md).

## Examples

| Example | What it shows |
| --- | --- |
| [`examples/minimal`](examples/minimal) | Name, cluster, network, image, and certificate. Everything else on its default. |
| [`examples/complete`](examples/complete) | An orders API with a Secrets Manager secret under a customer-managed key, an SQS interface endpoint and a DynamoDB gateway endpoint, task-role statements for exactly that table and queue, a writable `/tmp`, CPU autoscaling, a `/healthz` health check, WAF, access logs, and the platform's KMS key on the log group. |

## Testing

- **Contract tests** (`tests/*.tftest.hcl`, `make test`, CI): 63 `mock_provider` runs, no credentials. They assert the glue, not the leaves: the subnet layout and endpoint set the blueprint builds, the target group ARN reaching the service's load balancer configuration, the ALB's security group as the tasks' only ingress source, the endpoint security group and prefix lists as their egress, the execution role's derived policy for declared secrets and keys, the account and region guards, every input validation, and (`tests/vpc_contract.tftest.hcl`) the pinned `aws.modules.vpc` accepting exactly the layout the blueprint passes it. They need Terraform >= 1.8; see [CONTRIBUTING.md](CONTRIBUTING.md#why-the-tests-need-terraform-18).
- **Ordering check** (`make ordering`, CI): the service-after-listener edge in the real dependency graph.
- **End-to-end** (`make integration-e2e`, dispatch-only `integration` workflow): applies the blueprint for real against a disposable cluster, waits for steady state, and requires `200` from the ALB URL, then destroys everything. See [tests/integration/README.md](tests/integration/README.md).

## Versioning and releases

Releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and are recorded in [CHANGELOG.md](CHANGELOG.md). Pin the commit SHA of a release tag, never a branch or a movable tag. A leaf-module upgrade that changes what this blueprint creates is a blueprint release of its own, with the same scrutiny.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## License

Apache 2.0. See [LICENSE](LICENSE).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.35.0, < 7.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.35.0, < 7.0.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_alb"></a> [alb](#module\_alb) | git::https://github.com/hatan4ik/aws.modules.alb.git | 2c3441caf2e19fc469cf678f3ac4cac0c632678e |
| <a name="module_service"></a> [service](#module\_service) | git::https://github.com/hatan4ik/aws.modules.ecs-service.git | 79e268f3f60bd236418054e0b42d464640b88a89 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | git::https://github.com/hatan4ik/aws.modules.vpc.git | 969e78e0653ec54a6985fd93f9ca23345bd0b84a |

## Resources

| Name | Type |
|------|------|
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_arn"></a> [cluster\_arn](#input\_cluster\_arn) | ARN of the existing, shared ECS cluster the service runs on, normally the cluster\_arn output of the environment's aws.modules.ecs call. The blueprint never creates a cluster. It must be in the same account and region as the AWS provider (enforced at plan time). | `string` | n/a | yes |
| <a name="input_container"></a> [container](#input\_container) | The task's single application container and its Fargate size.<br/>image must be pinned to a digest (repository@sha256:<64 hex>); the ECS service module rejects anything else at plan time.<br/>port is the container port the ALB forwards to and health-checks. cpu and memory are task-level Fargate units and MiB (validated as a supported pair at plan time).<br/>environment is plain text; secrets maps variable names to Secrets Manager or SSM parameter ARNs, and the execution role is granted exactly those ARNs. secrets\_kms\_key\_arns lists customer-managed keys protecting them.<br/>The root filesystem is read-only; writable\_paths lists absolute paths (for example /tmp) that get a writable ephemeral volume. | <pre>object({<br/>    image                = string<br/>    port                 = optional(number, 8080)<br/>    cpu                  = optional(number, 256)<br/>    memory               = optional(number, 512)<br/>    cpu_architecture     = optional(string, "X86_64")<br/>    command              = optional(list(string))<br/>    environment          = optional(map(string), {})<br/>    secrets              = optional(map(string), {})<br/>    secrets_kms_key_arns = optional(set(string), [])<br/>    writable_paths       = optional(set(string), [])<br/>  })</pre> | n/a | yes |
| <a name="input_health_check"></a> [health\_check](#input\_health\_check) | The ALB target-group health check, the single most common reason a new service never becomes healthy.<br/>path must return a status in matcher from inside the container on container.port, without authentication, within 5 seconds. Checks run every 15 seconds; 2 consecutive passes mark a task healthy and 3 failures unhealthy.<br/>grace\_period\_seconds is how long ECS ignores failing checks after a task starts, so a slow-booting application is not killed before it can answer. | <pre>object({<br/>    path                 = optional(string, "/")<br/>    matcher              = optional(string, "200-399")<br/>    grace_period_seconds = optional(number, 60)<br/>  })</pre> | `{}` | no |
| <a name="input_load_balancer"></a> [load\_balancer](#input\_load\_balancer) | The internet-facing ALB in front of the service.<br/>certificate\_arn (an ACM certificate in the provider's region) serves HTTPS on 443 and redirects port 80 to it. Leaving it null serves plain HTTP on port 80 only, which a check block flags on every plan; use it only for a disposable environment.<br/>ingress\_cidrs limits who can reach the listeners. web\_acl\_arn associates a REGIONAL WAFv2 web ACL. access\_logs\_bucket names an existing S3 bucket whose policy already admits ELB log delivery.<br/>deletion\_protection = true (default) blocks deleting the ALB, including on terraform destroy, until it is set to false and applied. | <pre>object({<br/>    certificate_arn     = optional(string)<br/>    ingress_cidrs       = optional(set(string), ["0.0.0.0/0"])<br/>    web_acl_arn         = optional(string)<br/>    access_logs_bucket  = optional(string)<br/>    deletion_protection = optional(bool, true)<br/>  })</pre> | `{}` | no |
| <a name="input_logs"></a> [logs](#input\_logs) | The service's CloudWatch log group, /aws/ecs/<cluster>/<name>. kms\_key\_arn encrypts it with a customer-managed key (for example the cluster platform's application\_data\_kms\_key\_arn); that key's policy must already admit CloudWatch Logs for this log group's ARN, or the log group cannot be created. | <pre>object({<br/>    retention_in_days = optional(number, 365)<br/>    kms_key_arn       = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Service name: the ECS service, task family, VPC, ALB, and every derived resource name. 3-28 lowercase alphanumerics or hyphens, starting with a letter, so the longest derived name (the ALB target group <name>-app, 32 characters) fits its AWS limit. | `string` | n/a | yes |
| <a name="input_network"></a> [network](#input\_network) | The service's VPC. cidr\_block is a /16 to /19; each Availability Zone gets a public subnet (cidr\_block + 8 bits, for the ALB) and a private subnet (cidr\_block + 4 bits, for the tasks). availability\_zones lists 2 or 3 zone names.<br/>The private subnets have no internet route. Tasks reach AWS through VPC endpoints the blueprint always creates (ecr.api, ecr.dkr, logs, and the s3 gateway for image layers; secretsmanager and ssm are added automatically when container.secrets references them).<br/>interface\_endpoint\_services and gateway\_endpoint\_services add endpoints for AWS services the application itself calls (for example ["sqs"] and ["dynamodb"]); the task security group is opened to exactly those endpoints.<br/>nat\_gateway = true adds one NAT gateway (in the first zone) and an HTTPS-only egress rule to 0.0.0.0/0, for images outside ECR or calls to third-party APIs. | <pre>object({<br/>    cidr_block                  = string<br/>    availability_zones          = list(string)<br/>    nat_gateway                 = optional(bool, false)<br/>    interface_endpoint_services = optional(set(string), [])<br/>    gateway_endpoint_services   = optional(set(string), [])<br/>  })</pre> | n/a | yes |
| <a name="input_service"></a> [service](#input\_service) | How many tasks run and how deployments behave.<br/>desired\_count applies at creation only: the ECS service module ignores later drift because autoscaling and deployments change it, so changing it afterwards has no effect.<br/>autoscaling (null disables it) tracks average CPU at cpu\_target\_percent between min\_capacity and max\_capacity; desired\_count must lie inside that range.<br/>wait\_for\_steady\_state = true (default) makes terraform apply wait until the new tasks pass ALB health checks, so a deployment that never becomes healthy fails the apply instead of reporting success. | <pre>object({<br/>    desired_count         = optional(number, 2)<br/>    wait_for_steady_state = optional(bool, true)<br/>    autoscaling = optional(object({<br/>      min_capacity       = number<br/>      max_capacity       = number<br/>      cpu_target_percent = optional(number, 60)<br/>    }))<br/>  })</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the composed modules create. The leaf modules add Name (and Tier on subnets) and never override caller tags. | `map(string)` | `{}` | no |
| <a name="input_task_role_statements"></a> [task\_role\_statements](#input\_task\_role\_statements) | IAM statements for the application's task role, keyed by alphanumeric Sid: the AWS data the application itself reads or writes. Empty by default, so the task role grants nothing. The same shape aws.modules.ecs-service uses; the trust policy is fixed to ECS tasks in the cluster's account and region. | <pre>map(object({<br/>    effect    = optional(string, "Allow")<br/>    actions   = set(string)<br/>    resources = set(string)<br/>    conditions = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = set(string)<br/>    })), [])<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alb_arn"></a> [alb\_arn](#output\_alb\_arn) | ARN of the ALB. |
| <a name="output_alb_arn_suffix"></a> [alb\_arn\_suffix](#output\_alb\_arn\_suffix) | ARN suffix of the ALB, for CloudWatch metrics and alarms. |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | DNS name of the ALB. |
| <a name="output_alb_security_group_id"></a> [alb\_security\_group\_id](#output\_alb\_security\_group\_id) | ID of the ALB's security group. |
| <a name="output_alb_zone_id"></a> [alb\_zone\_id](#output\_alb\_zone\_id) | Route 53 hosted zone ID of the ALB, for an alias record (for example through aws.modules.route53). |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the cluster the service runs on, derived from cluster\_arn. |
| <a name="output_interface_endpoint_services"></a> [interface\_endpoint\_services](#output\_interface\_endpoint\_services) | AWS service suffixes that have an interface VPC endpoint in the private subnets. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | CloudWatch log group the container writes to. |
| <a name="output_nat_gateway_public_ips"></a> [nat\_gateway\_public\_ips](#output\_nat\_gateway\_public\_ips) | Public IP of the NAT gateway keyed by gateway key, the source address of the tasks' internet traffic for third-party allowlists; empty when network.nat\_gateway is false. |
| <a name="output_private_subnet_cidr_blocks"></a> [private\_subnet\_cidr\_blocks](#output\_private\_subnet\_cidr\_blocks) | Private subnet CIDR blocks keyed by AZ key, known at plan time. |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | Private subnet IDs keyed by AZ key: where the tasks run. |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | Public subnet IDs keyed by AZ key (az1, az2, az3): where the ALB's network interfaces live. |
| <a name="output_service_arn"></a> [service\_arn](#output\_service\_arn) | ARN of the ECS service. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Name of the ECS service. |
| <a name="output_target_group_arn"></a> [target\_group\_arn](#output\_target\_group\_arn) | ARN of the target group the service registers its tasks with. |
| <a name="output_task_definition_arn"></a> [task\_definition\_arn](#output\_task\_definition\_arn) | ARN of the registered task definition revision. |
| <a name="output_task_execution_role_arn"></a> [task\_execution\_role\_arn](#output\_task\_execution\_role\_arn) | ARN of the task execution role ECS uses to pull the image, write logs, and read the declared secrets. |
| <a name="output_task_execution_role_derived_policy"></a> [task\_execution\_role\_derived\_policy](#output\_task\_execution\_role\_derived\_policy) | The execution role's derived inline policy (JSON): exactly the declared secrets, parameters, and KMS keys, or null when none are declared. |
| <a name="output_task_role_arn"></a> [task\_role\_arn](#output\_task\_role\_arn) | ARN of the task role: the identity the application's AWS SDK calls run as. |
| <a name="output_task_role_name"></a> [task\_role\_name](#output\_task\_role\_name) | Name of the task role, for attaching further policies outside the blueprint. |
| <a name="output_task_security_group_id"></a> [task\_security\_group\_id](#output\_task\_security\_group\_id) | ID of the tasks' security group. Reference it from a data store's security group to let the service in. |
| <a name="output_url"></a> [url](#output\_url) | Base URL of the service: https://<ALB DNS name> with a certificate, http:// without. Point a DNS alias at alb\_dns\_name/alb\_zone\_id to serve it under the certificate's name. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the service's VPC. |
<!-- END_TF_DOCS -->
