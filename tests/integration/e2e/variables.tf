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
