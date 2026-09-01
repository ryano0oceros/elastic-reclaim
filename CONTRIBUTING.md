# Contributing

Thanks for your interest. This is a **proof of concept**, not a supported
product - please read [SECURITY.md](SECURITY.md) and the README's security
sections before you deploy it or build on it.

Because it is a PoC, the bar for changes is "does this make the demonstrated
pattern clearer, safer, or more correct" rather than "does this add a
feature." Broad new functionality may well be declined; that is not a
judgement on the work.

## Before you start

For anything beyond a typo or a docs fix, **open an issue first**. This
project has deliberate, documented tradeoffs (no TLS, an open default CIDR,
self-reported user attribution, local Terraform state) and a change that
"fixes" one of them may be re-implementing something already tracked in the
README's "Future enhancements" section. An issue avoids you writing code that
gets closed.

## Never commit secrets

This matters more here than in most repositories, because Terraform's file
formats are actively hostile to the unwary:

- **`terraform.tfstate` contains every secret in plaintext** - the Elastic API
  key, the generated proxy bearer token, the Serverless project password.
- **A plan file (`terraform plan -out=tfplan`) embeds a full copy of that
  state.** It is a zip archive, so a text-based secret scanner will not see
  inside it. `sensitive = true` suppresses CLI output only; it encrypts
  nothing on disk.
- **`terraform.tfvars`** holds your Elastic Cloud credentials.
- **`dev-config-*/`** bundles contain a live bearer token.

All of these are covered by `.gitignore`. Verify before committing:

```bash
git check-ignore -v <path>     # should print the matching rule
git status --short             # should not list any of the above
```

Note that `terraform/*.tfplan` does **not** match a bare file named `tfplan`,
which is the conventional `-out` target. All three patterns are present in
`.gitignore` for that reason - do not remove any of them.

When pasting logs or output into an issue or PR, scrub bearer tokens, API
keys, ALB hostnames, Elastic endpoint URLs, and AWS account IDs.

If you do expose a credential: **rotate it first, scrub history second**, in
that order. Rewriting history does not invalidate a leaked key, and orphaned
git objects remain retrievable from the forge for some time.

## Development setup

```bash
cd proxy
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
```

The test suite runs the full FastAPI application against a mocked Elastic
upstream. It makes no network calls and needs no AWS or Elastic credentials,
so it is safe to run anywhere.

To exercise the container without touching AWS or Elastic, see the
"Local development & testing" section of the [README](README.md).

## Change process

All changes land through a pull request. `main` is protected: it does not
accept direct pushes or force-pushes, and CI must pass before merge.

1. Fork, then branch from `main`. Use a short descriptive branch name.
2. Make the change. Keep it focused - one concern per PR.
3. Run the checks below locally.
4. Open a PR against `main` and fill in the template. Link the issue.
5. Address review feedback by pushing additional commits; they are squashed
   on merge, so there is no need to rewrite your branch history.

### Checks that must pass

CI runs these, but running them locally is faster than a round trip:

```bash
# Python
cd proxy && pytest -q
pip-audit --strict                      # no known vulnerable dependencies

# Terraform
terraform -chdir=terraform fmt -recursive -check -diff
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

CI additionally runs Trivy against the Terraform configuration and the built
image, and gitleaks over the full history.

### Commit messages

Write a concise imperative subject line ("Add X", "Fix Y") under about 72
characters. Where the change is not self-evident, use the body to explain
**why** - the constraint, the failure mode observed, or the alternative
rejected. The existing history is a reasonable guide.

Conventional Commits are not required.

### Code style

- Follow what is already there; there is no separate style guide.
- The codebase comments **why**, not what. Where a line encodes a non-obvious
  constraint - a protocol quirk, a fail-closed decision, an ordering
  dependency - say so, because that reasoning is invisible from the code and
  is the first thing lost to time.
- Keep prompt content out of logs. `_payload_shape()` in `proxy/app/main.py`
  logs request structure without message text; preserve that property.
- New behaviour needs a test. Bug fixes should include a test that fails
  before the fix.

## Changes to Terraform

Infrastructure changes cannot be verified by CI beyond `validate`, so state
in the PR what you actually ran - `terraform plan` against a real project, a
full `apply`, or neither. "Not applied" is an acceptable answer and far more
useful than silence.

**Never paste raw plan output**, which contains resource identifiers and can
contain sensitive values. Summarize the resource changes instead.

The `ec_elasticsearch_project` resource is in technical preview upstream, so
its schema can change between provider releases. If you bump the `elastic/ec`
pin in `terraform/versions.tf`, read that provider's changelog and say what
you checked.

## Reporting bugs

Open an issue using the bug template. The most useful reports include what
you expected, what happened, and the smallest reproduction you can manage.

**Do not use a public issue for a security vulnerability** - see
[SECURITY.md](SECURITY.md) for the private reporting path.

## Licensing

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), the same terms that cover this project.
