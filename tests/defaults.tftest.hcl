# Defaults: what a product team gets from name, cluster_arn, network,
# container, and an edge certificate, and nothing else.

# Shared fixture (repeated in every file, since Terraform test files cannot
# include one another): a mock AWS provider in us-east-2 / 123456789012 with
# well-formed ARNs, and aws.modules.vpc replaced by fixed outputs.
#
# Why the VPC is overridden: aws.modules.vpc's internet_path_declared check
# always warns in this blueprint (the internet-facing ALB needs an internet
# gateway), terraform test fails a run on any check warning in a nested
# module, and expect_failures cannot name a nested module's check. The
# blueprint's own contribution to the VPC (the subnet layout and endpoint set
# it passes in) is asserted through its locals here, and tests/vpc_contract
# proves aws.modules.vpc accepts exactly that shape. override_module requires
# Terraform >= 1.8 for terraform test; see CONTRIBUTING.md.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  # aws.modules.alb reads the VPC CIDR for its security group's egress rule.
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.40.0.0/16" }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/app/orders/50dc6c495c0c9188"
      arn_suffix = "app/orders/50dc6c495c0c9188"
      dns_name   = "orders-123456789.us-east-2.elb.amazonaws.com"
      zone_id    = "Z3AADJGX6KTTL2"
    }
  }
  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:listener/app/orders/50dc6c495c0c9188/f2f7dc8efc522ab2"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/orders-app/73e2d6bc24d8a067"
      arn_suffix = "targetgroup/orders-app/73e2d6bc24d8a067"
    }
  }
  mock_resource "aws_security_group" {
    defaults = {
      id  = "sg-0a0000000000000a1"
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0a0000000000000a1"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/orders-mock"
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn                  = "arn:aws:ecs:us-east-2:123456789012:task-definition/orders:1"
      arn_without_revision = "arn:aws:ecs:us-east-2:123456789012:task-definition/orders"
      revision             = 1
    }
  }
  mock_resource "aws_ecs_service" {
    defaults = {
      id  = "arn:aws:ecs:us-east-2:123456789012:service/platform/orders"
      arn = "arn:aws:ecs:us-east-2:123456789012:service/platform/orders"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-2:123456789012:log-group:/aws/ecs/platform/orders"
    }
  }
}

# Distinct IDs for the two security groups, so the tests can tell which one a
# rule references.
override_resource {
  target = module.alb.module.security_group.aws_security_group.this_cbd
  values = { id = "sg-0a1b000000000a1b0" }
}

override_resource {
  target = module.service.module.security_group.aws_security_group.this
  values = { id = "sg-07a5c000000007a5c" }
}

override_module {
  target = module.vpc
  outputs = {
    vpc_id = "vpc-0a1b2c3d4e5f60718"
    subnet_ids_by_tier = {
      public  = { az1 = "subnet-0a000000000000001", az2 = "subnet-0a000000000000002" }
      private = { az1 = "subnet-0b000000000000001", az2 = "subnet-0b000000000000002" }
    }
    subnet_cidr_blocks_by_tier = {
      public  = { az1 = "10.40.0.0/24", az2 = "10.40.1.0/24" }
      private = { az1 = "10.40.16.0/20", az2 = "10.40.32.0/20" }
    }
    endpoint_security_group_id       = "sg-0e000000000000001"
    gateway_endpoint_prefix_list_ids = { s3 = "pl-7ba54012", dynamodb = "pl-4ca54025" }
    nat_gateway_public_ips           = {}
  }
}

# The golden path: a digest-pinned ECR image, an ACM certificate, and a WAF
# web ACL (which also keeps aws.modules.alb's public_without_waf check quiet).
variables {
  name        = "orders"
  cluster_arn = "arn:aws:ecs:us-east-2:123456789012:cluster/platform"

  network = {
    cidr_block         = "10.40.0.0/16"
    availability_zones = ["us-east-2a", "us-east-2b"]
  }

  container = {
    image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  }

  load_balancer = {
    certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/11111111-1111-1111-1111-111111111111"
    web_acl_arn     = "arn:aws:wafv2:us-east-2:123456789012:regional/webacl/orders/22222222-2222-2222-2222-222222222222"
  }
}

