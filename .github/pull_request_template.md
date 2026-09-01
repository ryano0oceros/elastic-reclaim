<!--
Do not paste secrets. Bearer tokens, Elastic API keys, ALB hostnames,
Elastic endpoint URLs, and AWS account IDs appear in logs and Terraform
output - scrub them before submitting.
-->

## What this changes

<!-- One or two sentences. Link the issue: Fixes #123 -->

## Why

<!--
The constraint, the failure mode you hit, or the alternative you rejected.
This is the part that is invisible from the diff and the first thing lost
to time.
-->

## Testing

<!-- What you actually ran. "Not tested" is acceptable and more useful than silence. -->

- [ ] `pytest -q` passes in `proxy/`
- [ ] `pip-audit --strict` clean (if dependencies changed)
- [ ] `terraform fmt -recursive -check` and `terraform validate` pass (if Terraform changed)
- [ ] Added or updated tests covering this change

## Terraform changes

<!--
Delete this section if no Terraform changed.

State what you ran: a plan against a real project, a full apply, or neither.
Summarize the resource changes - do NOT paste raw plan output, which carries
resource identifiers and can carry sensitive values.
-->

## Checklist

- [ ] No secrets, tokens, endpoints, or account IDs in the diff or in this description
- [ ] No Terraform state or plan file is being committed (`git status --short`)
- [ ] Prompt content stays out of logs
- [ ] Documentation updated if behaviour or configuration changed
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` for anything user-visible
