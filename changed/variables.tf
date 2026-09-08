###############################################################################
# TIER 1 — the entire consumer contract.
#
# If a setting is not in this file, a product team cannot set it. That is the
# point. Anything platform-owned lives in platform.tf; anything deliberately
# unreachable is simply never passed to the upstream module.
#
# Every variable here has a validation. An input with no validation is an input
# whose failure mode is a broken runner three days later.
###############################################################################

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "name" {
  description = <<-EOT
    Short name for this Runner deployment. Drives every resource name, the VPC name, the IAM
    object prefix and the SSM parameter path, so it must be unique within the AWS account.

    Use something that identifies the team and purpose, e.g. `payments-ci` or `search-build`.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.name))
    error_message = "name must be 3-24 characters, lowercase alphanumeric and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = <<-EOT
    Tags applied to every resource created by this module, including the VPC and its subnets.

    `cost_centre` and `owner` are mandatory. Platform-controlled tag keys (`Name`,
    `Environment`, `platform:*`) cannot be overridden — they are merged last.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in ["cost_centre", "owner"] : contains(keys(var.tags), k)])
    error_message = "tags must include both `cost_centre` and `owner`."
  }

  validation {
    condition     = length([for k in keys(var.tags) : k if startswith(k, "platform:")]) == 0
    error_message = "tags must not use the reserved `platform:` key prefix."
  }
}

# ---------------------------------------------------------------------------
# GitLab registration
# ---------------------------------------------------------------------------

# There are exactly two supported ways to deliver the token, and they are mutually exclusive:
#
#   MANAGED (default)  set `runner_auth_token`. The module creates the SSM SecureString with a
#                      write-only argument. Terraform owns the whole lifecycle, including
#                      destroy. The token never enters state.
#
#   BYO PARAMETER      set `auth_token_parameter_name` (+ `auth_token_kms_key_arn`). The
#                      parameter is created and populated entirely outside Terraform — see
#                      docs/token-provisioning.md. This module only ever handles its *name*.
#
# Both keep the token out of state. BYO exists for stacks that provision the runner in GitLab
# from a script and never want the value to transit a Terraform variable at all.

variable "runner_auth_token" {
  description = <<-EOT
    GitLab Runner **authentication** token (`glrt-...`), obtained by creating a runner in the
    GitLab UI or API before running Terraform.

    This variable is `ephemeral`: it is written straight into an SSM SecureString using a
    write-only argument and is never persisted to Terraform state or shown in plan output.
    Supply it from your CI secret store, e.g. `TF_VAR_runner_auth_token`, never from a
    committed `.tfvars` file.

    Leave unset only if you are using `auth_token_parameter_name` instead.

    This is NOT the legacy registration token (`glrt-` vs `GR1348941...`) — the deprecated
    registration flow is not supported by this module.
  EOT
  type        = string
  ephemeral   = true
  sensitive   = true
  default     = null

  validation {
    # Deliberately a shape check only, so the error message cannot leak the value.
    condition     = var.runner_auth_token == null || startswith(coalesce(var.runner_auth_token, "glrt-"), "glrt-")
    error_message = "runner_auth_token must be a GitLab Runner authentication token beginning with `glrt-`. Legacy registration tokens are not supported."
  }

  validation {
    condition     = (var.runner_auth_token == null) != (var.auth_token_parameter_name == null)
    error_message = "Set exactly one of `runner_auth_token` (module-managed parameter) or `auth_token_parameter_name` (externally provisioned parameter). See docs/token-provisioning.md."
  }
}

variable "runner_auth_token_version" {
  description = <<-EOT
    Rotation counter for the token.

    Because the token never enters state — write-only in managed mode, wholly external in BYO
    mode — Terraform cannot detect that its value changed. This number is what tells it. In
    managed mode a change pushes the new value to SSM; in both modes it is stamped into an
    instance tag, and upstream's ASG has `instance_refresh { triggers = ["tag"] }`, so the
    change also rolls the instance to pick the new token up.

    Use the **GitLab runner id**. It is a database primary key, so it only ever increases, and
    it changes exactly when — and only when — a new token is minted. `scripts/gitlab-runner-token`
    exports it for you, which removes the "someone forgot to bump the counter" failure mode.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.runner_auth_token_version >= 1 && floor(var.runner_auth_token_version) == var.runner_auth_token_version
    error_message = "runner_auth_token_version must be a whole number of 1 or greater."
  }
}

