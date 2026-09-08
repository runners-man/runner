# Changed files — token-out-of-state work

33 files. Paths are relative to the module repository root.

Everything here is Option A: the script mints the token in GitLab and hands it to a single
`terraform`/`terragrunt` invocation as `TF_VAR_runner_auth_token`; the module writes it to SSM
through a write-only argument so it never reaches state.

Start with `docs/layout.md` (where each piece lives, and the pure-Terraform notes) and
`docs/token-provisioning.md` (why the obvious approach leaks, and what else to watch for).

---

## Modified — 8 files

| File | What changed |
|---|---|
| `variables.tf` | `runner_auth_token` now optional (`default = null`) with cross-variable validation. New: `runner_auth_token_expires_at`, `auth_token_parameter_name`, `auth_token_kms_key_arn`. `runner_auth_token_version` description rewritten — use the GitLab runner id, not a hand-maintained counter. |
| `locals.tf` | `auth_token_parameter_name` now `coalesce`d against the new variable; added `manage_auth_token_parameter`. Single source of truth for the name, so `runner.tf` need not know which mode is active. |
| `security.tf` | `aws_ssm_parameter.runner_auth_token` is `count`-gated on managed mode. New `aws_ssm_parameter.runner_auth_token_meta` (plain String, non-secret). New `dynamic "statement"` granting `kms:Decrypt` on an externally owned key. |
| `runner.tf` | `preregistered_runner_token_ssm_parameter_name` now reads `local.auth_token_parameter_name` rather than the resource attribute. Comment added on the `depends_on`. |
| `outputs.tf` | `auth_token_ssm_parameter_name` sourced from the local. New: `auth_token_mode`, `runner_auth_token_expires_at`, `runner_id`. |
| `guardrails.tf` | `effective_configuration` gains `auth_token_mode` and `auth_token_parameter_name` (never the value). New precondition: an external parameter must live under `/platform/gitlab-runner/<name>/`, because upstream builds the instance role's `ssm:GetParameter` grant from that literal string. |
| `docs/security-model.md` | Variable count 13 → 17. Token row rewritten. New section "The trap this avoids". |
| `CHANGELOG.md` | Entry for BYO-parameter mode. |

## New — Terraform

| File | Purpose |
|---|---|
| `checks.tf` | `check "runner_auth_token_expiry"` — a plan-time **warning** from 14 days out. A `check` warns; `guardrails.tf` is where things fail. |
| `tests/token-modes.tftest.hcl` | Seven `run` blocks covering both modes and five ways of getting them wrong. Note the limitation stated in its header: `terraform test` has no view of the state file, so the "no token in state" check is a `grep` over `terraform show -json`, run after a **refresh** — not after the first apply. |

## New — the supporting module (only if you want two states)

`modules/runner-secrets/` — `versions.tf`, `variables.tf`, `main.tf`, `checks.tf`,
`outputs.tf`, `README.md`.

KMS key + the SecureString (`value_wo`) + the non-secret metadata parameter + the expiry check.
Its four outputs — parameter name, key ARN, runner id, expiry — are all non-secret, which is the
whole point: the token *cannot* be output, because an output carrying it must be `ephemeral`
and ephemeral outputs are not written to state for another configuration to read.

**If one state is fine, skip this module entirely** and use the root module on its own. It
contains the same resources.

## New — the script

`bin/gitlab-runner-token`

Repository root, **not** inside a module — modules get vendored or pulled from a registry, so a
script buried in one is never on anyone's `PATH`.

```bash
# first time
gitlab-runner-token --name payments-ci --scope group --id 1234 -- terraform apply

# afterwards: reads the token back from SSM, mints nothing, produces no diff
gitlab-runner-token --name payments-ci -- terraform apply

# rotate: new runner, new id, value_wo re-sent, instance rolls, old runner deleted
gitlab-runner-token --name payments-ci --scope group --id 1234 --rotate -- terraform apply

# destroy, when the parameter is already gone
gitlab-runner-token --name payments-ci --no-mint -- terraform destroy
```

PAT from `$GITLAB_API_TOKEN` or the `credentials "your.gitlab.host"` block in `~/.terraformrc`.
There is deliberately no `--print-env`: `exec` confines the token to one process tree, whereas
`eval $(...)` would leave it in your shell and your history.

## New — docs

| File | |
|---|---|
| `docs/layout.md` | The three layouts, which file each block goes in, and the pure-Terraform section: saved plan files, `terraform_remote_state` in place of Terragrunt `dependency`, and `terraform destroy`. |
| `docs/token-provisioning.md` | Why creating the parameter in Terraform and populating it with the CLI leaks (`ignore_changes` suppresses diffs, not reads), plus twelve things worth deciding before you commit. |

## New — examples

`examples/split-state/` — Layout C as two Terragrunt units. **This is the one matching your
setup.**

`examples/external-token-provisioning/` — 9 files. This is **Option B**, which you did not
pick: the parameter is created entirely outside Terraform and the module receives only its
name. Kept because the BYO-mode variables exist either way and the pipeline sketch shows the
teardown problem. **Safe to delete** if you are staying with Option A.

---

## Two things to verify locally

1. **Saved plan files.** Ephemeral values are omitted from plan files, and `-var` is rejected
   when applying a saved plan — so `TF_VAR_` must be set for both commands. The docs state each
   half but not the combination; test it on your Terraform version before depending on it.
2. **Migrating an existing parameter** from `value` to `value_wo`: old state *versions* in your
   backend still hold the plaintext. Rotate the token after migrating and expire those
   versions, or you have fixed the future and left the past.
