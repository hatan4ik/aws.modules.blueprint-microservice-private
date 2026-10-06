variable "region" {
  description = "AWS region: the region of the cluster and the certificate."
  type        = string
  default     = "us-east-2"
}

variable "cluster_arn" {
  description = "ARN of the environment's shared ECS cluster, for example the cluster_arn output of its aws.modules.ecs call."
  type        = string
}

variable "availability_zones" {
  description = "Two or three Availability Zones in the region."
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "image" {
  description = "Container image pinned to a digest (repository@sha256:<64 hex>). It must listen on port 8080 and answer GET / with a 2xx or 3xx."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN in the same region, for the ALB's HTTPS listener."
  type        = string
}
