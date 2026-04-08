#!/usr/bin/env bash
# use-llama-cpp.sh — opt-in alternative backend for the harness.
#
# Switches Copilot CLI and Claude Code from Docker Model Runner (the default,
# wired in devcontainer.json) to a local llama.cpp server running INSIDE this
# devcontainer. Use this when DMR is unavailable or you want to experiment
# with a different model without rebuilding the container.
#
# IMPORTANT: source this file, don't execute it — it exports env vars that
# need to land in your current shell so claude/copilot pick them up.
#
#     source scripts/use-llama-cpp.sh
#
# Override the model with LLAMA_MODEL before sourcing, e.g.
#     LLAMA_MODEL=ggml-org/Qwen2.5-Coder-3B-Instruct-GGUF source scripts/use-llama-cpp.sh
#
# CAVEAT: this server runs CPU-only. Docker Desktop does not pass GPU/Metal
# through to Linux containers on macOS, so throughput will be much lower than
# DMR (which runs natively on the host). DMR remains the recommended backend.

set -u

# ---------- pretty printers (match post-create.sh) ----------------------------
hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# ---------- config ------------------------------------------------------------
LLAMA_CACHE_DIR="${HOME}/.llama-cache"
LLAMA_BIN_DIR="${LLAMA_CACHE_DIR}/bin"
LLAMA_MODEL_DIR="${LLAMA_CACHE_DIR}/models"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_HOST="127.0.0.1"
LLAMA_PID_FILE="${LLAMA_CACHE_DIR}/server.pid"
LLAMA_LOG_FILE="${LLAMA_CACHE_DIR}/server.log"
# Default model: small, capable coding model that's reasonable on CPU.
LLAMA_MODEL="${LLAMA_MODEL:-ggml-org/Qwen2.5-Coder-7B-Instruct-Q4_K_M-GGUF}"

# Detect if we were sourced — if not, the env exports won't reach the user's
# shell and the whole point of this script is lost.
_sourced=0
# shellcheck disable=SC2128
if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE}" != "${0}" ]; then
  _sourced=1
fi

mkdir -p "${LLAMA_BIN_DIR}" "${LLAMA_MODEL_DIR}"

# ---------- arch detection ----------------------------------------------------
hr "Detecting architecture"
_uname_m="$(uname -m)"
case "${_uname_m}" in
  x86_64|amd64)  LLAMA_ARCH="x64" ;;
  aarch64|arm64) LLAMA_ARCH="arm64" ;;
  *)
    err "Unsupported architecture: ${_uname_m}"
    err "llama.cpp prebuilt binaries are only published for x64 and arm64."
    return 1 2>/dev/null || exit 1
    ;;
esac
ok "arch=${LLAMA_ARCH}"

# ---------- ensure unzip/curl/tar are present ---------------------------------
for tool in curl tar; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "${tool} is required but not installed"
    return 1 2>/dev/null || exit 1
  fi
done

# ---------- install llama-server if missing -----------------------------------
LLAMA_SERVER_BIN=""
# Look for any previously-extracted llama-* dir containing llama-server.
if [ -d "${LLAMA_BIN_DIR}" ]; then
  for d in "${LLAMA_BIN_DIR}"/llama-*; do
    if [ -x "${d}/llama-server" ]; then
      LLAMA_SERVER_BIN="${d}/llama-server"
      break
    fi
  done
fi

if [ -z "${LLAMA_SERVER_BIN}" ]; then
  hr "Downloading latest llama-server prebuilt (ubuntu-${LLAMA_ARCH})"
  warn "This is a one-time download cached under ~/.llama-cache (gitignored,"
  warn "bind-mounted from the host so it survives container rebuilds)."

  # Discover the latest tag and matching asset URL via the GitHub API.
  _release_json="$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest 2>/dev/null || true)"
  if [ -z "${_release_json}" ]; then
    err "Failed to query the GitHub releases API"
    return 1 2>/dev/null || exit 1
  fi
  _asset_url="$(printf '%s' "${_release_json}" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
arch = '${LLAMA_ARCH}'
want = f'-bin-ubuntu-{arch}.tar.gz'
for a in data['assets']:
    name = a['name']
    # Match the plain CPU build only — skip openvino/rocm/vulkan variants.
    if name.endswith(want) and 'openvino' not in name and 'rocm' not in name and 'vulkan' not in name:
        print(a['browser_download_url'])
        break
")"

  if [ -z "${_asset_url}" ]; then
    err "Could not find a ubuntu-${LLAMA_ARCH} prebuilt asset in the latest release"
    return 1 2>/dev/null || exit 1
  fi

  ok "asset: ${_asset_url}"
  _tarball="${LLAMA_BIN_DIR}/llama-server.tar.gz"
  if ! curl -fL --progress-bar -o "${_tarball}" "${_asset_url}"; then
    err "Download failed"
    return 1 2>/dev/null || exit 1
  fi

  if ! tar -xzf "${_tarball}" -C "${LLAMA_BIN_DIR}"; then
    err "Extraction failed"
    return 1 2>/dev/null || exit 1
  fi
  rm -f "${_tarball}"

  for d in "${LLAMA_BIN_DIR}"/llama-*; do
    if [ -x "${d}/llama-server" ]; then
      LLAMA_SERVER_BIN="${d}/llama-server"
      break
    fi
  done

  if [ -z "${LLAMA_SERVER_BIN}" ]; then
    err "Extracted archive but llama-server binary not found"
    return 1 2>/dev/null || exit 1
  fi
