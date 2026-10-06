provider "aws" {
  region = var.region
}

# The smallest useful call: a digest-pinned image on the shared cluster,
# behind HTTPS. Everything else is the blueprint's default.
module "orders" {
  source = "../../"

  name        = "orders"
  cluster_arn = var.cluster_arn

  network = {
    cidr_block         = "10.40.0.0/16"
    availability_zones = var.availability_zones
  }

  container = {
    image = var.image
  }

  load_balancer = {
    certificate_arn = var.certificate_arn
  }
}
