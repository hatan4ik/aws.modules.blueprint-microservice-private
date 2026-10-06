# aws.modules.vpc accepts exactly the layout the blueprint builds.
#
# The other suites override module.vpc (see the comment at the top of
# tests/defaults.tftest.hcl) and assert the blueprint's local.subnets and
# local.endpoints values. This suite runs the pinned aws.modules.vpc itself, as
# terraform init downloaded it, with those same values, so its own
# validations, preconditions, and CIDR arithmetic are exercised against the
# blueprint's shape. Here the module is the root, so its always-firing
# internet_path_declared check can be named in expect_failures.
#
# Keep the variables below identical to what local.subnets and local.endpoints
# produce for the defaults fixture; tests/defaults.tftest.hcl asserts the
# blueprint side of the same values.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
}

variables {
  name                   = "orders"
  cidr_block             = "10.40.0.0/16"
  vpc_encryption_control = "monitor"

  subnets = {
    public = {
      availability_zones = {
        az1 = { availability_zone = "us-east-2a", newbits = 8, netnum = 0 }
        az2 = { availability_zone = "us-east-2b", newbits = 8, netnum = 1 }
      }
      allow_default_route = true
      routes = {
        internet = { destination_cidr_block = "0.0.0.0/0", internet_gateway = true }
      }
    }
    private = {
      availability_zones = {
        az1 = { availability_zone = "us-east-2a", newbits = 4, netnum = 1 }
        az2 = { availability_zone = "us-east-2b", newbits = 4, netnum = 2 }
      }
      allow_default_route = false
      routes              = {}
    }
  }

  internet = { nat_gateways = {} }

  endpoints = {
    interface = {
      "ecr.api" = { service_name = "com.amazonaws.us-east-2.ecr.api", subnet_tier = "private" }
      "ecr.dkr" = { service_name = "com.amazonaws.us-east-2.ecr.dkr", subnet_tier = "private" }
      "logs"    = { service_name = "com.amazonaws.us-east-2.logs", subnet_tier = "private" }
    }
    gateway = {
      s3 = { service_name = "com.amazonaws.us-east-2.s3", route_table_tiers = ["private"] }
    }
  }

  flow_logs = {
    destination = { create_kms_key = true }
  }
}

run "vpc_accepts_the_default_layout" {
  command = plan

  module {
    source = "./.terraform/modules/vpc"
  }

  expect_failures = [check.internet_path_declared]

  assert {
    condition     = output.subnet_cidr_blocks_by_tier == { public = { az1 = "10.40.0.0/24", az2 = "10.40.1.0/24" }, private = { az1 = "10.40.16.0/20", az2 = "10.40.32.0/20" } }
    error_message = "aws.modules.vpc turns the blueprint's newbits/netnum into non-overlapping /24 public and /20 private subnets."
  }

  assert {
    condition     = output.encryption_control_mode == "monitor"
    error_message = "Encryption control runs in monitor mode, the only mode compatible with the ALB's internet gateway."
  }

  assert {
    condition     = toset(keys(output.interface_endpoint_ids)) == toset(["ecr.api", "ecr.dkr", "logs"]) && toset(keys(output.gateway_endpoint_prefix_list_ids)) == toset(["s3"])
    error_message = "Every endpoint the blueprint declares is created, keyed by service suffix, which is how the blueprint looks up the S3 prefix list."
  }
}

run "vpc_accepts_the_nat_layout" {
  command = plan

  module {
    source = "./.terraform/modules/vpc"
  }

  variables {
    subnets = {
      public = {
        availability_zones = {
          az1 = { availability_zone = "us-east-2a", newbits = 8, netnum = 0 }
          az2 = { availability_zone = "us-east-2b", newbits = 8, netnum = 1 }
        }
        allow_default_route = true
        routes = {
          internet = { destination_cidr_block = "0.0.0.0/0", internet_gateway = true }
        }
      }
      private = {
        availability_zones = {
          az1 = { availability_zone = "us-east-2a", newbits = 4, netnum = 1 }
          az2 = { availability_zone = "us-east-2b", newbits = 4, netnum = 2 }
        }
        allow_default_route = true
        routes = {
          internet = { destination_cidr_block = "0.0.0.0/0", nat_gateway_key = "az1" }
        }
      }
    }
    internet = { nat_gateways = { az1 = { subnet = "public/az1" } } }
  }

  expect_failures = [check.internet_path_declared]

  assert {
    condition     = toset(keys(output.nat_gateway_ids)) == toset(["az1"])
    error_message = "The NAT layout's gateway key and subnet reference resolve inside aws.modules.vpc."
  }
}

run "vpc_accepts_three_zones_in_a_19" {
  command = plan

  module {
    source = "./.terraform/modules/vpc"
  }

  variables {
    cidr_block = "10.40.0.0/19"
    subnets = {
      public = {
        availability_zones = {
          az1 = { availability_zone = "us-east-2a", newbits = 8, netnum = 0 }
          az2 = { availability_zone = "us-east-2b", newbits = 8, netnum = 1 }
          az3 = { availability_zone = "us-east-2c", newbits = 8, netnum = 2 }
        }
        allow_default_route = true
        routes = {
          internet = { destination_cidr_block = "0.0.0.0/0", internet_gateway = true }
        }
      }
      private = {
        availability_zones = {
          az1 = { availability_zone = "us-east-2a", newbits = 4, netnum = 1 }
          az2 = { availability_zone = "us-east-2b", newbits = 4, netnum = 2 }
          az3 = { availability_zone = "us-east-2c", newbits = 4, netnum = 3 }
        }
        allow_default_route = false
        routes              = {}
      }
    }
  }

  expect_failures = [check.internet_path_declared]

  assert {
    condition     = output.subnet_cidr_blocks_by_tier == { public = { az1 = "10.40.0.0/27", az2 = "10.40.0.32/27", az3 = "10.40.0.64/27" }, private = { az1 = "10.40.2.0/23", az2 = "10.40.4.0/23", az3 = "10.40.6.0/23" } }
    error_message = "The smallest supported CIDR with three zones yields /27 public subnets (the ALB minimum) and /23 private subnets."
  }
}
