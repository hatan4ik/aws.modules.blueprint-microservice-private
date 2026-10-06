# The blueprint's whole interface. Every input is something a product team
# actually varies for one private HTTP microservice; everything else is a
# fixed, documented default inside main.tf. docs/DESIGN.md lists the leaf
# inputs that are deliberately not exposed and why.

# ---------------------------------------------------------------------------
# Identity and placement
# ---------------------------------------------------------------------------

variable "name" {
  description = "Service name: the ECS service, task family, VPC, ALB, and every derived resource name. 3-28 lowercase alphanumerics or hyphens, starting with a letter, so the longest derived name (the ALB target group <name>-app, 32 characters) fits its AWS limit."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,26}[a-z0-9]$", var.name))
    error_message = "name must be 3-28 lowercase alphanumeric characters or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "cluster_arn" {
  description = "ARN of the existing, shared ECS cluster the service runs on, normally the cluster_arn output of the environment's aws.modules.ecs call. The blueprint never creates a cluster. It must be in the same account and region as the AWS provider (enforced at plan time)."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:[a-z-]+:ecs:[a-z0-9-]+:[0-9]{12}:cluster/[A-Za-z0-9_-]+$", var.cluster_arn))
    error_message = "cluster_arn must be a full ECS cluster ARN (arn:<partition>:ecs:<region>:<account>:cluster/<name>)."
  }
}

