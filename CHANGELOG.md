# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the version is below `1.0.0`, **any release may contain breaking
changes** - including to the proxy's configuration variables, the Terraform
module inputs, and the analytics document shape. Pin a tag if you depend on
current behaviour.

## [Unreleased]

### Changed

- All GitHub Actions are pinned to a full commit SHA with the version as a
  trailing comment. A mutable tag means a compromised upstream action runs
  with access to the workflow; Dependabot still tracks the pins via the
  comment. Flagged by the CodeQL `actions` analysis.

### Fixed

- The Secret scan CI job, which could not run against a squashed history:
  `gitleaks-action` scans `<before>^..<after>` from the push event, and a
  root commit has no parent. Runs the binary directly over full history
  instead, plus a `--no-git` pass for the working tree, with a
  `.gitleaks.toml` allowlisting gitignored local files and documented
  placeholders.
- Removed an unused import in `proxy/tests/test_translator.py`.

## [0.0.1] - 2026-09-01

Initial public release. This is a **proof of concept** - see the security
caveats in the [README](README.md) and [SECURITY.md](SECURITY.md) before
deploying it anywhere.

### Added

- **Proxy** (`proxy/`) - FastAPI gateway translating the OpenAI
  chat-completions protocol to Elastic's unified inference API, with
  streaming SSE passthrough, mandatory bearer authentication compared using
  `secrets.compare_digest`, a request body size limit, and fail-closed
  handling of upstream errors.
- **Protocol compatibility handling** - strips fields Elastic's strict
  parser rejects on the request side (`cache_control`, `index` inside
  `tool_calls`) and drops the filler tool-call deltas some models emit on the
  response side, which strict clients reject.
- **Usage analytics** - per-request metadata (user, model, tokens, latency,
  time-to-first-byte) written fire-and-forget to an Elasticsearch data
  stream, so a telemetry failure never blocks a completion. Prompt content is
  excluded.
- **Cost attribution** - per-request spend derived from configurable
  per-model token rates, including prompt-size-based tier escalation. Models
  without a configured rate emit no cost field at all, so a missing rate
  shows as a gap rather than as zero spend.
- **Optional content capture** - full request and response text to a separate
  data stream with shorter retention. Default off, disclosed in the developer
  documentation.
- **Terraform** (`terraform/`) - Elastic Serverless project with one EIS
  inference endpoint per model alias, a scoped Elasticsearch API key, AWS
  VPC/ALB/ECR/ECS Fargate, and secrets delivered via Secrets Manager rather
  than the task definition. Split into per-provider modules so another cloud
  can be added without modifying the existing ones.
- **Kibana dashboards** - adoption, reliability, and cost/spend views,
  provisioned by Terraform.
- **Scripts** - `deploy.sh` (build, push, roll ECS, smoke test) and
  `dev-setup.sh` (per-developer configuration bundle generated from live
  Terraform outputs).
- **CI** - pytest, pip-audit, Terraform fmt/validate, Trivy against both the
  Terraform config and the built image, and gitleaks over full history.
- **Documentation** - platform team and developer onboarding guides, an EIS
  pricing reference, and an architecture diagram.
- Apache-2.0 `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, and a Code of
  Conduct.

### Security

- `.gitignore` now matches Terraform plan files three ways (`tfplan`,
  `*.tfplan`, `terraform/*.tfplan`). A plan file embeds a complete copy of
  state with every sensitive value in plaintext, and the conventional bare
  `tfplan` output target is **not** matched by a `terraform/*.tfplan` glob
  alone - which is how one was previously committed.
- Published from a fresh history so no previously committed plan file is
  reachable in the public repository.

[Unreleased]: https://github.com/ryano0oceros/elastic-reclaim/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/ryano0oceros/elastic-reclaim/releases/tag/v0.0.1
