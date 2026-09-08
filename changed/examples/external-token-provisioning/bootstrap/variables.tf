variable "name" {
  description = "Runner deployment name. Must match the `name` passed to the runner module — it is what makes the parameter path line up."
  type        = string
}

variable "tags" {
  description = "Tags applied to the key and role."
  type        = map(string)
  default     = {}
}

variable "gitlab_oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for your GitLab instance."
  type        = string
}

variable "gitlab_oidc_audience" {
  description = "OIDC audience, normally the GitLab hostname, e.g. gitlab.internal.example.com."
  type        = string
}

variable "provisioning_project_path" {
  description = "Full path of the GitLab project allowed to assume the provisioner role, e.g. platform/runner-bootstrap. Anything broader lets any pipeline overwrite any team's token."
  type        = string
}
