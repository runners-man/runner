###############################################################################
# Runner stack — the part that goes inside your much larger stack.
#
# The only thing that crosses the boundary from bootstrap is a *name* and a *key ARN*. Grep
# this whole directory for anything that could hold a token value: there is nothing. No
# `data "aws_ssm_parameter"`, no `aws_ssm_parameter` resource, no `external` data source
# returning a secret, no `gitlab_user_runner` resource.
###############################################################################

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "gitlab-runner/${var.name}/bootstrap.tfstate"
    region = var.aws_region
  }
}

module "gitlab_runner" {
  source  = "app.terraform.io/example/gitlab-runner-goldenpath/aws"
  version = "~> 1.0"

  name = var.name
  tags = {
    cost_centre = "CC-1234"
    owner       = "payments-platform"
  }

  # BYO-parameter mode. `runner_auth_token` is not set — the module's own validation enforces
  # that exactly one of the two is present, so there is no way to end up half in each mode.
  auth_token_parameter_name = data.terraform_remote_state.bootstrap.outputs.auth_token_parameter_name
  auth_token_kms_key_arn    = data.terraform_remote_state.bootstrap.outputs.auth_token_kms_key_arn

  # Still meaningful in BYO mode: it is stamped into an instance tag, and upstream's ASG
  # refreshes on tag change. This is the *only* signal Terraform has that the token behind the
  # parameter changed, because nothing in this stack can see the value. Bump it in the same
  # commit as a rotation, or the running instance keeps the old token until something else
  # replaces it.
  runner_auth_token_version = var.runner_auth_token_version

  runner_version      = "17.11.1"
  instance_type       = "m6i.xlarge"
  concurrent_jobs     = 4
  request_concurrency = 2

  default_job_image = "registry.internal.example.com/ci/base:2026.08"
  vpc_cidr          = "10.42.0.0/22"

  schedule = {
    enabled    = true
    start_time = "07:30"
    stop_time  = "19:30"
    time_zone  = "Europe/London"
  }
}

###############################################################################
# The gap this design has that the managed mode does not: nothing in Terraform
# guarantees the parameter exists before the instance boots and runs
# `aws ssm get-parameter`. Upstream's user data does `exit 1` if it comes back
# empty, so the failure is a runner that silently never registers, with the only
# evidence in CloudWatch.
#
# A `check` block turns that into a plan-time warning. It uses
# `describe-parameters`, which returns metadata only — deliberately not
# `data "aws_ssm_parameter"`, whose `value` lands in state (plaintext with
# decryption on, KMS ciphertext with it off; neither belongs there).
#
# Cost: the AWS CLI and credentials must be present wherever `terraform plan`
# runs. If that is not true for you, drop this and rely on the pipeline ordering
# instead — a check that cannot run is worse than no check.
###############################################################################
check "token_parameter_exists" {
  data "external" "token_parameter" {
    program = ["bash", "-c", <<-EOT
      set -euo pipefail
      n=$(aws ssm describe-parameters \
            --parameter-filters "Key=Name,Values=${data.terraform_remote_state.bootstrap.outputs.auth_token_parameter_name}" \
            --query 'length(Parameters)' --output text)
      printf '{"found":"%s"}' "$n"
    EOT
    ]
  }

  assert {
    condition     = data.external.token_parameter.result.found == "1"
    error_message = "The Runner authentication token parameter does not exist yet. Run scripts/provision-runner-token.sh before applying this stack, or the instance will boot, fail to read the token, and exit 1 in user data."
  }
}
