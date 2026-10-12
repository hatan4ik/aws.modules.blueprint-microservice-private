output "url" {
  description = "Base URL the e2e script polls."
  value       = module.blueprint.url
}

output "service_name" {
  description = "Name of the ECS service under test."
  value       = module.blueprint.service_name
}

output "private_subnet_ids" {
  description = "Private subnet IDs, whose route tables the e2e script proves have no default route."
  value       = module.blueprint.private_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "NAT gateway public IPs; the script requires this to be empty."
  value       = module.blueprint.nat_gateway_public_ips
}
