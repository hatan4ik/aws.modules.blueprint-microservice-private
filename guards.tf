# Plan-time guards on facts no single leaf module can see.
#
# aws.modules.ecs-service derives the account and region of its IAM trust
# policy (aws:SourceAccount, aws:SourceArn) and of its awslogs configuration
# from cluster_arn, while aws.modules.vpc and aws.modules.alb create their
# resources wherever the provider points. A cluster ARN from another account
# or region would therefore produce roles that trust the wrong account, a log
# configuration for the wrong region, and VPC endpoint service names that do
# not exist, and the failure would surface only at apply. These two reads turn
# that into a plan error. The region read also names the VPC endpoint services
# (locals.tf), since endpoints belong to the VPC's region.

data "aws_region" "current" {
  lifecycle {
    postcondition {
      condition     = self.region == local.region
      error_message = "cluster_arn is in region ${local.region} but the AWS provider targets ${self.region}. The service, its VPC, and its ALB must be in the cluster's region."
    }
  }
}

# Read only for its postcondition.
# tflint-ignore: terraform_unused_declarations
data "aws_caller_identity" "current" {
  lifecycle {
    postcondition {
      condition     = self.account_id == local.account_id
      error_message = "cluster_arn belongs to account ${local.account_id} but the AWS provider is authenticated to ${self.account_id}. ECS services cannot run on another account's cluster."
    }
  }
}
