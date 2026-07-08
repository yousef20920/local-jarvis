# OpenAI Runtime

Jarvis uses OpenAI GPT-5.5 through the Cloudflare Worker. The macOS app never stores or sends an OpenAI API key directly to OpenAI.

## Worker Secrets

For deployed Worker runs:

```bash
cd worker
npx wrangler secret put OPENAI_API_KEY
```

For Worker development on this machine, put the key in the ignored file:

```text
worker/.dev.vars
```

with:

```bash
OPENAI_API_KEY=your_key_here
```

Do not put API keys in `worker/wrangler.toml`, Swift files, `Info.plist`, Xcode build settings, or app bundle resources.

## Model

The Worker uses:

```toml
[vars]
OPENAI_MODEL = "gpt-5.5"
```

The app route is configured through `JarvisOpenAIResponsesProxyURL` in `Info.plist`. The default development value is:

```text
http://127.0.0.1:8787/responses
```

For production, change that value to the deployed Worker `/responses` URL.
