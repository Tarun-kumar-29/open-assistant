# Open Assistant

A push-to-talk voice assistant for your Mac, powered by Claude.
Hold **Fn**, speak, let go. It answers out loud, shows the reply in a small floating panel at the top of the screen, and can act on your Mac.

## What it can do

- **Talk:** answers in English, Hindi or Hinglish. It speaks a one-line summary and shows the full answer in a panel at the top of the screen (bullets, bold, code, copy button). Menu → Voice changes how much it speaks.
- **Any AI provider:** Claude by default, or switch to OpenAI, Groq, OpenRouter, or a local model via Ollama/LM Studio. The Model menu lists what your key can access.
- **Accurate transcription:** Groq Whisper (free API key) for the final transcript, tuned for Hinglish and your team's names; Apple's recognizer gives the live preview and is the fallback.
- **Dictate anywhere:** hold **Right Option**, speak, release, and the words are typed where your cursor is, in any app, with punctuation fixed and fillers removed.
- **Floating pill:** a small pill that appears while it's listening, thinking or speaking, then fades away. Click it to talk hands-free, right-click for the menu, drag it anywhere. Menu → Floating Pill lets you keep it always on (as a tiny dot), hide it for an hour, or turn it off.
- **Control your Mac:** open apps and links, run AppleScript (Music, Finder, Calendar, Reminders, volume…), run shell commands, type text into the focused app, read and write the clipboard, look at your screen.
- **Look things up:** web search for anything current.
- **Remember:** keeps durable facts in `memory.md` (say "remember that…"). The conversation itself carries over between presses and resets after 10 idle minutes.
- **Connectors:** plug in your apps (Linear, Notion, GitHub, Jira…) or local tools (files, git, a browser), like Claude's connectors. Sign-in happens in your browser with one click.

## Install (friends: start here)

One line in Terminal, no developer tools needed:

```bash
curl -fsSL https://raw.githubusercontent.com/Tarun-kumar-29/open-assistant/main/install.sh | bash
```

It downloads the latest release, puts **Open Assistant.app** in Applications and launches it. Then:

1. **Paste an API key** when asked: Anthropic by default (console.anthropic.com → API Keys). Or menu → **Provider** to use OpenAI, Groq, OpenRouter or a local model instead. Keys live in your Keychain.
2. **Allow the permissions** macOS asks for: Microphone, Speech Recognition, Accessibility and Input Monitoring (System Settings → Privacy & Security if a prompt is missed).
3. Menu bar icon → **Set Groq API Key…** with a free key from console.groq.com. This gives you accurate Hinglish transcription; without it Apple's recognizer is used.
4. Hold **Right ⌘** and say "hello".

The app is signed by its author, not notarized by Apple, so if you download the zip by hand instead of using the installer, right-click the app → Open the first time.

## Build from source (developers)

1. `xcode-select --install` if you don't have the command line tools.
2. `./build.sh --install` builds, copies to Applications and launches.
3. `./release.sh` builds and packages `dist/OpenAssistant-<version>.zip` for sharing.

After each rebuild macOS forgets the Accessibility grant (ad-hoc signature). See Troubleshooting for the one-time certificate that fixes this.

## Using it

| Action | What happens |
|---|---|
| Hold Fn and speak | Listens and shows a live transcript |
| Release Fn | Sends your words to Claude |
| Press Fn while it's talking | Interrupts it and starts listening again |
| Quick tap Fn | Stops it (cancels thinking or speaking) and hides the panel |
| Hold Right Option and speak | Dictation: types what you said into the focused app |
| Click the pill | Start listening; click again to send |
| Fn + another key (e.g. Fn+Delete) | Works as usual; it won't trigger the assistant |
| Menu → Ask by Typing… | Type a question instead of speaking |

Things to try:
- "Open Slack and VS Code"
- "Pause the music" / "Volume 30 percent"
- "What's on my screen? Summarise this page"
- "Type a polite reply saying I'll send it by evening"
- "Remember that standup is at 10:30"
- "Kal ka weather kaisa rahega Bengaluru mein?"

AppleScript and shell commands show a **Run / Cancel** dialog first. You can turn that off with `confirmScripts`, but leaving it on is safer.

## Config

