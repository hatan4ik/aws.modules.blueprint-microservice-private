variable "region" {
  description = "AWS region: the region of the cluster, the certificate, and every ARN below."
  type        = string
  default     = "us-east-2"
}

variable "cluster_arn" {
  description = "ARN of the environment's shared ECS cluster, for example the cluster_arn output of its aws.modules.ecs call read from the platform root's state."
  type        = string
}

variable "availability_zones" {
  description = "Two or three Availability Zones in the region."
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "image" {
  description = "Container image pinned to a digest (repository@sha256:<64 hex>). It must listen on 8080 and answer GET /healthz with 200."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the ALB's HTTPS listener."
  type        = string
}

variable "web_acl_arn" {
  description = "REGIONAL WAFv2 web ACL ARN, for example from aws.modules.waf."
  type        = string
}

variable "access_logs_bucket" {
  description = "Existing S3 bucket whose policy admits ELB access-log delivery."
  type        = string
}

variable "db_password_secret_arn" {
  description = "Secrets Manager secret ARN holding the database password."
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "KMS key ARN encrypting the database password secret."
  type        = string
}

variable "orders_table_arn" {
  description = "ARN of the DynamoDB table the service reads and writes."
  type        = string
}

variable "events_queue_arn" {
  description = "ARN of the SQS queue the service publishes to."
  type        = string
}

variable "events_queue_url" {
  description = "URL of the SQS queue the service publishes to."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "KMS key ARN for the service's log group, normally the platform's application_data_kms_key_arn."
  type        = string
}
