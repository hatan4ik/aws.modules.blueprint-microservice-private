variable "name" {
  description = "Unique service name from the setup root."
  type        = string
}

variable "cluster_arn" {
  description = "Disposable cluster ARN from the setup root."
  type        = string
}

variable "availability_zones" {
  description = "Two zones from the setup root."
  type        = list(string)
}

variable "image" {
  description = "Digest-pinned private ECR image from the private-ecr root."
  type        = string

  # The variant proves nothing if the image is not in a private ECR registry:
  # anything else (ECR Public, Docker Hub) would not be reachable without NAT
  # in the first place, or would bypass the ECR endpoints being tested.
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be a private ECR image pinned by digest (<account>.dkr.ecr.<region>.amazonaws.com/<repository>@sha256:<64 hex>)."
  }
}
