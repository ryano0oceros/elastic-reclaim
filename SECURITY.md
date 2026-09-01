# Security Policy

## Status of this project

`elastic-reclaim` is a **proof of concept**. It is published so the
OpenCode→EIS integration pattern can be read, copied, and adapted - not as a
supported product. It ships with deliberate, documented tradeoffs that make
it unsafe to deploy to an untrusted network without changes:

- **No TLS.** The ALB listener is plaintext HTTP:80. Bearer tokens and prompt
  content are readable and replayable on-path.
- **`allowed_cidr_blocks` defaults to `0.0.0.0/0`.**
- **User attribution is self-reported** via the `X-EIS-User` header. It is an
  analytics label, not an identity claim. Authentication is the shared bearer
  token only; there is no per-user authentication until SSO lands.
- **Terraform state is local and unencrypted.**

See the README's "Security model", "Future enhancements", and "Production
considerations" sections for the full reasoning and the shape of each fix.

## Supported versions

Only the latest commit on `main` is supported. There are no maintained
release branches and no backported fixes.

## Reporting a vulnerability

Please **do not open a public issue** for a security vulnerability.

Report privately via GitHub's
[private vulnerability reporting](https://github.com/ryano0oceros/elastic-reclaim/security/advisories/new)
on this repository.

Include where relevant: affected file or component, reproduction steps or a
proof of concept, and your assessment of the impact. Expect an initial
acknowledgement within 7 days. Given the PoC status of this project there is
no formal remediation SLA, though anything permitting credential disclosure
or unauthenticated inference will be prioritized.

Findings that restate an accepted tradeoff already documented above (absence
of TLS, the open default CIDR, self-reported `X-EIS-User`, local state) are
known and do not need a report.

## Deploying this safely

If you stand this up, at minimum:

1. Set `allowed_cidr_blocks` to your own workstation or office CIDR. Never
   leave it at `0.0.0.0/0`.
2. Add TLS (ACM certificate + HTTPS:443 listener) before any real prompt
   content crosses the wire, and retire the HTTP:80 listener.
3. Keep `capture_requests = false` unless you have a reason to record full
   prompt and response text, and have told your developers.
4. Migrate Terraform state to an encrypted S3 backend before a second person
   or machine touches the deployment.
5. Rotate `PROXY_API_KEY` when anyone with access leaves. It is a single
   shared token, so rotation is all-or-nothing until SSO replaces it.

## Handling secrets in this repository

Terraform **state and plan files contain every secret in plaintext**,
including the Elastic API key and the generated proxy bearer token. A
`sensitive = true` marking suppresses CLI output only; it does not encrypt
or redact anything on disk.

Never commit `terraform.tfstate`, `terraform.tfvars`, a `terraform plan -out`
file, or a generated `dev-config-*/` bundle. All are covered by
`.gitignore` - verify with `git check-ignore -v <path>` if unsure. Note in
particular that a `terraform/*.tfplan` pattern does **not** match a bare file
named `tfplan`, which is the conventional `-out` target.

If a credential is ever exposed, rotate it first and scrub history second -
in that order. History rewriting does not invalidate a leaked key.
