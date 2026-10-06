# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.x | Yes. Security fixes and functional fixes on the latest minor release. |
| 0.1.x | Security fixes only, until 2026-12-31. Upgrade with [docs/UPGRADE-1.0.md](docs/UPGRADE-1.0.md). |
| Unreleased `main` | Not supported for production use. |

## Reporting a vulnerability

Use GitHub private vulnerability reporting on this repository: open the Security tab and choose "Report a vulnerability". Do not open a public issue, pull request, or discussion for a security problem.

Include the module version or commit SHA, the inputs that reproduce the problem, the resulting plan or policy, and the impact you see.

## What counts

- A module default that weakens security: a public IP, an open ingress rule, a mutable image accepted, a writable root filesystem, an unencrypted or unbounded log group, a disabled circuit breaker.
- A validation bypass: an input the module claims to reject at plan time but that reaches the provider.
- IAM over-permission: an execution or task role granted an action or resource the caller did not declare, a trust policy assumable outside the cluster's account and region, or a derived policy broader than the referenced secrets, parameters, and keys.
- A caller-supplied role, security group, or log group that the module modifies.
- A dependency problem in the release pipeline that could publish unverified code.

Findings in your own inputs (for example an egress rule to `0.0.0.0/0` you declared) or in AWS services themselves are out of scope here; report the latter to AWS.

## Response

We acknowledge a report within 5 business days and keep you informed while we confirm, fix, and release. A fix ships as a patch release of every supported line with a `CHANGELOG.md` entry that credits the reporter unless they ask otherwise. Please give us a reasonable window before disclosing publicly.

## Security design

The module is secure by default: private tasks, no ingress, explicit egress, digest-pinned images, read-only root filesystems, a circuit breaker with rollback, an execution role limited to the AWS managed policy plus the exact secrets, parameters, and KMS keys the containers reference, an empty task role, trust policies conditioned on `aws:SourceAccount` and `aws:SourceArn`, and a log group with 365-day retention that is KMS-encrypted when a key is supplied. Every claim is enforced by a validation, a precondition, or a `check` block with a `terraform test` case behind it. The full description is in the [Security model](README.md#security-model) section of the README, and the reasoning in [docs/DESIGN.md](docs/DESIGN.md).
