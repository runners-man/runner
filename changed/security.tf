###############################################################################
# The three things the upstream module cannot do for us:
#   1. a customer-managed key scoped to this deployment
#   2. delivering the Runner authentication token without it touching state
#   3. the one IAM permission upstream omits when you bring your own KMS key
###############################################################################

# ---------------------------------------------------------------------------
# Customer-managed key
# ---------------------------------------------------------------------------

# One key per Runner deployment. A shared platform key would let any team's Runner decrypt any
# other team's token, which defeats the isolation the rest of the module works for.
resource "aws_kms_key" "runner" {
  description = "GitLab Runner ${var.name} - SSM token, S3 build cache, CloudWatch logs"

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
        # explicit grant in the key policy. Upstream encrypts the Runner's log group with
        # whatever key we hand it, so omitting this breaks log delivery silently.
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
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
# Runner authentication token
# ---------------------------------------------------------------------------

# `value_wo` is a write-only argument: the provider sends it to AWS and then discards it. It is
# never written to state, never rendered in a plan, and never recoverable from the state file.
#
# The cost of that guarantee is that Terraform also cannot tell when the value has changed —
# hence `value_wo_version`, which the consumer increments on rotation. See
# docs/adr/0002-write-only-token.md.
#
# In BYO mode (`auth_token_parameter_name` set) this resource is not created at all and the
# parameter is provisioned outside Terraform. Note what is deliberately *absent* from this file
# in that case: no `data "aws_ssm_parameter"` to look the value up, and no placeholder resource
# with `lifecycle { ignore_changes = [value] }`. Both of those put the decrypted value straight
# back into state on the next refresh — `ignore_changes` suppresses diffs, not reads. See
# docs/token-provisioning.md.
resource "aws_ssm_parameter" "runner_auth_token" {
  count = local.manage_auth_token_parameter ? 1 : 0

  name        = local.auth_token_parameter_name
  description = "GitLab Runner authentication token for ${var.name}. Managed by Terraform; value is write-only."
  type        = "SecureString"
  key_id      = aws_kms_key.runner.arn
  tier        = "Standard"

  value_wo         = var.runner_auth_token
  value_wo_version = var.runner_auth_token_version

  tags = local.tags
}

# Non-secret companion. Exists so the wrapper script can answer "which runner is this, and when
# does its token lapse?" on a later apply without reading the SecureString back, and so both
# facts are destroyed with the stack rather than left behind in Parameter Store.
#
# `value` here is deliberately the plain argument, not `value_wo`: there is nothing sensitive in
# it, and the script needs to read it.
resource "aws_ssm_parameter" "runner_auth_token_meta" {
  count = local.manage_auth_token_parameter ? 1 : 0

  name        = "${dirname(local.auth_token_parameter_name)}/token-meta"
  description = "Non-secret metadata for the ${var.name} Runner authentication token."
  type        = "String"
  tier        = "Standard"

  value = jsonencode({
    runner_id  = var.runner_auth_token_version
    expires_at = var.runner_auth_token_expires_at
  })

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Supplementary IAM
# ---------------------------------------------------------------------------

# Upstream attaches a KMS policy to the Runner role only when it manages the key itself
# (`enable_managed_kms_key = true`). We bring our own key, so without this the instance can
# read the SecureString parameter and then fail to decrypt it — a failure that only shows up in
# the boot log.
#
# Scoped to this one key and this one operation. `ViaService` is deliberately not constrained:
# the same key decrypts the SSM parameter, the S3 cache objects and the log group.
data "aws_iam_policy_document" "runner_kms_decrypt" {
  statement {
    sid = "DecryptRunnerManagedKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.runner.arn]
  }

  statement {
    # The S3 cache adapter writes objects encrypted with this key.
    sid = "EncryptCacheObjects"
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.runner.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # BYO mode: the token parameter is encrypted with a key this module does not own. Upstream
  # grants `ssm:GetParameter` on the parameter ARN but knows nothing about the key, so without
  # this the boot-time `get-parameter --with-decryption` returns AccessDenied.
  dynamic "statement" {
    for_each = local.manage_auth_token_parameter ? [] : [var.auth_token_kms_key_arn]

    content {
      sid       = "DecryptExternalTokenKey"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "runner_kms_decrypt" {
  name   = "${var.name}-kms-decrypt"
  role   = local.runner_instance_role_name
  policy = data.aws_iam_policy_document.runner_kms_decrypt.json

  # The role is created inside the child module. Its name is deterministic, so referencing it
  # by string avoids a dependency cycle with the KMS key — but Terraform then needs telling
  # about the ordering explicitly.
  depends_on = [module.gitlab_runner]
}
