# Composition root. Three leaf modules, called in dependency order, each
# pinned to the commit SHA of a released tag. Every AWS resource comes from one
# of them; locals.tf only reshapes outputs into inputs.
#
#   1. aws.modules.vpc          public + private subnets, endpoints, flow logs
#   2. aws.modules.alb          internet-facing ALB, its security group, one
#                               target group (it calls aws.modules.security-group
#                               itself)
#   3. aws.modules.ecs-service  task definition, Fargate service, task and
#                               execution roles (its own modules/iam), task
#                               security group (aws.modules.security-group),
#                               log group, autoscaling
#
# The ECS cluster is an input (cluster_arn), not a module call: see
# docs/DESIGN.md, "Step 5: the cluster is shared, not owned".

module "vpc" {
  source = "git::https://github.com/hatan4ik/aws.modules.vpc.git?ref=969e78e0653ec54a6985fd93f9ca23345bd0b84a" # v1.1.0

  name       = var.name
  cidr_block = var.network.cidr_block
  subnets    = local.subnets
  tags       = var.tags

  # The internet gateway is required by the internet-facing ALB; a NAT
  # gateway exists only when network.nat_gateway is true.
  internet = {
    nat_gateways = var.network.nat_gateway ? { az1 = { subnet = "public/az1" } } : {}
  }

  # aws.modules.vpc defaults to enforce, which rejects the internet gateway
  # an internet-facing ALB needs (see the module's nat-egress integration
  # suite). monitor still reports unencrypted in-VPC traffic.
  vpc_encryption_control = "monitor"

  endpoints = local.endpoints

  flow_logs = {
    destination = { create_kms_key = true }
  }
}

module "alb" {
  source = "git::https://github.com/hatan4ik/aws.modules.alb.git?ref=2c3441caf2e19fc469cf678f3ac4cac0c632678e" # v1.0.1

  name              = var.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = local.public_subnet_ids
  tags              = var.tags

  certificate_arn  = var.load_balancer.certificate_arn
  create_http_only = var.load_balancer.certificate_arn == null

  security_group_ingress_cidrs = var.load_balancer.ingress_cidrs
  web_acl_arn                  = var.load_balancer.web_acl_arn
  deletion_protection          = var.load_balancer.deletion_protection
  access_logs = var.load_balancer.access_logs_bucket == null ? null : {
    bucket_name = var.load_balancer.access_logs_bucket
    prefix      = var.name
  }

  target_groups = {
    (local.target_group_key) = {
      port        = var.container.port
      protocol    = "HTTP"
      target_type = "ip"
      health_check = {
        path                = var.health_check.path
        matcher             = var.health_check.matcher
        interval            = 15
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
      deregistration_delay = 30
    }
  }
  default_target_group_key = local.target_group_key
}

module "service" {
  source = "git::https://github.com/hatan4ik/aws.modules.ecs-service.git?ref=79e268f3f60bd236418054e0b42d464640b88a89" # v1.0.1

  name        = var.name
  cluster_arn = var.cluster_arn
  tags        = var.tags

  # Task definition: one container, sized by the caller, on Fargate.
  cpu                   = var.container.cpu
  memory                = var.container.memory
  cpu_architecture      = var.container.cpu_architecture
  container_definitions = local.container_definitions
  volumes               = { for volume in keys(local.writable_volumes) : volume => { configure_at_launch = false } }

  # Service: private subnets, no public IP, registered with the ALB.
  desired_count                     = var.service.desired_count
  wait_for_steady_state             = var.service.wait_for_steady_state
  load_balancers                    = local.service_load_balancers
  health_check_grace_period_seconds = var.health_check.grace_period_seconds
  autoscaling                       = local.autoscaling

  subnet_ids                   = local.private_subnet_ids
  assign_public_ip             = false
  vpc_id                       = module.vpc.vpc_id
  security_group_ingress_rules = local.task_ingress_rules
  security_group_egress_rules  = local.task_egress_rules

  # IAM: both roles are created by ecs-service's own modules/iam. The
  # execution role's secret and KMS permissions are derived from
  # container.secrets and secrets_kms_key_arns; the task role carries only the
  # caller's statements.
  task_execution_role_kms_key_arns = var.container.secrets_kms_key_arns
  task_role_statements             = var.task_role_statements

  cloudwatch_log_group_retention_in_days = var.logs.retention_in_days
  cloudwatch_log_group_kms_key_id        = var.logs.kms_key_arn
}
