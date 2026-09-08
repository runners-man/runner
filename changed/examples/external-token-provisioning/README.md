# Externally provisioned token (BYO parameter)

For stacks that want the Runner authentication token to never exist inside any Terraform
configuration — not as a variable, not as a resource attribute, not as a data source result.

Read `docs/token-provisioning.md` first. In particular, read why the parameter is **not** a
Terraform resource here: creating it in Terraform with a placeholder and `ignore_changes` puts
the real value into state on the next refresh.

## Shape

```
bootstrap/   KMS key + provisioning IAM role.        terraform apply
scripts/     GitLab API -> aws ssm put-parameter.    bash
runner/      this module in BYO mode.                terraform apply
```

Terraform owns the key. The script owns the parameter. Nothing owns both.

## Run it

```bash
terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply

export GITLAB_URL=https://gitlab.internal.example.com
export GITLAB_API_TOKEN=...            # group access token, create_runner scope only

./scripts/provision-runner-token.sh \
  --scope group --id 1234 \
  --name payments-ci \
  --parameter "$(terraform -chdir=bootstrap output -raw auth_token_parameter_name)" \
  --kms-key-arn "$(terraform -chdir=bootstrap output -raw auth_token_kms_key_arn)" \
  --tags docker,linux,payments-ci

terraform -chdir=runner init && terraform -chdir=runner apply
```

## Prove it

```bash
# Nothing in either state file should match.
terraform -chdir=bootstrap show -json | grep -c 'glrt-'   # expect 0
terraform -chdir=runner    show -json | grep -c 'glrt-'   # expect 0
```

Do the same after a `terraform refresh`, not just after the first apply — the whole point of
the gotcha is that it appears on the *second* plan.

## Teardown

`terraform destroy` does not remove the SSM parameter or the GitLab runner registration.
Run `scripts/deprovision-runner-token.sh` between the two destroys, with a credential that has
`api` scope — `create_runner` cannot delete runners.

## When you do not need this

If you are happy for the token to spend the length of an apply in `TF_VAR_runner_auth_token`,
use the module's default managed mode instead. It keeps the token out of state via `ephemeral`
+ `value_wo`, and Terraform keeps the whole lifecycle including destroy. See
`examples/minimal/`.
