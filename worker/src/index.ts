/**
 * Jarvis API Worker
 *
 * Keeps API keys out of the macOS app. The app sends prompts, screenshots,
 * TTS text, or transcription-token requests here; the Worker calls upstream
 * services using Cloudflare secrets.
 *
 * Routes:
 *   POST /responses         -> OpenAI Responses API
 *   POST /chat              -> OpenAI Responses API alias
 *   POST /tts               -> ElevenLabs TTS API
 *   POST /transcribe-token  -> AssemblyAI streaming token API
 */

interface Env {
  OPENAI_API_KEY: string;
  OPENAI_MODEL?: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/responses" || url.pathname === "/chat") {
        return await handleOpenAIResponses(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse({ error: String(error) }, 500);
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleOpenAIResponses(request: Request, env: Env): Promise<Response> {
  if (!env.OPENAI_API_KEY) {
    return jsonResponse({ error: "OPENAI_API_KEY is not configured." }, 500);
  }

  const requestBodyText = await request.text();
  let requestBody: Record<string, unknown>;

  try {
    requestBody = JSON.parse(requestBodyText) as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "Request body must be valid JSON." }, 400);
  }

  const openAIRequestBody = {
    ...requestBody,
    model: typeof requestBody.model === "string"
      ? requestBody.model
      : env.OPENAI_MODEL || "gpt-5.5",
  };

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(openAIRequestBody),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/responses] OpenAI API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "application/json",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
