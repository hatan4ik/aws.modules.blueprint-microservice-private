# Upgrading to 2.0.0

2.0.0 hardens three defaults. Each can make a 1.x configuration fail at plan or
remove access a running service had, which is why it is a major release. The
upgrade replaces no resource: the VPC endpoints' policies are updated in place.

## 1. Plain HTTP is opt-in

1.x served plain HTTP on port 80 whenever `load_balancer.certificate_arn` was
null. 2.0.0 fails the plan instead:

```
load_balancer.certificate_arn is null and load_balancer.allow_plain_http is false.
```

Either supply a certificate (recommended), or, if you relied on the HTTP
default for a disposable environment, opt in explicitly:

```hcl
load_balancer = {
  allow_plain_http = true
}
```

The `http_only_listener` check still warns on every plan while the opt-in is in
effect. `allow_plain_http` has no effect once `certificate_arn` is set.

## 2. Writable paths stay off system directories

`container.writable_paths` now rejects:

- un-normalised paths: `//`, `.` or `..` segments (a trailing `/` was already
  rejected);
- anything under `/etc`, `/usr`, `/bin`, `/sbin`, `/lib`, `/lib32`, `/lib64`,
  `/libx32`, `/root`, `/proc`, `/sys`, `/dev`, or `/boot`;
- `/var` and `/var/lib` themselves (`/var/lib/<app>` is still allowed);
- nested paths such as `/tmp` and `/tmp/cache` (list only the outer path);
- paths whose derived volume names collide, such as `/var/cache-app` and
  `/var/cache/app` (these already failed in 1.x, with a less helpful error).

Point the application's writes at an application directory (`/tmp`, `/run`,
`/var/cache/<app>`, `/var/log/<app>`, `/var/lib/<app>`, `/home/<user>`,
`/app/...`) and list that instead.

## 3. VPC endpoints carry least-privilege policies

| Endpoint | 1.x policy | 2.0.0 policy |
| --- | --- | --- |
| `ecr.api`, `ecr.dkr`, `logs`, `secretsmanager`, `ssm`, `dynamodb` (gateway) | full access | allow only when `aws:PrincipalAccount` is the provider's account |
| `s3` (gateway) | full access | `s3:GetObject` on `arn:aws:s3:::prod-<region>-starport-layer-bucket/*` (ECR image layers), and anything when `aws:ResourceAccount` is this account |
| caller-declared interface endpoints (`network.interface_endpoint_services`) | full access | unchanged (full access) |

What can break: the application reading or writing an S3 bucket owned by
another account in the same region (a public dataset, a partner's bucket) gets
`AccessDenied`, with or without a NAT gateway, because in-region S3 traffic
always takes the gateway route. Copy the data into a bucket this account owns,
or compose `aws.modules.vpc` directly with your own endpoint policy.
