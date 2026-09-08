output "auth_token_parameter_name" {
  description = "Name the provisioning script must write to, and the value to pass to the runner module's `auth_token_parameter_name`. A name, not a value — nothing secret crosses this boundary."
  value       = local.parameter_name
}

output "auth_token_kms_key_arn" {
  description = "Pass to the runner module's `auth_token_kms_key_arn` so the instance role is granted kms:Decrypt."
  value       = aws_kms_key.token.arn
}

output "provisioner_role_arn" {
  description = "Role the provisioning CI job assumes."
  value       = aws_iam_role.provisioner.arn
}
