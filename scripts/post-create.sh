#!/usr/bin/env bash
# post-create.sh — runs once after the devcontainer is built.
#
# This container only CONSUMES Docker Model Runner (DMR) over HTTP. Model
# pulls happen on the host (Docker Desktop UI or `docker model pull` in a
# host shell), not in here. This script verifies the wiring and tells the
# user what to do next if the configured model isn't loaded yet.

set -u

DMR_URL="${COPILOT_PROVIDER_BASE_URL:-http://model-runner.docker.internal/engines/v1}"
MODEL="${COPILOT_MODEL:-ai/gpt-oss}"
ANTHROPIC_URL="${ANTHROPIC_BASE_URL:-http://model-runner.docker.internal/anthropic}"
ANTHROPIC_MODEL_NAME="${ANTHROPIC_MODEL:-ai/gpt-oss}"

hr() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err() { printf '  \033[31m✗\033[0m %s\n' "$*"; }

hr "Probing Docker Model Runner at ${DMR_URL}/models"
warn "From inside the container DMR lives at model-runner.docker.internal (port 80)."
warn "The host-side URL http://localhost:12434 will NOT work in here."

if ! curl -fsS "${DMR_URL}/models" -o /tmp/dmr-models.json 2>/dev/null; then
  err "Could not reach ${DMR_URL}/models"
  warn "Confirm that Docker Model Runner is enabled on the host:"
  warn "  Docker Desktop → Settings → Beta features → 'Enable Docker Model Runner'"
  exit 0
fi

ok "DMR responded"

hr "Checking that '${MODEL}' is loaded"
# DMR returns model IDs with tag suffixes (e.g. "ai/gpt-oss:latest"), so we
# match on prefix rather than literal equality.
model_loaded=0
if command -v jq >/dev/null 2>&1; then
  if jq -e --arg m "${MODEL}" '.data[] | select(.id == $m or (.id | startswith($m + ":")))' \
       /tmp/dmr-models.json >/dev/null 2>&1; then
    model_loaded=1
  fi
else
  # Fallback: loose substring match against the bare model name (no quotes,
  # no tag) so "ai/gpt-oss" matches "ai/gpt-oss:latest" etc.
  if grep -q "${MODEL}" /tmp/dmr-models.json; then
    model_loaded=1
  fi
fi

if [ "${model_loaded}" -eq 1 ]; then
  ok "${MODEL} is available"
  if command -v jq >/dev/null 2>&1; then
    printf '  Available models:\n'
    jq -r '.data[].id' /tmp/dmr-models.json | sed 's/^/    • /'
  fi
else
  err "${MODEL} is NOT loaded in DMR"
  warn "Pull it from the HOST (not in this container):"
  warn ""
  warn "  Option A — Docker Desktop GUI:"
  warn "    Open Docker Desktop → 'Models' → search for '${MODEL}' → Pull"
  warn ""
  warn "  Option B — host shell:"
  warn "    docker model pull ${MODEL}"
  warn ""
  warn "Once the pull finishes, no rebuild needed — the next 'copilot' invocation"
  warn "will pick it up automatically."
fi

hr "Probing DMR Anthropic endpoint at ${ANTHROPIC_URL}/v1/messages/count_tokens"
# Cheap probe: count_tokens does no generation. If DMR's Anthropic shim
# doesn't support it, fall back to a 1-token messages call.
anthropic_ok=0
if curl -fsS -X POST "${ANTHROPIC_URL}/v1/messages/count_tokens" \
     -H 'content-type: application/json' \
     -H 'anthropic-version: 2023-06-01' \
     -d "{\"model\":\"${ANTHROPIC_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
     -o /tmp/dmr-anthropic.json 2>/dev/null; then
  anthropic_ok=1
elif curl -fsS -X POST "${ANTHROPIC_URL}/v1/messages" \
     -H 'content-type: application/json' \
     -H 'anthropic-version: 2023-06-01' \
     -d "{\"model\":\"${ANTHROPIC_MODEL_NAME}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
     -o /tmp/dmr-anthropic.json 2>/dev/null; then
  anthropic_ok=1
fi

if [ "${anthropic_ok}" -eq 1 ]; then
  ok "Anthropic endpoint responded"
else
  err "Anthropic endpoint probe failed"
  warn "Claude Code may not work. Confirm DMR exposes /anthropic/v1/messages on this host"
  warn "and that ${ANTHROPIC_MODEL_NAME} is loaded."
fi

hr "Next steps"
cat <<EOF
  • COPILOT_OFFLINE is set to 'true' in this container, which fully isolates
    Copilot CLI from the network. You must authenticate Copilot CLI ONCE
    before going offline. Easiest path:

      COPILOT_OFFLINE=false copilot
      # then inside the TUI: /login  (complete the device-flow)

    After /login succeeds, exit and re-run plain 'copilot' — it will use the
    cached credentials and talk only to DMR.

  • Launch Copilot CLI against the local model:

      copilot                       # uses COPILOT_MODEL=${MODEL}
      copilot --model ${MODEL}      # explicit override

  • Launch Claude Code against the local model:

      claude                        # uses ANTHROPIC_MODEL=${ANTHROPIC_MODEL_NAME}
      claude --model ${ANTHROPIC_MODEL_NAME}

    No /login is required — ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN
    bypass Anthropic's auth flow entirely.

  • Manage models from the HOST (Docker Desktop UI or host shell):

      docker model list
      docker model pull ai/<other-model>
      docker model ps
EOF
