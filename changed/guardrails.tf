###############################################################################
# Runtime assertions.
#
# `validation` blocks in variables.tf can only see variables. These preconditions
# can see data sources and locals, which is where the checks that actually matter
# live: the real architecture of the chosen instance type, the real architecture
# of the published AMI, and whether anyone has quietly weakened platform.tf.
#
# All of these fail at plan time, before anything is created.
###############################################################################

locals {
  # A flattened projection of every decision that actually reaches the child module.
  #
  # This exists so the guardrails are *testable*: `terraform test` cannot assert on a child
  # module's inputs or on locals, but it can assert on an output. tests/defaults.tftest.hcl
  # asserts against this, so a change that quietly re-enables Spot or docker+machine fails CI
  # rather than shipping.
  effective_configuration = {
    executor_type        = local.executor_type
    spot_price           = local.spot_price
    ami_id               = nonsensitive(data.aws_ssm_parameter.runner_ami_id.value)
    instance_type        = var.instance_type
    private_address_only = local.private_address_only
    use_eip              = local.use_eip
    imds_http_tokens     = local.metadata_options.http_tokens
    privileged           = var.job_privileged_mode
    docker_volumes       = local.docker_volumes
    allowed_images       = local.allowed_images
    helper_image         = local.helper_image
    default_job_image    = var.default_job_image
    internal_registry    = local.internal_registry
    scale_out_recurrence = local.scale_out_cron
    scale_in_recurrence  = local.scale_in_cron
    schedule_enabled     = var.schedule.enabled
    concurrent_jobs      = var.concurrent_jobs
    request_concurrency  = var.request_concurrency
    runner_version       = var.runner_version
    gitlab_url           = local.gitlab_url
    subnet_cidrs         = { for k, v in local.subnet_layout : k => v.cidr_block }
    job_env              = local.job_environment_variables
    docker_gc            = local.docker_gc
    max_lifetime_seconds = local.instance_max_lifetime_seconds
    root_volume_size_gb  = var.root_volume_size_gb

    # Never the token itself — only how it is delivered and where it lives. Both of these are
    # safe to render in a plan; the value behind them is not, and never appears here.
    auth_token_mode           = local.manage_auth_token_parameter ? "managed" : "external"
    auth_token_parameter_name = local.auth_token_parameter_name
  }
}

resource "terraform_data" "guardrails" {
  # Re-evaluated whenever any of this changes, so a later apply cannot drift past the checks.
  input = local.effective_configuration

  lifecycle {
    precondition {
      condition     = contains(data.aws_ec2_instance_type.runner.supported_architectures, "x86_64")
      error_message = "instance_type ${var.instance_type} does not support the x86_64 architecture. The platform AMI is AMD64-only; Graviton instance types cannot boot it."
    }

    precondition {
      condition     = data.aws_ami.runner.architecture == "x86_64"
      error_message = "The AMI published at ${local.ami_ssm_parameter_path} is not x86_64. This is a platform AMI pipeline fault — raise it with the platform team rather than working around it."
    }

    precondition {
      condition     = data.aws_ami.runner.state == "available"
      error_message = "The AMI published at ${local.ami_ssm_parameter_path} is not in the `available` state."
    }

    # Cross-checks the literal baked into variables.tf's validation against the real value in
    # platform.tf. Without this, changing the registry hostname in one place and not the other
    # would silently disable the image allowlist.
    precondition {
      condition     = startswith(var.default_job_image, "${local.internal_registry}/")
      error_message = "default_job_image must be hosted on ${local.internal_registry}. If this fires despite the variable validation passing, the registry hostname in variables.tf has drifted from platform.tf."
    }

    # Tripwires. These can only fail if someone has edited platform.tf, which is the point:
    # the failure is loud and the diff is on a security-owned file.
    precondition {
      condition     = local.spot_price == null
      error_message = "GUARDRAIL: Spot instances are not permitted for GitLab Runners. local.spot_price must remain null."
    }

    precondition {
      condition     = local.executor_type == "docker"
      error_message = "GUARDRAIL: only the docker executor is supported. Setting docker+machine or docker-autoscaler would re-enable autoscaling and the fleeting plugin."
    }

    precondition {
      condition     = local.private_address_only && !local.use_eip
      error_message = "GUARDRAIL: the Runner must not be publicly addressable. private_address_only must be true and use_eip false."
    }

    precondition {
      condition     = local.metadata_options.http_tokens == "required"
      error_message = "GUARDRAIL: IMDSv2 must be required."
    }

    precondition {
      condition     = !contains(local.docker_volumes, "/var/run/docker.sock:/var/run/docker.sock")
      error_message = "GUARDRAIL: the host Docker socket must never be mounted into job containers."
    }

    precondition {
      condition     = length(local.allowed_images) > 0 && alltrue([for i in local.allowed_images : startswith(i, local.internal_registry)])
      error_message = "GUARDRAIL: allowed_images must be non-empty and restricted to the internal registry."
    }

    # The reclaim stages have to escalate. Mis-ordered thresholds would silently skip stages,
    # so the runner would fill its disk while appearing to have cleanup configured.
    precondition {
      condition = (
        local.docker_gc.warn_pct < local.docker_gc.hard_pct &&
        local.docker_gc.hard_pct < local.docker_gc.crit_pct &&
        local.docker_gc.crit_pct < 100 &&
        local.docker_gc.warn_pct > 0
      )
      error_message = "GUARDRAIL: docker_gc thresholds must escalate strictly — 0 < warn < hard < crit < 100."
    }

    # AWS rejects any max_instance_lifetime below 86400. Catching it here beats an apply-time
    # API error on a value nobody expected to matter.
    precondition {
      condition     = local.instance_max_lifetime_seconds == 0 || local.instance_max_lifetime_seconds >= 86400
      error_message = "GUARDRAIL: instance_max_lifetime_seconds must be 0 (disabled) or at least 86400 — AWS rejects anything shorter."
    }

    # In BYO mode nothing here creates the parameter, so a typo in the name is not a Terraform
    # error — it is a runner that boots, fails `get-parameter`, and exits 1 in user data with
    # the only evidence in CloudWatch. Upstream builds its IAM grant from this same string, so
    # the name must at minimum be well formed and namespaced where the platform expects it.
    precondition {
      condition = (
        local.manage_auth_token_parameter ||
        can(regex("^/platform/gitlab-runner/[a-z0-9-]+/", local.auth_token_parameter_name))
      )
      error_message = "GUARDRAIL: an externally provisioned auth_token_parameter_name must live under /platform/gitlab-runner/<name>/ so it is covered by the platform's SSM key policy and audit rules."
    }
  }
}
