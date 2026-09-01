#!/usr/bin/env bash
# Generate a developer's OpenCode configuration from live Terraform outputs.
#
#   scripts/dev-setup.sh <username> [output-dir]
#
# Produces <output-dir>/opencode.json and <output-dir>/eis-proxy.env for the
# named developer. The model list comes straight from `terraform output
# eis_model_map`, so the picker can never drift from what the proxy actually
# serves - previously the two had to be kept in sync by hand.
#
# The username is embedded as an X-EIS-User header on every request for
# per-user usage dashboards. It is self-reported (see terraform/modules/sso
# for the authenticated replacement) - auth itself is the bearer token.
#
# Run by the platform team (needs terraform state access); hand the two
# generated files to the developer.

set -euo pipefail
cd "$(dirname "$0")/.."

USERNAME="${1:?usage: dev-setup.sh <username> [output-dir]}"
OUT_DIR="${2:-./dev-config-$USERNAME}"
TF="terraform -chdir=terraform"

BASE_URL=$($TF output -raw proxy_base_url)
TOKEN=$($TF output -raw proxy_api_key)
MODEL_MAP=$($TF output -json eis_model_map)
# Chosen by the platform team, not derived - see var.default_model_alias.
# Alphabetical order would hand every new developer the priciest model.
DEFAULT_MODEL=$($TF output -raw default_model_alias)

mkdir -p "$OUT_DIR"

python3 - "$USERNAME" "$OUT_DIR" "$DEFAULT_MODEL" <<PY
import json, sys, pathlib
username, out_dir, default_model = sys.argv[1:4]
model_map = json.loads('''$MODEL_MAP''')

config = {
    "\$schema": "https://opencode.ai/config.json",
    "model": f"eis-proxy/{default_model}",
    "provider": {
        "eis-proxy": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "Elastic Inference Service (via AWS proxy)",
            "options": {
                "baseURL": "{env:OPENAI_API_BASE}",
                "apiKey": "{env:OPENAI_API_KEY}",
                "headers": {"X-EIS-User": username},
            },
            "models": {alias: {"name": f"{alias} (via EIS)"} for alias in sorted(model_map)},
        }
    },
}
path = pathlib.Path(out_dir) / "opencode.json"
path.write_text(json.dumps(config, indent=2) + "\n")
print(f"wrote {path}")
PY

ENV_FILE="$OUT_DIR/eis-proxy.env"
cat > "$ENV_FILE" <<EOF
# EIS proxy access for $USERNAME - source this before running opencode:
#   set -a; source eis-proxy.env; set +a
OPENAI_API_BASE=$BASE_URL
OPENAI_API_KEY=$TOKEN
EOF
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE (mode 600 - contains the shared bearer token)"

ABS_ENV="$(cd "$OUT_DIR" && pwd)/eis-proxy.env"

cat <<EOF

Hand both files to $USERNAME with these instructions:

  1. Install OpenCode:            https://opencode.ai  (brew install sst/tap/opencode)
  2. Put opencode.json in your project root or ~/.config/opencode/
  3. Load the environment IN EVERY SHELL that runs opencode:

         set -a; source $ABS_ENV; set +a

     Make it permanent (recommended - otherwise a new terminal fails):

         echo 'set -a; source $ABS_ENV; set +a' >> ~/.zshrc

     Skipping this yields a confusing error - OpenCode resolves baseURL to
     an empty string and reports: "/chat/completions" cannot be parsed as a URL.
  4. Terminal:                    opencode
     VS Code:                     install the 'OpenCode' extension - it reuses
                                  the same config and environment.
  5. Switch models any time with  /models  (or Ctrl+X M, or F2)

Full guide: docs/developer-onboarding.md
EOF
