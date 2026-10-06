output "name" {
  description = "Unique name for the run, also the service name under test."
  value       = local.name
}

output "cluster_arn" {
  description = "ARN of the disposable ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "availability_zones" {
  description = "Two available zones in the caller's region."
  value       = slice(data.aws_availability_zones.available.names, 0, 2)
}
