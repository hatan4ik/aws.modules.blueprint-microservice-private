# The private-ecr e2e variant's fixtures, credential-free. The real run
# (scripts/integration-e2e.sh --variant private-ecr) is the proof that AWS
# serves the pull through the endpoints; these runs prove the pieces fit
# before anyone pays for it:
#
#   1. tests/integration/private-ecr maps a repository prefix to ECR Public
#      and produces a private, digest-pinned image URI under it;
#   2. the blueprint, with no NAT gateway, accepts exactly that URI (the
#      digest precondition in aws.modules.ecs-service passes) and gives the
#      task no path out of the VPC except the endpoints;
#   3. tests/integration/e2e-private-ecr refuses an image that is not in a
#      private ECR registry, so the variant cannot quietly fall back to ECR
#      Public.
#
# The e2e-private-ecr root cannot be planned whole here: it runs plain HTTP
# with no WAF, whose advisory checks warn inside the nested blueprint, and
# terraform test fails a run on a nested module's check warning (see
# CONTRIBUTING.md). Run 2 plans the blueprint as the root with a certificate
# instead, and run 3 replaces the nested blueprint to test the root's own
# image validation.
#
# Shared fixture as in the other files: a mock AWS provider in us-east-2 /
# 123456789012 and aws.modules.vpc replaced by fixed outputs.

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

run "private_ecr_fixture_caches_ecr_public_under_the_run_name" {
  command = plan

  module {
    source = "./tests/integration/private-ecr"
  }

  variables {
    name = "bp-e2e-a1b2c3"
  }

  assert {
    condition     = aws_ecr_pull_through_cache_rule.ecr_public.upstream_registry_url == "public.ecr.aws" && aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix == "bp-e2e-a1b2c3"
    error_message = "The cache rule maps the run's prefix to ECR Public, which needs no upstream credentials."
  }

  assert {
    condition     = aws_ecr_repository.image.name == "bp-e2e-a1b2c3/docker/library/nginx" && aws_ecr_repository.image.force_delete
    error_message = "The fixture pre-creates the exact repository the cache fills for public.ecr.aws/docker/library/nginx, and can delete it with its image, so nothing outlives the run."
  }

  assert {
    condition     = output.image == "123456789012.dkr.ecr.us-east-2.amazonaws.com/bp-e2e-a1b2c3/docker/library/nginx@sha256:62223d644fa234c3a1cc785ee14242ec47a77364226f1c811d2f669f96dc2ac8"
    error_message = "The image is the cached path in this account and region, pinned to the linux/amd64 nginx manifest digest."
  }
}

run "blueprint_runs_the_cached_image_with_no_internet_path" {
  command = plan

  variables {
    name        = "bp-e2e-a1b2c3"
    cluster_arn = "arn:aws:ecs:us-east-2:123456789012:cluster/bp-e2e-a1b2c3"

    network = {
      cidr_block         = "10.78.0.0/16"
      availability_zones = ["us-east-2a", "us-east-2b"]
      nat_gateway        = false
    }

    container = {
      image          = run.private_ecr_fixture_caches_ecr_public_under_the_run_name.image
      port           = 80
      writable_paths = ["/var/cache/nginx", "/run", "/tmp"]
    }

    # A certificate and a web ACL keep the advisory checks quiet; the e2e
    # root's plain-HTTP ALB is not what this run is about.
    load_balancer = {
      certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/11111111-1111-1111-1111-111111111111"
      web_acl_arn     = "arn:aws:wafv2:us-east-2:123456789012:regional/webacl/orders/22222222-2222-2222-2222-222222222222"
    }
  }

  assert {
    condition     = local.container_definitions.app.image == "123456789012.dkr.ecr.us-east-2.amazonaws.com/bp-e2e-a1b2c3/docker/library/nginx@sha256:62223d644fa234c3a1cc785ee14242ec47a77364226f1c811d2f669f96dc2ac8"
    error_message = "The task runs the fixture's cached image unchanged; aws.modules.ecs-service's digest precondition accepts it."
  }

  assert {
    condition     = length(local.subnets.private.routes) == 0 && !local.subnets.private.allow_default_route
    error_message = "Without a NAT gateway the private tier has no route out of the VPC."
  }

  assert {
    condition     = toset(keys(local.endpoints.interface)) == toset(["ecr.api", "ecr.dkr", "logs"]) && toset(keys(local.endpoints.gateway)) == toset(["s3"])
    error_message = "The pull can only use the endpoints the variant tests: ecr.api, ecr.dkr, logs, and the s3 gateway."
  }

  assert {
    condition     = toset(keys(local.task_egress_rules)) == toset(["endpoints", "s3-gateway"])
    error_message = "The task's only egress is HTTPS to the interface endpoints and the s3 gateway prefix list; no internet rule."
  }
}

run "e2e_private_ecr_root_refuses_a_public_image" {
  command = plan

  module {
    source = "./tests/integration/e2e-private-ecr"
  }

  variables {
    name               = "bp-e2e-a1b2c3"
    cluster_arn        = "arn:aws:ecs:us-east-2:123456789012:cluster/bp-e2e-a1b2c3"
    availability_zones = ["us-east-2a", "us-east-2b"]
    image              = "public.ecr.aws/docker/library/nginx@sha256:62223d644fa234c3a1cc785ee14242ec47a77364226f1c811d2f669f96dc2ac8"
  }

  # Only the root's own validation is under test; the blueprint is replaced
  # so its advisory checks (plain HTTP, no WAF, internet path) stay out of it.
  override_module {
    target  = module.blueprint
    outputs = {}
  }

  expect_failures = [var.image]
}
