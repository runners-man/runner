###############################################################################
# The one and only call to cattle-ops/gitlab-runner/aws.
#
# Everything a reviewer needs to audit the security surface of this module is in
# this file. Keep it that way.
#
# ---------------------------------------------------------------------------
# DELIBERATELY NOT PASSED — Tier 3
# ---------------------------------------------------------------------------
# These upstream inputs are never referenced anywhere in this repository, which
# means no consumer can reach them. This list is the actual enforcement of the
# constraints, and should be reviewed on every upstream version bump.
#
#   Autoscaling / fleeting / docker+machine — unreachable because
#   runner_worker.type is pinned to "docker":
#     runner_worker_docker_machine_fleet          runner_worker_docker_machine_role
#     runner_worker_docker_machine_instance       runner_worker_docker_machine_ami_id
#     runner_worker_docker_machine_ami_filter     runner_worker_docker_machine_ami_owners
#     runner_worker_docker_machine_ec2_options    runner_worker_docker_machine_ec2_metadata_options
#     runner_worker_docker_machine_autoscaling_options
#     runner_worker_docker_autoscaler             runner_worker_docker_autoscaler_role
#     runner_worker_docker_autoscaler_instance    runner_worker_docker_autoscaler_asg
#     runner_worker_docker_autoscaler_ami_id      runner_worker_docker_autoscaler_ami_filter
#     runner_worker_docker_autoscaler_ami_owners
#     runner_worker_docker_autoscaler_autoscaling_options
#     runner_worker_ingress_rules                 runner_worker_egress_rules
#
#   AMI selection — the AMI is platform-controlled:
#     runner_ami_filter                           runner_ami_owners
#
#   Deprecated registration flow — superseded by the preregistered token:
#     runner_gitlab_registration_config
#     runner_gitlab_registration_token_secure_parameter_store_name
#     runner_gitlab.registration_token
#     runner_gitlab.access_token_secure_parameter_store_name
#
#   Host escape vectors:
#     runner_worker_docker_services               runner_worker_docker_volumes_tmpfs
#     runner_worker_docker_services_volumes_tmpfs
#     runner_worker_gitlab_pipeline               (pre/post-build and pre-clone hooks)
#
#   Operational noise we do not want teams touching:
#     debug                                       suppressed_tags
#     runner_terminate_ec2_lambda_handler         runner_terminate_ec2_lambda_layer_arns
#     runner_terminate_ec2_environment_variables  runner_sentry_secure_parameter_store_name
#     kms_managed_alias_name                      kms_managed_deletion_rotation_window_in_days
###############################################################################

module "gitlab_runner" {
  source  = "cattle-ops/gitlab-runner/aws"
  version = "9.5.0" # keep in sync with local.gitlab_runner_version

  # -------------------------------------------------------------------------
  # Placement
  # -------------------------------------------------------------------------
  environment = local.environment
  vpc_id      = module.network.vpc_id

  # With the docker executor, upstream pins the Runner ASG to this single subnet
  # (`vpc_zone_identifier = [var.subnet_id]`). One subnet, one AZ — see docs/limitations.md.
  subnet_id = module.network.subnet_ids_by_key["runner"]

  # -------------------------------------------------------------------------
  # Naming and tagging
  # -------------------------------------------------------------------------
  tags                  = local.tags
  security_group_prefix = var.name
  iam_object_prefix     = var.name

  # -------------------------------------------------------------------------
  # Encryption
  # -------------------------------------------------------------------------
  # Our own CMK rather than upstream's managed one, so the same key covers the token
  # parameter, the cache bucket and the log group, and so its policy is auditable here.
  kms_key_id             = aws_kms_key.runner.arn
  enable_managed_kms_key = false

  iam_permissions_boundary = local.iam_permissions_boundary_name

  # -------------------------------------------------------------------------
  # Runner manager (the [global] section of config.toml)
  # -------------------------------------------------------------------------
  runner_manager = {
    maximum_concurrent_jobs   = var.concurrent_jobs
    gitlab_check_interval     = 3
    connection_max_age        = "15m"
    prometheus_listen_address = ""
    sentry_dsn                = ""
  }

  # -------------------------------------------------------------------------
  # The Runner instance
  # -------------------------------------------------------------------------
  runner_instance = {
    name = var.name
    type = var.instance_type

    # RED LINE: no Spot. `null` is upstream's on-demand value. There is no variable path to
    # anything else.
    spot_price = local.spot_price

    ebs_optimized = true
    monitoring    = true

    # Backstop for `schedule.enabled = false`. A scheduled runner gets a clean root volume
    # every morning because the instance is replaced; an always-on one never does, so the
    # ASG is told to retire it periodically. See docs/limitations.md on disk growth.
    max_lifetime_seconds = local.instance_max_lifetime_seconds
    private_address_only = local.private_address_only
    use_eip              = local.use_eip
    ssm_access           = local.ssm_access
    root_device_config   = local.root_device_config

    # Upstream's ASG refreshes instances when a tag changes. Putting the token rotation
    # counter in a tag is what makes `runner_auth_token_version` actually roll the instance
    # instead of only updating the SSM parameter.
    additional_tags = {
      "platform:token-version" = tostring(var.runner_auth_token_version)
    }
  }

