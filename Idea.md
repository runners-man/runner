# TASK: GitLab Runner token provisioning (bash script + Terraform edits)

You are editing an existing repository. Build a bash script and make specific Terraform edits so
that a GitLab Runner authentication token is stored in AWS SSM Parameter Store and **never**
appears in Terraform state or plan files.

Work through the sections in order. Do not skip Section 2.

---

## 1. HARD RULES

These are absolute. Do not change them. Do not "improve" them.

1. The Terraform variable holding the token MUST be declared `ephemeral = true` and `sensitive = true`.
2. The variable MUST be required. It MUST NOT have a `default`.
3. The SSM parameter MUST use the argument `value_wo`. It MUST NOT use `value`.
4. `value_wo_version` MUST be set from a variable. It MUST NOT be hardcoded to `1` or any literal.
5. `value_wo_version` MUST be the GitLab runner id.
6. The script MUST always resolve a real token before Terraform runs. Never run Terraform with an
   empty or missing token.
7. The script MUST NOT print the token to stdout. It MUST pass the token by exporting an
   environment variable and then calling `exec` on the user's command.
8. Terraform MUST NOT read the token. Never use `data "aws_ssm_parameter"`.
9. If any GitLab API call needed to make a decision fails, the script MUST exit non-zero. Never
   treat a failed API call as "no runner exists".

---

## 2. FACTS — do not re-derive these, do not work around them

These are verified facts about the `hashicorp/aws` provider. Accept them as given.

**FACT A.** `aws_ssm_parameter.value_wo` is a write-only argument. The provider sends it to AWS and
discards it. It is never written to state.

**FACT B.** `aws_ssm_parameter.value` IS written to state, in plaintext, even for a `SecureString`.

**FACT C.** Putting a placeholder in `value` plus `lifecycle { ignore_changes = [value] }` DOES NOT
work. `ignore_changes` suppresses diffs, not reads. The provider refreshes and stores the real
plaintext. Do not use this pattern.

**FACT D.** On every refresh the provider fetches the parameter **with decryption**, then checks
whether `value_wo` is non-empty in the config:
- non-empty → it sets `value` to null (safe)
- empty → it writes the decrypted plaintext into `value` in state (LEAK)

This is why Rule 6 exists. An empty `value_wo` does not mean "leave it alone".

**FACT E.** `value_wo` has `ExactlyOneOf{value_wo, insecure_value, value}` and
`RequiredWith{value_wo_version}`. Omitting the token is a validation error.

**FACT F.** The provider only re-sends `value_wo` when `value_wo_version` **changes**. If the
version is unchanged, Terraform sends nothing to AWS and produces no diff. This is why reusing an
existing token is cheap and safe.

**FACT G.** `POST /api/v4/user/runners` returns the token exactly once. There is NO API to read a
runner's token back. If the token is lost, the only recovery is to delete the runner and register a
new one.

**FACT H.** Reading the token from SSM **in bash** is safe and does not break anything. The value
goes: bash → environment variable → ephemeral Terraform variable → `value_wo`. It never becomes a
Terraform attribute. Only reading it *inside Terraform* is forbidden (Rule 8).

**FACT I.** The version is stamped into an EC2 instance tag. The upstream Auto Scaling group has
`instance_refresh { triggers = ["tag"] }`. So changing the version replaces the Runner instance.
This is desirable when the token changes, and harmful otherwise. Never increment the version on
every run.

---

## 3. THE THREE FACTS AND WHERE EACH LIVES

| Question | Answer comes from |
|---|---|
| Does a runner registration already exist? | The **description** of the GitLab runner |
| What is the token? | The **SSM SecureString parameter** |
| What is the version counter? | The **GitLab runner id** |

Do not create any extra storage. No metadata parameter. No local state file. No DynamoDB table.
GitLab returns the runner id in both cases you need it: in the description lookup, and in the
registration response.

---

## 4. SCRIPT INTERFACE

```
ensure-runner-token.sh --name <runner-name> --unique <unique-string> \
  --scope <group|project> --id <numeric-id> \
  [--gitlab-url <url>] [--region <aws-region>] [--rotate] [--no-mint] \
  -- <command to run>
```

- `--unique` is a unique string that comes from the user's input file.
- Everything after `--` is the command to run (for example `terraform apply`).
- `GITLAB_API_TOKEN` holds the GitLab personal access token.

Derived values:

```
DESCRIPTION  = the --unique value
TOKEN_PARAM  = /platform/gitlab-runner/<name>/auth-token
```

Build `DESCRIPTION` in exactly ONE place in the script. Use that same variable for both the lookup
and the registration. If the lookup string and the registration string differ by even one
character, the script registers a duplicate runner on every single run.

---

## 5. SCRIPT ALGORITHM

Follow these steps in this order.

### STEP 1 — Probe GitLab

Call:
- group scope: `GET /api/v4/groups/<id>/runners?type=group_type`
- project scope: `GET /api/v4/projects/<id>/runners?type=project_type`

Use the group/project endpoint, NOT a global runner list. Scoping prevents matching another team's
runner.

