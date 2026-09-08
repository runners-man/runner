# Split state (Layout C)

Two Terragrunt units. The secrets unit owns the KMS key and the token parameter; the runner
unit owns everything else and receives only the parameter's *name*.

```bash
bin/gitlab-runner-token --name payments-ci --scope group --id 1234 -- terragrunt run-all apply
```

The wrapper exports `TF_VAR_runner_auth_token`, `TF_VAR_runner_auth_token_version` and
`TF_VAR_runner_auth_token_expires_at` for the whole `run-all`. Only the `secrets` unit declares
them; the `runner` unit ignores the ones it does not declare and takes the non-secret values
through `dependency.secrets.outputs` instead.

## Why you might want this

Tear down and rebuild a Runner without minting a new token or touching GitLab — the parameter
lives in the other state. The key can also sit behind a different review path.

## What it costs

Ordering becomes Terragrunt's job. Apply the runner unit against a missing parameter and the
instance boots, upstream's user data hits `exit 1`, and the only evidence is in CloudWatch.
Use `run-all`, and keep the guardrail that requires the parameter to live under
`/platform/gitlab-runner/<name>/`.

If you do not need either of those properties, use the root module on its own — see
`docs/layout.md`, Layout A.
