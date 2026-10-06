# IAM: the task and execution roles come from aws.modules.ecs-service's own
# modules/iam. These runs prove the blueprint feeds it exactly the declared
# secrets, keys, and statements, and that the cluster ARN it derives trust
# from is in the deploying account and region.

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

run "no_secrets_means_no_derived_execution_permissions" {
  command = apply

  assert {
    condition     = output.task_execution_role_derived_policy == null
    error_message = "With no secrets and no KMS keys, the execution role gets only AmazonECSTaskExecutionRolePolicy and no derived inline policy."
  }

  assert {
    condition     = output.task_role_arn != null && output.task_execution_role_arn != null
    error_message = "Both roles are created by aws.modules.ecs-service."
  }

  assert {
    condition     = output.task_role_name == "orders-task"
    error_message = "The task role is named <name>-task."
  }
}

run "execution_role_reads_exactly_the_declared_secrets" {
  command = apply

  variables {
    container = {
      image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      secrets = {
        DB_PASSWORD = "arn:aws:secretsmanager:us-east-2:123456789012:secret:orders/db-AbCdEf:password::"
        API_KEY     = "arn:aws:ssm:us-east-2:123456789012:parameter/orders/api-key"
      }
      secrets_kms_key_arns = ["arn:aws:kms:us-east-2:123456789012:key/33333333-3333-3333-3333-333333333333"]
    }
  }

  assert {
    condition = jsondecode(output.task_execution_role_derived_policy).Statement == [
      { Sid = "ReadDeclaredSecrets", Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = ["arn:aws:secretsmanager:us-east-2:123456789012:secret:orders/db-AbCdEf"] },
      { Sid = "ReadDeclaredParameters", Effect = "Allow", Action = ["ssm:GetParameters"], Resource = ["arn:aws:ssm:us-east-2:123456789012:parameter/orders/api-key"] },
      { Sid = "DecryptDeclaredKeys", Effect = "Allow", Action = ["kms:Decrypt"], Resource = ["arn:aws:kms:us-east-2:123456789012:key/33333333-3333-3333-3333-333333333333"] },
    ]
    error_message = "The execution role may read exactly the declared secret (reduced from its JSON-key reference), the declared parameter, and decrypt with the declared key. Nothing else."
  }

  assert {
    condition     = local.container_definitions.app.secrets == var.container.secrets
    error_message = "Secrets reach the container definition unchanged."
  }
}

run "secret_stores_get_their_endpoints" {
  command = plan

  variables {
    container = {
      image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/orders@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      secrets = {
        DB_PASSWORD = "arn:aws:secretsmanager:us-east-2:123456789012:secret:orders/db-AbCdEf"
        API_KEY     = "arn:aws:ssm:us-east-2:123456789012:parameter/orders/api-key"
      }
    }
  }

  assert {
    condition     = toset(keys(local.endpoints.interface)) == toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager", "ssm"])
    error_message = "Declaring a Secrets Manager or SSM secret adds that store's interface endpoint, so the task can fetch it at start without an internet path."
  }
}

run "task_role_statements_never_reach_the_execution_role" {
  command = apply

  variables {
    task_role_statements = {
      OrdersTable = {
        actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        resources = ["arn:aws:dynamodb:us-east-2:123456789012:table/orders"]
      }
    }
  }

  assert {
    condition     = module.service.task_role_derived_policy == null
    error_message = "The task role has no derived permissions (ECS Exec is not enabled by the blueprint)."
  }

  assert {
    condition     = output.task_execution_role_derived_policy == null
    error_message = "Task role statements never leak into the execution role."
  }
}

run "cluster_in_another_region_is_rejected_at_plan" {
  command = plan

  variables {
    cluster_arn = "arn:aws:ecs:us-west-2:123456789012:cluster/platform"
  }

  # The roles' trust policy would name us-west-2 while every other resource
  # lands in the provider's us-east-2.
  expect_failures = [data.aws_region.current]
}

run "cluster_in_another_account_is_rejected_at_plan" {
  command = plan

  variables {
    cluster_arn = "arn:aws:ecs:us-east-2:210987654321:cluster/platform"
  }

  # The roles would trust ECS tasks of another account
  # (aws:SourceAccount = 210987654321).
  expect_failures = [data.aws_caller_identity.current]
}
