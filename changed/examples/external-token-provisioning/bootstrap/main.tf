###############################################################################
# Bootstrap stack.
#
# Creates the KMS key that will encrypt the token parameter, and the IAM identity the
# provisioning script assumes. It deliberately does NOT create the SSM parameter.
#
# Why not? Because `aws_ssm_parameter` reads its value back on every refresh. A placeholder
# resource with `lifecycle { ignore_changes = [value] }` — the obvious way to "create it in
# Terraform and populate it with the CLI" — puts the real token into state the moment anyone
# runs `terraform plan` after the CLI has written it. `ignore_changes` suppresses diffs, not
# reads. See docs/token-provisioning.md.
#
# So: Terraform owns the key. The script owns the parameter. Nothing owns both.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  parameter_prefix = "/platform/gitlab-runner/${var.name}"
  parameter_name   = "${local.parameter_prefix}/auth-token"

  # SSM parameter ARNs carry the leading slash of the name after `:parameter`, so
  # `/platform/x/auth-token` becomes `...:parameter/platform/x/auth-token`.
  parameter_prefix_arn = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.parameter_prefix}"

  tags = merge(var.tags, {
    "platform:component" = "gitlab-runner-token"
    "platform:runner"    = var.name
  })
}

# ---------------------------------------------------------------------------
# The key
# ---------------------------------------------------------------------------
# Separate from the runner module's own CMK (which covers the cache bucket and the log group).
# That split is intentional: this key's only job is the token, its policy names exactly two
# principals, and it outlives `terraform destroy` on the runner stack so a rebuild does not
# need the token re-minted.
resource "aws_kms_key" "token" {
  description             = "GitLab Runner ${var.name} - authentication token at rest"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # The provisioning pipeline can encrypt (write the token) but not decrypt (read it
        # back). Nothing in this design has a legitimate reason to read the token except the
        # Runner instance itself.
        Sid       = "ProvisionerWriteOnly"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.provisioner.arn }
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${data.aws_region.current.region}.amazonaws.com" }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "token" {
  name          = "alias/gitlab-runner-${var.name}-token"
  target_key_id = aws_kms_key.token.key_id
}

# ---------------------------------------------------------------------------
# The provisioning identity
# ---------------------------------------------------------------------------
# Assumed by the CI job that runs provision-runner-token.sh, via GitLab OIDC. Scoped to one
# parameter prefix, and — the important part — it has no `ssm:GetParameter` on the token
# itself, only on the non-secret companions.
resource "aws_iam_role" "provisioner" {
  name = "${var.name}-runner-token-provisioner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.gitlab_oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.gitlab_oidc_audience}:aud" = var.gitlab_oidc_audience
        }
        StringLike = {
          "${var.gitlab_oidc_audience}:sub" = "project_path:${var.provisioning_project_path}:ref_type:branch:ref:*"
        }
      }
    }]
  })

  tags = local.tags
}

data "aws_iam_policy_document" "provisioner" {
  statement {
    sid     = "WriteTokenParameter"
    actions = ["ssm:PutParameter", "ssm:AddTagsToResource"]

    # The token parameter and its two non-secret companions, and nothing else in the account.
    resources = ["${local.parameter_prefix_arn}/*"]
  }

  statement {
    # Metadata only — this is how the script tests for existence without reading the value.
    # DescribeParameters does not support resource-level permissions, hence the wildcard; the
    # call returns names and metadata, never values.
    sid       = "DiscoverParameters"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    # Note what is NOT here: GetParameter on the token itself. The provisioner writes it and
    # can never read it back. Neither can anything else except the Runner instance role.
    sid     = "ReadNonSecretCompanions"
    actions = ["ssm:GetParameter"]
    resources = [
      "${local.parameter_prefix_arn}/runner-id",
      "${local.parameter_prefix_arn}/token-expires-at",
    ]
  }
}

resource "aws_iam_role_policy" "provisioner" {
  name   = "token-provisioning"
  role   = aws_iam_role.provisioner.id
  policy = data.aws_iam_policy_document.provisioner.json
}
