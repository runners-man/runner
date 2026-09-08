###############################################################################
# Derivations only.
#
# No policy decisions live here — those are in platform.tf. This file turns the
# consumer contract plus the pinned constants into the exact shapes the two
# child modules want.
###############################################################################

locals {
  # -------------------------------------------------------------------------
  # Naming and tagging
  # -------------------------------------------------------------------------

  # Upstream derives almost every resource name from `environment`, including the SSM
  # parameter key and the IAM object prefix, so this single value is the naming root.
  environment = var.name

  # Platform tags are merged last and therefore win. That is deliberate: a consumer must not
  # be able to relabel a Runner as something else to dodge an SCP or a cost allocation report.
  tags = merge(
    var.tags,
    {
      "Name"                    = var.name
      "Environment"             = var.name
      "platform:module"         = "terraform-aws-gitlab-runner-goldenpath"
      "platform:component"      = "gitlab-runner"
      "platform:managed-by"     = "terraform"
      "platform:runner-version" = var.runner_version
    },
  )

  # Two AZs is all the fixed layout needs: one for the Runner and endpoints, a second only so
  # the public/NAT tier is not single-homed.
  availability_zones = slice(sort(data.aws_availability_zones.available.names), 0, 2)

  # -------------------------------------------------------------------------
  # Schedule → cron
  # -------------------------------------------------------------------------
  #
  # Consumers give us `08:00` and `["MON","TUE"]`; ASG scheduled actions want
  # `0 8 * * 1,2`. Days are sorted numerically so the rendered cron is stable
  # regardless of the order they were listed in.

  cron_day_number = {
    SUN = 0, MON = 1, TUE = 2, WED = 3, THU = 4, FRI = 5, SAT = 6
  }

  schedule_day_numbers = sort([for d in var.schedule.days : tostring(local.cron_day_number[d])])
  schedule_days_cron   = join(",", local.schedule_day_numbers)

  schedule_start_hour   = tonumber(split(":", var.schedule.start_time)[0])
  schedule_start_minute = tonumber(split(":", var.schedule.start_time)[1])
  schedule_stop_hour    = tonumber(split(":", var.schedule.stop_time)[0])
  schedule_stop_minute  = tonumber(split(":", var.schedule.stop_time)[1])

  scale_out_cron = "${local.schedule_start_minute} ${local.schedule_start_hour} * * ${local.schedule_days_cron}"
  scale_in_cron  = "${local.schedule_stop_minute} ${local.schedule_stop_hour} * * ${local.schedule_days_cron}"

  # Upstream types this as map(any), so every value unifies to string. min/max/desired are all
  # set to the same number because there is exactly one Runner instance: the schedule is a
  # power switch, not a scaling policy.
  runner_schedule_config = {
    scale_out_recurrence = local.scale_out_cron
    scale_out_count      = 1
    scale_out_time_zone  = var.schedule.time_zone
    scale_in_recurrence  = local.scale_in_cron
    scale_in_count       = 0
    scale_in_time_zone   = var.schedule.time_zone
  }

  # -------------------------------------------------------------------------
  # SSM parameter for the Runner authentication token
  # -------------------------------------------------------------------------

  # In managed mode the module owns this parameter; in BYO mode the name is supplied and the
  # parameter is created elsewhere. Either way this local is the single source of truth for the
  # name passed to upstream, so runner.tf does not need to know which mode is active.
  manage_auth_token_parameter = var.auth_token_parameter_name == null
  auth_token_parameter_name   = coalesce(var.auth_token_parameter_name, "/platform/gitlab-runner/${var.name}/auth-token")

  # -------------------------------------------------------------------------
  # Deterministic child-module resource names
  # -------------------------------------------------------------------------

  # Upstream builds the instance role name as `${iam_object_prefix}-instance`, and we pass
  # `iam_object_prefix = var.name`. Reproducing the name here rather than reading the module's
  # output is what lets security.tf attach a policy to that role without creating a dependency
  # cycle through the KMS key. Verified against cattle-ops v9.5.0 locals.tf; re-check on bump.
  runner_instance_role_name = "${var.name}-instance"

  # -------------------------------------------------------------------------
  # Job container configuration
  # -------------------------------------------------------------------------

  # The internal CA bundle is already in the AMI's system trust store, so the agent, curl and
  # git on the *host* trust it with no configuration. Job *containers* have their own trust
  # store, so the bundle is bind-mounted read-only at the path the GitLab Runner helper image
  # expects.
  #
  # `/certs/client` is added only in privileged mode: it is what a `docker:dind` service needs
  # to hand a TLS client certificate to the job container. We deliberately do NOT use upstream's
  # `runner_worker_docker_add_dind_volumes`, because that also bind-mounts `/var/run/docker.sock`
  # from the host — which hands every job root on the Runner.
  #
  # NOTE on `/builds`: it was previously declared here too, copying what upstream's
  # add_dind_volumes does. That is wrong for the docker executor. GitLab's own
  # documentation states that "all directories defined in volumes= are persistent between
  # builds", so declaring /builds turns the build directory into a volume that survives from
  # one job to the next and fights the runner's own checkout handling. GitLab's canonical
  # docker-in-docker configuration is `volumes = ["/certs/client", "/cache"]` — no /builds.
  #
  # Consequence to be aware of: a job that starts its own container and bind-mounts the
  # workspace into it (`docker run -v $(pwd):/src`) will not work, because the dind daemon
  # resolves that path in its own filesystem rather than the build container's. That is an
  # inherent dind limitation, not something /builds fixed correctly.
  docker_volumes = concat(
    [
      "/cache",
      "${local.ca_bundle_path}:${local.ca_bundle_container_path}:ro",
    ],
    var.job_privileged_mode ? ["/certs/client"] : [],
  )

  # Point the common language runtimes at the mounted bundle. Without these, a job that talks
  # to an internal HTTPS service gets a certificate error even though the host is fine.
  ca_environment_variables = [
    "SSL_CERT_FILE=${local.ca_bundle_container_path}",
    "GIT_SSL_CAINFO=${local.ca_bundle_container_path}",
    "REQUESTS_CA_BUNDLE=${local.ca_bundle_container_path}",
    "NODE_EXTRA_CA_CERTS=${local.ca_bundle_container_path}",
    "CURL_CA_BUNDLE=${local.ca_bundle_container_path}",
  ]

  dind_environment_variables = var.job_privileged_mode ? ["DOCKER_TLS_CERTDIR=/certs"] : []

  job_environment_variables = sort(concat(
    local.ca_environment_variables,
    local.dind_environment_variables,
    [for k, v in var.job_environment_variables : "${k}=${v}"],
  ))

  # The helper image is versioned in lockstep with the runner and pulled from the internal
  # registry. Leaving it unset would make the agent pull from registry.gitlab.com.
  helper_image = "${local.internal_registry}/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v${var.runner_version}"

  runner_worker_docker_options = {
    image                 = var.default_job_image
    helper_image          = local.helper_image
    privileged            = var.job_privileged_mode
    allowed_images        = local.allowed_images
    allowed_pull_policies = local.allowed_pull_policies
    pull_policies         = ["always"]
    disable_cache         = false
    shm_size              = 0
    # TLS to the *Docker daemon*, not to registries. The agent talks to the local daemon over a
    # unix socket, so this stays false; registry TLS is handled by the system CA bundle.
    tls_verify = false
    volumes    = local.docker_volumes
  }

  # -------------------------------------------------------------------------
  # Instance root volume
  # -------------------------------------------------------------------------

  # Encrypted with the AWS-managed aws/ebs key rather than our CMK: a customer-managed key on a
  # launch template requires an explicit grant for the Auto Scaling service-linked role, which
  # is a per-account prerequisite this module cannot create on a consumer's behalf.
  root_device_config = {
    device_name           = "/dev/xvda"
    delete_on_termination = "true"
    volume_type           = "gp3"
    volume_size           = tostring(var.root_volume_size_gb)
    encrypted             = "true"
    throughput            = "250"
    iops                  = "3000"
  }

  # -------------------------------------------------------------------------
  # User data: install and post-install
  # -------------------------------------------------------------------------
  #
  # Upstream's user data installs the Runner like this:
  #
  #     if ! ( rpm -q gitlab-runner >/dev/null ); then
  #       curl --fail --retry 6 -L https://packages.gitlab.com/install/.../script.rpm.sh | bash
  #       yum install gitlab-runner-${version} -y
  #     fi
  #
  # That URL is hardcoded and unreachable from an enterprise VPC. `pre_install_script` runs
  # immediately before that block, so installing the pinned version from the internal mirror
  # here makes the `rpm -q` guard short-circuit and the packages.gitlab.com call never happens
  # — while keeping `runner_version` a real, working consumer variable.
  #
  # See docs/adr/0004-internal-mirror-install-path.md.

  pre_install_script = <<-BASH
    echo "[platform] configuring Docker daemon"
    install -d -m 0755 /etc/docker
    cat > /etc/docker/daemon.json <<'DOCKERJSON'
    {
      "log-driver": "json-file",
      "log-opts": { "max-size": "10m", "max-file": "3" },
      "default-ulimits": { "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 } }
    }
    DOCKERJSON
    systemctl restart docker

    echo "[platform] installing gitlab-runner ${var.runner_version} from the internal mirror"
    cat > /etc/yum.repos.d/gitlab-runner.repo <<'RUNNERREPO'
    [gitlab-runner]
    name=GitLab Runner (internal mirror)
    baseurl=${local.rpm_mirror_base_url}
    enabled=1
    gpgcheck=1
    gpgkey=${local.rpm_mirror_gpg_key}
    sslverify=1
    sslcacert=${local.ca_bundle_path}
    repo_gpgcheck=0
    RUNNERREPO

    dnf install -y "gitlab-runner-${var.runner_version}"

    # Fail loudly rather than silently falling through to upstream's internet install path.
    if ! rpm -q gitlab-runner >/dev/null 2>&1; then
      echo "[platform] FATAL: gitlab-runner ${var.runner_version} is not available on the internal mirror" >&2
      exit 1
    fi
  BASH

  # Two fixes applied after the package is in place:
  #
  # 1. Upstream hardcodes `ServerAddress = "s3.amazonaws.com"` in its config.toml template. In
  #    a region other than us-east-1 that costs a redirect on every cache operation and forces
  #    the traffic out through NAT instead of the S3 gateway endpoint.
  # 2. The ASG terminate hook does not drain running jobs. SIGQUIT is GitLab Runner's graceful
  #    shutdown signal; with a long TimeoutStopSec, in-flight jobs finish during OS shutdown.
  post_install_script = <<-BASH
    echo "[platform] pinning the cache endpoint to the regional S3 endpoint"
    sed -i 's|ServerAddress = "s3.amazonaws.com"|ServerAddress = "s3.${data.aws_region.current.region}.amazonaws.com"|' /etc/gitlab-runner/config.toml

    echo "[platform] configuring graceful shutdown"
    install -d -m 0755 /etc/systemd/system/gitlab-runner.service.d
    cat > /etc/systemd/system/gitlab-runner.service.d/10-graceful-stop.conf <<'UNIT'
    [Service]
    KillSignal=SIGQUIT
    TimeoutStopSec=${local.job_drain_timeout_seconds}
    UNIT

    echo "[platform] installing the staged disk reclaim job"
    # NOTE: this is not runner-version-specific and would sit more naturally in the platform
    # AMI. It lives here because user data is the only injection point this module has.
    #
    # Every prune below is scoped by Docker to objects not in use by a running container, so a
    # job in flight is never touched. Purging images is close to free for us specifically:
    # pull_policy is pinned to `always`, so the local image cache is re-fetched every job
    # regardless and losing it costs one pull, not correctness.
    cat > /usr/local/sbin/platform-docker-gc <<'GCSCRIPT'
    #!/bin/bash
    # Staged reclaim of Docker disk. Does nothing until the volume is actually filling.
    set -uo pipefail

    TARGET=/var/lib/docker
    [ -d "$TARGET" ] || TARGET=/

    used() { df --output=pcent "$TARGET" 2>/dev/null | tail -1 | tr -dc '0-9'; }
    log()  { logger -t platform-docker-gc "$*"; }

    U=$(used)
    [ -n "$U" ] || exit 0
    if [ "$U" -lt ${local.docker_gc.warn_pct} ]; then exit 0; fi

    log "disk at $U% — starting staged reclaim"

    # Stage 1 — exited containers and dangling layers. Nothing referenced is removed.
    # Scoped to runner-managed objects: an unfiltered prune can also remove things a job is
    # between operations on, and there is nothing else on this host worth reclaiming anyway.
    docker container prune -f --filter "label=com.gitlab.gitlab-runner.managed=true" >/dev/null 2>&1
    docker image prune -f >/dev/null 2>&1
    U=$(used); log "after stage 1 (exited containers, dangling images): $U%"
    if [ "$U" -lt ${local.docker_gc.hard_pct} ]; then exit 0; fi

    # Stage 2 — the runner's own per-project cache volumes, then any image no running
    # container holds. clear-docker-cache ships with the gitlab-runner package and knows the
    # `runner-*` naming convention, so it will not touch anything it did not create.
    if [ -x /usr/share/gitlab-runner/clear-docker-cache ]; then
      /usr/share/gitlab-runner/clear-docker-cache prune-volumes >/dev/null 2>&1
    fi
    docker image prune -af --filter "label=com.gitlab.gitlab-runner.managed=true" >/dev/null 2>&1
    U=$(used); log "after stage 2 (runner cache volumes, unused images): $U%"
    if [ "$U" -lt ${local.docker_gc.crit_pct} ]; then exit 0; fi

    # Stage 3 — build cache. Last resort: this is the one that genuinely costs build time.
    docker builder prune -af >/dev/null 2>&1
    U=$(used); log "after stage 3 (build cache): $U%"
    if [ "$U" -ge ${local.docker_gc.crit_pct} ]; then
      log "WARNING: still at $U% after full reclaim. root_volume_size_gb is too small for this workload."
    fi
    exit 0
    GCSCRIPT
    chmod 0755 /usr/local/sbin/platform-docker-gc

    cat > /etc/systemd/system/platform-docker-gc.service <<'GCUNIT'
    [Unit]
    Description=Staged reclaim of Docker disk space
    After=docker.service
    Requires=docker.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/platform-docker-gc
    GCUNIT

    cat > /etc/systemd/system/platform-docker-gc.timer <<'GCTIMER'
    [Unit]
    Description=Check the Docker disk every few minutes and reclaim if it is filling

    [Timer]
    OnBootSec=5min
    OnUnitActiveSec=${local.docker_gc.interval_minutes}min
    RandomizedDelaySec=60
    Unit=platform-docker-gc.service

    [Install]
    WantedBy=timers.target
    GCTIMER

    echo "[platform] adding disk utilisation to the CloudWatch agent"
    # Upstream's agent config collects cpu and memory only, so a filling disk is invisible
    # until jobs start failing. The agent config is written earlier in user data, so this
    # patch lands on top of it.
    CW_CONFIG=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    if [ -f "$CW_CONFIG" ] && command -v jq >/dev/null 2>&1; then
      CW_TMP=$(mktemp)
      if jq '.metrics.metrics_collected.disk = {"resources":["/"],"measurement":["disk_used_percent"],"metrics_collection_interval":300}' "$CW_CONFIG" > "$CW_TMP"; then
        mv "$CW_TMP" "$CW_CONFIG"
        systemctl restart amazon-cloudwatch-agent || true
      else
        rm -f "$CW_TMP"
        echo "[platform] WARNING: could not add disk metrics to the CloudWatch agent config" >&2
      fi
    else
      echo "[platform] WARNING: CloudWatch agent config not found; disk utilisation will not be reported" >&2
    fi

    systemctl daemon-reload
    systemctl enable --now platform-docker-gc.timer
    systemctl restart gitlab-runner

    echo "[platform] gitlab-runner $(gitlab-runner --version | head -n1) ready"
  BASH

  # -------------------------------------------------------------------------
  # Security group rules
  # -------------------------------------------------------------------------
  #
  # No ingress at all. Session Manager is an outbound-initiated tunnel, so there is nothing to
  # open. Egress is restricted to internal networks, the VPC (interface endpoints), and S3.

  runner_egress_rules = {
    https_internal = {
      protocol       = "tcp"
      from_port      = 443
      to_port        = 443
      prefix_list_id = local.internal_prefix_list_id
      description    = "HTTPS to internal networks (GitLab, package mirror, container registry)"
    }
    http_internal = {
      protocol       = "tcp"
      from_port      = 80
      to_port        = 80
      prefix_list_id = local.internal_prefix_list_id
      description    = "HTTP to internal networks (package mirror redirects)"
    }
    https_s3 = {
      protocol       = "tcp"
      from_port      = 443
      to_port        = 443
      prefix_list_id = data.aws_ec2_managed_prefix_list.s3.id
      description    = "HTTPS to S3 for the build cache and AL2023 package repositories"
    }
    https_vpc = {
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = var.vpc_cidr
      description = "HTTPS to VPC interface endpoints"
    }
    dns_udp = {
      protocol    = "udp"
      from_port   = 53
      to_port     = 53
      cidr_block  = var.vpc_cidr
      description = "DNS to the VPC resolver"
    }
    dns_tcp = {
      protocol    = "tcp"
      from_port   = 53
      to_port     = 53
      cidr_block  = var.vpc_cidr
      description = "DNS to the VPC resolver (TCP fallback)"
    }
  }

  # Upstream defaults the terminate-hook lambda to 443 against 0.0.0.0/0. It only ever calls
  # the EC2 and Auto Scaling APIs, both of which have interface endpoints in this VPC.
  terminate_lambda_egress_rules = {
    https_vpc = {
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_block  = var.vpc_cidr
      description = "HTTPS to VPC interface endpoints (EC2, Auto Scaling)"
    }
  }

  # -------------------------------------------------------------------------
  # VPC endpoint policies
  # -------------------------------------------------------------------------

  # Same-account restriction on every interface endpoint. Stops the endpoint being used as a
  # path to another account's resources if credentials ever leak from a job container.
  same_account_endpoint_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSameAccountOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  endpoint_policies = { for service in local.aws_endpoints : service => local.same_account_endpoint_policy }
}
