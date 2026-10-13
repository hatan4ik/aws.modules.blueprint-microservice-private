# End-to-end runs

`scripts/integration-e2e.sh` (`make integration-e2e`, `make integration-e2e-private-ecr`, or the dispatch-only `integration` workflow) proves the composition against the real AWS API in **your** account. It has two variants, each run on its own; both create everything they need and destroy it again, also when a step fails.

| Variant | Command | Image | Egress from the private subnets |
| --- | --- | --- | --- |
| `public` (default) | `make integration-e2e` | stock nginx from ECR Public | NAT gateway |
| `private-ecr` | `make integration-e2e-private-ecr` | the same nginx, imported into a private ECR repository in the account | none: VPC endpoints only |

## The `public` variant

1. `tests/integration/setup` creates a disposable ECS cluster `bp-e2e-<hex>` (the blueprint never creates one) and picks two available zones.
2. `tests/integration/e2e` applies the blueprint against that cluster with stock nginx from ECR Public, pinned by digest, on port 80 with `/var/cache/nginx`, `/run`, and `/tmp` writable. It runs without a certificate (plain HTTP, opted into with `load_balancer.allow_plain_http = true`), with ALB deletion protection off, and with `network.nat_gateway = true`, because ECR Public is not served by the private ECR endpoints. `service.wait_for_steady_state` makes the apply wait until the task passes the ALB health check.
3. The script fails if any stopped task of the service reports `CannotPullContainerError` or `ResourceInitializationError`, then requires `200` from the ALB URL within five minutes.
4. Everything is destroyed in reverse order.

**Proves:** AWS accepts the composed VPC, ALB, IAM roles, security groups, task definition, and service; the service waits for the ALB listener; a task with a read-only root filesystem and the declared writable paths becomes healthy behind the ALB.

**Does not prove:** the private pull path. ECR Public serves layers through CloudFront over the NAT gateway, so the `ecr.api`, `ecr.dkr`, and `s3` endpoints and their policies are never used for the image.

## The `private-ecr` variant

1. `tests/integration/setup`, as above.
2. `tests/integration/private-ecr` gets a private copy of the image into the account without docker:
   - an ECR pull through cache rule maps the repository prefix `bp-e2e-<hex>/` to ECR Public (`public.ecr.aws`; ECR Public, unlike Docker Hub, needs no upstream credentials or Secrets Manager secret);
   - it creates the repository the cache fills, `bp-e2e-<hex>/docker/library/nginx`, itself, so Terraform owns it and deletes it (`force_delete`) at the end. A repository the cache created on its own would outlive the run;
   - [`import-image.sh`](private-ecr/import-image.sh), run by a `terraform_data` provisioner, pulls the image once through the cache the way `docker pull` would: an authenticated `GET /v2/<repository>/manifests/<digest>` against the private registry with `curl`. That makes ECR import the image from upstream. The script checks that the manifest ECR serves hashes to the pinned digest (a pull through cache stores the upstream manifest unchanged, so the digest is the same in both registries) and waits until `DescribeImages` lists the image and `BatchCheckLayerAvailability` reports every layer available.
   The image is pinned to the `linux/amd64` manifest of the nginx 1.27-alpine index the public variant uses, so only one platform is imported, and the digest is known before the import: the blueprint's digest requirement is met without a second step.
3. `tests/integration/e2e-private-ecr` applies the blueprint with `network.nat_gateway = false` and that private image (its `image` variable refuses anything that is not a digest-pinned private ECR URI). The task pulls it through the endpoints the blueprint creates, under the 2.0.0 endpoint policies:
   - `ecr.api` and `ecr.dkr` for the token and the manifest (policy: `aws:PrincipalAccount` is this account; the calls are signed by the execution role);
   - the `s3` gateway for the layers in `prod-<region>-starport-layer-bucket` (policy: unconditioned `s3:GetObject` on that bucket);
   - `logs` for the awslogs driver (policy: `aws:PrincipalAccount`).
