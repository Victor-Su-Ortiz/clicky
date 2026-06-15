/**
 * Clicky Proxy Worker
 *
 * Proxies requests to the MiniMax APIs so the app never ships with raw
 * API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat  → MiniMax Anthropic-compatible Messages API (streaming),
 *                 or Together AI's OpenAI-compatible API when
 *                 CHAT_UPSTREAM = "together" (the Worker translates the
 *                 request body and SSE stream both ways, so the app always
 *                 speaks Anthropic Messages format regardless of upstream)
 *   POST /tts   → MiniMax text-to-speech API (t2a_v2), or MiniMax speech on
 *                 Together AI when TTS_UPSTREAM = "together" (requires a
 *                 running dedicated endpoint — MiniMax speech models are not
 *                 serverless on Together)
 *   POST /stt   → NVIDIA Parakeet speech-to-text on Together AI — the app
 *                 sends a raw 16kHz mono WAV body and gets back {"text": ...}
 *   GET  /stt-stream → websocket relay to Together's realtime transcription
 *                 endpoint (Parakeet). The relay exists because the realtime
 *                 endpoint authenticates via an Authorization header, which a
 *                 client websocket can't set without shipping the key.
 */

interface Env {
  MINIMAX_API_KEY: string;
  MINIMAX_VOICE_ID: string;
  // Some MiniMax accounts require a GroupId query parameter on the TTS
  // endpoint (the current docs show Bearer-only auth, but older accounts
  // and guides still use it). Leave unset unless TTS requests fail.
  MINIMAX_GROUP_ID?: string;
  ASSEMBLYAI_API_KEY: string;
  // Which upstream serves /chat: "together" (active) or "minimax".
  // Live on Together serverless M3 (MiniMaxAI/MiniMax-M3) as of 2026-06-14 —
  // vision verified working with the base64 screenshots the app sends. The
  // value is set in wrangler.toml; if unset here the code falls back to the
  // MiniMax-direct path. Flip to "minimax" to revert to MiniMax-direct.
  CHAT_UPSTREAM?: string;
  TOGETHER_API_KEY?: string;
  // Together serverless model id. Defaults to "MiniMaxAI/MiniMax-M3" — the
  // vision model the app uses, now listed on Together serverless.
  TOGETHER_CHAT_MODEL?: string;
  // Thinking mode for the Together M3 chat path: "disabled" (default — fastest,
  // best for the real-time voice UX), "enabled", or "adaptive". Sent as
  // chat_template_kwargs.thinking_mode. M3 is a reasoning model, so without
  // this it reasons before every critique (filtered before TTS, but slower).
  TOGETHER_THINKING_MODE?: string;
  // Which upstream serves /tts: "minimax" (default) or "together".
  // The Together path serves the same MiniMax speech model but requires a
  // RUNNING dedicated endpoint on the Together account (~$6.49/hr while up;
  // MiniMax speech models are not serverless there) — flip only after
  // starting it, and flip back to "minimax" once it stops.
  TTS_UPSTREAM?: string;
  TOGETHER_TTS_MODEL?: string;
  // Voice id for the Together TTS path. Together's catalog for the MiniMax
  // speech model does NOT include the MiniMax-direct voice ids (e.g.
  // English_FriendlyPerson) — its English voices are English_Aussie_Bloke,
  // English_ManWithDeepVoice, and English_radiant_girl.
  TOGETHER_TTS_VOICE?: string;
}

const DEFAULT_TOGETHER_CHAT_MODEL = "MiniMaxAI/MiniMax-M3";