fi

LLAMA_SERVER_DIR="$(dirname "${LLAMA_SERVER_BIN}")"
ok "llama-server: ${LLAMA_SERVER_BIN}"

# ---------- start (or reuse) the server ---------------------------------------
hr "Starting llama-server on ${LLAMA_HOST}:${LLAMA_PORT}"

_already_running=0
if [ -f "${LLAMA_PID_FILE}" ]; then
  _existing_pid="$(cat "${LLAMA_PID_FILE}" 2>/dev/null || true)"
  if [ -n "${_existing_pid}" ] && kill -0 "${_existing_pid}" 2>/dev/null; then
    if curl -fsS "http://${LLAMA_HOST}:${LLAMA_PORT}/health" >/dev/null 2>&1; then
      ok "Reusing running server (pid ${_existing_pid})"
      _already_running=1
    fi
  fi
fi

if [ "${_already_running}" -eq 0 ]; then
  warn "First run will download the GGUF (~4-5 GB for the default model);"
  warn "subsequent launches reuse the cache."
  # LLAMA_CACHE redirects llama.cpp's HF download cache into the persistent
  # bind-mounted dir so model downloads survive container rebuilds.
  export LLAMA_CACHE="${LLAMA_MODEL_DIR}"

  # LD_LIBRARY_PATH so llama-server finds the bundled .so files next to it.
  LD_LIBRARY_PATH="${LLAMA_SERVER_DIR}:${LD_LIBRARY_PATH:-}" \
  nohup "${LLAMA_SERVER_BIN}" \
      -hf "${LLAMA_MODEL}" \
      --host "${LLAMA_HOST}" \
      --port "${LLAMA_PORT}" \
      --jinja \
      > "${LLAMA_LOG_FILE}" 2>&1 &
  echo $! > "${LLAMA_PID_FILE}"
  ok "Launched (pid $(cat "${LLAMA_PID_FILE}"); log: ${LLAMA_LOG_FILE})"

  # Poll /health for up to ~5 minutes (cold start downloads + loads the model).
  hr "Waiting for /health to become ready"
  _ready=0
  for i in $(seq 1 150); do
    if curl -fsS "http://${LLAMA_HOST}:${LLAMA_PORT}/health" >/dev/null 2>&1; then
      _ready=1
      break
    fi
    # Bail early if the process died.
    if ! kill -0 "$(cat "${LLAMA_PID_FILE}")" 2>/dev/null; then
      err "llama-server exited before becoming ready. Last 30 log lines:"
      tail -n 30 "${LLAMA_LOG_FILE}" | sed 's/^/    /'
      return 1 2>/dev/null || exit 1
    fi
    sleep 2
  done

  if [ "${_ready}" -ne 1 ]; then
    err "Timed out waiting for llama-server. Last 30 log lines:"
    tail -n 30 "${LLAMA_LOG_FILE}" | sed 's/^/    /'
    return 1 2>/dev/null || exit 1
  fi
  ok "Server is ready"
fi

# ---------- export overrides for the current shell ----------------------------
hr "Pointing Copilot CLI and Claude Code at llama-server"

# llama-server ignores the request body's "model" field — it serves whatever
# GGUF was loaded at startup — so any non-empty name works for both harnesses.
export COPILOT_PROVIDER_BASE_URL="http://${LLAMA_HOST}:${LLAMA_PORT}/v1"
export COPILOT_PROVIDER_TYPE="openai"
export COPILOT_MODEL="local-model"

export ANTHROPIC_BASE_URL="http://${LLAMA_HOST}:${LLAMA_PORT}"
export ANTHROPIC_MODEL="local-model"
export ANTHROPIC_SMALL_FAST_MODEL="local-model"

ok "COPILOT_PROVIDER_BASE_URL=${COPILOT_PROVIDER_BASE_URL}"
ok "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"

if [ "${_sourced}" -ne 1 ]; then
  warn ""
  warn "This script was EXECUTED, not SOURCED. The exports above only exist"
  warn "in the script's subshell — your interactive shell still points at DMR."
  warn "Re-run with:    source scripts/use-llama-cpp.sh"
fi

hr "Next steps"
cat <<EOF
  • In THIS shell, claude and copilot now talk to llama-server:

      claude
      copilot

  • Open a NEW terminal to revert to DMR — the env overrides only live in
    this shell. Or unset them manually:

      unset COPILOT_PROVIDER_BASE_URL COPILOT_MODEL \\
            ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL

  • Stop the server:

      kill \$(cat ${LLAMA_PID_FILE}) && rm ${LLAMA_PID_FILE}

  • Performance note: this server runs CPU-ONLY inside the container (no
    Metal/CUDA passthrough). Expect tokens/sec well below what DMR delivers
    on the host. DMR is still the recommended default.
EOF