4. The script requires that the NAT gateway output is empty and that no private route table has a `0.0.0.0/0` or `::/0` route, so the pull cannot have left the VPC; fails if any stopped task reports `CannotPullContainerError` or `ResourceInitializationError` (and prints every stopped task's reason, also when the apply itself fails, so a refused pull is diagnosed instead of only timing out); then requires `200` from the ALB URL.
5. Everything is destroyed in reverse order: blueprint, image fixture (rule and repository with its image), cluster.

**Proves:** a Fargate task in a subnet with no route out of the VPC pulls a private ECR image, fetches its layers, and ships its logs through exactly the endpoints and endpoint policies the blueprint creates, with the execution role ecs-service creates (only `AmazonECSTaskExecutionRolePolicy`, no extra statements).

**Does not prove:**

- A *first* pull through a pull through cache from inside the VPC. The fixture imports the image from where Terraform runs, under the caller's credentials. That is deliberate: a first pull needs `ecr:BatchImportUpstreamImage` (and `ecr:CreateRepository` when the repository does not exist), which the blueprint's execution role does not have and the blueprint does not let callers add, and AWS documents that a first pull through a pull through cache over PrivateLink may need an internet route. A service that relies on the cache filling on demand needs those permissions on its execution role and a pre-warmed or internet-reachable first pull; the blueprint does not support that today.
- A pull by tag after the cache's 24-hour window, when ECR checks upstream again on the caller's behalf. The task pulls by digest minutes after the import.
- Secrets: `secretsmanager` and `ssm` endpoints are not created, because the container declares no secrets.
- HTTPS on the ALB, WAF, access logs, autoscaling, or a customer-managed log key; both variants run plain HTTP without them.
- `ARM64` tasks; the image is `linux/amd64`.

## Why plain `terraform apply`

Both variants are plain applies rather than `terraform test` suites because `aws.modules.vpc`'s `internet_path_declared` check always warns for this blueprint and `terraform test` fails a run on any nested module's check warning (see [CONTRIBUTING.md](../../CONTRIBUTING.md#why-the-tests-need-terraform-18)). The credential-free [`tests/private_ecr_fixture.tftest.hcl`](../private_ecr_fixture.tftest.hcl) covers what can be checked without AWS: the cache rule, repository, and image URI the fixture produces; that the blueprint accepts that URI with no NAT gateway and leaves the task only the endpoint egress; and that the e2e-private-ecr root refuses a public image.

## Cost and time

| Variant | What runs | Cost | Typical time |
| --- | --- | --- | --- |
| `public` | An ALB, a NAT gateway and Elastic IP, three interface endpoints in two zones, one Fargate task, flow logs | Well under a dollar | 15 to 25 minutes, most of it ALB and NAT creation and teardown |
| `private-ecr` | An ALB, three interface endpoints in two zones, one Fargate task, flow logs, a pull through cache rule, and one ECR repository holding a 21 MB image for the length of the run | Well under a dollar, slightly less than `public` (no NAT gateway or Elastic IP) | 15 to 25 minutes, most of it ALB creation and teardown; the import itself takes under a minute |

In both, the flow-log KMS key lingers pending deletion for 30 days, unusable and free of charge.

## Run it

```bash
export AWS_PROFILE=<your profile>   # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
export AWS_REGION=<region>
make integration-e2e                # public variant
make integration-e2e-private-ecr    # private-ecr variant; also needs curl and python3 on PATH
```

The credentials need to create and delete VPC networking (VPC, subnets, route tables, internet and NAT gateways, Elastic IPs, endpoints, security groups, flow logs), a KMS key and CloudWatch log groups, an ALB with its listeners and target group, IAM roles and inline policies (`iam:PassRole` on them to ECS), an ECS cluster, task definition, and service. The script also calls `ecs:ListTasks`, `ecs:DescribeTasks`, and (private-ecr) `ec2:DescribeRouteTables`.

The `private-ecr` variant additionally needs the statements in [`iam/private-ecr-permissions-policy.json`](iam/private-ecr-permissions-policy.json) (replace `<ACCOUNT_ID>`):

| Sid | Actions | Resource | Why |
| --- | --- | --- | --- |
| `PullThroughCacheRules` | `ecr:CreatePullThroughCacheRule`, `ecr:DeletePullThroughCacheRule`, `ecr:DescribePullThroughCacheRules` | `*` (these actions have no resource type) | the rule's lifecycle |
| `RegistryLogin` | `ecr:GetAuthorizationToken` | `*` | the registry password `import-image.sh` uses |
| `CacheRepositoryLifecycle` | `ecr:CreateRepository`, `ecr:DeleteRepository`, `ecr:DescribeRepositories`, `ecr:ListTagsForResource`, `ecr:TagResource` | `repository/bp-e2e-*` | the cache repository, created before the first pull and force-deleted at the end |
| `ImportThroughTheCache` | `ecr:BatchGetImage`, `ecr:BatchImportUpstreamImage`, `ecr:DescribeImages`, `ecr:BatchCheckLayerAvailability` | `repository/bp-e2e-*` | the first pull, which imports the image from ECR Public, and the wait for it |
| `PullThroughCacheServiceLinkedRole` | `iam:CreateServiceLinkedRole` (condition `iam:AWSServiceName` = `pullthroughcache.ecr.amazonaws.com`) | `AWSServiceRoleForECRPullThroughCache` | ECR creates this role with the first pull through cache rule in the account; afterwards the statement is unused |
| `DiagnoseTasksAndRoutes` | `ecs:ListTasks`, `ecs:DescribeTasks`, `ec2:DescribeRouteTables` | `*` | the stopped-task and route-table assertions |

The task's execution role needs nothing beyond what the blueprint gives it: the image is already cached when the task starts.

State is local to each root directory and git-ignored.

In CI, the `integration` workflow assumes `vars.AWS_INTEGRATION_ROLE_ARN` through GitHub OIDC in `vars.AWS_INTEGRATION_REGION`, both set on the protected `integration` environment, exactly as the leaf modules' integration workflows do. Choose the variant when dispatching:

```bash
gh workflow run integration.yml -R hatan4ik/aws.modules.blueprint-microservice-private -f suite=e2e -f variant=public
gh workflow run integration.yml -R hatan4ik/aws.modules.blueprint-microservice-private -f suite=e2e -f variant=private-ecr
```

Runs are serialised (one `integration` concurrency group), so dispatching both queues the second.

## Cleaning up after an interrupted run

Every resource carries `Disposable = true` and `IntegrationTest = aws.modules.blueprint-microservice-private`. Destroy in this order, with the values the script printed:

1. `terraform -chdir=tests/integration/e2e destroy -var name=... -var cluster_arn=... -var availability_zones=...` (public), or `terraform -chdir=tests/integration/e2e-private-ecr destroy` with the same three and `-var image=...` (private-ecr);
2. private-ecr only: `terraform -chdir=tests/integration/private-ecr destroy -var name=...` (removes the pull through cache rule and the repository with its image);
3. `terraform -chdir=tests/integration/setup destroy`.

Alternatively, the janitor tool described below (`make integration-cleanup`) removes the compute and network-attachment resources without Terraform state. It does not delete the VPC, subnets, route tables, internet gateway or security groups; use the Terraform steps above for those.

## SRE / ConOps Debugging & Triage Tools

The repository provides three dedicated scripts in `scripts/` (wrapped as `make` targets) for real-time stack inspection, CI failure triage, and emergency orphan resource cleanup.

### 1. Live Stack Diagnostics (`make integration-diagnose`)

Inspects active AWS infrastructure created by the blueprint integration tests in real time without modifying resources:

```bash
make integration-diagnose
# or with options:
scripts/diagnose-integration-stack.sh --profile <profile> --region <region> --cluster <cluster-name>
```

**Checks performed:**
- **Identity & Scope**: Validates caller account and region.
- **ECS Services & Tasks**: Lists tasks, inspects container states, and extracts exact error reasons from stopped tasks (`CannotPullContainerError`, `ResourceInitializationError`, exit codes).
- **VPC & Interface Endpoints**: Confirms endpoints (`ecr.api`, `ecr.dkr`, `s3`, `logs`, `secretsmanager`, `ssm`) are `available` and associated with the VPC.
- **Route Table Verification**: Verifies zero default routes (`0.0.0.0/0`, `::/0`) in private subnets for true isolated egress.
- **Security Group Validation**: Checks rules and asserts description regex conformity with the EC2 API.
- **ALB Health & Connectivity**: Probes ALB DNS directly for HTTP 200 responses.
- **ECR Pull Through Cache**: Checks cache rules and repository image digest availability.

### 2. GitHub Actions Incident Triage (`make integration-triage`)

Triages GitHub Actions integration workflow runs, filtering out teardown noise and isolating the exact root cause:

```bash
make integration-triage
# or inspect a specific run:
scripts/triage-integration-run.sh --run-id <run-id>
# or watch an in-flight run:
scripts/triage-integration-run.sh --watch
```

**Features:**
- Highlights failed steps with clear status indicators.
- Extracts and summarizes the exact failing logs (e.g. AWS API error responses, Terraform errors, ECS container pull failures).
- Distinguishes primary apply failures from expected teardown errors during unwinding.

### 3. Emergency Cleanup Janitor (`make integration-cleanup`)

If a local or CI run is aborted mid-execution, orphaned AWS resources can be discovered and deleted in dependency order without Terraform state:

```bash
# Preview exactly what would be deleted (nothing is changed, no confirmation needed):
scripts/cleanup-integration-stack.sh --dry-run

# Interactive: lists what will be deleted, then asks you to type "delete":
make integration-cleanup
# or:
scripts/cleanup-integration-stack.sh --profile <profile> --region <region>

# Unattended (CI, no terminal): refuses to run (exit 2) unless you pass --yes:
scripts/cleanup-integration-stack.sh --yes
```

A resource is selected only when its name starts with `--prefix` (default `bp-e2e-`, which must match `^[a-z0-9][a-z0-9-]{2,}$`) **and** it carries `IntegrationTest = aws.modules.blueprint-microservice-private`. Two kinds of resource cannot be matched on the tag, so the prefix alone selects them and the plan lists them under `UNTAGGED`: ECR pull-through cache rules (AWS cannot tag them) and ECR repositories with no tags at all (the ones a pull through cache creates itself).

It deletes, waiting for each stage to finish before starting the next:
1. ECS services (scaled to zero, deleted, waited until inactive)
2. Application Load Balancers (waited until deleted)
3. Target groups
4. ECR repositories and pull through cache rules
5. VPC endpoints (polled until gone, 5 minute limit)
6. NAT gateways (waited until deleted) and their Elastic IPs
7. The ECS cluster, last

It does **not** delete the VPC, subnets, route tables, internet gateway or security groups, and does not touch CloudWatch log groups, task definitions, IAM roles or the flow-log KMS key. It lists the VPC-level resources it finds so you can see what remains; remove them with the Terraform steps in "Cleaning up after an interrupted run".

Failures are never swallowed: every failed call is printed and counted, the run continues, and it exits `1` with a summary if anything failed or a cluster survived. It only prints `Cleanup complete` when every selected resource was deleted. `AWS_PROFILE` is used when set; there is no default profile.

