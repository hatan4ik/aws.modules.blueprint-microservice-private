variable "name" {
  description = "Unique run name from the setup root; the pull through cache rule's repository prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*$", var.name)) && length(var.name) >= 2 && length(var.name) <= 30
    error_message = "name must be a valid ECR pull through cache prefix: 2-30 lowercase alphanumerics separated by single ., _ or -."
  }
}