variable "tags" {
  description = "Tags applied to every resource the composed modules create. The leaf modules add Name (and Tier on subnets) and never override caller tags."
  type        = map(string)
  default     = {}
  nullable    = false
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "network" {
  description = <<-EOT
    The service's VPC. cidr_block is a /16 to /19; each Availability Zone gets a public subnet (cidr_block + 8 bits, for the ALB) and a private subnet (cidr_block + 4 bits, for the tasks). availability_zones lists 2 or 3 zone names.
    The private subnets have no internet route. Tasks reach AWS through VPC endpoints the blueprint always creates (ecr.api, ecr.dkr, logs, and the s3 gateway for image layers; secretsmanager and ssm are added automatically when container.secrets references them).
    interface_endpoint_services and gateway_endpoint_services add endpoints for AWS services the application itself calls (for example ["sqs"] and ["dynamodb"]); the task security group is opened to exactly those endpoints.
    nat_gateway = true adds one NAT gateway (in the first zone) and an HTTPS-only egress rule to 0.0.0.0/0, for images outside ECR or calls to third-party APIs.
  EOT
  type = object({
    cidr_block                  = string
    availability_zones          = list(string)
    nat_gateway                 = optional(bool, false)
    interface_endpoint_services = optional(set(string), [])
    gateway_endpoint_services   = optional(set(string), [])
  })
  nullable = false

  validation {
    condition     = can(cidrhost(var.network.cidr_block, 0)) ? (tonumber(split("/", var.network.cidr_block)[1]) >= 16 && tonumber(split("/", var.network.cidr_block)[1]) <= 19) : false
    error_message = "network.cidr_block must be a valid IPv4 CIDR between /16 and /19, so every public subnet is at least a /27 (the ALB minimum)."
  }

  validation {
    condition     = length(var.network.availability_zones) >= 2 && length(var.network.availability_zones) <= 3 && length(distinct(var.network.availability_zones)) == length(var.network.availability_zones)
    error_message = "network.availability_zones must list 2 or 3 distinct Availability Zones; the ALB needs at least two."
  }

  validation {
    condition     = alltrue([for zone in var.network.availability_zones : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9][a-z]$", zone))])
    error_message = "Every network.availability_zones entry must be a zone name such as us-east-2a."
  }

  validation {
    condition     = alltrue([for service in var.network.interface_endpoint_services : can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", service)) && !startswith(service, "com.amazonaws.") && !contains(["s3", "dynamodb"], service)])
    error_message = "network.interface_endpoint_services entries must be AWS service suffixes such as sqs or kms (not the full com.amazonaws.<region> name), and s3 and dynamodb belong in gateway_endpoint_services."
  }

  validation {
    condition     = alltrue([for service in var.network.gateway_endpoint_services : contains(["s3", "dynamodb"], service)])
    error_message = "network.gateway_endpoint_services may only contain s3 or dynamodb, the two services AWS offers as gateway endpoints (s3 is always created)."
  }
}

# ---------------------------------------------------------------------------
# Workload
# ---------------------------------------------------------------------------

variable "container" {
  description = <<-EOT
    The task's single application container and its Fargate size.
    image must be pinned to a digest (repository@sha256:<64 hex>); the ECS service module rejects anything else at plan time.
    port is the container port the ALB forwards to and health-checks. cpu and memory are task-level Fargate units and MiB (validated as a supported pair at plan time).
    environment is plain text; secrets maps variable names to Secrets Manager or SSM parameter ARNs, and the execution role is granted exactly those ARNs. secrets_kms_key_arns lists customer-managed keys protecting them.
    The root filesystem is read-only; writable_paths lists absolute paths (for example /tmp) that get a writable ephemeral volume.
  EOT
  type = object({
    image                = string
    port                 = optional(number, 8080)
    cpu                  = optional(number, 256)
    memory               = optional(number, 512)
    cpu_architecture     = optional(string, "X86_64")
    command              = optional(list(string))
    environment          = optional(map(string), {})
    secrets              = optional(map(string), {})
    secrets_kms_key_arns = optional(set(string), [])
    writable_paths       = optional(set(string), [])
  })
  nullable = false

  validation {
    condition     = var.container.port >= 1 && var.container.port <= 65535 && floor(var.container.port) == var.container.port
    error_message = "container.port must be a whole number between 1 and 65535."
  }

  validation {
    condition     = alltrue([for arn in values(var.container.secrets) : can(regex("^arn:[a-z-]+:(secretsmanager|ssm):[a-z0-9-]+:[0-9]{12}:", arn))])
    error_message = "Every container.secrets value must be a Secrets Manager secret ARN or an SSM parameter ARN."
  }

  validation {
    condition     = alltrue([for arn in var.container.secrets_kms_key_arns : can(regex("^arn:[a-z-]+:kms:[a-z0-9-]+:[0-9]{12}:key/", arn))])
    error_message = "Every container.secrets_kms_key_arns entry must be a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<id>)."
  }

  validation {
    condition     = alltrue([for path in var.container.writable_paths : can(regex("^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$", path))])
    error_message = "Every container.writable_paths entry must be an absolute path such as /tmp, without a trailing slash."
  }

  validation {
    condition     = contains(["X86_64", "ARM64"], var.container.cpu_architecture)
    error_message = "container.cpu_architecture must be X86_64 or ARM64, matching the image."
  }
}

variable "task_role_statements" {
  description = "IAM statements for the application's task role, keyed by alphanumeric Sid: the AWS data the application itself reads or writes. Empty by default, so the task role grants nothing. The same shape aws.modules.ecs-service uses; the trust policy is fixed to ECS tasks in the cluster's account and region."
  type = map(object({
    effect    = optional(string, "Allow")
    actions   = set(string)
    resources = set(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = set(string)
    })), [])
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for sid in keys(var.task_role_statements) : can(regex("^[A-Za-z0-9]+$", sid))])
    error_message = "task_role_statements keys are IAM Sids and must be alphanumeric."
  }

  validation {
    condition     = alltrue([for statement in values(var.task_role_statements) : !contains(statement.actions, "*") && !contains(statement.resources, "*") || statement.effect == "Deny"])
    error_message = "An Allow statement in task_role_statements may not use \"*\" as an action or a resource. Name the actions and resources the application needs."
  }
}

# ---------------------------------------------------------------------------
# Service behaviour
# ---------------------------------------------------------------------------

variable "service" {
  description = <<-EOT
    How many tasks run and how deployments behave.
    desired_count applies at creation only: the ECS service module ignores later drift because autoscaling and deployments change it, so changing it afterwards has no effect.
    autoscaling (null disables it) tracks average CPU at cpu_target_percent between min_capacity and max_capacity; desired_count must lie inside that range.
    wait_for_steady_state = true (default) makes terraform apply wait until the new tasks pass ALB health checks, so a deployment that never becomes healthy fails the apply instead of reporting success.
  EOT
  type = object({
    desired_count         = optional(number, 2)
    wait_for_steady_state = optional(bool, true)
    autoscaling = optional(object({
      min_capacity       = number
      max_capacity       = number
      cpu_target_percent = optional(number, 60)
    }))
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.service.desired_count >= 1 && floor(var.service.desired_count) == var.service.desired_count
    error_message = "service.desired_count must be a whole number of at least 1."
  }

  validation {
    condition = var.service.autoscaling == null ? true : (
      var.service.autoscaling.min_capacity >= 1 &&
      var.service.autoscaling.max_capacity >= var.service.autoscaling.min_capacity &&
      var.service.autoscaling.cpu_target_percent > 0 && var.service.autoscaling.cpu_target_percent <= 100
    )
    error_message = "service.autoscaling needs min_capacity of at least 1, max_capacity no lower than min_capacity, and cpu_target_percent between 1 and 100."
  }

  validation {
    condition     = var.service.autoscaling == null ? true : (var.service.desired_count >= var.service.autoscaling.min_capacity && var.service.desired_count <= var.service.autoscaling.max_capacity)
    error_message = "service.desired_count must lie within service.autoscaling.min_capacity and max_capacity."
  }
}

variable "health_check" {
  description = <<-EOT
    The ALB target-group health check, the single most common reason a new service never becomes healthy.
    path must return a status in matcher from inside the container on container.port, without authentication, within 5 seconds. Checks run every 15 seconds; 2 consecutive passes mark a task healthy and 3 failures unhealthy.
    grace_period_seconds is how long ECS ignores failing checks after a task starts, so a slow-booting application is not killed before it can answer.
  EOT
  type = object({
    path                 = optional(string, "/")
    matcher              = optional(string, "200-399")
    grace_period_seconds = optional(number, 60)
  })
  default  = {}
  nullable = false

  validation {
    condition     = startswith(var.health_check.path, "/") && length(var.health_check.path) <= 1024
    error_message = "health_check.path must start with / and be at most 1024 characters."
  }

  validation {
    condition     = can(regex("^[0-9]{3}(-[0-9]{3})?(,[0-9]{3}(-[0-9]{3})?)*$", var.health_check.matcher))
    error_message = "health_check.matcher must be HTTP codes such as \"200\", \"200-399\", or \"200,204\"."
  }

  validation {
    condition     = var.health_check.grace_period_seconds >= 0 && var.health_check.grace_period_seconds <= 3600
    error_message = "health_check.grace_period_seconds must be between 0 and 3600."
  }
}

# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------

variable "load_balancer" {
  description = <<-EOT
    The internet-facing ALB in front of the service.
    certificate_arn (an ACM certificate in the provider's region) serves HTTPS on 443 and redirects port 80 to it. Leaving it null serves plain HTTP on port 80 only, which a check block flags on every plan; use it only for a disposable environment.
    ingress_cidrs limits who can reach the listeners. web_acl_arn associates a REGIONAL WAFv2 web ACL. access_logs_bucket names an existing S3 bucket whose policy already admits ELB log delivery.
    deletion_protection = true (default) blocks deleting the ALB, including on terraform destroy, until it is set to false and applied.
  EOT
  type = object({
    certificate_arn     = optional(string)
    ingress_cidrs       = optional(set(string), ["0.0.0.0/0"])
    web_acl_arn         = optional(string)
    access_logs_bucket  = optional(string)
    deletion_protection = optional(bool, true)
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.load_balancer.certificate_arn == null ? true : can(regex("^arn:[a-z0-9-]+:acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]{36}$", var.load_balancer.certificate_arn))
    error_message = "load_balancer.certificate_arn must be an ACM certificate ARN."
  }

  validation {
    condition     = length(var.load_balancer.ingress_cidrs) > 0 && alltrue([for cidr in var.load_balancer.ingress_cidrs : can(cidrnetmask(cidr))])
    error_message = "load_balancer.ingress_cidrs must list at least one valid IPv4 CIDR."
  }

  validation {
    condition     = var.load_balancer.access_logs_bucket == null ? true : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.load_balancer.access_logs_bucket))
    error_message = "load_balancer.access_logs_bucket must be an S3 bucket name, not an ARN."
  }
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

variable "logs" {
  description = "The service's CloudWatch log group, /aws/ecs/<cluster>/<name>. kms_key_arn encrypts it with a customer-managed key (for example the cluster platform's application_data_kms_key_arn); that key's policy must already admit CloudWatch Logs for this log group's ARN, or the log group cannot be created."
  type = object({
    retention_in_days = optional(number, 365)
    kms_key_arn       = optional(string)
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.logs.retention_in_days)
    error_message = "logs.retention_in_days must be a CloudWatch Logs retention value (1 to 3653 days; never-expire is not offered)."
  }

  validation {
    condition     = var.logs.kms_key_arn == null ? true : can(regex("^arn:[a-z-]+:kms:[a-z0-9-]+:[0-9]{12}:key/", var.logs.kms_key_arn))
    error_message = "logs.kms_key_arn must be a KMS key ARN."
  }
}
