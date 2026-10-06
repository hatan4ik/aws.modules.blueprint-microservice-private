# Every blueprint input validation fails at plan with expect_failures, and
# the advisory check fires only when it should. Validations the leaf modules
# already own (digest-pinned image, Fargate cpu/memory pairs) are covered by
# their own suites; a run here cannot name a nested module's precondition.

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

run "rejects_name_too_long_for_the_target_group" {
  command = plan

  variables {
    name = "orders-service-with-a-long-nm"
  }

  expect_failures = [var.name]
}

run "rejects_name_starting_with_a_digit" {
  command = plan

  variables {
    name = "9orders"
  }

  expect_failures = [var.name]
}

run "rejects_cluster_arn_not_an_ecs_cluster" {
  command = plan

  variables {
    cluster_arn = "arn:aws:ecs:us-east-2:123456789012:service/platform/orders"
  }

  expect_failures = [var.cluster_arn]
}

run "rejects_cidr_too_small_for_alb_subnets" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/20", availability_zones = ["us-east-2a", "us-east-2b"] }
  }

  expect_failures = [var.network]
}

run "rejects_cidr_not_a_cidr" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0", availability_zones = ["us-east-2a", "us-east-2b"] }
  }

  expect_failures = [var.network]
}

run "rejects_single_availability_zone" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/16", availability_zones = ["us-east-2a"] }
  }

  expect_failures = [var.network]
}

run "rejects_duplicate_availability_zones" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/16", availability_zones = ["us-east-2a", "us-east-2a"] }
  }

  expect_failures = [var.network]
}

run "rejects_four_availability_zones" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/16", availability_zones = ["us-east-2a", "us-east-2b", "us-east-2c", "us-east-2d"] }
  }

  expect_failures = [var.network]
}

run "rejects_availability_zone_id_instead_of_name" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/16", availability_zones = ["use2-az1", "use2-az2"] }
  }

  expect_failures = [var.network]
}

run "rejects_full_endpoint_service_name" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/16", availability_zones = ["us-east-2a", "us-east-2b"], interface_endpoint_services = ["com.amazonaws.us-east-2.sqs"] }
  }

  expect_failures = [var.network]
}

run "rejects_s3_as_interface_endpoint" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/16", availability_zones = ["us-east-2a", "us-east-2b"], interface_endpoint_services = ["s3"] }
  }

  expect_failures = [var.network]
}

run "rejects_unknown_gateway_endpoint" {
  command = plan

  variables {
    network = { cidr_block = "10.40.0.0/16", availability_zones = ["us-east-2a", "us-east-2b"], gateway_endpoint_services = ["sqs"] }
  }

  expect_failures = [var.network]
}

run "rejects_container_port_out_of_range" {
  command = plan

  variables {
    container = { image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", port = 70000 }
  }

  expect_failures = [var.container]
}

run "rejects_secret_that_is_not_an_arn" {
  command = plan

  variables {
    container = { image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", secrets = { DB_PASSWORD = "orders/db" } }
  }

  expect_failures = [var.container]
}

run "rejects_secret_kms_key_alias_instead_of_key" {
  command = plan

  variables {
    container = { image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", secrets_kms_key_arns = ["arn:aws:kms:us-east-2:123456789012:alias/orders"] }
  }

  expect_failures = [var.container]
}

run "rejects_relative_writable_path" {
  command = plan

  variables {
    container = { image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", writable_paths = ["tmp"] }
  }

  expect_failures = [var.container]
}

run "rejects_trailing_slash_writable_path" {
  command = plan

  variables {
    container = { image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", writable_paths = ["/tmp/"] }
  }

  expect_failures = [var.container]
}

run "rejects_unknown_cpu_architecture" {
  command = plan

  variables {
    container = { image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", cpu_architecture = "AMD64" }
  }

  expect_failures = [var.container]
}

run "rejects_non_alphanumeric_sid" {
  command = plan

  variables {
    task_role_statements = { "orders-table" = { actions = ["dynamodb:GetItem"], resources = ["arn:aws:dynamodb:us-east-2:123456789012:table/orders"] } }
  }

  expect_failures = [var.task_role_statements]
}

run "rejects_wildcard_action_allow" {
  command = plan

  variables {
    task_role_statements = { Everything = { actions = ["*"], resources = ["arn:aws:dynamodb:us-east-2:123456789012:table/orders"] } }
  }

  expect_failures = [var.task_role_statements]
}

run "rejects_wildcard_resource_allow" {
  command = plan

  variables {
    task_role_statements = { AnyTable = { actions = ["dynamodb:GetItem"], resources = ["*"] } }
  }

  expect_failures = [var.task_role_statements]
}

run "rejects_zero_desired_count" {
  command = plan

  variables {
    service = { desired_count = 0 }
  }

  expect_failures = [var.service]
}

run "rejects_desired_count_outside_autoscaling_range" {
  command = plan

  variables {
    service = { desired_count = 1, autoscaling = { min_capacity = 2, max_capacity = 4 } }
  }

  expect_failures = [var.service]
}

run "rejects_autoscaling_max_below_min" {
  command = plan

  variables {
    service = { desired_count = 2, autoscaling = { min_capacity = 2, max_capacity = 1 } }
  }

  expect_failures = [var.service]
}

run "rejects_autoscaling_target_over_100" {
  command = plan

  variables {
    service = { desired_count = 2, autoscaling = { min_capacity = 2, max_capacity = 4, cpu_target_percent = 150 } }
  }

  expect_failures = [var.service]
}

run "rejects_relative_health_check_path" {
  command = plan

  variables {
    health_check = { path = "healthz" }
  }

  expect_failures = [var.health_check]
}

run "rejects_bad_health_check_matcher" {
  command = plan

  variables {
    health_check = { matcher = "2xx" }
  }

  expect_failures = [var.health_check]
}

run "rejects_negative_grace_period" {
  command = plan

  variables {
    health_check = { grace_period_seconds = -1 }
  }

  expect_failures = [var.health_check]
}

run "rejects_certificate_that_is_not_acm" {
  command = plan

  variables {
    load_balancer = { certificate_arn = "arn:aws:iam::123456789012:server-certificate/orders" }
  }

  expect_failures = [var.load_balancer]
}

run "rejects_empty_ingress_cidrs" {
  command = plan

  variables {
    load_balancer = { certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/11111111-1111-1111-1111-111111111111", ingress_cidrs = [] }
  }

  expect_failures = [var.load_balancer]
}

run "rejects_access_logs_bucket_arn" {
  command = plan

  variables {
    load_balancer = { certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/11111111-1111-1111-1111-111111111111", access_logs_bucket = "arn:aws:s3:::orders-logs" }
  }

  expect_failures = [var.load_balancer]
}

run "rejects_never_expiring_logs" {
  command = plan

  variables {
    logs = { retention_in_days = 0 }
  }

  expect_failures = [var.logs]
}

run "rejects_log_key_alias" {
  command = plan

  variables {
    logs = { kms_key_arn = "alias/orders" }
  }

  expect_failures = [var.logs]
}

run "accepts_a_deny_statement_with_wildcards" {
  command = plan

  variables {
    task_role_statements = {
      DenyDeletes = { effect = "Deny", actions = ["dynamodb:DeleteTable"], resources = ["*"] }
    }
  }
}

run "warns_when_serving_plain_http" {
  command = plan

  variables {
    load_balancer = {
      web_acl_arn = "arn:aws:wafv2:us-east-2:123456789012:regional/webacl/orders/22222222-2222-2222-2222-222222222222"
    }
  }

  expect_failures = [check.http_only_listener]
}

