# Moving over from Reins

Horizon began as a fork of [Reins](https://github.com/ibrahimcetin/reins), so
if you used Reins you already know the basics: point it at an Ollama server,
pick a model, talk. This page covers what you need to set up, what you can
skip, and how to bring your old chats with you.

Horizon installs alongside Reins (it's a separate app, `com.miles.horizon`), so
you can keep Reins installed until you're happy everything came across.

## What you need

**Your Ollama server, and nothing else.**

Settings → **Ollama Server** → enter the same address you used in Reins, e.g.
`http://192.168.1.10:11434`. Tap the scan icon to find it on your network
instead of typing it. Pick a model, and you're chatting.

That's the whole required setup. Everything below is optional.

## Bringing your chats over

Horizon imports both formats Reins exports:

| From Reins | What comes across |
|---|---|
| **`.reins` file** | Title, model, system prompt, chat settings (temperature, context size, …), and every message with the time it was actually sent. |
| **Markdown transcript** (`.md`) | Title, model and every message. Reins doesn't record when each message was sent in a transcript, so they're given made-up times a second apart to keep them in order. |

To import: open any chat → **⋯** (top right) → **Import a chat** → pick the
file. Each import becomes a new chat; nothing existing is overwritten.

Things to check after importing:

- **The model has to exist on your server.** An imported chat asks for the
  exact model name it used in Reins (`llama3:latest`, say). If that model is
  gone, switch it in **⋯ → Chat settings**.
- **Only text is imported.** Images attached in Reins aren't carried over.
- Your Reins *settings* (server address and so on) don't transfer. Enter them
  once in Horizon. After that, Settings → **Backup & Restore** exports them so
  you won't have to again.

## What's optional

None of these are needed to use Horizon the way you used Reins. Add them when
you want them.

| Feature | Where | What you need |
|---|---|---|
| **Use it away from home** | Settings → Ollama Server → backup address | A second address that reaches your server from outside: a Tailscale/ZeroTier IP, or a tunnel hostname. Horizon fails over to it on its own. |
| **Cloudflare Access** | Settings → Ollama Server | A service token (Client ID + Secret), if your tunnel is behind Access. The same token is used for every server Horizon talks to. |
| **Hosted models** (Claude, GPT, Gemini, …) | Settings → **Cloud Models** | An [OpenRouter](https://openrouter.ai) key, which covers hundreds of models. Or, under **Direct provider keys**, your own Anthropic, OpenAI or Google key. The OpenAI one also takes a base URL for any OpenAI-compatible server. |
| **Web search** | Settings → **Tools & Web Search** | A SearXNG address or a SerpAPI key. Reading web pages and telling the time work without either. |
| **Home Assistant** | Settings → **Home Assistant** | Your instance URL and a long-lived access token. |
| **Voice** | Settings → **Voice** | Works out of the box with your phone's own speech recognition and voice. For live transcription and better accuracy, run your own servers. See [Running the voice servers](../README.md#running-the-voice-servers). |
| **"Hey Horizon"** | Settings → Voice | Nothing extra. The wake word runs entirely on your phone. |
| **Look and feel** | Settings → **Appearance** | Theme, accent colour, shape, text size. |

### If you set up voice off your home network

Each voice server has two addresses, one for home and one for **anywhere**,
just like the Ollama server. Away from home, only the "anywhere" address can
answer, so fill it in for every voice server you use: **Live**, **Accuracy
pass** and a self-hosted voice for spoken replies. If one is blank, that piece falls
back silently. For example, a blank live address means you wait for the whole
recording to upload instead of seeing words as you speak.

## Where things moved

| In Reins | In Horizon |
|---|---|
| Server address | Settings → Ollama Server |
| Per-chat system prompt and options | ⋯ → Chat settings (per chat, as before) |
| Exporting a chat | ⋯ → Chat settings → Export |
| Importing a chat | ⋯ → Import a chat (takes `.reins`, `.md` and `.txt`) |
