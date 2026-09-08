variable "name" {
  description = "Runner deployment name. Must match the `name` given to the runner module — it is what makes the parameter path line up with the IAM grant upstream builds from it."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.name))
    error_message = "name must be 3-24 characters, lowercase alphanumeric and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Tags applied to the key and the parameters."
  type        = map(string)
  default     = {}
}

# The one variable that matters.
#
# `ephemeral` propagates across the module boundary: the caller can only assign an ephemeral
# value here because this declaration is also ephemeral. Drop the keyword and Terraform refuses
# the assignment outright — the boundary is checked, not trusted.
variable "runner_auth_token" {
  description = "GitLab Runner authentication token (glrt-...). Ephemeral: omitted from state and plan files, and it is an error to reference it anywhere that would persist it."
  type        = string
  ephemeral   = true
  sensitive   = true

  validation {
    # A shape check only, so the error message cannot leak the value.
    condition     = startswith(var.runner_auth_token, "glrt-")
    error_message = "runner_auth_token must be a GitLab Runner authentication token beginning with `glrt-`. Legacy registration tokens are not supported."
  }
}

variable "runner_auth_token_version" {
  description = "Rotation counter. Use the GitLab runner id: a database primary key, so it only ever increases and changes exactly when a new token is minted."
  type        = number

  validation {
    condition     = var.runner_auth_token_version >= 1 && floor(var.runner_auth_token_version) == var.runner_auth_token_version
    error_message = "runner_auth_token_version must be a whole number of 1 or greater."
  }
}

variable "runner_auth_token_expires_at" {
  description = "RFC3339 expiry, or `never`. Not a secret — deliberately in state and outputs so a plan can warn before the token lapses."
  type        = string
  default     = "never"

  validation {
    condition = (
      var.runner_auth_token_expires_at == "never" ||
      can(timecmp(var.runner_auth_token_expires_at, "2000-01-01T00:00:00Z"))
    )
    error_message = "runner_auth_token_expires_at must be `never` or an RFC3339 timestamp."
  }
}

variable "cloudwatch_log_group_arn_pattern" {
  description = "ARN pattern the key policy allows CloudWatch Logs to encrypt under. Leave default unless your log groups live outside this account."
  type        = string
  default     = null
}
