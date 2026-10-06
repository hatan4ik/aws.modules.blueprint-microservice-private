# ------------------------------------------------------------------- edge

output "url" {
  description = "Base URL of the service: https://<ALB DNS name> with a certificate, http:// without. Point a DNS alias at alb_dns_name/alb_zone_id to serve it under the certificate's name."
  value       = "${var.load_balancer.certificate_arn != null ? "https" : "http"}://${module.alb.alb_dns_name}"
}

output "alb_arn" {
  description = "ARN of the ALB."
  value       = module.alb.alb_arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "Route 53 hosted zone ID of the ALB, for an alias record (for example through aws.modules.route53)."
  value       = module.alb.alb_zone_id
}

output "alb_arn_suffix" {
  description = "ARN suffix of the ALB, for CloudWatch metrics and alarms."
  value       = module.alb.alb_arn_suffix
}

output "alb_security_group_id" {
  description = "ID of the ALB's security group."
  value       = module.alb.security_group_id
}

output "target_group_arn" {
  description = "ARN of the target group the service registers its tasks with."
  value       = module.alb.target_group_arns[local.target_group_key]
}

# ---------------------------------------------------------------- service

output "service_name" {
  description = "Name of the ECS service."
  value       = module.service.name
}

output "service_arn" {
  description = "ARN of the ECS service."
  value       = module.service.arn
}

output "cluster_name" {
  description = "Name of the cluster the service runs on, derived from cluster_arn."
  value       = module.service.cluster_name
}

output "task_definition_arn" {
  description = "ARN of the registered task definition revision."
  value       = module.service.task_definition_arn
}

output "task_role_arn" {
  description = "ARN of the task role: the identity the application's AWS SDK calls run as."
  value       = module.service.task_role_arn
}

output "task_role_name" {
  description = "Name of the task role, for attaching further policies outside the blueprint."
  value       = module.service.task_role_name
}

output "task_execution_role_arn" {
  description = "ARN of the task execution role ECS uses to pull the image, write logs, and read the declared secrets."
  value       = module.service.task_execution_role_arn
}

output "task_execution_role_derived_policy" {
  description = "The execution role's derived inline policy (JSON): exactly the declared secrets, parameters, and KMS keys, or null when none are declared."
  value       = module.service.task_execution_role_derived_policy
}

output "task_security_group_id" {
  description = "ID of the tasks' security group. Reference it from a data store's security group to let the service in."
  value       = module.service.security_group_id
}

output "log_group_name" {
  description = "CloudWatch log group the container writes to."
  value       = module.service.cloudwatch_log_group_name
}

# ---------------------------------------------------------------- network

output "vpc_id" {
  description = "ID of the service's VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by AZ key (az1, az2, az3): where the ALB's network interfaces live."
  value       = module.vpc.subnet_ids_by_tier["public"]
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by AZ key: where the tasks run."
  value       = module.vpc.subnet_ids_by_tier["private"]
}

output "private_subnet_cidr_blocks" {
  description = "Private subnet CIDR blocks keyed by AZ key, known at plan time."
  value       = module.vpc.subnet_cidr_blocks_by_tier["private"]
}

output "interface_endpoint_services" {
  description = "AWS service suffixes that have an interface VPC endpoint in the private subnets."
  value       = sort(tolist(local.interface_endpoint_services))
}

output "nat_gateway_public_ips" {
  description = "Public IP of the NAT gateway keyed by gateway key, the source address of the tasks' internet traffic for third-party allowlists; empty when network.nat_gateway is false."
  value       = module.vpc.nat_gateway_public_ips
}
