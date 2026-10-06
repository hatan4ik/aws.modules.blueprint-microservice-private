output "url" {
  description = "Base URL of the service; alias a DNS name covered by the certificate to alb_dns_name."
  value       = module.orders.url
}

output "alb_dns_name" {
  description = "DNS name of the ALB."
  value       = module.orders.alb_dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB, for a Route 53 alias record."
  value       = module.orders.alb_zone_id
}

output "task_role_arn" {
  description = "Task role ARN, for resource policies that must admit the service."
  value       = module.orders.task_role_arn
}

output "task_security_group_id" {
  description = "Task security group ID, for data-store security groups that must admit the service."
  value       = module.orders.task_security_group_id
}
