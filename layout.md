# Where each piece lives

Three layouts work. The one thing that does **not** work is passing the token itself between
two Terraform states — so that constraint, not taste, is what picks the layout.

## The rule that settles it

`ephemeral` is enforced at every boundary:

- An ephemeral value can only be assigned to a variable that is **also** declared `ephemeral`.
  Assign it to an ordinary variable and Terraform refuses the configuration.
- An `output` returning an ephemeral value must itself be declared `ephemeral`, and
  *"You cannot add the `ephemeral` argument to `output` blocks in the root module"* — ephemeral
  outputs exist only to pass data **between child modules in one configuration**.
- Ephemeral outputs are not written to state, so `terraform_remote_state` and Terragrunt
  `dependency` blocks cannot read them.

So the token can travel **root → child module** as many hops as you like. It can never travel
**state → state**. Which is fine, because it does not need to: the runner module only needs the
parameter *name*.

```
  TF_VAR_runner_auth_token
        │
        ▼
  root / Terragrunt unit  ──► child module var (ephemeral) ──► value_wo ──► AWS
        │                                                          │
        │                                                          ✗ stops here
        ▼
  outputs that cross a state boundary: parameter name, key ARN, runner id, expiry
                                        └── none of these is a secret
```

---

## Layout A — one module, one state (simplest)

Everything in the root module. This repository as published.

```
terraform-aws-gitlab-runner-goldenpath/
├── versions.tf     required_version >= 1.11.0, aws >= 5.83.0
├── variables.tf    runner_auth_token (ephemeral), _version, _expires_at, + the rest
├── locals.tf       local.auth_token_parameter_name
├── security.tf     aws_kms_key + aws_ssm_parameter (value_wo) + the meta parameter
│                   + aws_iam_role_policy granting kms:Decrypt to the instance role
├── runner.tf       the cattle-ops module call
├── checks.tf       the expiry warning
├── guardrails.tf   the plan-time red lines
└── outputs.tf
```

Terragrunt:

```
live/payments-ci/terragrunt.hcl      -> source = ".../terraform-aws-gitlab-runner-goldenpath"
```

Pick this unless you have a reason not to. One apply, automatic ordering, atomic destroy, and
the parameter name never has to be agreed between two places.

---

## Layout B — two modules, one state

A wrapper root module calls both. Use when you want the code separated but not the lifecycle.

```
terraform-aws-gitlab-runner-goldenpath/
├── modules/runner-secrets/       KMS + SSM + expiry check
│   ├── versions.tf variables.tf main.tf checks.tf outputs.tf
├── variables.tf                  runner module, now in BYO mode
├── security.tf                   only the kms:Decrypt policy remains
├── runner.tf
└── ...
live/payments-ci/
└── main.tf        module "runner_secrets" + module "gitlab_runner", wired by outputs
```

The wrapper declares `variable "runner_auth_token" { ephemeral = true }` and passes it to
`module.runner_secrets`. Both declarations must carry the keyword.

---

## Layout C — two modules, two states (the Terragrunt idiom)

```
live/payments-ci/
├── secrets/terragrunt.hcl     source = ".../modules/runner-secrets"
└── runner/terragrunt.hcl      source = "..."          (BYO mode)
                               dependency "secrets" { config_path = "../secrets" }
```

```hcl
# live/payments-ci/runner/terragrunt.hcl
dependency "secrets" {
  config_path = "../secrets"
}

inputs = {
  name                      = "payments-ci"
  auth_token_parameter_name = dependency.secrets.outputs.auth_token_parameter_name
  auth_token_kms_key_arn    = dependency.secrets.outputs.kms_key_arn
  runner_auth_token_version = dependency.secrets.outputs.runner_id
}
```

Only the `secrets` unit declares `runner_auth_token`. `TF_VAR_runner_auth_token` is exported
for the whole `run-all`, and the `runner` unit ignores it because it does not declare it.

