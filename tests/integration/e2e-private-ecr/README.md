# e2e-private-ecr root

Applied by `scripts/integration-e2e.sh --variant private-ecr`: the blueprint with no NAT gateway, running a private ECR image from the [private-ecr](../private-ecr) fixture. See [../README.md](../README.md). Not a deployable pattern.

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
| <a name="module_blueprint"></a> [blueprint](#module\_blueprint) | ../../../ | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_availability_zones"></a> [availability\_zones](#input\_availability\_zones) | Two zones from the setup root. | `list(string)` | n/a | yes |
| <a name="input_cluster_arn"></a> [cluster\_arn](#input\_cluster\_arn) | Disposable cluster ARN from the setup root. | `string` | n/a | yes |
| <a name="input_image"></a> [image](#input\_image) | Digest-pinned private ECR image from the private-ecr root. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Unique service name from the setup root. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_nat_gateway_public_ips"></a> [nat\_gateway\_public\_ips](#output\_nat\_gateway\_public\_ips) | NAT gateway public IPs; the script requires this to be empty. |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | Private subnet IDs, whose route tables the e2e script proves have no default route. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Name of the ECS service under test. |
| <a name="output_url"></a> [url](#output\_url) | Base URL the e2e script polls. |
<!-- END_TF_DOCS -->