No pagination needed — users have at most a few runners.

Count the runners whose `description` is **exactly equal** to `DESCRIPTION`.

```
if HTTP status is not 200:
    print error, exit 1          # Rule 9. Do not continue.
if match count == 0:
    GL_ID = ""                   # no registration exists
if match count == 1:
    GL_ID = that runner's id
if match count > 1:
    print error, exit 1          # the unique string is not unique
```

Exiting on >1 match is mandatory: later steps DELETE the matched runner, and deleting the wrong
one is unrecoverable.

If the API returns 401 or 403, say in the error message that listing runners requires `api` scope
and Maintainer or Owner, and that `create_runner` scope alone is not enough.

### STEP 2 — Probe SSM

```
SSM_TOKEN = aws ssm get-parameter --name $TOKEN_PARAM --with-decryption \
              --query 'Parameter.Value' --output text
```

Treat the token as present only if the command succeeded AND the value starts with `glrt-`.
Otherwise set `SSM_TOKEN = ""`.

Suppress stderr on this call. A missing parameter is a normal, expected state, not an error.

### STEP 3 — Decide

```
if --rotate was passed:
    ACTION = REGISTER;  DELETE_FIRST = GL_ID
else if GL_ID is set     and SSM_TOKEN is set:
    ACTION = REUSE
else if GL_ID is empty   and SSM_TOKEN is set:
    ACTION = REGISTER                      # user deleted their registration
else if GL_ID is set     and SSM_TOKEN is empty:
    ACTION = REGISTER;  DELETE_FIRST = GL_ID   # token unrecoverable, see FACT G
else:
    ACTION = REGISTER                      # first run
```

Print which branch was taken. The operator needs to see it.

### STEP 4 — If ACTION is REUSE

```
TOKEN      = SSM_TOKEN
RUNNER_ID  = GL_ID
```

Do nothing else. Make no further API calls. Because the version is unchanged, Terraform will send
nothing to AWS (FACT F).

### STEP 5 — If ACTION is REGISTER

5a. If `DELETE_FIRST` is set, delete that runner first:

```
DELETE /api/v4/runners/<DELETE_FIRST>
  204 or 404 -> fine, continue
  403        -> error: "create_runner cannot delete runners; this needs api scope", exit 1
  anything else -> error, exit 1
```

Delete BEFORE registering. The old runner holds a token nobody can produce any more; deleting it
revokes that token.

5b. Register:

```
POST /api/v4/user/runners
  runner_type  = group_type   (or project_type)
  group_id     = <id>         (or project_id = <id>)
  description  = $DESCRIPTION
  tag_list     = docker,linux,<name>
  run_untagged = false
  locked       = true
```

Expect HTTP 201. On any other status, print the response body with any `glrt-...` string redacted,
then exit 1. Add a hint for 401 (token invalid or missing `create_runner` scope) and 403 (not a
Maintainer or Owner of the group/project).

From the 201 response read:
```
TOKEN      = .token
RUNNER_ID  = .id
```

Verify `TOKEN` starts with `glrt-`. If not, exit 1 and state that runner `RUNNER_ID` is now orphaned
in GitLab.

### STEP 6 — Hand off

```
export TF_VAR_runner_auth_token="$TOKEN"
export TF_VAR_runner_auth_token_version="$RUNNER_ID"
exec "$@"
```

Use `exec`. Do not run the command as a subprocess and do not print the variables.

### STEP 7 — `--no-mint` mode

`terraform destroy` still requires a value for a required variable. If `ACTION` is `REGISTER` and
`--no-mint` was passed, do not call GitLab. Instead:

```
TOKEN     = "glrt-PLACEHOLDER-DO-NOT-APPLY"
RUNNER_ID = GL_ID if set, otherwise 1
```

Print a loud warning that this is safe for `destroy` and `plan` only and must never be used for
`apply`.

### Script hygiene

- Start with `set -euo pipefail` then `set +x`. The `set +x` guards against a caller enabling trace,
  which would print the token.
- Put the GitLab token in a `curl --config` file, not on the command line. Command-line arguments
  are visible to every user on the machine via `ps`.
- Create that file in a `mktemp -d` directory with `umask 077`, and delete it with a `trap` on
  `EXIT INT TERM`.
- Write API response bodies to files in that directory, not to variables.

---

## 6. TERRAFORM EDITS

Use these blocks as written. Do not redesign them.

### 6a. `versions.tf`

```hcl
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.83.0"
    }
  }
}
```

Both constraints are load-bearing: write-only arguments need Terraform 1.11, and `value_wo` on
`aws_ssm_parameter` needs AWS provider 5.83.

### 6b. `variables.tf` — add both

```hcl
variable "runner_auth_token" {
  description = "GitLab Runner authentication token. Ephemeral: never written to state or plan files. Supplied via TF_VAR_runner_auth_token by ensure-runner-token.sh."
  type        = string
  ephemeral   = true
  sensitive   = true

  validation {
    condition     = startswith(var.runner_auth_token, "glrt-")
    error_message = "runner_auth_token must begin with `glrt-`."
  }
}

variable "runner_auth_token_version" {
  description = "The GitLab runner id. Changes only when a new runner is registered, which is exactly when the token must be re-sent to SSM."
  type        = number
}
```

