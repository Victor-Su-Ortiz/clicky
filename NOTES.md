# Status notes — 2026-06-10

## Which chat API is Clicky using?

**MiniMax, unchanged.** The live Cloudflare Worker (`clicky-proxy.minimax-together.workers.dev`) is still the original MiniMax-only version — the Together AI work below has NOT been deployed.

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
