# Complete

A realistic private microservice: `orders-api` reads its database password from Secrets Manager (under a customer-managed key), publishes to SQS, reads and writes one DynamoDB table, needs a writable `/tmp`, and scales on CPU between two and eight tasks across three zones. There is no NAT gateway; every AWS call goes through a VPC endpoint:

- `ecr.api`, `ecr.dkr`, `logs`, and the `s3` gateway: always, so the task can start.
- `secretsmanager`: added by the blueprint because `container.secrets` references a Secrets Manager ARN.
- `sqs` and the `dynamodb` gateway: declared in `network`, because the application calls them. The task security group is opened to exactly these.

The task role gets exactly the four DynamoDB actions on the table and its indexes and `sqs:SendMessage` on the queue; the execution role gets exactly the one secret and the one key. The ALB serves HTTPS with WAF and access logs, the health check is `GET /healthz` expecting `200` with a 90-second grace period, and the log group uses the platform's KMS key for 90 days.

Before applying, the platform's key policy must admit CloudWatch Logs for `/aws/ecs/<cluster>/orders-api` (add it to `aws.modules.ecs`'s `additional_cloudwatch_log_group_arns`), the access-log bucket's policy must admit ELB log delivery, and the image must answer `/healthz` on port 8080.

## Run

```sh
terraform init
terraform plan -var-file=orders.tfvars   # cluster_arn, image, certificate_arn, web_acl_arn, access_logs_bucket, and the data ARNs
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.35.0, < 7.0.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_orders"></a> [orders](#module\_orders) | ../../ | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_logs_bucket"></a> [access\_logs\_bucket](#input\_access\_logs\_bucket) | Existing S3 bucket whose policy admits ELB access-log delivery. | `string` | n/a | yes |
| <a name="input_availability_zones"></a> [availability\_zones](#input\_availability\_zones) | Two or three Availability Zones in the region. | `list(string)` | <pre>[<br/>  "us-east-2a",<br/>  "us-east-2b",<br/>  "us-east-2c"<br/>]</pre> | no |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ACM certificate ARN for the ALB's HTTPS listener. | `string` | n/a | yes |
| <a name="input_cluster_arn"></a> [cluster\_arn](#input\_cluster\_arn) | ARN of the environment's shared ECS cluster, for example the cluster\_arn output of its aws.modules.ecs call read from the platform root's state. | `string` | n/a | yes |
| <a name="input_db_password_secret_arn"></a> [db\_password\_secret\_arn](#input\_db\_password\_secret\_arn) | Secrets Manager secret ARN holding the database password. | `string` | n/a | yes |
| <a name="input_events_queue_arn"></a> [events\_queue\_arn](#input\_events\_queue\_arn) | ARN of the SQS queue the service publishes to. | `string` | n/a | yes |
| <a name="input_events_queue_url"></a> [events\_queue\_url](#input\_events\_queue\_url) | URL of the SQS queue the service publishes to. | `string` | n/a | yes |
| <a name="input_image"></a> [image](#input\_image) | Container image pinned to a digest (repository@sha256:<64 hex>). It must listen on 8080 and answer GET /healthz with 200. | `string` | n/a | yes |
| <a name="input_logs_kms_key_arn"></a> [logs\_kms\_key\_arn](#input\_logs\_kms\_key\_arn) | KMS key ARN for the service's log group, normally the platform's application\_data\_kms\_key\_arn. | `string` | n/a | yes |
| <a name="input_orders_table_arn"></a> [orders\_table\_arn](#input\_orders\_table\_arn) | ARN of the DynamoDB table the service reads and writes. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region: the region of the cluster, the certificate, and every ARN below. | `string` | `"us-east-2"` | no |
| <a name="input_secrets_kms_key_arn"></a> [secrets\_kms\_key\_arn](#input\_secrets\_kms\_key\_arn) | KMS key ARN encrypting the database password secret. | `string` | n/a | yes |
| <a name="input_web_acl_arn"></a> [web\_acl\_arn](#input\_web\_acl\_arn) | REGIONAL WAFv2 web ACL ARN, for example from aws.modules.waf. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | DNS name of the ALB. |
| <a name="output_alb_zone_id"></a> [alb\_zone\_id](#output\_alb\_zone\_id) | Hosted zone ID of the ALB, for a Route 53 alias record. |
| <a name="output_task_role_arn"></a> [task\_role\_arn](#output\_task\_role\_arn) | Task role ARN, for resource policies that must admit the service. |
| <a name="output_task_security_group_id"></a> [task\_security\_group\_id](#output\_task\_security\_group\_id) | Task security group ID, for data-store security groups that must admit the service. |
| <a name="output_url"></a> [url](#output\_url) | Base URL of the service; alias a DNS name covered by the certificate to alb\_dns\_name. |
<!-- END_TF_DOCS -->