variable "runner_auth_token_expires_at" {
  description = <<-EOT
    RFC3339 timestamp at which the token expires, or `"never"`. Not a secret — it is stored in
    state and surfaced as an output on purpose, so a plan can warn before the token lapses.

    Supplied by `scripts/gitlab-runner-token` from GitLab's `token_expires_at`. Leave at
    `"never"` if your group or project sets no runner expiration, which is the recommended
    configuration for platform runners — see docs/token-provisioning.md.
  EOT
  type        = string
  default     = "never"

  validation {
    condition = (
      var.runner_auth_token_expires_at == "never" ||
      can(timecmp(var.runner_auth_token_expires_at, "2000-01-01T00:00:00Z"))
    )
    error_message = "runner_auth_token_expires_at must be `never` or an RFC3339 timestamp, e.g. `2026-12-07T21:22:35Z`."
  }
}

variable "auth_token_parameter_name" {
  description = <<-EOT
    BYO-parameter mode. Name of an SSM SecureString parameter, created and populated outside
    Terraform, holding the Runner authentication token.

    This module never reads the parameter — it only passes the name through to the upstream
    module, which grants the instance role `ssm:GetParameter` on exactly this ARN and reads it
    at boot. No `data "aws_ssm_parameter"` is used anywhere, so no ciphertext or plaintext
    reaches state.

    Mutually exclusive with `runner_auth_token`. When set, you must also set
    `auth_token_kms_key_arn`, and you own creating, rotating and deleting the parameter.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.auth_token_parameter_name == null || startswith(coalesce(var.auth_token_parameter_name, "/"), "/")
    error_message = "auth_token_parameter_name must be a fully qualified SSM parameter name beginning with `/`."
  }
}

variable "auth_token_kms_key_arn" {
  description = <<-EOT
    ARN of the KMS key encrypting `auth_token_parameter_name`. The module grants the Runner
    instance role `kms:Decrypt` on this key; without it the instance reads the SecureString and
    then fails to decrypt it, which only shows up in the boot log.

    Required with — and only valid with — `auth_token_parameter_name`.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.auth_token_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", coalesce(var.auth_token_kms_key_arn, "arn:aws:kms:")))
    error_message = "auth_token_kms_key_arn must be a KMS key ARN."
  }

  validation {
    condition     = (var.auth_token_kms_key_arn == null) == (var.auth_token_parameter_name == null)
    error_message = "auth_token_kms_key_arn and auth_token_parameter_name must be set together."
  }
}

variable "runner_version" {
  description = <<-EOT
    GitLab Runner version, e.g. `17.11.1`. This single value drives everything: the RPM pulled
    from the internal mirror, the runner helper image tag pulled from the internal registry,
    and the version reported to GitLab.

    Keep it within one minor version of your GitLab server. Only versions mirrored internally
    will resolve.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.runner_version))
    error_message = "runner_version must be a three-part version such as `17.11.1` (no `v` prefix, no suffix)."
  }
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    EC2 instance type for the Runner. AMD64/x86_64 only — the platform AMI is built for that
    architecture and Graviton types will not boot it.

    Two layers of enforcement: the family must be on the allowlist below, and at plan time the
    type's advertised architecture is checked against the EC2 API. Size for your peak
    concurrency — all `concurrent_jobs` run as containers on this one instance.
  EOT
  type        = string
  default     = "m7i.large"

  validation {
    condition = contains(
      ["t3", "t3a", "m6i", "m6a", "m7i", "m7a", "c6i", "c6a", "c7i", "c7a", "r6i", "r6a", "r7i", "r7a"],
      split(".", var.instance_type)[0]
    )
    error_message = "instance_type family must be one of the approved AMD64 families: t3, t3a, m6i, m6a, m7i, m7a, c6i, c6a, c7i, c7a, r6i, r6a, r7i, r7a. Graviton (g-suffixed) families are not supported."
  }

  validation {
    condition     = can(regex("^[a-z0-9]+\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must be of the form `family.size`, e.g. `m7i.large`."
  }
}

variable "root_volume_size_gb" {
  description = <<-EOT
    Size of the Runner's encrypted gp3 root volume in GiB. This is where Docker images, layers
    and build workspaces live, so size it for your largest concurrent build set rather than for
    the OS.
  EOT
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size_gb >= 30 && var.root_volume_size_gb <= 1000
    error_message = "root_volume_size_gb must be between 30 and 1000."
  }
}

# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------

variable "concurrent_jobs" {
  description = <<-EOT
    Maximum number of CI jobs executed at the same time on this Runner. Sets both the global
    `concurrent` and the runner's `limit` in config.toml.

    Every job is a container on the single Runner instance, so this competes directly for the
    CPU, memory and disk of `instance_type`. A rough starting point is one job per two vCPUs.
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.concurrent_jobs >= 1 && var.concurrent_jobs <= 20 && floor(var.concurrent_jobs) == var.concurrent_jobs
    error_message = "concurrent_jobs must be a whole number between 1 and 20. If you need more throughput, use a larger instance_type or a second deployment."
  }
}

variable "request_concurrency" {
  description = <<-EOT
    Number of simultaneous requests the Runner makes to GitLab when polling for new jobs
    (`request_concurrency`). Raising it helps when many short jobs are queued; it does not
    increase how many jobs run at once — that is `concurrent_jobs`.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.request_concurrency >= 1 && var.request_concurrency <= 10 && floor(var.request_concurrency) == var.request_concurrency
    error_message = "request_concurrency must be a whole number between 1 and 10."
  }
}

# ---------------------------------------------------------------------------
# Job execution
# ---------------------------------------------------------------------------

variable "default_job_image" {
  description = <<-EOT
    Container image used for jobs that do not specify `image:` in `.gitlab-ci.yml`.

    Must be hosted on the internal registry. Jobs may override it, but only with another image
    from the same registry — this is enforced by `allowed_images` in the generated config.toml,
    not merely by convention.
  EOT
  type        = string
  default     = "registry.internal.example.com/library/docker:27-cli"

  validation {
    # NOTE: keep the literal below in sync with local.internal_registry in platform.tf.
    # terraform_data.guardrails asserts they have not drifted.
    condition     = startswith(var.default_job_image, "registry.internal.example.com/")
    error_message = "default_job_image must be hosted on the internal registry (registry.internal.example.com/...). Public registries are not reachable and not permitted."
  }

  validation {
    condition     = can(regex(":[A-Za-z0-9_.-]+$", var.default_job_image)) && !endswith(var.default_job_image, ":latest")
    error_message = "default_job_image must carry an explicit tag, and `:latest` is not permitted."
  }
}

variable "job_privileged_mode" {
  description = <<-EOT
    Run job containers in Docker privileged mode. Required for classic docker-in-docker
    (`docker:dind` as a service).

    Understand the trade: a privileged container can escape to the host, and the host holds
    this Runner's IAM role and its GitLab token. If you only need to build images, prefer the
    rootless Buildah pattern in `examples/rootless-image-build` and leave this `false`.

    Note that even when `true`, this module does NOT mount the host Docker socket into job
    containers — that is upstream's default dind behaviour and we deliberately do not use it.
  EOT
  type        = bool
  default     = true
}

