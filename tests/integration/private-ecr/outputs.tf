output "image" {
  description = "The private, digest-pinned image URI the e2e-private-ecr root runs, available once the import has completed."
  value       = "${local.registry}/${local.repository_name}@${local.image_digest}"

  depends_on = [terraform_data.import]
}

output "repository_name" {
  description = "The cache repository holding the imported image."
  value       = aws_ecr_repository.image.name
}