Open it from the menu bar icon → **Open Config File**. After editing, click **Reload Config**. File location: `~/Library/Application Support/OpenAssistant/config.json`

| Key | Default | Notes |
|---|---|---|
| `provider` | `anthropic` | `anthropic`, `openai`, `groq`, `openrouter`, or `custom` (any OpenAI-compatible URL, e.g. Ollama). Menu → **Provider** |
| `model` | `claude-sonnet-5-5` | Menu → **Model** lists the provider's live models; or type any ID |
| `customBaseURL` | `""` | For the custom provider, e.g. `http://localhost:11434/v1` |
| `maxTokens` | `2048` | Maximum reply length |
| `hotkey` | `fn` | `fn`, `rightOption`, `rightCommand`, `rightControl`, `keycode:<n>` for any key (that key is then reserved for the assistant), or `none` |
| `dictationHotkey` | `rightOption` | Key to hold for dictation; same options, or `none` |
| `dictationCleanup` | `true` | Fix punctuation and remove fillers before inserting (uses `dictationModel`) |
| `dictationModel` | `""` | Model for dictation cleanup; empty picks a fast one for the provider |
| `dictationInsert` | `paste` | How text is inserted: `paste` (⌘V, works in WhatsApp, Slack, browsers, everything), `accessibility` (direct insert in native fields, no clipboard), or `type` (keystrokes; slowest) |
| `pillMode` | `activeOnly` | `activeOnly` (appears only while listening/thinking/speaking), `always` (small dot when idle), or `never` |
| `pillPosition` | `bottomCenter` | `bottomCenter`, `bottomLeft`, `bottomRight`, `topCenter`, `topLeft`, `topRight`, or drag the pill anywhere |
| `transcriber` | `groq` | `groq` or `apple` for the final transcript |
| `groqModel` | `whisper-large-v3-turbo` | `whisper-large-v3` is slightly more accurate, slower |
| `transcribeLanguage` | `""` | Force a language code (`en`, `hi`) or leave empty for auto-detect |
| `transcribePrompt` | Hinglish sample + names | Style hint for Whisper: keeps Hinglish in Roman script; add your own names and jargon here |
| `speakMode` | `firstLine` | `firstLine` (one-line summary), `all`, or `none` |
| `speechLocale` | `en-IN` | Recognition language. `en-IN` handles Indian English and Hinglish best; `hi-IN` for mostly Hindi |
| `onDeviceRecognition` | `false` | `true` keeps audio fully on-device (slightly less accurate) |
| `voiceIdentifier` | `""` | Empty picks the best installed voice for the locale. Better voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices (download a *Premium* or *Enhanced* one) |
| `speechRate` | `0.52` | 0.4 is slow, 0.6 is fast |
| `speakReplies` | `true` | `false` shows the text only |
| `webSearch` | `true` | Lets it search the web |
| `confirmScripts` | `true` | Ask before AppleScript and shell commands |
| `conversationResetMinutes` | `10` | Start a fresh conversation after this much idle time |
| `panelHideSeconds` | `14` | How long the panel stays after it finishes speaking |
| `userName` | `Tarun` | What it calls you |
| `extraInstructions` | `""` | Anything you want it to always know or do |

## Connectors

Menu bar icon → **Connectors…** (⌘K). This works like Claude's connectors:

1. Click **Add → Browse Catalog**, pick a service and click **Add & Connect**.
2. If the service needs sign-in, its row shows **Log In**. Click it, approve access in your browser, and you're done. The app refreshes the sign-in automatically from then on.
3. Ask for something: "what's assigned to me in Linear?", "find the onboarding page in Notion", "open PRs on our repo?"

**Catalog: apps (sign in with your account)**
- **One-click sign-in:** Linear, Notion, Jira & Confluence, Sentry, Stripe, Supabase, Vercel, Hugging Face.
- **Zapier:** the quickest route to Gmail and Google Calendar if you don't want a Google Cloud project; paste the URL and token from mcp.zapier.com.
- **No sign-in needed:** Context7, DeepWiki, Cloudflare Docs.
- **Token required:** GitHub needs a personal access token pasted into the header.

