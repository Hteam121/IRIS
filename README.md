# Dory (the IRIS project)

**Dory is your own voice assistant for the Mac, like Jarvis from Iron Man.**

A small floating dot follows your mouse around. You say "Hey Dory" (or just hold **Option+Space** and talk), and it answers out loud while the words stream onto the screen. It can look at your screen, point at things on it, open apps, search the web for real answers, run coding and research tasks in the background with Claude Code, and remember things you tell it.

> **Naming note:** the assistant is called **Dory**, but the project keeps its original internal name, IRIS. The repo, the bundle id (`com.iris.app`), the settings folder (`~/.iris/`), and every `IRIS_*` environment variable are unchanged, so existing installs, permissions, and config carry over.

This guide takes you from zero to a working copy on your own Mac. No deep coding knowledge needed. Just follow the steps in order.

---

## What it can do

- 🎙️ **Talk to it two ways.** Say "Hey Dory" (the name works anywhere in a sentence, even "can you check that, Dory?"), or hold **Option+Space** and talk, then let go. Both are free, the listening runs on your Mac.
- ⚡ **It answers as it thinks.** Replies stream in: it starts speaking the first sentence while the rest is still being written, so it feels fast.
- 👁️ **It can see your screen.** Ask "What's on my screen?" or "Summarize this page."
- 👉 **It can point.** Ask "Where's the WiFi icon?" and an animated arrow flies to it on screen.
- 🧠 **It thinks using Claude** (your Claude subscription or an Anthropic API key), so the answers are smart.
- 🌍 **It knows what's happening.** Ask "what's going on in the world today" and it searches the web, then gives you a short human summary instead of reading articles.
- 🏠 **It answers simple things locally.** With Ollama (or Apple's on-device models) installed, easy questions are answered for free on your Mac and only hard ones go to the cloud.
- 🖱️ **It controls your Mac.** Open apps, folders, terminals, run web searches, even type and click for you.
- 🤖 **It really does things.** Say "create a notes file on my desktop" and a real Claude Code session runs it in the background. You see its live progress ("Editing notes.txt"), hear a short spoken update, and can say "continue that task" later to pick up where it left off, or "cancel that" to stop it.
- 🧩 **It has skills.** Drop a markdown file in `~/.iris/skills/` and Dory learns a new routine, no rebuild needed.
- 💾 **It remembers things.** Tell it "remember I prefer Chrome" once and it keeps that forever.
- 💸 **It watches your spending.** You set a monthly dollar limit and Dory stays under it automatically. With just a Claude subscription and no API keys, day-to-day use costs nothing extra.
- 🪟 **It stays out of the way.** No dock icon, just a tiny eye in your menu bar and a dot that follows your cursor (or lives in the notch if you prefer).

---

## Before you start

You will need a few things. Don't worry, the setup script installs most of them for you.

**On your Mac:**

- macOS 13 or newer (macOS 14 or newer is best, because screen vision needs it).
- Xcode 15 or newer, free from the Mac App Store. This is what builds the app.
- An Apple ID. The free one is fine. It is used to "sign" the app so your Mac trusts it.

**Two AI services power Dory:**

1. **Claude (the brain).** This is basically required. Dory thinks, sees your screen, searches the web, and runs background tasks using the `claude` command line tool, which runs on your Claude Pro or Max **subscription**. That means no extra per-message charges. You log in once. (If you prefer, set an `ANTHROPIC_API_KEY` instead and Dory uses the streaming API directly, with prompt caching to keep costs down.)
2. **An OpenAI key (the voice).** Recommended. This powers the natural speaking voice (a quick, friendly female voice by default). Without it, Dory still works fully but speaks with the basic built-in macOS voice.

**Optional but nice:** [Ollama](https://ollama.com) with any small model pulled (for example `ollama pull llama3.2`). Dory then answers simple questions locally for free.

> Short version: log in to Claude for the brain, add an OpenAI key for the good voice, and optionally run Ollama for free local answers.

---

## Setup, step by step

### Step 1: Download the project

Open the **Terminal** app and run these lines one at a time:

```bash
git clone https://github.com/Hteam121/IRIS.git
cd IRIS
./setup.sh
```

`setup.sh` checks your Mac, installs the missing tools (using Homebrew and npm), and creates a settings file for you. It is safe to run more than once. If you do not have Homebrew yet, install it first from [brew.sh](https://brew.sh).

### Step 2: Add your keys

The setup script made a file called `.env`. Open it in any text editor and fill in your OpenAI key:

```bash
OPENAI_API_KEY=sk-...        # for the natural speaking voice (recommended)
ANTHROPIC_API_KEY=           # leave this blank to use your Claude subscription
```

Then log in to Claude once so the brain works. In Terminal, run:

```bash
claude
```

Follow the login prompt. It uses your Claude Pro or Max subscription.

### Step 3: Create the Xcode project file

```bash
xcodegen generate
```

This builds `IRIS.xcodeproj`, the file Xcode opens.

### Step 4: Set your signing identity (important on a fresh download)

The project comes with the original author's signing setting, which will not exist on your Mac. You need to point it at your own Apple ID, or the build will fail. The easy way:

1. Open the project: `open IRIS.xcodeproj`
2. Click the **IRIS** target, then the **Signing & Capabilities** tab.
3. Turn on **Automatically manage signing** and pick your **Team** (your Apple ID).

Why this matters: macOS links permissions like the microphone and screen recording to your signing identity. Using your own Apple ID keeps those permissions even after you rebuild. (Advanced users can instead edit `DEVELOPMENT_TEAM` in `project.yml` and run `xcodegen generate` again.)

### Step 5: Run it

In Xcode, press the **Run** button (or `Cmd + R`). Dory starts as a menu bar app. Look for the small **eye icon** in the top menu bar. There is no dock icon. The first time it runs, it asks for some permissions, covered in the next section.

### Step 6 (optional): Use it like a normal app

If you do not want to open Xcode every time, build a finished copy and put it in your Applications folder:

```bash
./scripts/install-app.sh
```

This builds `Dory.app`, installs it to `/Applications`, and opens it. After that you can launch it from Spotlight or Finder like any other app. To start it automatically when your Mac boots, add it under **System Settings, General, Login Items**.

### Step 7 (optional): Calendar and other integrations

Background tasks can use MCP servers (small tool plugins). To let Dory schedule things on Google Calendar, copy the example and follow its notes:

```bash
cp mcp.json.example ~/.iris/mcp.json
```

The first calendar task opens a Google login once. No other setup is needed; background tasks are powered by the same `claude` tool you logged into in Step 2.

---

## Permissions you need to grant

The first time Dory runs, a **setup window** walks you through each permission with a live checkmark, so you can just follow it. You can reopen it any time from the menu bar eye icon, under "Setup & Permissions". For reference:

| Permission | What it is for | How to allow it |
| --- | --- | --- |
| **Microphone** | Hearing "Hey Dory" and your requests. | Click Allow when asked. |
| **Speech Recognition** | Understanding what you say. | Click Allow when asked. |
| **Screen Recording** | Looking at your screen. | This one is not a popup. Go to **System Settings, Privacy & Security, Screen Recording**, turn on Dory, then quit and reopen it. |
| **Accessibility** | The Option+Space push-to-talk hotkey, plus typing and clicking for you. | Go to **System Settings, Privacy & Security, Accessibility** and turn on Dory. |
| **Automation** | Opening Terminal and Claude Code. | Click Allow the first time it opens Terminal. |

---

## How to talk to Dory

Two ways, always available:

- **Wake word:** say "Hey Dory" and your request in one breath. The name also works on its own, anywhere in the sentence ("what's this error about, Dory?").
- **Push-to-talk:** hold **Option+Space**, talk, let go. No wake word needed, and it is the most reliable way in a noisy room.

Some examples:

| You say | What Dory does |
| --- | --- |
| "Hey Dory, what time is it?" | Tells you out loud, instantly and locally. |
| "Hey Dory, what's going on in the world today?" | Searches the web and gives you a short spoken summary. |
| "Hey Dory, what's on my screen?" | Looks at your screen and explains it. |
| "Hey Dory, where's the WiFi icon?" | Flies an animated arrow to it on screen. |
| "Hey Dory, open Chrome" | Opens the app. |
| "Hey Dory, open my Desktop" | Opens the folder in Finder. |
| "Hey Dory, run my morning briefing" | Runs the installed skill of that name. |
| "Hey Dory, search the web for noise cancelling headphones" | Opens a browser search. |
| "Hey Dory, create a notes file on my desktop" | A Claude Code session actually does it, with live progress. |
| "Hey Dory, find the top 3 deals on XM5 headphones" | Works on it in the background and reports back. |
| "Hey Dory, continue that task, and also add a title" | Resumes the last background session with your new instruction. |
| "Hey Dory, cancel the deal search" | Stops that background task. |
| "Hey Dory, remember I prefer Chrome for searches" | Saves that and uses it from now on. |
| "Hey Dory, open a terminal and start Claude in my project" | Opens Terminal and a visible Claude Code session. |

Saying "dory agent" before a task still works and always forces the background-agent path.

The floating dot changes color to show what it is doing: gray means idle, blue means listening, purple means thinking, green means speaking. Background tasks show as small pills under it with live progress, and you can also cancel them from the menu bar.

### Skills

A skill is a small markdown file that teaches Dory a routine. Dory ships with a few (`morning-briefing`, `focus-mode`, `research-topic`) which are copied to `~/.iris/skills/` on first launch. Add your own by dropping a file there:

```markdown
---
name: standup-prep
description: Get everything ready for the morning standup.
mode: inline
---
1. Open Slack and my calendar.
2. Summarize today's meetings out loud.
```

`mode: inline` skills are carried out live in the conversation; `mode: agent` skills run in the background. Say the skill's name ("Hey Dory, run standup prep") to trigger it.

---

## Settings you can change

You usually do not need to touch these. Settings are read from two optional files: `.env` in the project folder and `~/.iris/config.json` in your home folder. Every setting is optional and has a sensible default. (The `IRIS_*` names are the project's original internal names — see the naming note up top.)

The most useful ones:

| Setting (in `.env`) | Default | What it does |
| --- | --- | --- |
| `OPENAI_API_KEY` | none | Turns on the natural speaking voice. |
| `ANTHROPIC_API_KEY` | none | Optional. Use the Anthropic API (streaming, cached) instead of your Claude subscription. |
| `IRIS_MODEL` | `claude-sonnet-4-6` | Which Claude model to think with. |
| `IRIS_WAKE_PHRASE` | `hey dory` | The phrase that wakes it up. |
| `IRIS_WAKE_NAME_ONLY` | `1` | Also wake on the bare name anywhere in a sentence. |
| `IRIS_TTS_VOICE` | `nova` | The speaking voice (alloy, ash, coral, echo, fable, nova, onyx, sage, shimmer). |
| `IRIS_TTS_SPEED` | `1.15` | How fast it talks (1.0 is normal, up to 4.0). |
| `IRIS_UI_MODE` | `buddy` | `buddy` follows your cursor; `notch` anchors to the camera notch. |
| `IRIS_MONTHLY_BUDGET` | `20` | Your monthly API dollar limit. Set `0` for no limit. |
| `IRIS_MEMORY` | `true` | Whether Dory remembers things you teach it. |
| `IRIS_POINTER` | `true` | The on-screen pointing arrow. |
| `IRIS_SKILLS` | `true` | The skills system (`~/.iris/skills/`). |
| `IRIS_LOCAL_LLM` | `true` | Answer simple questions with a free local model first. |
| `IRIS_LOCAL_MODEL` | `llama3.2` | Which Ollama model to use locally (falls back to whatever you have pulled). |
| `IRIS_OLLAMA_URL` | `http://localhost:11434` | Where Ollama is running. |

There are more options (push-to-talk key, agent model, and so on). The full list lives in `IRIS/Config/Settings.swift`. Common ones (keys, model, budget, wake phrase, voice) are also editable in the Settings window from the menu bar. Your keys and settings stay on your machine and are never uploaded.

### About the monthly budget

Dory meters every paid call (the speaking voice, and API answers when you use a key) against your monthly limit:

1. While you have budget, it uses the natural voice and the best answering path.
2. As you get close to the limit, it leans harder on the free paths (local model, then your Claude subscription).
3. If you hit the limit, it switches to the free built-in voice too, so spending stops entirely.

This resets at the start of each month. Raise `IRIS_MONTHLY_BUDGET` (or set it to `0`) any time. If you only use the Claude subscription and no OpenAI key, there is nothing to meter at all.

---

## If something goes wrong

| Problem | Fix |
| --- | --- |
| Build fails about signing | Set your own Team in Xcode under Signing & Capabilities, then build again. See Step 4. |
| "claude not found" | Install it with `npm install -g @anthropic-ai/claude-code`, then run `claude` once to log in. |
| Mic looks on but Dory never hears you | Run `tccutil reset Microphone com.iris.app` in Terminal, reopen Dory, and allow the mic prompt again. |
| It doesn't hear "Hey Dory" reliably | Speak the name clearly ("DOOR-ee"), or just hold Option+Space and talk. Common mishearings like "dori"/"dora" are accepted automatically. You can also set your own `IRIS_WAKE_PHRASE`. |
| Option+Space does nothing | Turn on Dory under System Settings, Privacy & Security, Accessibility (the setup window has a button for it). |
| Screen vision says it cannot see | Turn on Dory in System Settings, Privacy & Security, Screen Recording, then quit and reopen it. |
| The voice sounds robotic | The natural voice needs an `OPENAI_API_KEY`. Without it, Dory uses the basic built-in voice. |
| It says the budget is reached | You hit your `IRIS_MONTHLY_BUDGET`. Raise it or set it to `0` in your `.env` file. |
| A background task went wrong | Each session writes a log to `~/.iris/logs/`, and past sessions are listed in `~/.iris/sessions.json`. |
| Want to see what it is doing | Dory writes a log to `~/.iris/iris.log`. View it with `tail -f ~/.iris/iris.log`. |

---

## For developers

This project is open source under the [MIT license](LICENSE). You are free to clone it, change it, and share it.

There are two kinds of users:

- **Developers** build it from source with Xcode and `xcodegen`, as described above.
- **Everyone else** is better off with a ready-made `Dory.app` they can just double click. They do not need Xcode, because macOS already includes what the app needs to run.

To share a build that other people can run without any tools, the maintainer signs the app with a Developer ID certificate, gets it notarized by Apple, and uploads it to GitHub Releases. Notarization (which needs a paid Apple Developer account) is what lets others open it without a security warning. The source code stays public, while official downloads are signed by the maintainer. Note that even a downloaded copy still needs a Claude login for the brain and an OpenAI key for the live voice.

### Project layout

- `IRIS/` holds the Swift source code (core, config, UI, voice, vision, actions, AI).
- `IRIS/Core/CompanionManager.swift` is the central state machine that runs the whole pipeline.
- `IRIS/AI/ClaudeEngine.swift` answers questions (local model first, then streaming Claude with prompt caching and web search).
- `IRIS/AI/ClaudeSessionManager.swift` runs background tasks as resumable Claude Code sessions.
- `IRIS/Core/Persona.swift` is where the Dory identity lives (name, triggers, system prompts).
- `project.yml` is the spec that generates `IRIS.xcodeproj` (the product is `Dory.app`).
- `plan.md` is the original build plan and architecture.
- `docs/algorithms.md` lists the exact formulas and tuned numbers.
- `CLAUDE.md` is guidance for working in this repo with Claude Code.

---

## License

[MIT](LICENSE)
