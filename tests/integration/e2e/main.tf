# The blueprint applied for real, as a caller would, with the three settings a
# disposable run needs: no certificate (plain HTTP), no deletion protection,
# and a NAT gateway because the image comes from ECR Public, which private ECR
# endpoints do not serve.
#
# This is a plain root applied by scripts/integration-e2e.sh rather than a
# terraform test suite: aws.modules.vpc's internet_path_declared check always
# warns for this blueprint, and terraform test fails any run on a nested
# module's check warning (see CONTRIBUTING.md).

provider "aws" {}

module "blueprint" {
  source = "../../../"

  name        = var.name
  cluster_arn = var.cluster_arn

  network = {
    cidr_block         = "10.77.0.0/16"
    availability_zones = var.availability_zones
    nat_gateway        = true
  }

  # Stock nginx, pinned by digest, on the read-only root filesystem: it needs
  # its cache, run, and temp directories writable, and nothing else.
  container = {
    image          = "public.ecr.aws/docker/library/nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10" # 1.27-alpine
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
