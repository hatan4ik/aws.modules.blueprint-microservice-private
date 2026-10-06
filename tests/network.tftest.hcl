# Network variants: NAT egress, extra endpoints, three zones, the smallest
# CIDR, and writable paths on the read-only root filesystem.

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

run "nat_gateway_adds_a_private_default_route_and_https_egress" {
  command = plan

  variables {
    network = {
      cidr_block         = "10.40.0.0/16"
      availability_zones = ["us-east-2a", "us-east-2b"]
      nat_gateway        = true
    }
  }

  assert {
    condition     = local.subnets.private.allow_default_route && local.subnets.private.routes.internet == { destination_cidr_block = "0.0.0.0/0", nat_gateway_key = "az1" }
    error_message = "nat_gateway routes the private tier's 0.0.0.0/0 through the NAT gateway in az1."
  }

  assert {
    condition     = local.task_egress_rules.internet == { description = "HTTPS to the internet through the NAT gateway", from_port = 443, to_port = 443, cidr_ipv4 = "0.0.0.0/0" }
    error_message = "nat_gateway opens HTTPS, and only HTTPS, to the internet from the tasks."
  }

  assert {
    condition     = toset(keys(local.endpoints.interface)) == toset(["ecr.api", "ecr.dkr", "logs"])
    error_message = "The VPC endpoints stay with a NAT gateway: image pulls and logs never cross it."
  }
}

run "application_endpoints_open_matching_egress" {
  command = plan

  variables {
    network = {
      cidr_block                  = "10.40.0.0/16"
      availability_zones          = ["us-east-2a", "us-east-2b"]
      interface_endpoint_services = ["sqs", "kms"]
      gateway_endpoint_services   = ["dynamodb"]
    }
  }

  assert {
    condition     = toset(keys(local.endpoints.interface)) == toset(["ecr.api", "ecr.dkr", "logs", "sqs", "kms"])
    error_message = "Application interface endpoints are added to the platform set."
  }

  assert {
    condition     = toset(keys(local.endpoints.gateway)) == toset(["s3", "dynamodb"])
    error_message = "The DynamoDB gateway endpoint is added beside S3."
  }

  assert {
    condition     = toset(keys(local.task_egress_rules)) == toset(["endpoints", "s3-gateway", "dynamodb-gateway"])
    error_message = "Each gateway endpoint gets its own HTTPS egress rule; interface endpoints share the endpoint security group rule."
  }
}

run "dynamodb_gateway_egress_targets_its_prefix_list" {
  command = apply

  variables {
    network = {
      cidr_block                = "10.40.0.0/16"
      availability_zones        = ["us-east-2a", "us-east-2b"]
      gateway_endpoint_services = ["dynamodb"]
    }
  }

  assert {
    condition     = local.task_egress_rules["dynamodb-gateway"].prefix_list_id == "pl-4ca54025"
    error_message = "HTTPS egress to DynamoDB targets aws.modules.vpc's DynamoDB gateway prefix list."
  }
}

run "three_zones_and_the_smallest_cidr_do_not_overlap" {
  command = plan

  variables {
    network = {
      cidr_block         = "10.40.0.0/19"
      availability_zones = ["us-east-2a", "us-east-2b", "us-east-2c"]
    }
  }

  assert {
    condition     = keys(local.subnets.public.availability_zones) == ["az1", "az2", "az3"] && keys(local.subnets.private.availability_zones) == ["az1", "az2", "az3"]
    error_message = "Three zones give three subnets per tier, keyed az1..az3."
  }

  assert {
    condition     = [for zone in values(local.subnets.public.availability_zones) : cidrsubnet(var.network.cidr_block, zone.newbits, zone.netnum)] == ["10.40.0.0/27", "10.40.0.32/27", "10.40.0.64/27"] && [for zone in values(local.subnets.private.availability_zones) : cidrsubnet(var.network.cidr_block, zone.newbits, zone.netnum)] == ["10.40.2.0/23", "10.40.4.0/23", "10.40.6.0/23"]
    error_message = "A /19 yields /27 public subnets (the ALB minimum) inside the first /23 and /23 private subnets after it, with no overlap."
  }
}

run "writable_paths_become_ephemeral_volumes" {
  command = plan

  variables {
    container = {
      image          = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      writable_paths = ["/tmp", "/var/cache/app"]
    }
  }

  assert {
    condition     = local.writable_volumes == { "rw-tmp" = "/tmp", "rw-var-cache-app" = "/var/cache/app" }
    error_message = "Each writable path becomes one volume named after the path."
  }

  assert {
    condition     = toset(local.container_definitions.app.mount_points) == toset([{ source_volume = "rw-tmp", container_path = "/tmp" }, { source_volume = "rw-var-cache-app", container_path = "/var/cache/app" }])
    error_message = "The container mounts each volume at its path; the rest of the root filesystem stays read-only."
  }
}

run "autoscaling_tracks_cpu" {
  command = plan

  variables {
    service = {
      desired_count = 3
      autoscaling   = { min_capacity = 2, max_capacity = 10 }
    }
  }

  assert {
    condition     = local.autoscaling.min_capacity == 2 && local.autoscaling.max_capacity == 10 && local.autoscaling.policies.cpu.target_tracking.predefined_metric_type == "ECSServiceAverageCPUUtilization" && local.autoscaling.policies.cpu.target_tracking.target_value == 60
    error_message = "Autoscaling tracks average CPU at 60 percent between the given bounds."
  }
}
