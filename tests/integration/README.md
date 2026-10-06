# End-to-end run

`scripts/integration-e2e.sh` (`make integration-e2e`, or the dispatch-only `integration` workflow) proves the composition against the real AWS API in **your** account:

1. `tests/integration/setup` creates a disposable ECS cluster `bp-e2e-<hex>` (the blueprint never creates one) and picks two available zones.
2. `tests/integration/e2e` applies the blueprint against that cluster with stock nginx from ECR Public, pinned by digest, on port 80 with `/var/cache/nginx`, `/run`, and `/tmp` writable. It runs without a certificate (plain HTTP), with ALB deletion protection off, and with `network.nat_gateway = true`, because ECR Public is not served by the private ECR endpoints. `service.wait_for_steady_state` makes the apply wait until the task passes the ALB health check.
3. The script requires `200` from the ALB URL within five minutes.
4. Both roots are destroyed, also when any step fails.

It is a plain `terraform apply` rather than a `terraform test` suite because `aws.modules.vpc`'s `internet_path_declared` check always warns for this blueprint and `terraform test` fails a run on any nested module's check warning (see [CONTRIBUTING.md](../../CONTRIBUTING.md#why-the-tests-need-terraform-18)).

| What | Cost | Typical time |
| --- | --- | --- |
| An ALB, a NAT gateway and Elastic IP, three interface endpoints in two zones, one Fargate task, flow logs | Well under a dollar for the run. The flow-log KMS key lingers pending deletion for 30 days, unusable and free of charge. | 15 to 25 minutes, most of it ALB and NAT creation and teardown |

## Run it

```bash
export AWS_PROFILE=<your profile>   # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
export AWS_REGION=<region>
make integration-e2e
```

The credentials need to create and delete VPC networking (VPC, subnets, route tables, internet and NAT gateways, Elastic IPs, endpoints, security groups, flow logs), a KMS key and CloudWatch log groups, an ALB with its listeners and target group, IAM roles and inline policies (`iam:PassRole` on them to ECS), an ECS cluster, task definition, and service. State is local to the two directories and git-ignored.

In CI, the `integration` workflow assumes `vars.AWS_INTEGRATION_ROLE_ARN` through GitHub OIDC in `vars.AWS_INTEGRATION_REGION`, both set on the protected `integration` environment, exactly as the leaf modules' integration workflows do.

If a run is interrupted before cleanup, destroy by hand: `terraform -chdir=tests/integration/e2e destroy` (with the same three `-var` values the script printed) and then `terraform -chdir=tests/integration/setup destroy`. Every resource carries `Disposable = true` and `IntegrationTest = aws.modules.blueprint-microservice-private`.
