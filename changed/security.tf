###############################################################################
# The key and the token — delegated to modules/runner-secrets.
#
# Why a submodule rather than resources in this file: it makes the pair independently
# *sourceable*. This root module composes it, giving one state. A Terragrunt stack can instead
# run `modules/runner-secrets` as its own unit and point this module at the result through
# `auth_token_parameter_name` + `auth_token_kms_key_arn`, giving two states.
#
# Same code, two layouts, chosen by the consumer rather than baked in here. See docs/layout.md.
#
# The token reaches the submodule because `runner_auth_token` is declared `ephemeral` on BOTH
# sides. Terraform checks that at the boundary — assign an ephemeral value to an ordinary
# variable and it refuses the configuration outright.
###############################################################################

module "secrets" {
  count  = local.manage_auth_token_parameter ? 1 : 0
  source = "./modules/runner-secrets"

  name = var.name
  tags = var.tags

  runner_auth_token            = var.runner_auth_token
  runner_auth_token_version    = var.runner_auth_token_version
  runner_auth_token_expires_at = var.runner_auth_token_expires_at
}

# ---------------------------------------------------------------------------
# Supplementary IAM
# ---------------------------------------------------------------------------

# Upstream attaches a KMS policy to the Runner role only when it manages the key itself
# (`enable_managed_kms_key = true`). We always bring our own — from the submodule in managed
# mode, from a variable in external mode — so without this the instance reads the SecureString
# and then fails to decrypt it, a failure that only shows up in the boot log.
#
# Scoped to one key. `ViaService` is deliberately unconstrained on the decrypt statement:
# the same key decrypts the SSM parameter, the S3 cache objects and the log group.
data "aws_iam_policy_document" "runner_kms_decrypt" {
  statement {
    sid = "DecryptRunnerKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [local.kms_key_arn]
  }

  statement {
    # The S3 cache adapter writes objects encrypted with this key.
    sid = "EncryptCacheObjects"
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [local.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "runner_kms_decrypt" {
  name   = "${var.name}-kms-decrypt"
  role   = local.runner_instance_role_name
  policy = data.aws_iam_policy_document.runner_kms_decrypt.json

  # The role is created inside the child module. Its name is deterministic, so referencing it
  # by string avoids a dependency cycle with the key — but Terraform then needs telling about
  # the ordering explicitly.
  depends_on = [module.gitlab_runner]
}
