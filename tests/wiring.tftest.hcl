# Cross-module wiring: every value that crosses from one leaf module into
# another arrives intact. Mocked applies, so ARNs and IDs are concrete.

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

run "alb_target_group_reaches_the_service_load_balancer" {
  command = apply

  assert {
    condition     = keys(local.service_load_balancers) == ["app"]
    error_message = "The service registers with exactly one target group, under the same key aws.modules.alb uses for it."
  }

  assert {
    condition     = local.service_load_balancers.app.target_group_arn == module.alb.target_group_arns["app"]
    error_message = "ecs-service's load_balancers[app].target_group_arn is exactly aws.modules.alb's target_group_arns[app], unchanged."
  }

  assert {
    condition     = output.target_group_arn == "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/orders-app/73e2d6bc24d8a067"
    error_message = "target_group_arn reports the ALB's target group."
  }

  assert {
    condition     = local.service_load_balancers.app.container_name == "app" && contains(keys(local.container_definitions), local.service_load_balancers.app.container_name)
    error_message = "The load balancer attachment names the declared container."
  }

  assert {
    condition     = local.service_load_balancers.app.container_port == 8080 && local.container_definitions.app.port_mappings[0].container_port == 8080
    error_message = "The attachment's container_port, the container's port mapping, and the target group's port are one value: container.port."
  }
}

run "service_waits_for_the_forwarding_listener" {
  command = apply

  # The target group ARN handed to ecs-service is gated on the listener ARN,
  # so Terraform orders CreateService after the listener exists.
  assert {
    condition     = local.forwarding_listener_arn == module.alb.https_listener_arn
    error_message = "With a certificate, the service's target group ARN is gated on the HTTPS listener."
  }
}

run "service_waits_for_the_http_only_listener" {
  command = apply

  variables {
    load_balancer = {
      web_acl_arn = "arn:aws:wafv2:us-east-2:123456789012:regional/webacl/orders/22222222-2222-2222-2222-222222222222"
    }
  }

  expect_failures = [check.http_only_listener]

  assert {
    condition     = local.forwarding_listener_arn == module.alb.http_listener_arn && module.alb.https_listener_arn == null
    error_message = "Without a certificate, the gate is the HTTP-only listener, the one that forwards."
  }

  assert {
    condition     = output.url == "http://orders-123456789.us-east-2.elb.amazonaws.com"
    error_message = "Without a certificate the URL is plain HTTP."
  }
}

run "task_security_group_admits_only_the_alb_security_group" {
  command = apply

  assert {
    condition     = local.task_ingress_rules.alb.referenced_security_group_id == module.alb.security_group_id
    error_message = "The tasks' only ingress source is the ALB's own security group."
  }

  assert {
    condition     = module.alb.security_group_id == "sg-0a1b000000000a1b0" && output.alb_security_group_id == "sg-0a1b000000000a1b0"
    error_message = "The ALB's security group is the group aws.modules.alb created."
  }

  assert {
    condition     = output.task_security_group_id == "sg-07a5c000000007a5c" && output.task_security_group_id != output.alb_security_group_id
    error_message = "The tasks have their own security group, created by aws.modules.ecs-service."
  }
}

run "task_egress_targets_the_vpc_endpoints" {
  command = apply

  assert {
    condition     = local.task_egress_rules.endpoints.referenced_security_group_id == "sg-0e000000000000001"
    error_message = "HTTPS egress to the interface endpoints references aws.modules.vpc's endpoint security group, not a CIDR."
  }

  assert {
    condition     = local.task_egress_rules["s3-gateway"].prefix_list_id == "pl-7ba54012"
    error_message = "HTTPS egress to S3 (ECR image layers) targets aws.modules.vpc's S3 gateway endpoint prefix list."
  }
}

run "subnets_split_between_alb_and_tasks" {
  command = apply

  assert {
    condition     = local.public_subnet_ids == toset(["subnet-0a000000000000001", "subnet-0a000000000000002"])
    error_message = "The ALB is placed in the VPC's public tier."
  }

  assert {
    condition     = local.private_subnet_ids == toset(["subnet-0b000000000000001", "subnet-0b000000000000002"])
    error_message = "The tasks run in the VPC's private tier."
  }

  assert {
    condition     = output.vpc_id == "vpc-0a1b2c3d4e5f60718"
    error_message = "Every leaf module is placed in the blueprint's VPC."
  }
}

run "service_runs_on_the_given_cluster" {
  command = apply

  assert {
    condition     = output.cluster_name == "platform"
    error_message = "The service runs on the cluster named by cluster_arn."
  }

  assert {
    condition     = output.log_group_name == "/aws/ecs/platform/orders"
    error_message = "The service's log group is /aws/ecs/<cluster>/<name>, created by aws.modules.ecs-service."
  }

  assert {
    condition     = output.service_arn == "arn:aws:ecs:us-east-2:123456789012:service/platform/orders"
    error_message = "service_arn reports the ECS service."
  }
}
