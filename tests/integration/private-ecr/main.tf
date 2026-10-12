# Disposable prerequisite for the private-ecr e2e variant: a private ECR copy
# of stock nginx in the caller's own account, put there without docker.
#
#   1. A pull through cache rule maps the repository prefix <name>/ in this
#      registry to ECR Public (public.ecr.aws, which needs no credentials).
#   2. The repository the cache would create on first pull is created here
#      first, so Terraform owns it and destroys it (force_delete) with the run.
#      A repository the cache creates itself would outlive the run.
#   3. import-image.sh pulls the image once through the cache with the
#      registry HTTP API (curl, authenticated by `aws ecr
#      get-login-password`) from wherever Terraform runs, then waits until
#      ECR lists the image and every layer is available.
#
# Step 3 is why the task itself needs no pull through cache permissions: the
# first pull (ecr:BatchImportUpstreamImage, and an internet route, which AWS
# documents as possibly required for a first pull through PrivateLink) happens
# here, outside the VPC, under the caller's credentials. The task then pulls
# an ordinary cached private image through the VPC endpoints with nothing
# beyond AmazonECSTaskExecutionRolePolicy, by digest, well inside the
# 24-hour window in which ECR serves a cached image without asking upstream.
#
# Created and destroyed by scripts/integration-e2e.sh --variant private-ecr.

provider "aws" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  # Stock nginx 1.27-alpine, linux/amd64 image manifest (a child of the
  # multi-architecture index the public variant pins). Pinning the one
  # platform keeps the import to one image instead of every architecture in
  # the index. A pull through cache stores the upstream manifest unchanged,
  # so the digest is the same in both registries; import-image.sh fails if it
  # is not.
  upstream_repository = "docker/library/nginx"
  image_digest        = "sha256:62223d644fa234c3a1cc785ee14242ec47a77364226f1c811d2f669f96dc2ac8"

  registry        = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
  repository_name = "${var.name}/${local.upstream_repository}"

  tags = {
    Name            = var.name
    IntegrationTest = "aws.modules.blueprint-microservice-private"
    Disposable      = "true"
  }
}

resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = var.name
  upstream_registry_url = "public.ecr.aws"
}

resource "aws_ecr_repository" "image" {
  name         = local.repository_name
  force_delete = true

  # Pulled by digest only. A mutable tag would let the cache refresh it, which
  # this run never relies on.
  image_tag_mutability = "MUTABLE"

  tags = local.tags
}

resource "terraform_data" "import" {
  triggers_replace = [
    aws_ecr_pull_through_cache_rule.ecr_public.id,
    aws_ecr_repository.image.repository_url,
    local.image_digest,
  ]

  provisioner "local-exec" {
    command = "${path.module}/import-image.sh"

    environment = {
      AWS_REGION = data.aws_region.current.region
      REGISTRY   = local.registry
      REPOSITORY = aws_ecr_repository.image.name
      DIGEST     = local.image_digest
    }
  }
}
