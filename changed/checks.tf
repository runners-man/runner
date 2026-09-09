###############################################################################
# Checks — warnings, not failures.
#
# `terraform_data.guardrails` in guardrails.tf holds the red lines: it fails the plan. This
# file holds the things that should raise a flag without blocking a deploy, because failing an
# apply is the wrong response to "your token expires in nine days".
###############################################################################

check "runner_auth_token_expiry" {
  assert {
    # In managed mode modules/runner-secrets raises this warning itself, so skip it here rather
    # than print the same paragraph twice on every plan.
    condition = (
      local.manage_auth_token_parameter ||
      var.runner_auth_token_expires_at == "never" ||
      timecmp(plantimestamp(), timeadd(var.runner_auth_token_expires_at, "-336h")) < 0
    )
    error_message = <<-EOT
      The Runner authentication token expires at ${var.runner_auth_token_expires_at}, less than
      14 days away.

      Rotate it before then:
        gitlab-runner-token --name ${var.name} --scope <group|project> --id <id> --rotate -- terragrunt apply

      Note that if your group or project sets a runner expiration, GitLab also rotates the
      token by itself and writes the new value into config.toml on the running host — never
      back to SSM. On this architecture the host is replaced on every scheduled scale-out, so
      that rotated value is discarded and the next instance boots with whatever SSM holds. The
      recommended configuration for platform runners is to leave "Runners expiration" empty and
      rotate deliberately.
    EOT
  }
}
