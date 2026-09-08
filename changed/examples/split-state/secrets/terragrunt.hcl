# Layout C, unit 1 of 2 — the KMS key and the token parameter.
#
# This is the only unit that declares `runner_auth_token`. The token arrives as
# TF_VAR_runner_auth_token from `bin/gitlab-runner-token`, reaches `value_wo`, and stops.
# Nothing it outputs is a secret.

terraform {
  source = "git::ssh://git@gitlab.internal.example.com/platform/terraform-aws-gitlab-runner-goldenpath.git//modules/runner-secrets?ref=v1.0.0"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  name = "payments-ci"

  tags = {
    cost_centre = "CC-1234"
    owner       = "payments-platform"
  }

  # runner_auth_token, runner_auth_token_version and runner_auth_token_expires_at all come from
  # the environment. Do NOT put them here — a Terragrunt input is a file on disk.
}
