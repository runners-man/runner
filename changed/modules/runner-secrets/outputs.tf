# Everything that crosses the boundary to the runner module. Note what is not here: the token.
# An output returning it would have to be declared `ephemeral`, and ephemeral outputs cannot be
# read from state — so it could not reach another Terragrunt unit even if you wanted it to.

output "auth_token_parameter_name" {
  description = "Pass to the runner module's `auth_token_parameter_name`. Upstream builds the instance role's ssm:GetParameter grant from this exact string, so it must match."
  value       = aws_ssm_parameter.runner_auth_token.name
}

output "kms_key_arn" {
  description = "Pass to the runner module's `auth_token_kms_key_arn`. The same key encrypts the build cache and the log group."
  value       = aws_kms_key.runner.arn
}

output "runner_id" {
  description = "GitLab runner id, doubling as the rotation counter. Pass to the runner module's `runner_auth_token_version` so a rotation rolls the instance."
  value       = var.runner_auth_token_version
}

output "token_expires_at" {
  description = "When the current token lapses, or `never`."
  value       = var.runner_auth_token_expires_at
}