**What you gain.** The token survives `terragrunt destroy` of the runner unit, so you can tear
down and rebuild a Runner without minting a new one and without touching GitLab. The key can be
owned by a different team with its own review path.

**What you pay.** Ordering is Terragrunt's job, not Terraform's — apply the runner unit against
a missing parameter and the instance boots, upstream's user data hits
`echo "ERROR: The preregistered runner token is not available in SSM."; exit 1`, and the only
evidence is in CloudWatch. Upstream also builds the instance role's `ssm:GetParameter` grant
from the parameter name string, so a mismatch between the two units is an `AccessDenied` at
boot rather than a plan error. The runner module's guardrail precondition requires the external
name to sit under `/platform/gitlab-runner/<name>/` to narrow that class of typo.

---

## Pure Terraform, without Terragrunt

Nothing in the design depends on Terragrunt. `ephemeral`, `value_wo`, `check` and
`plantimestamp()` are all core Terraform; Terragrunt only ever shells out to `terraform`. The
module is usable standalone with `terraform apply`, and the same code works unchanged once the
larger stack wraps it.

Three things do change:

**1. Layout C's `dependency` block becomes `terraform_remote_state`.** Same property — only
non-secret values cross, because ephemeral outputs are not in state to be read:

```hcl
data "terraform_remote_state" "secrets" {
  backend = "s3"
  config = {
    bucket = "my-tf-state"
    key    = "gitlab-runner/payments-ci/secrets.tfstate"
    region = "eu-west-2"
  }
}

module "gitlab_runner" {
  source = "../../"

  auth_token_parameter_name = data.terraform_remote_state.secrets.outputs.auth_token_parameter_name
  auth_token_kms_key_arn    = data.terraform_remote_state.secrets.outputs.kms_key_arn
  runner_auth_token_version = data.terraform_remote_state.secrets.outputs.runner_id
}
```

There is no `mock_outputs` equivalent, so the secrets root must be applied before the runner
root can plan. For standalone development that is friction for nothing — use **Layout A** while
the module stands alone, and let the larger stack choose the split later. Nothing in the module
has to change: `auth_token_parameter_name` and `runner_auth_token` are mutually exclusive
inputs, so moving from A to C is an input change, not a code change.

**2. Saved plan files.** Ephemeral values are omitted from plan files, and `-var` / `-var-file`
are rejected when applying a saved plan — so `TF_VAR_` is the only channel left, and it must be
set for **both** commands:

```bash
gitlab-runner-token --name payments-ci -- bash -c 'terraform plan -out=tf.plan && terraform apply tf.plan'
```

One wrapper invocation covering both sidesteps the question. If you plan in one CI job and
apply in a later one, the token has to be re-resolved in the second job. Verify the exact
behaviour on your Terraform version before relying on it — this is the one part of the design
the published docs do not state outright.

**3. `terraform destroy` still demands a value** for a required variable, even for a resource it
is about to delete. If the parameter is already gone there is nothing to read back, and you do
not want to mint a live GitLab runner purely to tear one down:

```bash
gitlab-runner-token --name payments-ci --no-mint -- terraform destroy
```

`--no-mint` exports a placeholder that satisfies the `glrt-` validation and nothing else. It
warns loudly, because applying with it would write the placeholder to SSM and the Runner would
fail to register.

Without the wrapper at all, `terraform apply` prompts for the token interactively — sensitive
variables are not echoed, so that is a workable fallback for a one-off, just not for anything
repeatable.

## The wrapper script

`bin/gitlab-runner-token` lives at the **repository root, not inside a module**. Modules get
vendored or downloaded from a registry; a script buried inside one will not be on anybody's
`PATH`. Ship it in the same repo, tell people to symlink it into `~/.local/bin`, or vendor it
into the Terragrunt live repo next to the units that use it.

It works the same for all three layouts, because in every one of them the token arrives the
same way — as `TF_VAR_runner_auth_token` in the environment of a single command:

```bash
gitlab-runner-token --name payments-ci --scope group --id 1234 -- terragrunt run-all apply
```
