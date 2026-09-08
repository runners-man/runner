# runner-secrets

The KMS key and the Runner authentication token parameter, split out from the runner module.

Use this **only if you want two states**. If one state is fine, use the root module on its own
— it contains the same resources and needs no cross-module coordination. See
`docs/layout.md` for the decision.

## The boundary

```
  TF_VAR_runner_auth_token  ──►  var.runner_auth_token   (ephemeral)
                                       │
                                       ▼
                                 value_wo                 ──►  AWS, then discarded
                                       │
                                       ✗  cannot be output, cannot cross a state boundary

  outputs: auth_token_parameter_name, kms_key_arn, runner_id, token_expires_at
           └── none of these is a secret
```

`ephemeral` is checked at the module boundary, not trusted across it: the caller can only
assign an ephemeral value to `var.runner_auth_token` because this module also declares it
ephemeral. And an `output` returning the token would have to be ephemeral too — which cannot be
read from state, so it could never reach the runner module. The design is enforced by the
language rather than by discipline.

## Usage

```hcl
module "runner_secrets" {
  source = "../../modules/runner-secrets"

  name                         = "payments-ci"
  runner_auth_token            = var.runner_auth_token             # ephemeral in the caller too
  runner_auth_token_version    = var.runner_auth_token_version     # the GitLab runner id
  runner_auth_token_expires_at = var.runner_auth_token_expires_at

  tags = { cost_centre = "CC-1234", owner = "payments-platform" }
}
```

Then the runner module in BYO mode:

```hcl
module "gitlab_runner" {
  source = "../../"

  name                      = "payments-ci"
  auth_token_parameter_name = module.runner_secrets.auth_token_parameter_name
  auth_token_kms_key_arn    = module.runner_secrets.kms_key_arn
  runner_auth_token_version = module.runner_secrets.runner_id
  # ...
}
```
