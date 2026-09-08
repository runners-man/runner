# Layout C, unit 2 of 2 — the Runner itself, in BYO-parameter mode.
#
# Note what crosses the state boundary: a parameter name, a key ARN, a runner id and an expiry
# date. The token cannot cross, because an output carrying it would have to be `ephemeral` and
# ephemeral outputs are not written to state for a dependency block to read. That is the
# guarantee, enforced by Terraform rather than by convention.

terraform {
  source = "git::ssh://git@gitlab.internal.example.com/platform/terraform-aws-gitlab-runner-goldenpath.git?ref=v1.0.0"
}

include "root" {
  path = find_in_parent_folders()
}

dependency "secrets" {
  config_path = "../secrets"

  # So `terragrunt plan` works on a clean stack before secrets has been applied.
  mock_outputs = {
    auth_token_parameter_name = "/platform/gitlab-runner/payments-ci/auth-token"
    kms_key_arn               = "arn:aws:kms:eu-west-2:111122223333:key/00000000-0000-0000-0000-000000000000"
    runner_id                 = 1
    token_expires_at          = "never"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

inputs = {
  name = "payments-ci"

  # BYO-parameter mode: this unit never handles the token, only its address.
  auth_token_parameter_name = dependency.secrets.outputs.auth_token_parameter_name
  auth_token_kms_key_arn    = dependency.secrets.outputs.kms_key_arn

  # Stamped into an instance tag. Upstream's ASG has instance_refresh { triggers = ["tag"] },
  # so when the secrets unit mints a new token this is what actually rolls the instance.
  runner_auth_token_version    = dependency.secrets.outputs.runner_id
  runner_auth_token_expires_at = dependency.secrets.outputs.token_expires_at

  runner_version      = "17.11.1"
  instance_type       = "m6i.xlarge"
  concurrent_jobs     = 4
  request_concurrency = 2
  default_job_image   = "registry.internal.example.com/ci/base:2026.08"
  vpc_cidr            = "10.42.0.0/22"

  schedule = {
    enabled    = true
    start_time = "07:30"
    stop_time  = "19:30"
    time_zone  = "Europe/London"
  }

  tags = {
    cost_centre = "CC-1234"
    owner       = "payments-platform"
  }
}
