# Glue: every value here translates one leaf module's output (or a blueprint
# input) into the exact shape another leaf module's input expects. No AWS
# resource is declared in this repository; see main.tf for the module calls.

locals {
  # arn:<partition>:ecs:<region>:<account>:cluster/<name>. aws.modules.ecs-service
  # derives its trust policy and log configuration from these two fields;
  # guards.tf fails the plan unless they match the provider's.
  cluster_arn_parts = split(":", var.cluster_arn)
  region            = local.cluster_arn_parts[3]
  account_id        = local.cluster_arn_parts[4]

  # ------------------------------------------------------------------ VPC

  # Stable AZ keys (az1, az2, az3) name subnets and route tables in
  # aws.modules.vpc; zone names only appear as values.
  availability_zones = { for index, zone in var.network.availability_zones : "az${index + 1}" => zone }

  # Public /24s (for a /16) occupy the first 1/16 of the VPC; private /20s
  # take netnum 1..3 of the 4-bit split, so the two tiers never overlap for
  # any /16 to /19 block. Same layout as aws.modules.vpc's three-tier-nat
  # example, minus the data tier.
  subnets = {
    public = {
      availability_zones = {
        for index, key in keys(local.availability_zones) : key => {
          availability_zone = local.availability_zones[key]
          newbits           = 8
          netnum            = index
        }
      }
      allow_default_route = true
      routes = {
        internet = { destination_cidr_block = "0.0.0.0/0", internet_gateway = true }
      }
    }

    private = {
      availability_zones = {
        for index, key in keys(local.availability_zones) : key => {
          availability_zone = local.availability_zones[key]
          newbits           = 4
          netnum            = index + 1
        }
      }
      # No default route unless a NAT gateway is declared: the tier's only
      # paths out are the VPC endpoints below.
      allow_default_route = var.network.nat_gateway
      routes = var.network.nat_gateway ? {
        internet = { destination_cidr_block = "0.0.0.0/0", nat_gateway_key = "az1" }
      } : {}
    }
  }

  # Endpoints a Fargate task needs to start with no internet path: image
  # manifest and auth (ecr.api, ecr.dkr), image layers (s3, gateway), and the
  # awslogs driver (logs). Secret stores are added only when the container
  # references them, then whatever the application declares.
  secret_services = toset([for arn in values(var.container.secrets) : split(":", arn)[2]])

  interface_endpoint_services = setunion(
    ["ecr.api", "ecr.dkr", "logs"],
    local.secret_services,
    var.network.interface_endpoint_services,
  )
  gateway_endpoint_services = setunion(["s3"], var.network.gateway_endpoint_services)

  endpoints = {
    interface = {
      for service in local.interface_endpoint_services : service => {
        service_name = "com.amazonaws.${data.aws_region.current.region}.${service}"
        subnet_tier  = "private"
      }
    }
    gateway = {
      for service in local.gateway_endpoint_services : service => {
        service_name      = "com.amazonaws.${data.aws_region.current.region}.${service}"
        route_table_tiers = ["private"]
      }
    }
  }

  public_subnet_ids  = toset(values(module.vpc.subnet_ids_by_tier["public"]))
  private_subnet_ids = toset(values(module.vpc.subnet_ids_by_tier["private"]))

  # ------------------------------------------------------------------ ALB

  target_group_key = "app"
  container_name   = "app"

  # The listener that forwards to the target group: HTTPS when a certificate
  # is given, otherwise the HTTP-only listener.
  forwarding_listener_arn = var.load_balancer.certificate_arn != null ? module.alb.https_listener_arn : module.alb.http_listener_arn

  # ECS rejects CreateService when the target group is not yet attached to a
  # load balancer ("target group ... does not have an associated load
  # balancer"). The target group and the listener are separate resources in
  # aws.modules.alb, and target_group_arns depends only on the former, so
  # passing it straight through lets Terraform create the service in parallel
  # with the listener. Routing the ARN through the listener's ARN makes the
  # service (and only the service) wait for the listener. A module-wide
  # depends_on = [module.alb] would also work, but it would hold back the
  # roles, log group, and task definition behind the ALB's multi-minute
  # creation for no reason, and it hides the actual dependency.
  target_group_arn = local.forwarding_listener_arn == null ? null : module.alb.target_group_arns[local.target_group_key]

  # Exactly the load_balancers entry aws.modules.ecs-service expects.
  service_load_balancers = {
    (local.target_group_key) = {
      target_group_arn = local.target_group_arn
      container_name   = local.container_name
      container_port   = var.container.port
    }
  }

  # -------------------------------------------------------------- service

  # One ephemeral bind-mount volume per writable path, named from the path
  # (/tmp -> rw-tmp, /var/cache/app -> rw-var-cache-app).
  writable_volumes = {
    for path in var.container.writable_paths : "rw-${replace(trimprefix(path, "/"), "/[^A-Za-z0-9_-]/", "-")}" => path
  }

  container_definitions = {
    (local.container_name) = {
      image         = var.container.image
      command       = var.container.command
      environment   = var.container.environment
      secrets       = var.container.secrets
      port_mappings = [{ name = "http", container_port = var.container.port, app_protocol = "http" }]
      mount_points = [
        for volume, path in local.writable_volumes : { source_volume = volume, container_path = path }
      ]
    }
  }

  # Task security group. Ingress: only the ALB, only on the container port.
  # Egress: HTTPS to the interface endpoints' security group and to each
  # gateway endpoint's prefix list, plus the internet when a NAT gateway
  # exists. DNS needs no rule: security groups do not filter the VPC resolver.
  task_ingress_rules = {
    alb = {
      description                  = "Container port from the ${var.name} ALB only"
      from_port                    = var.container.port
      to_port                      = var.container.port
      referenced_security_group_id = module.alb.security_group_id
    }
  }

  task_egress_rules = merge(
    {
      endpoints = {
        description                  = "HTTPS to the VPC interface endpoints"
        from_port                    = 443
        to_port                      = 443
        referenced_security_group_id = module.vpc.endpoint_security_group_id
      }
    },
    {
      for service in local.gateway_endpoint_services : "${service}-gateway" => {
        description    = "HTTPS to the ${service} gateway endpoint"
        from_port      = 443
        to_port        = 443
        prefix_list_id = module.vpc.gateway_endpoint_prefix_list_ids[service]
      }
    },
    var.network.nat_gateway ? {
      internet = {
        description = "HTTPS to the internet through the NAT gateway"
        from_port   = 443
        to_port     = 443
        cidr_ipv4   = "0.0.0.0/0"
      }
    } : {},
  )

  autoscaling = var.service.autoscaling == null ? null : {
    min_capacity = var.service.autoscaling.min_capacity
    max_capacity = var.service.autoscaling.max_capacity
    policies = {
      cpu = {
        target_tracking = {
          predefined_metric_type = "ECSServiceAverageCPUUtilization"
          target_value           = var.service.autoscaling.cpu_target_percent
        }
      }
    }
  }
}
