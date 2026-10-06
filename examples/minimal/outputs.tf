output "url" {
  description = "Base URL of the service."
  value       = module.orders.url
}

output "service_name" {
  description = "Name of the ECS service."
  value       = module.orders.service_name
}