  # The platform-controlled AMI. Setting this short-circuits upstream's AMI filter data source
  # entirely — it is not even instantiated.
  runner_ami_id = nonsensitive(data.aws_ssm_parameter.runner_ami_id.value)

  runner_metadata_options = local.metadata_options

  # -------------------------------------------------------------------------
  # Networking
  # -------------------------------------------------------------------------
  runner_networking = {
    security_group_description = "GitLab Runner ${var.name} manager"
  }

  # No inbound at all. Session Manager is an outbound-initiated tunnel.
  runner_ingress_rules = {}
  runner_egress_rules  = local.runner_egress_rules

  # -------------------------------------------------------------------------
  # IAM
  # -------------------------------------------------------------------------
  runner_role = {
    create_role_profile = true

    # Consumers cannot attach policies: `policy_arns` is hardcoded empty and there is no
    # variable feeding it. Jobs that need AWS access assume a team-owned role through GitLab
    # OIDC — see docs/security-model.md.
    policy_arns = []

    # Not needed by the docker executor; only docker+machine created service-linked roles.
    allow_iam_service_linked_role_creation = false
  }

  # -------------------------------------------------------------------------
  # Schedule
  # -------------------------------------------------------------------------
  runner_schedule_enable = var.schedule.enabled
  runner_schedule_config = local.runner_schedule_config

  # Roll the instance when the launch template changes (new AMI, new runner version, new user
  # data), rather than leaving a stale instance running until it is manually replaced.
  runner_enable_asg_recreation = true

  # -------------------------------------------------------------------------
  # GitLab connection
  # -------------------------------------------------------------------------
  runner_gitlab = {
    url            = local.gitlab_url
    url_clone      = local.gitlab_clone_url
    runner_version = var.runner_version

    # The modern authentication-token flow. The instance reads this SecureString at boot and
    # writes it into config.toml; the token is never an input to the launch template and never
    # appears in user data.
    preregistered_runner_token_ssm_parameter_name = local.auth_token_parameter_name

    # `certificate` and `ca_certificate` are intentionally left empty. Supplying either makes
    # upstream write a new PEM into /etc/gitlab-runner/certs and run `update-ca-trust`, which
    # would duplicate — and could conflict with — the CA bundle already baked into the AMI at
    # ${local.ca_bundle_path}. The agent trusts the internal CAs through the system store.
    certificate    = ""
    ca_certificate = ""
  }

  # -------------------------------------------------------------------------
  # Install
  # -------------------------------------------------------------------------
  runner_install = {
    # Installs the pinned runner version from the internal mirror, which makes upstream's
    # `rpm -q gitlab-runner` guard short-circuit its hardcoded packages.gitlab.com call.
    pre_install_script = local.pre_install_script

    # Repairs the hardcoded S3 cache endpoint and installs the graceful-shutdown drop-in.
    post_install_script = local.post_install_script

    yum_update                   = true
    amazon_ecr_credential_helper = false
  }

  # -------------------------------------------------------------------------
  # Logging
  # -------------------------------------------------------------------------
  runner_cloudwatch = {
    enable         = true
    log_group_name = "/platform/gitlab-runner/${var.name}"
    retention_days = local.log_retention_days
  }

  # -------------------------------------------------------------------------
  # Runner worker (the [[runners]] section of config.toml)
  # -------------------------------------------------------------------------
  runner_worker = {
    # RED LINE: docker only. This is what makes every docker+machine, fleeting and
    # docker-autoscaler resource in the upstream module evaluate to zero instances.
    type = local.executor_type

    max_jobs              = var.concurrent_jobs
    request_concurrency   = var.request_concurrency
    output_limit          = 4096
    environment_variables = local.job_environment_variables

    # Workers are containers on this host; there is nothing separate to connect to.
    ssm_access      = false
    use_private_key = false
  }

  runner_worker_docker_options = local.runner_worker_docker_options

  # Upstream's dind helper also bind-mounts /var/run/docker.sock, handing every job container
  # control of the host Docker daemon. We add /certs/client and /builds ourselves in
  # local.docker_volumes instead, so docker-in-docker works without the socket.
  runner_worker_docker_add_dind_volumes = false

  # -------------------------------------------------------------------------
  # Distributed cache
  # -------------------------------------------------------------------------
  runner_worker_cache = {
    create              = true
    authentication_type = "iam"

    # One Runner per bucket, so there is nothing to share and no cross-team read path.
    shared = false

    expiration_days                          = var.cache_expiration_days
    include_account_id                       = true
    random_suffix                            = true
    versioning                               = false
    create_aws_s3_bucket_public_access_block = true
  }

  # -------------------------------------------------------------------------
  # Termination
  # -------------------------------------------------------------------------
  # Upstream's terminate hook is a no-op for the docker executor and explicitly does not wait
  # for running jobs. Widening the lifecycle heartbeat gives the systemd drop-in installed by
  # post_install_script room to drain gracefully.
  runner_terminate_ec2_lifecycle_timeout_duration = local.job_drain_timeout_seconds
  runner_terminate_ec2_timeout_duration           = 90
  runner_terminate_ec2_lambda_egress_rules        = local.terminate_lambda_egress_rules

  # Managed mode only — in BYO mode the parameter is not a Terraform resource here, so the
  # ordering guarantee comes from the stack that creates it (see docs/token-provisioning.md).
  depends_on = [aws_ssm_parameter.runner_auth_token]
}
