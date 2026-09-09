All parses clean. Layout A, flat — no submodule, no BYO mode, no `count`.

## `versions.tf` — 2 lines

```hcl
terraform {
  required_version = ">= 1.11.0"   # CHANGED — write-only arguments

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.83.0"        # CHANGED — value_wo on aws_ssm_parameter
    }
  }
}
```

## `variables.tf` — add 3

```hcl
variable "runner_auth_token" {
  description = <<-EOT
    GitLab Runner authentication token (`glrt-...`).

    `ephemeral`: Terraform omits it from state and plan files, and it is a configuration error
    to reference it anywhere that would persist it. Supplied as TF_VAR_runner_auth_token by
    bin/gitlab-runner-token — never from a committed .tfvars file.
  EOT
  type      = string
  ephemeral = true
  sensitive = true

  validation {
    # A shape check only, so the error message cannot leak the value.
    condition     = startswith(var.runner_auth_token, "glrt-")
    error_message = "runner_auth_token must be a GitLab Runner authentication token beginning with `glrt-`. Legacy registration tokens are not supported."
  }
}

variable "runner_auth_token_version" {
  description = <<-EOT
    Rotation counter. Because the token never enters state, Terraform cannot detect that its
    value changed — this number is what tells it.

    Use the GitLab runner id: a database primary key, so it only ever increases, and it changes
    exactly when a new token is minted. The script exports it, which removes the "someone forgot
    to bump the counter" failure mode.
  EOT
  type = number

  validation {
    condition     = var.runner_auth_token_version >= 1 && floor(var.runner_auth_token_version) == var.runner_auth_token_version
    error_message = "runner_auth_token_version must be a whole number of 1 or greater."
  }
}

variable "runner_auth_token_expires_at" {
  description = "RFC3339 expiry, or `never`. NOT a secret — deliberately in state and outputs so a plan can warn before the token lapses."
  type        = string
  default     = "never"

  validation {
    condition = (
      var.runner_auth_token_expires_at == "never" ||
      can(timecmp(var.runner_auth_token_expires_at, "2000-01-01T00:00:00Z"))
    )
    error_message = "runner_auth_token_expires_at must be `never` or an RFC3339 timestamp."
  }
}
```

## `locals.tf` — add 1

```hcl
  auth_token_parameter_name = "/platform/gitlab-runner/${var.name}/auth-token"
```

## `security.tf` — add 4 blocks

```hcl
# value_wo is a write-only argument: the provider sends it to AWS and discards it. Never in
# state, never in a plan. NOT `value` — and NOT a placeholder plus ignore_changes, which reads
# the real value back on the next refresh.
resource "aws_ssm_parameter" "runner_auth_token" {
  name        = local.auth_token_parameter_name
  description = "GitLab Runner authentication token for ${var.name}. Managed by Terraform; value is write-only."
  type        = "SecureString"
  key_id      = aws_kms_key.runner.arn
  tier        = "Standard"

  value_wo         = var.runner_auth_token
  value_wo_version = var.runner_auth_token_version

  tags = local.tags
}

# Non-secret companion, so the script can answer "which runner is this, and when does its token
# lapse?" on a later apply without reading the SecureString back. Plain `value` on purpose.
resource "aws_ssm_parameter" "runner_auth_token_meta" {
  name        = "/platform/gitlab-runner/${var.name}/token-meta"
  description = "Non-secret metadata for the ${var.name} Runner authentication token."
  type        = "String"
  tier        = "Standard"

  value = jsonencode({
    runner_id  = var.runner_auth_token_version
    expires_at = var.runner_auth_token_expires_at
  })

  tags = local.tags
}

# Upstream attaches a KMS policy to the Runner role only when it manages the key itself
# (enable_managed_kms_key = true). We bring our own, so without this the instance reads the
# SecureString and then fails to decrypt it — visible only in the boot log.
data "aws_iam_policy_document" "runner_kms_decrypt" {
  statement {
    sid       = "DecryptRunnerKey"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.runner.arn]
  }

  statement {
    sid       = "EncryptCacheObjects"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.runner.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "runner_kms_decrypt" {
  name   = "${var.name}-kms-decrypt"
  role   = "${var.name}-instance"   # upstream builds this from iam_object_prefix
  policy = data.aws_iam_policy_document.runner_kms_decrypt.json

  depends_on = [module.gitlab_runner]
}
```

If your KMS key policy doesn't already grant the CloudWatch Logs service principal — upstream encrypts the log group with whatever key you hand it, and IAM delegation isn't enough for a service principal — add:

```hcl
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      },
```

## `runner.tf` — 4 changes inside the module block

```hcl
  kms_key_id             = aws_kms_key.runner.arn
  enable_managed_kms_key = false

  runner_instance = {
    # ...
    # Upstream's ASG has instance_refresh { triggers = ["tag"] }. This tag is what turns a
    # rotation into an actual instance roll rather than only an SSM update.
    additional_tags = {
      "platform:token-version" = tostring(var.runner_auth_token_version)
    }
  }

  runner_gitlab = {
    # ...
    preregistered_runner_token_ssm_parameter_name = aws_ssm_parameter.runner_auth_token.name
  }

  depends_on = [aws_ssm_parameter.runner_auth_token]
```

## `checks.tf` — new file

```hcl
# A warning, not a failure. Failing an apply is the wrong response to "expires in nine days" —
# but saying nothing until the morning it breaks is worse.
check "runner_auth_token_expiry" {
  assert {
    condition = (
      var.runner_auth_token_expires_at == "never" ||
      timecmp(plantimestamp(), timeadd(var.runner_auth_token_expires_at, "-336h")) < 0
    )
    error_message = <<-EOT
      The Runner authentication token expires at ${var.runner_auth_token_expires_at}, less than
      14 days away. Rotate it:

        gitlab-runner-token --name ${var.name} --scope <group|project> --id <id> --rotate -- terraform apply

      If your group or project sets a runner expiration, GitLab also rotates the token by itself
      and writes the new value into config.toml on the running host — never back to SSM. The host
      is replaced on every scheduled scale-out, so that value is discarded and the next instance
      boots with whatever SSM holds. Leave "Runners expiration" empty for platform runners and
      rotate deliberately.
    EOT
  }
}
```

## `outputs.tf` — add 3

```hcl
output "auth_token_ssm_parameter_name" {
  description = "Name of the SSM SecureString holding the Runner authentication token. The value never enters Terraform state and cannot be read back from Terraform."
  value       = aws_ssm_parameter.runner_auth_token.name
}

output "runner_auth_token_expires_at" {
  description = "When the current Runner authentication token lapses, or `never`. Not a secret. A plan warns from 14 days out."
  value       = var.runner_auth_token_expires_at
}

output "runner_id" {
  description = "GitLab id of the runner this deployment is registered as. Doubles as the token rotation counter."
  value       = var.runner_auth_token_version
}
```

---

Two notes. `bin/gitlab-runner-token` is unchanged — it works the same against a flat module.

And since you've dropped BYO mode, the Layout C door is closed unless the consuming product writes its own KMS + SSM unit. If you want to leave it ajar cheaply, add `count = var.auth_token_parameter_name == null ? 1 : 0` to the two `aws_ssm_parameter` resources and the KMS key later — it's additive, not a restructure.