variable "job_environment_variables" {
  description = <<-EOT
    Extra environment variables injected into every job container.

    Reserved prefixes are rejected: `AWS_*` (would shadow the instance role credentials),
    `CI_*` and `GITLAB_*` (owned by GitLab), and `DOCKER_HOST` (would redirect the Docker
    client). CA-bundle variables are set for you and must not be supplied here.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = length([
      for k in keys(var.job_environment_variables) : k
      if startswith(k, "AWS_") || startswith(k, "CI_") || startswith(k, "GITLAB_") ||
      contains(["DOCKER_HOST", "DOCKER_TLS_CERTDIR", "SSL_CERT_FILE", "GIT_SSL_CAINFO", "REQUESTS_CA_BUNDLE", "NODE_EXTRA_CA_CERTS"], k)
    ]) == 0
    error_message = "job_environment_variables must not set AWS_*, CI_*, GITLAB_*, DOCKER_HOST, DOCKER_TLS_CERTDIR, or any CA-bundle variable. These are managed by the platform."
  }

  validation {
    condition     = alltrue([for k in keys(var.job_environment_variables) : can(regex("^[A-Z][A-Z0-9_]*$", k))])
    error_message = "job_environment_variables keys must be UPPER_SNAKE_CASE."
  }
}

# ---------------------------------------------------------------------------
# Schedule
# ---------------------------------------------------------------------------

variable "schedule" {
  description = <<-EOT
    Daily start/stop schedule for the Runner instance. Outside the window the Auto Scaling
    group is scaled to zero and you pay for nothing but the VPC.

    `start_time` and `stop_time` are 24-hour `HH:MM` in `time_zone`, which is a full IANA name
    so daylight saving is handled for you. `days` are the days the Runner starts.

    Jobs still running at `stop_time` get the shutdown grace period and no more — leave
    headroom after your longest pipeline. Set `enabled = false` to run the Runner continuously.
  EOT
  type = object({
    enabled    = optional(bool, true)
    start_time = optional(string, "08:00")
    stop_time  = optional(string, "18:00")
    days       = optional(list(string), ["MON", "TUE", "WED", "THU", "FRI"])
    time_zone  = optional(string, "Europe/London")
  })
  default = {}

  validation {
    condition = alltrue([
      can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.schedule.start_time)),
      can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.schedule.stop_time)),
    ])
    error_message = "schedule.start_time and schedule.stop_time must be 24-hour HH:MM, e.g. `08:00` or `18:30`."
  }

  validation {
    condition     = var.schedule.start_time != var.schedule.stop_time
    error_message = "schedule.start_time and schedule.stop_time must differ."
  }

  validation {
    condition = length(var.schedule.days) > 0 && alltrue([
      for d in var.schedule.days : contains(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], d)
    ])
    error_message = "schedule.days must be a non-empty list drawn from MON, TUE, WED, THU, FRI, SAT, SUN."
  }

  validation {
    condition     = length(var.schedule.days) == length(distinct(var.schedule.days))
    error_message = "schedule.days must not contain duplicates."
  }

  validation {
    condition     = can(regex("^[A-Za-z]+/[A-Za-z_+-]+$|^UTC$|^Etc/UTC$", var.schedule.time_zone))
    error_message = "schedule.time_zone must be an IANA time zone name such as `Europe/London`, or `UTC`."
  }
}

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

variable "cache_expiration_days" {
  description = <<-EOT
    Number of days before objects in the distributed S3 cache expire. Lower means cheaper
    storage and colder builds; higher means the opposite. The bucket itself is created,
    encrypted and locked down by the module.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.cache_expiration_days >= 1 && var.cache_expiration_days <= 90 && floor(var.cache_expiration_days) == var.cache_expiration_days
    error_message = "cache_expiration_days must be a whole number between 1 and 90."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the dedicated VPC this module creates for the Runner, allocated to you by
    IPAM. Must be a /22 or larger (a /22 leaves comfortable room for the fixed subnet layout:
    two public /26 for NAT, one private /24 for the Runner, one isolated /26 for the VPC
    endpoints).

    The Runner never shares a VPC with anything else — that isolation is part of the security
    model, not an implementation detail.
  EOT
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. `10.64.16.0/22`."
  }

  validation {
    condition     = tonumber(split("/", var.vpc_cidr)[1]) <= 22 && tonumber(split("/", var.vpc_cidr)[1]) >= 16
    error_message = "vpc_cidr must be between /16 and /22. Smaller than /22 cannot hold the required subnet layout."
  }
}
