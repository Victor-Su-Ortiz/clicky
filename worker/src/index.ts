/**
 * Clicky Proxy Worker
 *
 * Proxies requests to the MiniMax APIs so the app never ships with raw
 * API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat  → MiniMax Anthropic-compatible Messages API (streaming)
 *   POST /tts   → MiniMax text-to-speech API (t2a_v2)
 */

interface Env {
  MINIMAX_API_KEY: string;
  MINIMAX_VOICE_ID: string;
  // Some MiniMax accounts require a GroupId query parameter on the TTS
  // endpoint (the current docs show Bearer-only auth, but older accounts
  // and guides still use it). Leave unset unless TTS requests fail.
  MINIMAX_GROUP_ID?: string;
  ASSEMBLYAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  // MiniMax's Anthropic-compatible endpoint accepts the same request body
  // and emits the same SSE event stream as api.anthropic.com/v1/messages,
  // so the app's existing Anthropic-format payload passes through unchanged.
  const response = await fetch("https://api.minimax.io/anthropic/v1/messages", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.MINIMAX_API_KEY}`,
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] MiniMax API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
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
  // The app sends only { "text": "..." } — the model, voice, and audio
  // settings live here so they can change without an app update.
  const requestBody = (await request.json()) as { text?: string };
  const textToSpeak = requestBody.text;

  if (typeof textToSpeak !== "string" || textToSpeak.length === 0) {
    return new Response(
      JSON.stringify({ error: "Missing 'text' in request body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const ttsURL = env.MINIMAX_GROUP_ID
    ? `https://api.minimax.io/v1/t2a_v2?GroupId=${env.MINIMAX_GROUP_ID}`
    : "https://api.minimax.io/v1/t2a_v2";

  const response = await fetch(ttsURL, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.MINIMAX_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "speech-2.8-turbo",
      text: textToSpeak,
      stream: false,
      voice_setting: {
        voice_id: env.MINIMAX_VOICE_ID,
        speed: 1.0,
        vol: 1.0,
        pitch: 0,
      },
      audio_setting: {
        format: "mp3",
        sample_rate: 32000,
        bitrate: 128000,
        channel: 1,
      },
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] MiniMax TTS error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  // MiniMax returns the audio as a hex-encoded string inside a JSON
  // envelope (not raw bytes), and reports request-level failures via
  // base_resp.status_code even on HTTP 200. Decode the hex here so the
  // app receives a complete MP3 buffer it can hand to AVAudioPlayer.
  const result = (await response.json()) as {
    data?: { audio?: string };
    base_resp?: { status_code?: number; status_msg?: string };
  };

  if (result.base_resp?.status_code !== 0 || !result.data?.audio) {
    console.error(`[/tts] MiniMax TTS synthesis failed: ${JSON.stringify(result.base_resp)}`);
    return new Response(
      JSON.stringify({ error: result.base_resp?.status_msg || "TTS synthesis failed" }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const audioBuffer = hexDecodeToArrayBuffer(result.data.audio);
  return new Response(audioBuffer, {
    status: 200,
    headers: { "content-type": "audio/mpeg" },
  });
}

function hexDecodeToArrayBuffer(hexString: string): ArrayBuffer {
  const bytes = new Uint8Array(hexString.length / 2);
  for (let byteIndex = 0; byteIndex < bytes.length; byteIndex++) {
    bytes[byteIndex] = parseInt(hexString.slice(byteIndex * 2, byteIndex * 2 + 2), 16);
  }
  return bytes.buffer;
}
