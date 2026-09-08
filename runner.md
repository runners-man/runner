
## 1. The guarantee, precisely

Two language-level mechanisms, not conventions:

- **`ephemeral = true` on the variable.** Terraform omits ephemeral values from state *and plan files*, and referencing one anywhere non-ephemeral is a **hard error at validate time**. You cannot accidentally `output` it, or stuff it in a `local` that something else reads. The compiler enforces it.
- **`value_wo` on `aws_ssm_parameter`.** Provider docs: *"write-only values are never stored to state."* The provider sends it and discards it. Contrast the plain `value` argument on the same resource: *"The unencrypted value of a SecureString will be stored in the raw state as plain-text."*

Requires **Terraform ≥ 1.11** and **AWS provider ≥ 5.83** (6.x fine). If `value_wo` comes back as an unsupported argument, that's the version.

What it does **not** cover, stated plainly:

- The process environment during the apply — the token is in the operator's env for that one command. The wrapper `exec`s your command so it never reaches your interactive shell or history.
- `TF_LOG=trace` will print the request body. Don't debug with trace while applying this.
- **Saved plans.** Ephemeral values aren't in the plan file, so `plan -out=x` then `apply x` needs the variable set at *both* steps. Wrap both, or don't use saved plans here.
- **If you're migrating an existing parameter from `value` to `value_wo`**: old state *versions* in your backend still hold the plaintext. Rotate the token after the migration and expire those versions — otherwise you've fixed the future and left the past.

## 2. `versions.tf`

```hcl
terraform {
  required_version = ">= 1.11.0"   # load-bearing: write-only arguments

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.83.0"        # load-bearing: value_wo on aws_ssm_parameter
    }
  }
}
```

## 3. `variables.tf`

```hcl
variable "runner_auth_token" {
  description = <<-EOT
    GitLab Runner authentication token (glrt-...).

    `ephemeral`: Terraform omits it from state and plan files, and it is an error to reference
    it anywhere that would persist it. Supplied via TF_VAR_runner_auth_token by
    scripts/gitlab-runner-token — never from a .tfvars file.
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
    Rotation counter. Use the GitLab runner id: it is a database primary key, so it only ever
    increases, and it changes exactly when — and only when — a new token is minted. That
    removes the "someone forgot to bump the counter" failure mode entirely.
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

## 4. Wherever your SSM resources live

```hcl
locals {
  auth_token_parameter_name = "/platform/gitlab-runner/${var.name}/auth-token"
}

resource "aws_ssm_parameter" "runner_auth_token" {
  name        = local.auth_token_parameter_name
  description = "GitLab Runner authentication token for ${var.name}. Value is write-only."
  type        = "SecureString"
  key_id      = aws_kms_key.runner.arn   # or your existing key; omit for the AWS-managed one
  tier        = "Standard"

  # The whole point. NOT `value`.
  value_wo         = var.runner_auth_token
  value_wo_version = var.runner_auth_token_version

  tags = local.tags
}

# Non-secret companion: lets the wrapper answer "which runner is this and when does its token
# lapse?" on a later apply without reading the SecureString back — and gets destroyed with the
# stack instead of being left behind in Parameter Store.
resource "aws_ssm_parameter" "runner_auth_token_meta" {
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
```

Plain `value` on the second one is correct — nothing sensitive is in it, and the script needs to read it.

## 5. The `cattle-ops` module call

```hcl
module "gitlab_runner" {
  # ...

  runner_gitlab = {
    url            = local.gitlab_url
    runner_version = var.runner_version

    preregistered_runner_token_ssm_parameter_name = aws_ssm_parameter.runner_auth_token.name
  }

  runner_instance = {
    # ...
    # Upstream's ASG has instance_refresh { triggers = ["tag"] }. This tag is what turns a
    # rotation into an actual instance roll rather than only an SSM update.
    additional_tags = {
      "platform:token-version" = tostring(var.runner_auth_token_version)
    }
  }

  depends_on = [aws_ssm_parameter.runner_auth_token]
}
```

## 6. IAM — only if you bring your own KMS key

Upstream attaches its KMS policy **only** when `enable_managed_kms_key = true`. With your own key the instance reads the SecureString and then fails to decrypt it, visible only in the boot log:

```hcl
data "aws_iam_policy_document" "runner_kms_decrypt" {
  statement {
    sid       = "DecryptRunnerManagedKey"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.runner.arn]
  }
}

resource "aws_iam_role_policy" "runner_kms_decrypt" {
  name       = "${var.name}-kms-decrypt"
  role       = "${var.name}-instance"   # upstream builds this from iam_object_prefix
  policy     = data.aws_iam_policy_document.runner_kms_decrypt.json
  depends_on = [module.gitlab_runner]
}
```

## 7. `checks.tf` — clean expiry

```hcl
check "runner_auth_token_expiry" {
  assert {
    condition = (
      var.runner_auth_token_expires_at == "never" ||
      timecmp(plantimestamp(), timeadd(var.runner_auth_token_expires_at, "-336h")) < 0
    )
    error_message = "The Runner authentication token expires at ${var.runner_auth_token_expires_at}, less than 14 days away. Rotate with: gitlab-runner-token --name ${var.name} --scope <group|project> --id <id> --rotate -- terragrunt apply"
  }
}
```

A `check` warns; it doesn't fail the apply. Failing a deploy is the wrong response to "expires in nine days."

**But the real answer on expiry is upstream of Terraform.** GitLab only auto-rotates when the group or project sets a runner expiration, and it writes the rotated token into `config.toml` **on the running host — never back to SSM**. Your instance is replaced on every scheduled scale-out, so that rotated value is discarded and the next morning's instance boots with whatever SSM holds, which GitLab has already invalidated. That's [cattle-ops #1196](https://github.com/cattle-ops/terraform-aws-gitlab-runner/issues/1196), still open with no fix.

So: **leave "Runners expiration" empty** for platform runners (group/project → Settings → CI/CD → Runners) and rotate deliberately with `--rotate`. The `check` block and the wrapper's `--min-remaining-days` are the fallback if your policy forbids that.

## 8. Usage

```bash
# first time
gitlab-runner-token --name payments-ci --scope group --id 1234 -- terragrunt apply

# every time after — reads the token back from SSM, mints nothing, no diff
gitlab-runner-token --name payments-ci -- terragrunt apply

# rotate: new runner, new id, value_wo re-sent, instance rolls, old runner deleted
gitlab-runner-token --name payments-ci --scope group --id 1234 --rotate -- terragrunt apply
```

The PAT comes from `$GITLAB_API_TOKEN` or the `credentials "your.gitlab.host"` block in `~/.terraformrc` — the same one you already use for the module registry. Group scope needs Maintainer/Owner on the group; a 403 on group scope is the signal to fall back to `--scope project`, and the script says so in the error.

There's deliberately no `--print-env`. `eval $(...)` would leave the token in your shell for the rest of the day; `exec` confines it to that one process tree.
