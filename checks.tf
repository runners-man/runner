# A warning, not a failure. Failing an apply is the wrong response to "your token expires in
# nine days" — but saying nothing until the morning it stops working is worse.
check "runner_auth_token_expiry" {
  assert {
    condition = (
      var.runner_auth_token_expires_at == "never" ||
      timecmp(plantimestamp(), timeadd(var.runner_auth_token_expires_at, "-336h")) < 0
    )
    error_message = <<-EOT
      The Runner authentication token expires at ${var.runner_auth_token_expires_at}, less than
      14 days away. Rotate it:

        gitlab-runner-token --name ${var.name} --scope <group|project> --id <id> --rotate -- terragrunt run-all apply

      If your group or project sets a runner expiration, GitLab also rotates the token by
      itself and writes the new value into config.toml on the running host — never back to SSM.
      The host is replaced on every scheduled scale-out, so that value is discarded and the next
      instance boots with whatever SSM holds. Leave "Runners expiration" empty for platform
      runners and rotate deliberately.
    EOT
  }
}
