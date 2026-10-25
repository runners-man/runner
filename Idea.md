GitLab Runner token provisioning — specification

## Objective

A user-run bash script provisions a GitLab Runner authentication token and hands it to a Terraform module, which stores it in an AWS SSM SecureString parameter. The token must never appear in Terraform state or plan files. The flow must be safe to re-run repeatedly, and must correctly pick up a new token whenever a new registration happens.

## Core mechanism — why the token stays out of state

Two independent mechanisms, both required:

**The Terraform variable is declared `ephemeral`.** Terraform omits ephemeral values from state and plan files, and it is a configuration error to reference one anywhere that would persist it — so it cannot accidentally be assigned to a normal attribute, an output, or user data. Requires Terraform ≥ 1.11.

**The SSM parameter uses the write-only argument `value_wo`, not `value`.** The provider sends the value to AWS and discards it; the attribute is never stored. Requires AWS provider ≥ 5.83.

Both are necessary. State stores resource _attributes_, not variable values, so the variable itself was never the leak — the leak would be `value = var.token`. Conversely, without `ephemeral`, the value would still be written into saved plan files.

Critically, `value_wo` must **always** be supplied with a real value. In the AWS provider's read path, the parameter is fetched with decryption on every refresh, and the provider then branches on whether `value_wo` is non-empty in the current config: if it is non-empty, the `value` attribute is explicitly nulled; if it is empty, the provider writes the **decrypted plaintext** into state. An empty `value_wo` does not mean "leave it alone" — it means "this parameter has no write-only value". Additionally, `value_wo` carries `ExactlyOneOf{value_wo, insecure_value, value}` and `RequiredWith{value_wo_version}`, so omitting it is a validation error. Therefore: never make the token variable optional, and never run an apply without resolving a real token.

## Identity and state model

Three facts, each with exactly one home:

|Fact|Source of truth|
|---|---|
|Does a registration exist?|The **description** of the GitLab runner, which contains a unique string from the user's input file|
|The token|The SSM SecureString parameter|
|The rotation counter|The **GitLab runner id**|

No additional metadata store is needed. GitLab returns the runner id on both paths — from the description lookup when reusing, from the registration response when registering.

The description must be constructed in exactly one place in the script and used for both the lookup and the registration. Two slightly different expressions is the failure mode that silently registers a duplicate on every run.

## The script

Runs before Terraform, in the same process tree. It is not invoked by Terraform — no `local-exec`, no `external` data source. It resolves values, exports them as environment variables, then replaces itself with the command it was given (`exec`), so the token exists only in that process tree and never reaches the user's interactive shell or shell history. There should be no option that prints the token to stdout.

### Step 1 — Probe GitLab

List the runners of the group or project being deployed into (not a global runner list — scoping prevents matching another team's identically described runner) and count those whose description exactly equals the expected string.

- **Zero matches** → no registration exists.
- **Exactly one match** → a registration exists; capture its id.
- **More than one match** → abort with a clear error. The unique string is not unique, and one branch below deletes the runner it matched, so guessing is unacceptable.

If the listing call fails with 401 or 403, **abort**. Do not treat a failed lookup as "no registration exists" — that would register a duplicate. Note that listing runners requires `api` scope and Maintainer/Owner; the narrower `create_runner` scope is not sufficient.

### Step 2 — Probe SSM

Read the token parameter with decryption. Treat it as present only if the value is non-empty and begins with `glrt-`.

This read is what makes re-runs work, and it does not compromise the objective: it happens in bash, so the value travels environment variable → ephemeral variable → `value_wo` and never becomes a Terraform attribute. The equivalent read inside Terraform — `data "aws_ssm_parameter"` — _would_ store the value and must not be used. Anyone able to perform this read could mint a fresh token anyway.

### Step 3 — Decide

|Registration in GitLab|Token in SSM|Action|
|---|---|---|
|no|no|First run. Register. Version = new runner id.|
|yes|yes|Steady state. Reuse the token read from SSM. Version = the matched runner id.|
|no|yes|The user deleted their registration. Register. Version = the **new** runner id, so the new token propagates.|
|yes|no|Token is unrecoverable — GitLab returns it exactly once and there is no API to read it back. Delete the matched runner (this revokes its token), then register.|
|rotate requested|—|Delete the existing runner if one was matched, then register.|

### Step 4 — Export and hand off

Export the resolved token, the runner id as the version counter, and the token expiry if used, then `exec` the given command.

## Why rotation needs no separate mechanism

The runner id is a database primary key: it only ever increases, and it changes exactly when — and only when — a new registration happens. That is precisely the contract `value_wo_version` wants.

So rotation is just the `no | yes` row: delete the registration in GitLab (which revokes its token), re-run, and a new id is minted. The changed version is what causes the provider to push the new value to SSM and roll the instance. A `--rotate` flag is only a shortcut for the same path.

**Do not implement the version as a counter that advances on every run.** The version is stamped into an instance tag, and the upstream module's Auto Scaling group refreshes instances when a tag changes — so an always-advancing counter would replace the Runner on every apply, killing in-flight jobs.

## Terraform changes

In the module:

- The token variable: `ephemeral = true`, `sensitive = true`, **required** (no default), validated only for the `glrt-` prefix so the error message cannot leak the value.
- The parameter: `value_wo = var.runner_auth_token` and `value_wo_version = var.runner_auth_token_version`. **The version must not be hardcoded** — a fixed value means `Update` never re-reads the write-only argument, because it only does so under `if d.HasChanges("value_wo_version")`, and new tokens are therefore silently ignored.
- Stamp the version into the instance's additional tags, so a new token also rolls the running agent rather than only updating SSM.
- Pass the parameter's name to the upstream module's preregistered-token input. Upstream builds the instance role's `ssm:GetParameter` grant from that literal string, so the name must match exactly or the instance fails to read it at boot.

If there is a wrapper root module between the variable and the resource, `ephemeral = true` must be declared on **both** variable declarations — Terraform refuses to assign an ephemeral value to a non-ephemeral variable.

## Operational notes

- **Saved plans.** Ephemeral values are not written to plan files, and `-var`/`-var-file` are rejected when applying a saved plan, so `TF_VAR_` is the only channel and must be set for both the plan and the apply. Wrapping both in one script invocation avoids the issue.
- **Destroy.** Terraform still demands a value for a required variable even when destroying the resource. Provide a mode that exports a syntactically valid placeholder when nothing can be read back, warning loudly that it must never be used for an apply.
- **Credential scopes.** Registering needs `create_runner`; listing and deleting need `api`. The `yes | no` and rotate rows delete runners, so the broader scope is required for them.
- **Input file coupling.** The SSM parameter path derives from the runner name; the GitLab identity derives from the unique string. If these are separate fields, a user can change one without the other — changing the name alone lands in the `no | no` row and produces a second live runner. Derive both from one field, or validate that they move together.
- **Partial failure is self-healing.** If registration succeeds but the apply fails, the next run sees `yes | no`, deletes the orphan, and registers cleanly.
