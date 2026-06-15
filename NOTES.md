# Status notes — 2026-06-10 (updated 2026-06-11)

## TTS via Together (built + deployed, dormant — demo-day flip)

The Worker now has a `TTS_UPSTREAM` toggle (mirrors `CHAT_UPSTREAM`). It is deployed set to `"minimax"`, so TTS behavior is unchanged (MiniMax direct, `English_FriendlyPerson`). The `"together"` path serves the **same model** (`minimax/speech-2.8-turbo`) through Together AI — but MiniMax speech is NOT serverless on Together (verified against the live API, including id aliases and the stream flag): it requires a **dedicated endpoint**, 1× H100 at 10.82¢/min ≈ **$6.49/hr, billed only while running**.

**Demo-day recipe (~5 min):**

1. Start the endpoint: https://api.together.ai/models/minimax/speech-2.8-turbo → "Create dedicated endpoint" → 1× H100 → set the inactive/auto-stop timeout to ~10 min. First spin-up takes a few minutes.
2. Flip: edit `worker/wrangler.toml` → `TTS_UPSTREAM = "together"`, then `cd worker && npx wrangler deploy`.
3. Verify: `curl -s -X POST https://clicky-proxy.minimax-together.workers.dev/tts -H 'Content-Type: application/json' -d '{"text":"hi"}' -o /tmp/check.mp3 && file /tmp/check.mp3` → should say MPEG audio.
4. After the demo: stop the endpoint in the Together dashboard (or let auto-stop catch it), flip `TTS_UPSTREAM` back to `"minimax"`, redeploy.

**Voice caveat:** Together's catalog for this model does not include `English_FriendlyPerson`. `TOGETHER_TTS_VOICE` is preset to `English_radiant_girl` (alternatives: `English_Aussie_Bloke`, `English_ManWithDeepVoice`). Once the endpoint is live, try setting `English_FriendlyPerson` anyway — the catalog may just be the validated subset.

**Verified (2026-06-11):** the Together branch was exercised live via `wrangler dev` (auth + request shape correct — Together returns the expected "non-serverless model" 400 until an endpoint runs, passed through and logged); after deploy (version `09455c40`), production `/tts` (MiniMax MP3) and `/chat` were regression-checked. Chat M3 re-checked the same day: still absent from Together (no serverless listing, no dedicated hardware), so chat stays on MiniMax direct.

## ✅ Worker deployed (2026-06-12) — STT is live

Speech-to-text defaults to **NVIDIA Parakeet on Together AI** (`VoiceTranscriptionProvider = "parakeet"` in Info.plist). The Worker is deployed with the `TOGETHER_API_KEY` secret set, and all routes were verified live: `/stt-stream` (websocket streaming, ~280 ms release→transcript), `/stt` (upload fallback), `/transcribe-token` and `/chat` (regression-checked, unchanged). Just rebuild the app in Xcode.

(To revert STT: set `VoiceTranscriptionProvider` back to `assemblyai` in `leanring-buddy/Info.plist` and rebuild — the AssemblyAI route is still live.)

## Which chat API is Clicky using?

**Together AI serverless M3**, as of 2026-06-14 (`CHAT_UPSTREAM = "together"`, `TOGETHER_CHAT_MODEL = "MiniMaxAI/MiniMax-M3"`, deployed version `25afb1f2`). Same M3 vision model as before, now served through Together's OpenAI-compatible endpoint with reasoning disabled for latency. Flip `CHAT_UPSTREAM` back to `"minimax"` + redeploy to return to MiniMax-direct. (TTS and STT unchanged.)

## Together AI chat — LIVE (deployed 2026-06-14)

`/chat` now runs on Together's serverless MiniMax M3 (`MiniMaxAI/MiniMax-M3` — $0.30/1M in · $0.06/1M cached · $1.20/1M out, ~524K ctx), controlled by `CHAT_UPSTREAM` in `worker/wrangler.toml`. The app never changes — the Worker translates Anthropic ⇄ OpenAI internally and the app always sees Anthropic Messages format.

**Verified live (2026-06-14, deployed version `25afb1f2`):**

- **Vision works with base64 `data:` URLs** — exactly what the app sends. Tested through the deployed Worker `/chat` in the app's Anthropic format (system + text + base64 image, streaming): returned clean `content_block_delta`/`text_delta` events, a single `[DONE]`, no `<think>` leak, and an accurate description of the test image. (Earlier "I don't see an image" replies were only for tiny featureless solid-color test images — a model quirk, not a vision failure. A real photo / a webpage screenshot is described correctly.)
- **Reasoning isolation** — M3 streams reasoning in a separate `delta.reasoning` field, which the Worker already ignores (it forwards only `delta.content`). No reasoning reaches TTS.
- **Thinking disabled for latency** — `TOGETHER_THINKING_MODE = "disabled"` makes the Worker send `chat_template_kwargs:{"thinking_mode":"disabled"}` (verified: reasoning tokens → 0). Set it to `"enabled"`/`"adaptive"` to turn reasoning back on. NB: the `{"thinking": false}` variant does NOT work — only `thinking_mode` does.

**Revert to MiniMax-direct** anytime: set `CHAT_UPSTREAM = "minimax"` in `wrangler.toml`, then `cd worker && npx wrangler deploy`. TTS always stays on MiniMax (Together doesn't host their speech model serverless), so keep `MINIMAX_API_KEY` set regardless.

**Re-check vision later** (e.g. if Together changes the deployment) — send a real image, not a solid color:

```bash
KEY=$(grep '^TOGETHER_API_KEY=' worker/.dev.vars | cut -d= -f2-)
curl -sL https://picsum.photos/id/237/400/300.jpg -o /tmp/img.jpg
B64=$(base64 < /tmp/img.jpg | tr -d '\n')
curl -s https://api.together.xyz/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"MiniMaxAI/MiniMax-M3","max_tokens":60,"messages":[{"role":"user","content":[{"type":"text","text":"Describe this image."},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,'"$B64"'"}}]}]}'
```

A real description → vision OK.

## Other loose ends

- **Custom cursor image:** drop a PNG into Xcode → `Assets.xcassets` → `clicky-cursor` (empty slot waiting). Transparent background, tip pointing **up**, ~32–48 px square. Until then the blue triangle shows. Remove the image to go back.
- **Uncommitted changes:** the Together translation layer (`worker/src/index.ts`, `wrangler.toml`), the cursor-image support (`OverlayWindow.swift`, new imageset), and `AGENTS.md` doc updates are not committed yet.