const TOGETHER_STT_MODEL = "nvidia/parakeet-tdt-0.6b-v3";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Websocket upgrades are GET requests, so this route must be handled
    // before the POST-only guard below.
    if (url.pathname === "/stt-stream") {
      try {
        return await handleSTTStream(request, env);
      } catch (error) {
        console.error(`[/stt-stream] Unhandled error:`, error);
        return new Response(
          JSON.stringify({ error: String(error) }),
          { status: 500, headers: { "content-type": "application/json" } }
        );
      }
    }

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

      if (url.pathname === "/stt") {
        return await handleSTT(request, env);
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

  if (env.CHAT_UPSTREAM === "together") {
    return handleChatViaTogether(body, env);
  }

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

/**
 * Serves /chat through Together AI's OpenAI-compatible endpoint while the
 * app keeps speaking Anthropic Messages format: the request body is
 * translated Anthropic → OpenAI on the way out, and the response (JSON or
 * SSE stream) is translated back OpenAI → Anthropic on the way in.
 */
async function handleChatViaTogether(anthropicBodyText: string, env: Env): Promise<Response> {
  if (!env.TOGETHER_API_KEY) {
    return new Response(
      JSON.stringify({ error: "CHAT_UPSTREAM is 'together' but the TOGETHER_API_KEY secret is not set" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  let anthropicRequest: AnthropicChatRequest;
  try {
    anthropicRequest = JSON.parse(anthropicBodyText) as AnthropicChatRequest;
  } catch (error) {
    return new Response(
      JSON.stringify({ error: `Invalid JSON request body: ${String(error)}` }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const togetherModelId = env.TOGETHER_CHAT_MODEL || DEFAULT_TOGETHER_CHAT_MODEL;
  const togetherThinkingMode = env.TOGETHER_THINKING_MODE || "disabled";
  const openAIRequest = anthropicToOpenAIChatRequest(anthropicRequest, togetherModelId, togetherThinkingMode);

  const response = await fetch("https://api.together.xyz/v1/chat/completions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.TOGETHER_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(openAIRequest),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Together API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  if (openAIRequest.stream) {
    const translatedStream = response.body!.pipeThrough(createOpenAIToAnthropicSSETransform());
    return new Response(translatedStream, {
      status: 200,
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
      },
    });
  }

  const openAIResponse = (await response.json()) as OpenAIChatResponse;
  return new Response(JSON.stringify(openAIToAnthropicResponse(openAIResponse)), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

// MARK: Anthropic ⇄ OpenAI translation

interface AnthropicContentBlock {
  type: string;
  text?: string;
  source?: { type: string; media_type: string; data: string };
}

interface AnthropicChatRequest {
  model?: string;
  max_tokens?: number;
  stream?: boolean;
  system?: string;
  messages?: Array<{ role: string; content: string | AnthropicContentBlock[] }>;
}

interface OpenAIChatRequest {
  model: string;
  max_tokens?: number;
  stream: boolean;
  messages: Array<{ role: string; content: unknown }>;
  // vLLM/OpenAI-compatible passthrough Together uses to toggle M3's reasoning.
  chat_template_kwargs?: { thinking_mode: string };
}

interface OpenAIChatResponse {
  choices?: Array<{ message?: { content?: unknown } }>;
}

/**
 * Translates the app's Anthropic Messages request into an OpenAI
 * chat-completions request for Together. The Anthropic "system" string
 * becomes a leading system message, and base64 image blocks become
 * data-URL image_url parts.
 */
export function anthropicToOpenAIChatRequest(
  anthropicRequest: AnthropicChatRequest,
  togetherModelId: string,
  thinkingMode?: string
): OpenAIChatRequest {
  const openAIMessages: Array<{ role: string; content: unknown }> = [];

  if (typeof anthropicRequest.system === "string" && anthropicRequest.system.length > 0) {
    openAIMessages.push({ role: "system", content: anthropicRequest.system });
  }

  for (const message of anthropicRequest.messages ?? []) {
    // Conversation-history entries arrive as plain strings.
    if (typeof message.content === "string") {
      openAIMessages.push({ role: message.role, content: message.content });
      continue;
    }

    // The current user turn arrives as content blocks: labeled screenshots
    // (base64 images) interleaved with text, then the prompt text.
    const openAIContentParts: unknown[] = [];
    for (const contentBlock of message.content) {
      if (contentBlock.type === "text" && typeof contentBlock.text === "string") {
        openAIContentParts.push({ type: "text", text: contentBlock.text });
      } else if (contentBlock.type === "image" && contentBlock.source?.type === "base64") {
        openAIContentParts.push({
          type: "image_url",
          image_url: {
            url: `data:${contentBlock.source.media_type};base64,${contentBlock.source.data}`,
          },
        });
      }
    }
    openAIMessages.push({ role: message.role, content: openAIContentParts });
  }

  const openAIRequest: OpenAIChatRequest = {
    model: togetherModelId,
    max_tokens: anthropicRequest.max_tokens,
    stream: anthropicRequest.stream === true,
    messages: openAIMessages,
  };

  // M3 reasons by default; disable it (or set enabled/adaptive) via the
  // vLLM-style chat_template_kwargs so reasoning latency stays out of the
  // spoken critique. Only sent when a mode is configured.
  if (typeof thinkingMode === "string" && thinkingMode.length > 0) {
    openAIRequest.chat_template_kwargs = { thinking_mode: thinkingMode };
  }

  return openAIRequest;
}

/**
 * Translates a non-streaming OpenAI chat-completions response into the
 * Anthropic Messages shape the app parses ({content: [{type, text}]}).
 */
export function openAIToAnthropicResponse(openAIResponse: OpenAIChatResponse): object {
  const messageContent = openAIResponse.choices?.[0]?.message?.content;
  const responseText = typeof messageContent === "string" ? messageContent : "";
  return {
    role: "assistant",
    content: [{ type: "text", text: removeThinkingBlocks(responseText) }],
  };
}

const THINKING_OPENING_TAG = "<think>";
const THINKING_CLOSING_TAG = "</think>";

/**
 * Strips <think>...</think> reasoning blocks (including an unterminated
 * trailing block) from a complete response. MiniMax reasoning models emit
 * these inline through OpenAI-compatible endpoints; the app must only ever
 * see the final answer text, since the spoken critique goes to TTS.
 *
 * Some chat templates pre-fill the opening <think> tag in the prompt, so
 * the model output begins directly with reasoning and only a closing tag
 * ever appears (a known behavior of OpenAI-compatible servings of
 * reasoning models). A closing tag with no earlier opening tag therefore
 * terminates that implicit reasoning prefix.
 */
export function removeThinkingBlocks(text: string): string {
  let workingText = text;

  const firstClosingTagIndex = workingText.indexOf(THINKING_CLOSING_TAG);
  const firstOpeningTagIndex = workingText.indexOf(THINKING_OPENING_TAG);
  if (
    firstClosingTagIndex !== -1 &&
    (firstOpeningTagIndex === -1 || firstClosingTagIndex < firstOpeningTagIndex)
  ) {
    workingText = workingText.slice(firstClosingTagIndex + THINKING_CLOSING_TAG.length);
  }

  return workingText
    .replace(/<think>[\s\S]*?<\/think>/g, "")
    .replace(/<think>[\s\S]*$/, "")
    .trim();
}

/**
 * Streaming-safe <think> block filter. Tags can arrive split across SSE
 * chunks ("<thi" in one delta, "nk>" in the next), so the filter withholds
 * any trailing text that could be the start of a tag until the next push
 * resolves it.
 *
 * Until the first tag (or end of stream) it is unknown whether the stream
 * head is answer text or reasoning from a chat template that pre-filled the
 * opening <think> tag (in which case only a closing tag ever appears). Text
 * is withheld during this head phase: an orphan closing tag discards it as
 * reasoning, an opening tag starts a normal block, and end of stream
 * releases it as answer text. Withholding costs nothing here because the
 * app ignores intermediate chunks — it only uses the accumulated final text.
 */
export class ThinkingTagFilter {
  private isHeadPhase = true;
  private insideThinkingBlock = false;
  private carryText = "";

  /** Feeds a content delta; returns the displayable text it resolves to. */
  push(deltaText: string): string {
    let workingText = this.carryText + deltaText;
    this.carryText = "";
    let displayableText = "";

    while (workingText.length > 0) {
      if (this.isHeadPhase) {
        const openingTagIndex = workingText.indexOf(THINKING_OPENING_TAG);
        const closingTagIndex = workingText.indexOf(THINKING_CLOSING_TAG);

        if (closingTagIndex !== -1 && (openingTagIndex === -1 || closingTagIndex < openingTagIndex)) {
          // Orphan closing tag: everything withheld so far was reasoning
          // generated after a pre-filled opening tag — drop it.
          workingText = workingText.slice(closingTagIndex + THINKING_CLOSING_TAG.length);
          this.isHeadPhase = false;
          continue;
        }
        if (openingTagIndex !== -1) {
          // Normal block start: the text before the opening tag is answer text.
          displayableText += workingText.slice(0, openingTagIndex);
          workingText = workingText.slice(openingTagIndex + THINKING_OPENING_TAG.length);
          this.isHeadPhase = false;
          this.insideThinkingBlock = true;
          continue;
        }
        // No tag seen yet: withhold everything until a tag or end of stream
        // decides whether this head text is reasoning or answer.
        this.carryText = workingText;
        return displayableText;
      }

      if (this.insideThinkingBlock) {
        const closingTagIndex = workingText.indexOf(THINKING_CLOSING_TAG);
        if (closingTagIndex !== -1) {
          workingText = workingText.slice(closingTagIndex + THINKING_CLOSING_TAG.length);
          this.insideThinkingBlock = false;
          continue;
        }
        // Still inside the block: drop the text, but keep a tail that could
        // be the start of the closing tag for the next push.
        this.carryText = longestSuffixThatIsTagPrefix(workingText, THINKING_CLOSING_TAG);
        return displayableText;
      }

      const openingTagIndex = workingText.indexOf(THINKING_OPENING_TAG);
      if (openingTagIndex !== -1) {
        displayableText += workingText.slice(0, openingTagIndex);
        workingText = workingText.slice(openingTagIndex + THINKING_OPENING_TAG.length);
        this.insideThinkingBlock = true;
        continue;
      }

      // No tag: emit everything except a tail that could be the start of an
      // opening tag.
      const withheldTail = longestSuffixThatIsTagPrefix(workingText, THINKING_OPENING_TAG);
      displayableText += workingText.slice(0, workingText.length - withheldTail.length);
      this.carryText = withheldTail;
      return displayableText;
    }

    return displayableText;
  }

  /** Releases any withheld text at end of stream: head-phase text was a
   *  tag-less answer, a post-head tail was only a potential tag prefix.
   *  Text withheld inside an unterminated thinking block stays dropped. */
  flush(): string {
    const remainingText = this.insideThinkingBlock ? "" : this.carryText;
    this.carryText = "";
    return remainingText;
  }
}

/** Longest suffix of `text` that is a proper prefix of `tag` (e.g. "abc<th"
 *  → "<th" for tag "<think>"), or "" when no suffix could start the tag. */
function longestSuffixThatIsTagPrefix(text: string, tag: string): string {
  const maximumLength = Math.min(text.length, tag.length - 1);
  for (let suffixLength = maximumLength; suffixLength >= 1; suffixLength--) {
    const suffix = text.slice(text.length - suffixLength);
    if (tag.startsWith(suffix)) {
      return suffix;
    }
  }
  return "";
}

/**
 * Converts Together's OpenAI-style SSE stream into the Anthropic-style SSE
 * events the app parses: each content delta becomes a content_block_delta /
 * text_delta event, reasoning is filtered out, and the stream ends with
 * "data: [DONE]" (which the app treats as end-of-stream).
 */
export function createOpenAIToAnthropicSSETransform(): TransformStream<Uint8Array, Uint8Array> {
  const textDecoder = new TextDecoder();
  const textEncoder = new TextEncoder();
  const thinkingTagFilter = new ThinkingTagFilter();
  let incompleteLineBuffer = "";
  let hasEmittedDone = false;
  let hasErrored = false;

  const emitTextDelta = (controller: TransformStreamDefaultController<Uint8Array>, text: string) => {
    if (text.length === 0) {
      return;
    }
    const anthropicEvent = {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text },
    };
    controller.enqueue(textEncoder.encode(`data: ${JSON.stringify(anthropicEvent)}\n\n`));
  };

  const emitDone = (controller: TransformStreamDefaultController<Uint8Array>) => {
    if (hasEmittedDone) {
      return;
    }
    hasEmittedDone = true;
    emitTextDelta(controller, thinkingTagFilter.flush());
    controller.enqueue(textEncoder.encode("data: [DONE]\n\n"));
  };

  const processLine = (line: string, controller: TransformStreamDefaultController<Uint8Array>) => {
    if (!line.startsWith("data: ")) {
      return;
    }
    const payload = line.slice("data: ".length).trim();
    if (payload === "[DONE]") {
      emitDone(controller);
      return;
    }

    let parsedChunk: { error?: unknown; choices?: Array<{ delta?: { content?: unknown } }> };
    try {
      parsedChunk = JSON.parse(payload);
    } catch {
      return;
    }

    // OpenAI-compatible backends can fail mid-generation after the 200
    // header: the failure arrives in-band as an SSE error payload. Don't
    // swallow it and synthesize a clean end-of-stream — log it for
    // `wrangler tail` and error the stream, so the app's existing
    // response-error path handles it the same way as a pre-stream failure.
    if (parsedChunk.error !== undefined) {
      console.error(`[/chat] Together mid-stream error: ${payload}`);
      hasErrored = true;
      controller.error(new Error(`Together mid-stream error: ${payload}`));
      return;
    }

    // Reasoning arrives either in a separate delta field (ignored here) or
    // inline as <think> tags in content (removed by the filter) — only the
    // final answer text is forwarded to the app.
    const deltaContent = parsedChunk.choices?.[0]?.delta?.content;
    if (typeof deltaContent === "string" && deltaContent.length > 0) {
      emitTextDelta(controller, thinkingTagFilter.push(deltaContent));
    }
  };

  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      if (hasErrored) {
        return;
      }
      incompleteLineBuffer += textDecoder.decode(chunk, { stream: true });
      let newlineIndex = incompleteLineBuffer.indexOf("\n");
      while (newlineIndex !== -1 && !hasErrored) {
        const line = incompleteLineBuffer.slice(0, newlineIndex).replace(/\r$/, "");
        incompleteLineBuffer = incompleteLineBuffer.slice(newlineIndex + 1);
        processLine(line, controller);
        newlineIndex = incompleteLineBuffer.indexOf("\n");
      }
    },
    flush(controller) {
      if (hasErrored) {
        return;
      }
      if (incompleteLineBuffer.length > 0) {
        processLine(incompleteLineBuffer.replace(/\r$/, ""), controller);
      }
      emitDone(controller);
    },
  });
}

/**
 * Relays a websocket to Together's realtime transcription endpoint with the
 * API key injected. Messages pass through untouched in both directions —
 * the app speaks Together's realtime protocol directly (append/commit in,
 * transcription delta/completed events out).
 */
async function handleSTTStream(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return new Response("Expected a websocket upgrade", { status: 426 });
  }
  if (!env.TOGETHER_API_KEY) {
    return new Response(
      JSON.stringify({ error: "The /stt-stream route needs the TOGETHER_API_KEY secret — run: npx wrangler secret put TOGETHER_API_KEY" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  // Outbound websockets from a Worker use fetch with an Upgrade header —
  // this is also the only way to attach the Authorization header, which is
  // the entire reason this relay exists. Connect upstream FIRST so a
  // failure surfaces as a clean HTTP error instead of a dead client socket.
  const upstreamResponse = await fetch(
    `https://api.together.ai/v1/realtime?model=${encodeURIComponent(TOGETHER_STT_MODEL)}&input_audio_format=pcm_s16le_16000`,
    {
      headers: {
        Upgrade: "websocket",
        Authorization: `Bearer ${env.TOGETHER_API_KEY}`,
        "OpenAI-Beta": "realtime=v1",
      },
    }
  );

  const upstreamSocket = upstreamResponse.webSocket;
  if (!upstreamSocket) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/stt-stream] Together realtime refused upgrade ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody || "Upstream websocket upgrade failed", {
      status: upstreamResponse.status === 101 ? 502 : upstreamResponse.status,
    });
  }
  upstreamSocket.accept();

  const webSocketPair = new WebSocketPair();
  const clientSocket = webSocketPair[0];
  const serverSocket = webSocketPair[1];
  serverSocket.accept();

  /// Closing with an invalid/reserved code throws in the Workers runtime,
  /// so closes fall back to a plain 1000 when passthrough fails.
  const safeClose = (socket: WebSocket, code?: number, reason?: string) => {
    try {
      socket.close(code, reason?.slice(0, 120));
    } catch {
      try { socket.close(1000); } catch {}
    }
  };

  serverSocket.addEventListener("message", (event) => {
    try { upstreamSocket.send(event.data); } catch {}
  });
  upstreamSocket.addEventListener("message", (event) => {
    try { serverSocket.send(event.data); } catch {}
  });
  serverSocket.addEventListener("close", (event) => safeClose(upstreamSocket, event.code, event.reason));
  upstreamSocket.addEventListener("close", (event) => safeClose(serverSocket, event.code, event.reason));
  serverSocket.addEventListener("error", () => safeClose(upstreamSocket, 1011, "client error"));
  upstreamSocket.addEventListener("error", () => safeClose(serverSocket, 1011, "upstream error"));

  return new Response(null, { status: 101, webSocket: clientSocket });
}

/**
 * Transcribes push-to-talk audio with NVIDIA Parakeet on Together AI. The
 * app sends the raw WAV bytes; the model and request shape live here (like
 * /tts owns the voice settings) so they can change without an app update.
 */
async function handleSTT(request: Request, env: Env): Promise<Response> {
  if (!env.TOGETHER_API_KEY) {
    return new Response(
      JSON.stringify({ error: "The /stt route needs the TOGETHER_API_KEY secret — run: npx wrangler secret put TOGETHER_API_KEY" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const audioWAVBuffer = await request.arrayBuffer();
  if (audioWAVBuffer.byteLength === 0) {
    return new Response(
      JSON.stringify({ error: "Missing WAV audio in request body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const togetherFormData = new FormData();
  togetherFormData.append("model", TOGETHER_STT_MODEL);
  togetherFormData.append("language", "en");
  togetherFormData.append("response_format", "json");
  togetherFormData.append(
    "file",
    new Blob([audioWAVBuffer], { type: "audio/wav" }),
    "voice-input.wav"
  );

  // fetch sets the multipart boundary header itself from the FormData body.
  const response = await fetch("https://api.together.xyz/v1/audio/transcriptions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.TOGETHER_API_KEY}`,
    },
    body: togetherFormData,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/stt] Together transcription error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Together returns OpenAI-shaped JSON ({"text": "..."}); pass it through.
  const transcriptionBody = await response.text();
  return new Response(transcriptionBody, {
    status: 200,
    headers: { "content-type": "application/json" },
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

  if (env.TTS_UPSTREAM === "together") {
    return handleTTSViaTogether(textToSpeak, env);
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

/**
 * MiniMax speech on Together AI's OpenAI-compatible speech endpoint.
 * Unlike MiniMax's t2a_v2 (hex-encoded audio inside a JSON envelope),
 * Together returns the MP3 bytes directly, so no decoding is needed —
 * the app receives audio/mpeg either way and can't tell the upstreams
 * apart. Requires a RUNNING dedicated endpoint for the model on the
 * Together account; without one, Together replies 400 "Unable to access
 * non-serverless model", which is passed through and logged here.
 */
async function handleTTSViaTogether(textToSpeak: string, env: Env): Promise<Response> {
  if (!env.TOGETHER_API_KEY) {
    return new Response(
      JSON.stringify({ error: "TTS_UPSTREAM is \"together\" but the TOGETHER_API_KEY secret is not set" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const response = await fetch("https://api.together.xyz/v1/audio/speech", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.TOGETHER_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: env.TOGETHER_TTS_MODEL || "minimax/speech-2.8-turbo",
      input: textToSpeak,
      voice: env.TOGETHER_TTS_VOICE || "English_radiant_girl",
      response_format: "mp3",
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] Together TTS error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
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