**Catalog: on this Mac (local)**
- **Google (Gmail, Calendar, Meet, Drive):** needs a free Google Cloud OAuth client; the editor note walks you through it. Meet links are created through Calendar events ("set up a Meet with Aryan tomorrow at 4").
- **Files:** pick which folders.
- **Web Fetch**, **Git**, **Time Zones:** these need `uv` (`brew install uv`).
- **Browser (Playwright)**, **Knowledge Graph Memory:** these need Node.js.

**Custom connectors** (Add → Custom…):
- **Remote:** paste any MCP server URL (Streamable HTTP, usually ending in `/mcp`). If it uses OAuth, you'll get a Log In button. If it uses an API key instead, add a header such as `Authorization: Bearer <key>`. This is how you add **Oplo** or **VocalLabs**: paste their MCP URL.
- **Local:** any command that runs an MCP server, e.g. `npx -y some-mcp-server`. Put each argument on its own line and add environment variables such as API keys.

Notes:
- **Turning a connector off:** use its switch. Its tools disappear from the assistant immediately.
- **Logs:** each local connector writes its errors to a log. Open it with **⋯ → Show Log**.
- **Where things are stored:** sign-in tokens are kept in your Keychain. The connector list is in `~/Library/Application Support/OpenAssistant/connectors.json`, readable only by you. Header values such as API keys are saved there.
- **Not supported:** older SSE-only servers (URLs ending in `/sse`). Most services now offer a `/mcp` endpoint instead.

## Troubleshooting

- **Fn does nothing / "Waiting for Accessibility permission" even though the toggle is on.** After a rebuild, macOS keeps the grant tied to the old binary. In Accessibility, remove *Open Assistant* with "–", add it again, check Input Monitoring too, then relaunch. To stop this recurring, create a self-signed certificate called **Open Assistant Dev** (Keychain Access → Certificate Assistant → Create a Certificate → type Code Signing, or the `openssl`/`security` one-liner in the docs); `build.sh` signs with it automatically and the permissions then survive rebuilds.
- **The emoji picker or dictation pops up.** See step 5. Or switch to `"hotkey": "rightOption"` and `"dictationHotkey": "rightCommand"`.
- **Dictation types nothing.** Menu → **Test Dictation Insert (3 s)**, then click into a text field and wait: a test sentence should appear and the panel reports which method was used. Check **Open Dictation Log** (`~/Documents/Open Assistant/dictation.log`) for what happened. If paste is blocked in that app, set `dictationInsert` to `type`. Accessibility permission is required for all methods.
- **"Speech recognition is unavailable".** Server-based recognition needs internet. Try `onDeviceRecognition: true`, or check `speechLocale`.
- **API error 401.** The key is wrong. Use menu → Set Anthropic API Key…
- **The screenshot only shows the wallpaper.** Grant Screen Recording permission, then relaunch.
- **Keychain asks for permission after a rebuild.** Click *Always Allow*. This happens because the app is signed locally.
- **A local connector shows "command not found" in its log.** Use the full path to the command (run `which npx` in Terminal to find it).
- **Log In fails with "doesn't support automatic sign-in".** That service needs an API token: edit the connector and add it as a header.

## Files

```
Sources/
  App.swift            entry point
  AppDelegate.swift    menu bar, permissions, settings
  HotkeyMonitor.swift  global push-to-talk key (CGEvent tap)
  SpeechInput.swift    microphone, Apple live preview, audio capture
  Transcriber.swift    Groq Whisper upload + 16 kHz recorder
  SpeechOutput.swift   text-to-speech, sentence by sentence
  ClaudeClient.swift   streaming Messages API client
  Assistant.swift      conversation loop, tool calls, system prompt
  Tools.swift          Mac-control tools
  Memory.swift         long-term memory file
  Panel.swift          floating reply panel (SwiftUI)
  Pill.swift           always-on floating pill at the bottom of the screen
  MCP.swift            MCP client (local stdio + remote Streamable HTTP)
  OAuth.swift          browser sign-in for connectors (OAuth 2.1 + PKCE)
  Connectors.swift     connector list, catalog, tool routing
  ConnectorsUI.swift   Connectors window
Info.plist             permissions text
build.sh               compile, sign, install
```

Memory lives at `~/Library/Application Support/OpenAssistant/memory.md`. You can edit it by hand.
