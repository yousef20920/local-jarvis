# Local Runtime

Jarvis runs the macOS app natively and uses the native Ollama macOS app for the local model server.

**Why native instead of Docker:** Docker Desktop on macOS has no GPU access, so models run CPU-only inside the VM. An 8B vision model takes minutes per inference there. The native Ollama app uses the Apple Silicon GPU via Metal, bringing each agent step down to seconds.

## Start Ollama

Install once (already done on this machine):

```bash
brew install --cask ollama-app
```

Then launch it (it lives in the menu bar and auto-starts its server):

```bash
open -a Ollama
```

Ollama is exposed on:

```text
http://localhost:11434
```

## Pull Local Models

```bash
ollama pull qwen3-vl:8b-instruct
```

The app defaults to one multimodal model for everything — voice intent routing, the computer-use agent loop, and screen-aware answers:

```text
Agent + vision: qwen3-vl:8b-instruct
```

**Use the `-instruct` tags, not the bare ones.** The bare `qwen3-vl:8b` tag is the *thinking* variant: it burns minutes of thinking tokens per call and returns empty content when JSON output is enforced. The instruct variant answers directly in seconds.

`qwen3-vl:4b-instruct` is available in the in-app model picker as a faster, smaller option:

```bash
ollama pull qwen3-vl:4b-instruct
```

If you want to test a different local tag, choose it in the app model picker or set the `jarvisLocalLLMModel` and `jarvisLocalVisionModel` app defaults.

## Check Status

```bash
curl http://localhost:11434/api/tags
```

## Legacy Docker Setup

The repo still contains `docker-compose.yml` from the earlier Docker-based setup. Do not run it while the native app is running — both bind port 11434. If the Docker container is up, stop it first:

```bash
docker compose stop ollama
```