The validation checks the prefix only. Never write a validation whose error message could contain
the value.

### 6c. The SSM parameter

```hcl
resource "aws_ssm_parameter" "runner_auth_token" {
  name   = "/platform/gitlab-runner/${var.name}/auth-token"
  type   = "SecureString"
  key_id = aws_kms_key.runner.arn

  value_wo         = var.runner_auth_token
  value_wo_version = var.runner_auth_token_version
}
```

### 6d. The upstream module call — three edits

```hcl
module "gitlab_runner" {
  # ... existing configuration ...

  runner_gitlab = {
    # ... existing fields ...
    preregistered_runner_token_ssm_parameter_name = aws_ssm_parameter.runner_auth_token.name
  }

  runner_instance = {
    # ... existing fields ...
    additional_tags = {
      "platform:token-version" = tostring(var.runner_auth_token_version)
    }
  }

  depends_on = [aws_ssm_parameter.runner_auth_token]
}
```

The `additional_tags` entry is required. Without it a new token reaches SSM but the running agent
keeps using the old one until something else replaces the instance (FACT I).

The parameter name must match exactly: the upstream module builds the instance role's
`ssm:GetParameter` IAM grant from that literal string. A mismatch is an `AccessDenied` at boot, not
a Terraform error.

### 6e. If a wrapper root module exists

If a root module sits between the variable and the SSM resource, declare the variable as
`ephemeral = true` in **both** places and pass it through:

```hcl
variable "runner_auth_token" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "runner" {
  source = "./modules/runner"

  runner_auth_token         = var.runner_auth_token
  runner_auth_token_version = var.runner_auth_token_version
}
```

Terraform refuses to assign an ephemeral value to a non-ephemeral variable, so missing the keyword
in either place is a hard error.

---

## 7. FORBIDDEN PATTERNS

Do not produce any of these. Each one reintroduces the plaintext token into state.

```hcl
# WRONG — plaintext in state
resource "aws_ssm_parameter" "t" {
  value = var.runner_auth_token
}

# WRONG — ignore_changes suppresses diffs, not reads (FACT C)
resource "aws_ssm_parameter" "t" {
  value     = "PLACEHOLDER"
  lifecycle { ignore_changes = [value] }
}

# WRONG — data sources store what they read
data "aws_ssm_parameter" "t" {
  name = "/platform/gitlab-runner/x/auth-token"
}

# WRONG — hardcoded version means new tokens are silently ignored (FACT F)
value_wo_version = 1

# WRONG — makes it possible to apply with no token, which triggers FACT D
variable "runner_auth_token" {
  type    = string
  default = null
}

# WRONG — the gitlab provider exposes the token as a readable attribute
resource "gitlab_user_runner" "r" { }
```

Also do not:
- call the script from Terraform via `local-exec`, `null_resource`, or `data "external"`
- add a `--print-env` or `--export` mode to the script
- add pagination to the GitLab listing call (not needed; users have at most a few runners)
- create a metadata parameter, local cache file, or any other store for the runner id

---

## 8. ACCEPTANCE CHECKLIST

Verify each item before reporting the work complete.

Static checks:
- [ ] `grep -rn 'value_wo_version' ` shows a variable reference, never a literal number
- [ ] `grep -rn '^\s*value\s*=' ` matches no `aws_ssm_parameter` resource holding the token
- [ ] `grep -rn 'ignore_changes'` does not appear near any SSM parameter
- [ ] `grep -rn 'data "aws_ssm_parameter"'` returns nothing for the token path
- [ ] `ephemeral = true` appears on every declaration of `runner_auth_token`
- [ ] `terraform validate` passes
- [ ] `shellcheck` passes on the script
- [ ] `bash -n` passes on the script

Behavioural checks. Stub out `aws` and `curl` with fake executables placed earlier on `PATH`, then
confirm each branch prints the expected decision and exports the expected variables:
- [ ] no runner, no parameter → registers; version = new id
- [ ] runner present, parameter present → reuses; version unchanged; **no GitLab POST or DELETE**
- [ ] no runner, parameter present → registers; version = new id, different from the old one
- [ ] runner present, no parameter → deletes the runner, then registers
- [ ] `--rotate` → deletes the old runner, then registers
- [ ] two runners share the description → exits 1, registers nothing, deletes nothing
- [ ] the runner listing returns 403 → exits 1, registers nothing
- [ ] `--no-mint` with no parameter → exports the placeholder, makes no GitLab calls

The second behavioural check is the most important one. If reusing an existing token makes a GitLab
POST, the script is wrong.

Finally, after a real apply and then a second `terraform plan`, confirm:

```
terraform show -json | grep -c 'glrt-'      # must be 0
```

Run this after a **refresh or second plan**, not just after the first apply. FACT D means a leak
appears on the second plan, not the first.
