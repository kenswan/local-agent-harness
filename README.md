# local-agent-harness

A reproducible dev container for running multiple AI coding **agent harnesses**
against **local LLMs** served by [Docker Model Runner](https://docs.docker.com/ai/model-runner/).
The container ships the harnesses; the host (via Docker Desktop) ships the
models. One model serves every harness.

Currently bundled harnesses:

- **[GitHub Copilot CLI](https://github.com/features/copilot/cli)** — wired to
  DMR's OpenAI-compatible endpoint.
- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** — wired to
  DMR's Anthropic-compatible endpoint.

Both talk to the same local model (default: `ai/gpt-oss`) over HTTP. No API
keys, no usage costs, no data leaves the machine for inference.

## Why two harnesses, one model?

Each harness has different ergonomics, tools, and prompting style, but they
all want a model behind an HTTP API. DMR exposes the same underlying model
through three different API shapes simultaneously:

```
Docker Model Runner (ai/gpt-oss)
  ├── /engines/v1     OpenAI-compatible    ◄── GitHub Copilot CLI
  ├── /anthropic/v1   Anthropic-compatible ◄── Claude Code
  └── /api            Ollama-compatible    ◄── (future harnesses)
```

So you can compare harnesses head-to-head without paying for cloud inference,
without rate limits, and without leaking your repo to a third party.

## Notable: Claude Code keeps WebSearch/WebFetch even on a local model

Worth calling out because it's a real differentiator:

**Claude Code's `WebSearch` and `WebFetch` tools live in the harness, not in
the model.** Pointing Claude Code at a local model via `ANTHROPIC_BASE_URL`
does **not** strip those tools — the local model can still ask the harness to
search the web or fetch a URL, and the harness performs the call client-side
and feeds results back into the conversation.

By contrast, GitHub Copilot CLI in `COPILOT_OFFLINE=true` mode is fully
network-isolated and has no equivalent web tool. So if you want to keep
inference local **and** still let the agent browse external docs, Claude Code
is the harness for that workflow.

## Prerequisites

- **Docker Desktop** with **Docker Model Runner enabled**
  (Settings → Beta features → "Enable Docker Model Runner").
- **VS Code** with the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers).
- A model pulled on the **host**. The default is `ai/gpt-oss`:

  ```sh
  # On the host (not inside the container):
  docker model pull ai/gpt-oss
  ```

  Or pull it from the Docker Desktop GUI under **Models**.

## Getting started

1. Clone this repo.
2. Open it in VS Code.
3. Command Palette → **Dev Containers: Reopen in Container**.
4. Wait for the build + post-create script to finish. You should see two green
   probes (`/engines/v1/models` and the Anthropic endpoint) and a confirmation
   that `ai/gpt-oss` is loaded.
5. Run a harness:

   ```sh
   claude     # Claude Code, talking to ai/gpt-oss via DMR
   copilot    # GitHub Copilot CLI, talking to ai/gpt-oss via DMR
   ```

That's it. No `/login`, no cloud accounts, no API keys.

### One-time Copilot CLI authentication

Copilot CLI is configured with `COPILOT_OFFLINE=true`, which fully isolates
it from the network. Even though the model is local, Copilot CLI still wants
to verify a GitHub Copilot entitlement on first launch. Do this once with
offline mode temporarily disabled:

```sh
COPILOT_OFFLINE=false copilot
# inside the TUI: /login   (complete the device flow once)
# exit, then run plain `copilot` for all future sessions
```

Claude Code needs no equivalent step — `ANTHROPIC_BASE_URL` +
`ANTHROPIC_AUTH_TOKEN` skip the Anthropic login flow entirely.

## How it's wired

Inside the container, both harnesses point at the same DMR instance running
on the host. The magic hostname `model-runner.docker.internal` is auto-injected
by Docker Desktop into every container when DMR is enabled — that's the only
URL that works from inside the container. (The host-side
`http://localhost:12434` does **not** work from in here, because `localhost`
inside a container means the container itself.)

**Copilot CLI** (`.devcontainer/devcontainer.json`):
```jsonc
"COPILOT_PROVIDER_BASE_URL": "http://model-runner.docker.internal/engines/v1",
"COPILOT_PROVIDER_TYPE": "openai",
"COPILOT_MODEL": "ai/gpt-oss",
"COPILOT_OFFLINE": "true"
```

**Claude Code** (`.devcontainer/devcontainer.json`):
```jsonc
"ANTHROPIC_BASE_URL": "http://model-runner.docker.internal/anthropic",
"ANTHROPIC_AUTH_TOKEN": "not-needed",
"ANTHROPIC_MODEL": "ai/gpt-oss",
"ANTHROPIC_SMALL_FAST_MODEL": "ai/gpt-oss"
```

Both harnesses are installed via official devcontainer features, so the
container itself stays minimal — just a Node 22 base image plus the two
features and a small post-create probe script.

## Switching models

Pull a different model on the **host**:

```sh
docker model pull ai/qwen2.5
```

Then either edit `.devcontainer/devcontainer.json` to change `COPILOT_MODEL`
and `ANTHROPIC_MODEL`, or override per-invocation:

```sh
copilot --model ai/qwen2.5
claude  --model ai/qwen2.5
```

Model management is intentionally a host-side concern. The standalone
`docker model` CLI plugin would conflict with Docker Desktop's DMR if run
inside the container, so the container talks to DMR purely over HTTP.

## Layout

```
.devcontainer/
├── devcontainer.json   # base image, features, env vars
└── post-create.sh      # probes DMR + prints launch hints
```

No Dockerfile, no docker-compose — the entire harness setup is one
`devcontainer.json` plus a verification script.

## Adding more harnesses

The pattern is: pick a harness, find the env vars it uses to point at a
custom endpoint, add them to `containerEnv`, and (if available) add an
official devcontainer feature for the install. Most agent CLIs accept either
an OpenAI-compatible or Anthropic-compatible base URL, so DMR can serve them
without any extra translation layer.
