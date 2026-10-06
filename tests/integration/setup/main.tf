# Disposable prerequisite for the e2e suite: the shared ECS cluster the
# blueprint deliberately does not create, plus a unique name and two zones.
# Created and destroyed by scripts/integration-e2e.sh in the caller's own
# account; nothing here is shared or long-lived.

provider "aws" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name = "bp-e2e-${random_id.suffix.hex}"
}

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name            = local.name
    IntegrationTest = "aws.modules.blueprint-microservice-private"
    Disposable      = "true"
  }
}
