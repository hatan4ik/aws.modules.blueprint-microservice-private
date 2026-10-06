provider "aws" {
  region = var.region
}

# A realistic private microservice: an orders API that reads a database
# password from Secrets Manager, publishes to an SQS queue, reads and writes a
# DynamoDB table, needs a writable /tmp, and scales on CPU. No NAT gateway:
# every AWS call goes through a VPC endpoint the blueprint creates.
module "orders" {
  source = "../../"

  name        = "orders-api"
  cluster_arn = var.cluster_arn

  network = {
    cidr_block                  = "10.40.0.0/16"
    availability_zones          = var.availability_zones
    interface_endpoint_services = ["sqs"]
    gateway_endpoint_services   = ["dynamodb"]
  }

  container = {
    image  = var.image
    port   = 8080
    cpu    = 512
    memory = 1024

    environment = {
      ORDERS_TABLE = split("/", var.orders_table_arn)[1]
      EVENTS_QUEUE = var.events_queue_url
    }

    # The execution role is granted exactly this secret (and the key below);
    # the blueprint adds the secretsmanager endpoint because it is declared.
    secrets = {
      DB_PASSWORD = var.db_password_secret_arn
    }
    secrets_kms_key_arns = [var.secrets_kms_key_arn]

    writable_paths = ["/tmp"]
  }

  # What the application itself may do with AWS. Nothing else is granted.
  task_role_statements = {
    OrdersTable = {
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
      resources = [var.orders_table_arn, "${var.orders_table_arn}/index/*"]
    }
    PublishEvents = {
      actions   = ["sqs:SendMessage"]
      resources = [var.events_queue_arn]
    }
  }

  service = {
    desired_count = 2
    autoscaling = {
      min_capacity       = 2
      max_capacity       = 8
      cpu_target_percent = 60
    }
  }

  health_check = {
    path                 = "/healthz"
    matcher              = "200"
    grace_period_seconds = 90
  }

  load_balancer = {
    certificate_arn    = var.certificate_arn
    web_acl_arn        = var.web_acl_arn
    access_logs_bucket = var.access_logs_bucket
  }

  # The platform's shared key. Its policy must already admit CloudWatch Logs
  # for /aws/ecs/<cluster>/orders-api (aws.modules.ecs:
  # additional_cloudwatch_log_group_arns), or the log group cannot be created.
  logs = {
    retention_in_days = 90
    kms_key_arn       = var.logs_kms_key_arn
  }

  tags = {
    Service     = "orders-api"
    Environment = "dev"
    Owner       = "orders-team"
  }
}
