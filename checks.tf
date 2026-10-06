# Advisory checks: they warn on every plan and apply but never block. Each
# names a composition that is valid yet usually unintended. The leaf modules
# add their own (for example aws.modules.alb's public_without_waf and
# aws.modules.vpc's internet_path_declared).

check "http_only_listener" {
  assert {
    condition     = var.load_balancer.certificate_arn != null
    error_message = "load_balancer.certificate_arn is null, so the ALB serves plain HTTP on port 80 and traffic between clients and the service is unencrypted. Supply an ACM certificate for anything but a disposable environment."
  }
}