run "network_layout_is_public_alb_tier_and_private_task_tier" {
  command = plan

  assert {
    condition     = toset(keys(local.subnets)) == toset(["public", "private"])
    error_message = "The VPC has exactly two tiers: public for the ALB and private for the tasks."
  }

  assert {
    condition = local.subnets.public.availability_zones == {
      az1 = { availability_zone = "us-east-2a", newbits = 8, netnum = 0 }
      az2 = { availability_zone = "us-east-2b", newbits = 8, netnum = 1 }
    }
    error_message = "Public subnets are cidr_block + 8 bits (a /24 of a /16), netnum 0 and 1, one per zone in order."
  }

  assert {
    condition = local.subnets.private.availability_zones == {
      az1 = { availability_zone = "us-east-2a", newbits = 4, netnum = 1 }
      az2 = { availability_zone = "us-east-2b", newbits = 4, netnum = 2 }
    }
    error_message = "Private subnets are cidr_block + 4 bits (a /20 of a /16), netnum 1 and 2, clear of the public /24s in netnum 0."
  }

  assert {
    condition     = local.subnets.public.allow_default_route && local.subnets.public.routes.internet.internet_gateway
    error_message = "The public tier routes 0.0.0.0/0 to the internet gateway, which the internet-facing ALB needs."
  }

  assert {
    condition     = !local.subnets.private.allow_default_route && length(local.subnets.private.routes) == 0
    error_message = "Without nat_gateway the private tier has no default route at all: no internet path from the tasks."
  }
}

run "private_tier_reaches_aws_only_through_endpoints" {
  command = plan

  assert {
    condition     = toset(keys(local.endpoints.interface)) == toset(["ecr.api", "ecr.dkr", "logs"])
    error_message = "With no secrets and no extra services, the interface endpoints are exactly the three a Fargate task needs to start: ecr.api, ecr.dkr, logs."
  }

  assert {
    condition     = alltrue([for key, endpoint in local.endpoints.interface : endpoint.service_name == "com.amazonaws.us-east-2.${key}" && endpoint.subnet_tier == "private"])
    error_message = "Interface endpoint service names use the cluster's region and sit in the private tier."
  }

  assert {
    condition     = keys(local.endpoints.gateway) == ["s3"] && local.endpoints.gateway.s3.service_name == "com.amazonaws.us-east-2.s3" && local.endpoints.gateway.s3.route_table_tiers == ["private"]
    error_message = "The S3 gateway endpoint (ECR image layers) is attached to the private tier's route tables."
  }

  assert {
    condition     = output.interface_endpoint_services == tolist(["ecr.api", "ecr.dkr", "logs"])
    error_message = "interface_endpoint_services reports the endpoint set, sorted."
  }
}

run "task_security_group_is_alb_in_endpoints_out" {
  command = plan

  assert {
    condition     = keys(local.task_ingress_rules) == ["alb"] && local.task_ingress_rules.alb.from_port == 8080 && local.task_ingress_rules.alb.to_port == 8080
    error_message = "The tasks accept exactly one ingress rule: the container port (8080 by default) from the ALB."
  }

  assert {
    condition     = toset(keys(local.task_egress_rules)) == toset(["endpoints", "s3-gateway"])
    error_message = "Without nat_gateway, the tasks' only egress is HTTPS to the interface endpoints and to the S3 gateway endpoint."
  }

  assert {
    condition     = alltrue([for rule in values(local.task_egress_rules) : rule.from_port == 443 && rule.to_port == 443])
    error_message = "Every egress rule is HTTPS only."
  }
}

run "container_is_digest_pinned_single_app_container" {
  command = plan

  assert {
    condition     = keys(local.container_definitions) == ["app"]
    error_message = "The task has one container, named app."
  }

  assert {
    condition     = local.container_definitions.app.port_mappings == [{ name = "http", container_port = 8080, app_protocol = "http" }]
    error_message = "The container exposes the ALB's target port, named http."
  }

  assert {
    condition     = length(local.container_definitions.app.mount_points) == 0 && length(local.writable_volumes) == 0
    error_message = "No writable paths are declared by default, so the root filesystem stays entirely read-only."
  }
}

run "service_defaults_wait_for_health_and_run_two_tasks" {
  command = plan

  assert {
    condition     = var.service.desired_count == 2 && var.service.wait_for_steady_state
    error_message = "Two tasks by default (one per zone), and apply waits for them to pass health checks."
  }

  assert {
    condition     = local.autoscaling == null
    error_message = "Autoscaling is off unless service.autoscaling is set."
  }

  assert {
    condition     = var.health_check.path == "/" && var.health_check.matcher == "200-399" && var.health_check.grace_period_seconds == 60
    error_message = "The health check defaults to / with any 2xx or 3xx, after a 60-second grace period."
  }

  assert {
    condition     = var.logs.retention_in_days == 365 && var.logs.kms_key_arn == null
    error_message = "Logs are kept for a year by default."
  }
}

run "edge_defaults_are_https_with_deletion_protection" {
  command = apply

  assert {
    condition     = output.url == "https://orders-123456789.us-east-2.elb.amazonaws.com"
    error_message = "With a certificate the service is served over HTTPS at the ALB's DNS name."
  }

  assert {
    condition     = local.forwarding_listener_arn == module.alb.https_listener_arn && module.alb.http_listener_arn != null
    error_message = "With a certificate the HTTPS listener forwards and an HTTP listener exists only to redirect."
  }

  assert {
    condition     = var.load_balancer.deletion_protection && var.load_balancer.ingress_cidrs == toset(["0.0.0.0/0"])
    error_message = "The ALB is open to the internet and deletion-protected by default."
  }
}
