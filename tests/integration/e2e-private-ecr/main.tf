# The private-ECR variant of the e2e run: the path this blueprint exists for.
# No NAT gateway, so the private subnets have no route out of the VPC, and the
# image is a private ECR image in this account (put there by the private-ecr
# fixture root through a pull through cache). Pulling it exercises every
# endpoint the blueprint creates and the 2.0.0 endpoint policies:
#
#   - ecr.api, ecr.dkr: authorization token and manifest, signed by the
#     execution role (policy: aws:PrincipalAccount is this account);
#   - s3 gateway: layer download from prod-<region>-starport-layer-bucket
#     with URLs ECR signs (policy: unconditioned s3:GetObject on that bucket);
#   - logs: the awslogs driver (policy: aws:PrincipalAccount).
#
# A denial on any of them leaves the task in CannotPullContainerError or
# ResourceInitializationError, the apply times out waiting for steady state,
# and scripts/integration-e2e.sh prints the stopped tasks' reasons.
#
# Plain HTTP and no deletion protection, as in the e2e root: the ALB path is
# not what this variant tests. A plain root rather than a terraform test
# suite for the same reason as e2e (see that root's comment).

provider "aws" {}

module "blueprint" {
  source = "../../../"

  name        = var.name
  cluster_arn = var.cluster_arn

  network = {
    cidr_block         = "10.78.0.0/16"
    availability_zones = var.availability_zones
    nat_gateway        = false
  }

  # Stock nginx (linux/amd64), pinned by digest, from the private cache
  # repository; the same writable paths as the e2e root.
  container = {
    image          = var.image
    port           = 80
    writable_paths = ["/var/cache/nginx", "/run", "/tmp"]
  }

  service = {
    desired_count = 1
  }

  health_check = {
    path    = "/"
    matcher = "200"
  }

  load_balancer = {
    allow_plain_http    = true
    deletion_protection = false
  }

  logs = {
    retention_in_days = 1
  }

  tags = {
    IntegrationTest = "aws.modules.blueprint-microservice-private"
    Disposable      = "true"
  }
}
