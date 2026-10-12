# Minimal

The smallest useful call: a digest-pinned image on the environment's shared cluster, behind HTTPS, with every other setting on the blueprint's default. That is a `/16` VPC with public and private subnets in two zones, ECR, CloudWatch Logs, and S3 endpoints and no NAT gateway, an internet-facing ALB with an HTTP-to-HTTPS redirect, and two 0.25 vCPU / 0.5 GB tasks that must answer `GET /` on port 8080 with a 2xx or 3xx.

## Run

```sh
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and replace every example value with environment values.
terraform init
terraform plan
```

`terraform.tfvars.example` is a complete, sanitized input template. The copied
`terraform.tfvars` file is deliberately ignored by Git and must use resource
identifiers from the same region and account as the shared ECS cluster.

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
| <a name="input_availability_zones"></a> [availability\_zones](#input\_availability\_zones) | Two or three Availability Zones in the region. | `list(string)` | <pre>[<br/>  "us-east-2a",<br/>  "us-east-2b"<br/>]</pre> | no |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ACM certificate ARN in the same region, for the ALB's HTTPS listener. | `string` | n/a | yes |
| <a name="input_cluster_arn"></a> [cluster\_arn](#input\_cluster\_arn) | ARN of the environment's shared ECS cluster, for example the cluster\_arn output of its aws.modules.ecs call. | `string` | n/a | yes |
| <a name="input_image"></a> [image](#input\_image) | Container image pinned to a digest (repository@sha256:<64 hex>). It must listen on port 8080 and answer GET / with a 2xx or 3xx. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region: the region of the cluster and the certificate. | `string` | `"us-east-2"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Name of the ECS service. |
| <a name="output_url"></a> [url](#output\_url) | Base URL of the service. |
<!-- END_TF_DOCS -->
