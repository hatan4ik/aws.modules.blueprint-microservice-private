# Contributing

Thank you for improving `aws.modules.blueprint-microservice-private`. This repository is a composition root: it calls `aws.modules.vpc`, `aws.modules.alb`, and `aws.modules.ecs-service` and owns no AWS resource of its own. Most behaviour changes belong in a leaf module; a change here is either glue (how one leaf's output becomes another's input), an exposed input, or a pinned leaf version.

## Development setup

| Tool | Purpose | Install |
| --- | --- | --- |
| Terraform 1.7.5 and 1.8.x | 1.7.5 is the fleet's pinned version and the consumer floor; `terraform test` needs 1.8 or later (see below) | [releases](https://releases.hashicorp.com/terraform/) or `tfenv` |
| [tflint](https://github.com/terraform-linters/tflint) | Lint with `.tflint.hcl` | `brew install tflint && tflint --init` |
| [terraform-docs](https://terraform-docs.io) v0.20.0 | The README tables. Pinned to the version the CI docs action bundles; `make docs` refuses others. | [v0.20.0 release](https://github.com/terraform-docs/terraform-docs/releases/tag/v0.20.0) |
| [checkov](https://www.checkov.io), [trivy](https://trivy.dev) | Static security policy | `pip install checkov`, `brew install trivy` |

```sh
terraform init -backend=false -input=false
make check TEST_TERRAFORM=/path/to/terraform-1.8.5
```

## The local gate

| Target | What it runs |
| --- | --- |
| `make fmt` | `terraform fmt -check -recursive -diff`. `make fmt-fix` rewrites. |
| `make validate` | `terraform init -backend=false` and `terraform validate` in the root, every example, and the integration roots. |
| `make lint` | `tflint` everywhere with the root `.tflint.hcl`. |
| `make test` | `terraform test` in the root with `$(TEST_TERRAFORM)`, which must be 1.8 or later. |
| `make ordering` | `scripts/check-listener-ordering.sh`: the ECS service depends on the ALB listeners in `terraform graph`. |
| `make docs` / `make docs-check` | Regenerate / verify the terraform-docs tables in every README. |
| `make security` | Checkov and Trivy (HIGH, CRITICAL). |
| `make check` | All of the above in that order. CI runs the same steps. |

## Why the tests need Terraform 1.8

Two Terraform behaviours, verified on 1.7.5, 1.8.5, and 1.9.8:

1. A `check` block that fails inside a nested module fails the `terraform test` run, and `expect_failures` cannot reference a nested module's check. `aws.modules.vpc`'s `internet_path_declared` check always fires in this blueprint (the ALB needs an internet gateway), so no run can contain the real vpc module as a child.
2. `override_module` replaces a child module's outputs on 1.8 and later. On 1.7.5 the overridden module is still planned, with unknown inputs, and fails on its `count` and `for_each` expressions.

The suites therefore override `module.vpc` with fixed outputs and assert the values the blueprint passes into it through its locals; `tests/vpc_contract.tftest.hcl` runs the pinned vpc module itself as the run's root (`./.terraform/modules/vpc`, so `terraform init` must have run) where its check can be expected. CI runs the root's quality job on 1.8.5 and validates the root on 1.7.5 in a separate job, since consumers may still use 1.7.

## Writing tests

- Every file starts with the same fixture: the mock provider (us-east-2, account 123456789012, well-formed ARNs), the `module.vpc` override, distinct security group IDs for the ALB and the tasks, and a golden-path `variables` block. Terraform test files cannot include one another, so keep the copies identical.
- Assert the glue. Locals are referenceable from test assertions; nested module resources are not. When a leaf exposes the value as an output (for example `task_execution_role_derived_policy`), assert the output after a mocked `command = apply`.
- A mocked apply needs concrete, well-formed ARNs and IDs wherever the AWS provider validates them; extend the `mock_resource` defaults rather than switching a run to `plan` to dodge a value.
- Validations get an `expect_failures` run each (`tests/validation.tftest.hcl`). A run with `expect_failures` passes only if exactly those objects fail.
- `||` and `&&` do not short-circuit in Terraform 1.7. Guard with a conditional (`x == null ? true : x.field > 0`).
- Mocked tests cannot see ordering. If a change touches how the target group ARN reaches the service, `make ordering` must still pass.

## Changing a leaf pin

1. Read the leaf's changelog and diff between the pinned commit and the new release's commit, looking for changed defaults, renamed outputs, and new checks (a new always-firing check in a nested module breaks every test run; see above).
2. Update the SHA and the version comment in `main.tf` (and the version in the README's "What gets created" headings).
3. Run `make check`, then the end-to-end run (`make integration-e2e`) in your own account.
4. Record it in `CHANGELOG.md`. A leaf upgrade that changes what the blueprint creates is a minor or major blueprint release.

## Commits and pull requests

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Every pull request: `make check` passes, new behaviour has a test, `make docs` regenerated the tables, `CHANGELOG.md` has an `## [Unreleased]` entry, and a new input is justified against the "Inputs deliberately not exposed" table in `docs/DESIGN.md`.

## Release process

Releases are cut by maintainers.

1. Move the `## [Unreleased]` entries in `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD` and merge that to `main`.
2. Create a signed annotated tag on the merge commit (`git tag -s vX.Y.Z -m "aws.modules.blueprint-microservice-private vX.Y.Z"`) and push it.
3. Dispatch the `module-release` workflow with `release_tag = vX.Y.Z`.
4. Announce the release with its commit SHA. Consumers pin the SHA, not the tag. Tags are never moved or deleted.
