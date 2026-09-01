# Developer onboarding

You're getting a Claude Code-style coding agent - OpenCode - in your
terminal and VS Code, with model access (Claude, Gemini, GPT) routed through
your company's Elastic platform. No personal API keys, nothing to pay for.

## What you need from the platform team

Two files, generated for you personally:

- `opencode.json` - agent configuration with the available models
- `eis-proxy.env` - the proxy URL and access token (**treat as a secret**)

If you don't have them, ask the platform team to run
`scripts/dev-setup.sh <your-name>`.

## Setup (5 minutes)

1. **Install OpenCode**

   ```bash
   brew install sst/tap/opencode
   ```

   (Other platforms: <https://opencode.ai> - `curl -fsSL https://opencode.ai/install | bash`)

2. **Place the config** - either per-project or global:

   ```bash
   cp opencode.json /path/to/your/project/    # just this project
   # or
   mkdir -p ~/.config/opencode && cp opencode.json ~/.config/opencode/
   ```

3. **Load the environment — do not skip this**

   `opencode.json` reads the proxy URL and token from environment variables,
   so they must be set in *every* shell that runs OpenCode. Load them once:

   ```bash
   set -a; source /full/path/to/eis-proxy.env; set +a
   ```

   Then make it permanent, so new terminals and VS Code inherit it:

   ```bash
   echo 'set -a; source /full/path/to/eis-proxy.env; set +a' >> ~/.zshrc
   ```

   Use the **absolute path** — a relative path breaks the moment you `cd`.

   > **If you skip this**, OpenCode still launches and the model picker still
   > lists models, but every request fails with
   > `"/chat/completions" cannot be parsed as a URL`. That error means the
   > URL variable was empty, not that anything is wrong with the proxy.

   Verify before moving on:

   ```bash
   echo $OPENAI_API_BASE    # must print an http://... URL, not an empty line
   ```

## Use it

**Terminal:**

```bash
cd your-project
opencode
```

Ask it to read files, explain code, make changes, run commands - it's an
agent, not a chatbot.

**VS Code:** install the **OpenCode** extension from the marketplace. It
embeds the same agent in your editor and picks up the same `opencode.json`
and environment - no separate configuration. Launch VS Code from a terminal
that has the env loaded (`code .`), or set the variables user-wide.

**One-shot mode** (no TUI):

```bash
opencode run "explain what proxy/app/main.py does"
```

## Switching models

Exactly like switching models in Claude Code:

| Action | How |
|---|---|
| Pick from the list | type `/models`, or press `Ctrl+X` then `M` |
| Cycle recent models | `F2` |
| One-shot with a model | `opencode run --model eis-proxy/gemini "..."` |

The list (e.g. `claude`, `gemini`, `gpt`) is whatever the platform team has
enabled. If a model you expect is missing, ask them - enabling one is a
config change on their side, then they'll re-issue your `opencode.json`.

## What's logged (read this)

- **Always**: usage metadata per request - your name (from the config),
  model, token counts, latency, success/failure. This powers team usage
  dashboards. **Prompt content is not included.**
- **Only if the platform team enables capture mode**: full request and
  response content, retained 30 days, for query analytics. The platform
  team's own runbook requires telling you when this is on. If in doubt, ask.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `"/chat/completions" cannot be parsed as a URL` | `OPENAI_API_BASE` is unset in this shell, so baseURL resolved to empty. Re-run the `source` step (step 3) — and add it to `~/.zshrc` so new terminals work |
| `401` / auth errors | Environment not loaded - re-run the `source` step; check `echo $OPENAI_API_KEY` |
| `Unknown model '...'` | Your `opencode.json` is older than the platform's model list - request a regenerated one |
| Connection refused / timeout | Proxy URL changed or service down - confirm `$OPENAI_API_BASE` with the platform team |
| `502` mentioning upstream auth | Platform-side Elastic credential issue - not your setup; report it |
| Model responds but tools fail | Report it with the model name - protocol quirks are handled proxy-side (README "Protocol compatibility notes") |
