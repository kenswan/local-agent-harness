# Claude Open Source

## Requirements

[Docker Desktop](https://www.docker.com/products/docker-desktop/)

## 1. Docker Models

Reference: [https://docs.docker.com/ai/model-runner/get-started/](https://docs.docker.com/ai/model-runner/get-started/)

### Enable TCP
Command: `docker desktop enable model-runner --tcp`

### Docker Model Runner URL

#### Host
[http://localhost:12434](http://localhost:12434)

### Containers
[http://model-runner.docker.internal](http://model-runner.docker.internal)

### View Downloaded Models

#### Host
Command: `docker model list`

#### Container
Command: `curl -s http://host.docker.internal:12434/v1/models | jq -r '.data[].id'`

### Download Model
Command: `docker model pull gpt-oss`

## 2. Install Claude Code

Reference: [https://claude.com/product/claude-code](https://claude.com/product/claude-code)

Command: `curl -fsSL https://claude.ai/install.sh | bash`

## 3. Start Claude Code

### Host
```bash 
ANTHROPIC_BASE_URL=http://localhost:12434 \
ANTHROPIC_AUTH_TOKEN=not-needed \
ANTHROPIC_MODEL=docker.io/ai/gemma4:26B \
ANTHROPIC_SMALL_FAST_MODEL=docker.io/ai/gemma4:26B \
DISABLE_AUTOUPDATER=1 \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
claude
````

### Container
```bash 
ANTHROPIC_BASE_URL=http://model-runner.docker.internal \
ANTHROPIC_AUTH_TOKEN=not-needed \
ANTHROPIC_MODEL=docker.io/ai/gemma4:26B \
ANTHROPIC_SMALL_FAST_MODEL=docker.io/ai/gemma4:26B \
DISABLE_AUTOUPDATER=1 \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
claude
````

## 4. Add Web Search

### Install Playwright
`npx -y playwright install chromium --with-deps`

### Install Playwright MCP
`claude mcp add playwright -- npx -y @playwright/mcp --browser chromium`
