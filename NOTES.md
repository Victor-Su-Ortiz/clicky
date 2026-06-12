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

**MiniMax, unchanged.** The Together AI **chat** upstream is still dormant (`CHAT_UPSTREAM = "minimax"`) — deploying the Worker for STT does not change the chat behavior at all.

## Together AI support (built, dormant, not deployed)

The local `worker/` code now supports Together as an alternate `/chat` upstream, controlled by `CHAT_UPSTREAM` in `worker/wrangler.toml`:

- `CHAT_UPSTREAM = "minimax"` (current value) → exact same verbatim passthrough to `api.minimax.io` as before. The Together path is completely dormant.
- The app never changes either way — the Worker translates Anthropic ⇄ OpenAI formats internally.

**Why not switched yet:** Together only serves MiniMax M2.7, which is **text-only** (no screenshots → Clicky's core flow can't work). MiniMax M3 (the vision model Clicky uses) is listed as "coming soon" on https://www.together.ai/models/minimax-m3.

**Deploying the new Worker is safe whenever** (no behavior change while `CHAT_UPSTREAM = "minimax"`):

```bash
cd worker && npx wrangler deploy
```

**To switch to Together later** (once M3 is live on Together):

```bash
cd worker
npx wrangler secret put TOGETHER_API_KEY     # paste Together key
# edit wrangler.toml: CHAT_UPSTREAM = "together"
#                     TOGETHER_CHAT_MODEL = "<M3 model id from Together>"
npx wrangler deploy
```

Flip back anytime by reverting `CHAT_UPSTREAM` to `"minimax"` and redeploying. TTS always stays on MiniMax (Together doesn't host their speech model), so keep `MINIMAX_API_KEY` set regardless.

## Other loose ends

- **Custom cursor image:** drop a PNG into Xcode → `Assets.xcassets` → `clicky-cursor` (empty slot waiting). Transparent background, tip pointing **up**, ~32–48 px square. Until then the blue triangle shows. Remove the image to go back.
- **Uncommitted changes:** the Together translation layer (`worker/src/index.ts`, `wrangler.toml`), the cursor-image support (`OverlayWindow.swift`, new imageset), and `AGENTS.md` doc updates are not committed yet.
