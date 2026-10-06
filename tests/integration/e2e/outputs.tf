output "url" {
  description = "Base URL the e2e script polls."
  value       = module.blueprint.url
}

output "service_name" {
  description = "Name of the ECS service under test."
  value       = module.blueprint.service_name
}
