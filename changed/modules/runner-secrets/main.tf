###############################################################################
# Supporting module: the KMS key and the token parameter.
#
# Split out from the runner module so that the two have independent lifecycles — you can
# destroy and rebuild a Runner without re-minting its token, and a different team can own the
# key if your governance requires it.
#
# The token enters here and stops here. It reaches `value_wo`, which the provider sends to AWS
# and discards. Nothing in this module can emit it: an `output` returning it would have to be
# declared `ephemeral`, and an ephemeral output cannot be read from state, so it could never
# reach the runner module across a state boundary anyway. Only the parameter *name* and the key
# ARN travel onward, and neither is a secret.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  parameter_name = "/platform/gitlab-runner/${var.name}/auth-token"
  meta_name      = "/platform/gitlab-runner/${var.name}/token-meta"

  log_group_pattern = coalesce(
    var.cloudwatch_log_group_arn_pattern,
    "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"
  )

  tags = merge(var.tags, {
    "platform:component" = "gitlab-runner-secrets"
    "platform:runner"    = var.name
  })
}

# ---------------------------------------------------------------------------
# Key
# ---------------------------------------------------------------------------
# One key per Runner deployment. A shared platform key would let any team's Runner decrypt any
# other team's token.
#
# It covers the token, the S3 build cache and the log group, because the runner module hands
# this same ARN to `kms_key_id` upstream. Splitting them would mean three keys and three
# policies for no additional isolation.
resource "aws_kms_key" "runner" {
  description             = "GitLab Runner ${var.name} - SSM token, S3 build cache, CloudWatch logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Delegates authorisation to IAM. Without this, IAM policies granting kms:Decrypt have
        # no effect on this key.
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # CloudWatch Logs is a service principal, so IAM delegation is not enough — it needs an
        # explicit grant here. Omitting it breaks log delivery silently.
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
        Condition = {
          ArnLike = { "kms:EncryptionContext:aws:logs:arn" = local.log_group_pattern }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "runner" {
  name          = "alias/gitlab-runner-${var.name}"
  target_key_id = aws_kms_key.runner.key_id
}

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
# `value_wo` is a write-only argument: the provider sends the value to AWS and discards it. It
# is never written to state, never rendered in a plan, and not recoverable from a state file.
#
# `value` — the ordinary argument — would put the plaintext in state, and so would a
# placeholder plus `lifecycle { ignore_changes = [value] }`, because ignore_changes suppresses
# diffs, not reads. See docs/token-provisioning.md.
resource "aws_ssm_parameter" "runner_auth_token" {
  name        = local.parameter_name
  description = "GitLab Runner authentication token for ${var.name}. Managed by Terraform; value is write-only."
  type        = "SecureString"
  key_id      = aws_kms_key.runner.arn
  tier        = "Standard"

  value_wo         = var.runner_auth_token
  value_wo_version = var.runner_auth_token_version

  tags = local.tags
}

# Non-secret companion, so the wrapper script can answer "which runner is this, and when does
# its token lapse?" on a later apply without reading the SecureString back — and so both facts
# are destroyed with the stack rather than left in Parameter Store.
#
# Plain `value` on purpose: there is nothing sensitive in it, and the script needs to read it.
resource "aws_ssm_parameter" "runner_auth_token_meta" {
  name        = local.meta_name
  description = "Non-secret metadata for the ${var.name} Runner authentication token."
  type        = "String"
  tier        = "Standard"

  value = jsonencode({
    runner_id  = var.runner_auth_token_version
    expires_at = var.runner_auth_token_expires_at
  })

  tags = local.tags
}
