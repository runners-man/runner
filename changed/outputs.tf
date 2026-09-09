###############################################################################
# Outputs are part of the contract too, so this list is deliberately short.
# Everything here is something a consuming team actually needs for day-two
# operations; nothing here leaks a secret.
###############################################################################

output "runner_autoscaling_group_name" {
  description = "Name of the Auto Scaling group holding the Runner instance. Use it to check whether the schedule has scaled the Runner in or out."
  value       = module.gitlab_runner.runner_as_group_name
}

output "runner_instance_role_arn" {
  description = "ARN of the IAM role attached to the Runner instance. Add this as a trusted principal if a job needs to assume a role in another account."
  value       = module.gitlab_runner.runner_agent_role_arn
}

output "runner_instance_role_name" {
  description = "Name of the IAM role attached to the Runner instance."
  value       = module.gitlab_runner.runner_agent_role_name
}

output "runner_security_group_id" {
  description = "Security group attached to the Runner instance. Reference it from an internal service's ingress rules to let the Runner reach it."
  value       = module.gitlab_runner.runner_agent_sg_id
}

output "cache_bucket_name" {
  description = "S3 bucket backing the distributed build cache."
  value       = module.gitlab_runner.runner_cache_bucket_name
}

output "cache_bucket_arn" {
  description = "ARN of the S3 bucket backing the distributed build cache."
  value       = module.gitlab_runner.runner_cache_bucket_arn
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group carrying the Runner's user-data, agent and job logs. First place to look when a Runner does not come up."
  value       = "/platform/gitlab-runner/${var.name}"
}

output "auth_token_ssm_parameter_name" {
  description = "Name of the SSM SecureString holding the Runner authentication token. The value never enters Terraform state and cannot be read back from Terraform."
  value       = local.auth_token_parameter_name
}

output "runner_auth_token_expires_at" {
  description = "When the current Runner authentication token lapses, or `never`. Not a secret. A plan warns from 14 days out."
  value       = var.runner_auth_token_expires_at
}

output "runner_id" {
  description = "GitLab id of the runner this deployment is registered as. Doubles as the token rotation counter."
  value       = var.runner_auth_token_version
}

output "auth_token_mode" {
  description = "`managed` when this module creates the token parameter with a write-only argument, `external` when the parameter is provisioned outside Terraform and passed in by name."
  value       = local.manage_auth_token_parameter ? "managed" : "external"
}

output "kms_key_arn" {
  description = "ARN of the customer-managed key encrypting the token, the cache and the logs for this deployment."
  value       = local.kms_key_arn
}

output "vpc_id" {
  description = "ID of the dedicated VPC created for this Runner."
  value       = module.network.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the dedicated VPC."
  value       = module.network.vpc_cidr_block
}

output "runner_subnet_id" {
  description = "ID of the private subnet the Runner instance runs in."
  value       = module.network.subnet_ids_by_key["runner"]
}

output "schedule" {
  description = "The schedule as it was actually applied, including the derived cron expressions. Check this if the Runner is starting at an unexpected time."
  value = {
    enabled              = var.schedule.enabled
    time_zone            = var.schedule.time_zone
    scale_out_recurrence = local.scale_out_cron
    scale_in_recurrence  = local.scale_in_cron
    start_time           = var.schedule.start_time
    stop_time            = var.schedule.stop_time
    days                 = var.schedule.days
  }
}

output "session_manager_command" {
  description = "Ready-made AWS CLI command to open a Session Manager shell on the Runner host, for debugging a failed boot."
  value       = "aws ssm start-session --target $(aws ec2 describe-instances --filters 'Name=tag:Name,Values=${var.name}' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text)"
}

output "gitlab_url" {
  description = "The GitLab instance this Runner registers against."
  value       = local.gitlab_url
}

output "effective_configuration" {
  description = <<-EOT
    Every decision that actually reached the upstream module, flattened. Two uses: it tells a
    consumer what they got without reading the module source, and it is what the guardrail
    test suite asserts against so a weakened control fails CI.
  EOT
  value       = local.effective_configuration
}
