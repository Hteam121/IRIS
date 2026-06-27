# IRIS

**IRIS (Intelligent Realtime Intelligence System) is your own voice assistant for the Mac, like Jarvis from Iron Man.**

A small floating dot sits near your mouse. You say "Hey IRIS", then talk to it normally. It answers out loud, can look at your screen, open apps, run web searches, and remember things you tell it.

This guide takes you from zero to a working copy of IRIS on your own Mac. No deep coding knowledge needed. Just follow the steps in order.

---

## What it can do

- 🎙️ **Talk to it** out loud. Say "Hey IRIS" and have a normal back-and-forth conversation.
- 👁️ **It can see your screen.** Ask "What's on my screen?" or "Summarize this page."
- 🧠 **It thinks using Claude** (your Claude subscription), so the answers are smart and up to date.
- 🖱️ **It controls your Mac.** Open apps, folders, terminals, run web searches, even type and click for you.
- 🤖 **It runs tasks in the background** while you keep talking (for example, "find the 3 best deals on headphones").
- 💾 **It remembers things.** Tell it "remember I prefer Chrome" once and it keeps that forever.
- 💸 **It watches your spending.** You set a monthly dollar limit and IRIS stays under it automatically.
- 🪟 **It stays out of the way.** No dock icon, just a tiny eye in your menu bar.

---

## Before you start

You will need a few things. Don't worry, the setup script installs most of them for you.

**On your Mac:**

- macOS 13 or newer (macOS 14 or newer is best, because screen vision needs it).
- Xcode 15 or newer, free from the Mac App Store. This is what builds the app.
- An Apple ID. The free one is fine. It is used to "sign" the app so your Mac trusts it.

**Two AI services power IRIS:**

1. **Claude (the brain).** This is basically required. IRIS thinks using the `claude` command line tool, which runs on your Claude Pro or Max **subscription**. That means no extra per-message charges, and it always uses the newest Claude models. You log in once.
2. **An OpenAI key (the voice).** Strongly recommended. This powers the live "Hey IRIS" voice, the natural speaking voice, and screen vision. Without it, IRIS still works but uses a more basic, robotic built-in voice.

> Short version: log in to Claude for the brain, and add an OpenAI key for the good voice.

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
OPENAI_API_KEY=sk-...        # for the live voice and screen vision (recommended)
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

In Xcode, press the **Run** button (or `Cmd + R`). IRIS starts as a menu bar app. Look for the small **eye icon** in the top menu bar. There is no dock icon. The first time it runs, it asks for some permissions, covered in the next section.

### Step 6 (optional): Use it like a normal app

If you do not want to open Xcode every time, build a finished copy and put it in your Applications folder:

```bash
./scripts/install-app.sh
```

This builds IRIS, installs it to `/Applications`, and opens it. After that you can launch it from Spotlight or Finder like any other app. To start it automatically when your Mac boots, add it under **System Settings, General, Login Items**.

### Step 7 (optional): Background task helper

If you want IRIS to run longer research tasks in the background, set up the small Python helper:

```bash
cd sidecar
./setup.sh
```

Then tell IRIS where it lives by adding this to `~/.iris/config.json`:

```json
{ "sidecarPython": "/Users/you/Desktop/IRIS/sidecar/.venv/bin/python" }
```

IRIS starts and manages this helper on its own. See [`sidecar/README.md`](sidecar/README.md) for Google Calendar setup.

---

## Permissions you need to grant

The first time IRIS runs, macOS asks for permission to do certain things. IRIS cannot work without them.

| Permission | What it is for | How to allow it |
| --- | --- | --- |
| **Microphone** | Hearing "Hey IRIS" and your requests. | Click Allow when asked. |
| **Speech Recognition** | Understanding what you say. | Click Allow when asked. |
| **Screen Recording** | Looking at your screen. | This one is not a popup. Go to **System Settings, Privacy & Security, Screen Recording**, turn on IRIS, then quit and reopen IRIS. |
| **Accessibility** | Typing and clicking for you. | Go to **System Settings, Privacy & Security, Accessibility** and turn on IRIS. |
| **Automation** | Opening Terminal and Claude Code. | Click Allow the first time it opens Terminal. |

---

## How to talk to IRIS

Say the wake phrase "Hey IRIS", then your request. Some examples:

| You say | What IRIS does |
| --- | --- |
| "Hey IRIS, what time is it?" | Tells you out loud. |
| "Hey IRIS, what's on my screen?" | Looks at your screen and explains it. |
| "Hey IRIS, open Chrome" | Opens the app. |
| "Hey IRIS, open my Desktop" | Opens the folder in Finder. |
| "Hey IRIS, search the web for noise cancelling headphones" | Opens a browser search. |
| "Hey IRIS, find the top 3 deals on XM5 headphones" | Works on it in the background and reports back. |
| "Hey IRIS, remember I prefer Chrome for searches" | Saves that and uses it from now on. |
| "Hey IRIS, open a terminal and start Claude in my project" | Opens Terminal and a Claude Code session. |

The floating dot changes color to show what it is doing: gray means idle, blue means listening, purple means thinking, green means speaking.

---

## Settings you can change

You usually do not need to touch these. IRIS reads settings from two optional files: `.env` in the project folder and `~/.iris/config.json` in your home folder. Every setting is optional and has a sensible default.

The most useful ones:

| Setting (in `.env`) | Default | What it does |
| --- | --- | --- |
| `OPENAI_API_KEY` | none | Turns on the live voice, natural speech, and screen vision. |
| `ANTHROPIC_API_KEY` | none | Optional. Use the Anthropic API instead of your Claude subscription. |
| `IRIS_MODEL` | `claude-sonnet-4-6` | Which Claude model to think with. |
| `IRIS_WAKE_PHRASE` | `hey iris` | The phrase that wakes it up. |
| `IRIS_REALTIME_VOICE` | `marin` | The live voice (marin, cedar, alloy, ash, sage, verse, and more). |
| `IRIS_MONTHLY_BUDGET` | `20` | Your monthly OpenAI dollar limit. Set `0` for no limit. |
| `IRIS_MEMORY` | `true` | Whether IRIS remembers things you teach it. |

There are more options (voice speed, the background helper, and so on). The full list lives in `IRIS/Config/Settings.swift`. Your keys and settings stay on your machine and are never uploaded.

### About the monthly budget

IRIS keeps track of how much it spends on OpenAI each month and adjusts itself so it never goes over your limit:

1. While you have plenty of budget, it uses the best live voice.
2. As you get close to your limit, it switches to the free Claude path for replies.
3. If you hit the limit, it uses the free built-in voice only, so spending stops.

This resets at the start of each month. Raise `IRIS_MONTHLY_BUDGET` (or set it to `0`) any time.

---

## If something goes wrong

| Problem | Fix |
| --- | --- |
| Build fails about signing | Set your own Team in Xcode under Signing & Capabilities, then build again. See Step 4. |
| "claude not found" | Install it with `npm install -g @anthropic-ai/claude-code`, then run `claude` once to log in. |
| Mic looks on but IRIS never hears you | Run `tccutil reset Microphone com.iris.app` in Terminal, reopen IRIS, and allow the mic prompt again. |
| Screen vision says it cannot see | Turn on IRIS in System Settings, Privacy & Security, Screen Recording, then quit and reopen IRIS. |
| No live voice | The live voice needs an `OPENAI_API_KEY`. Without it, IRIS uses the basic built-in voice. |
| It says the budget is reached | You hit your `IRIS_MONTHLY_BUDGET`. Raise it or set it to `0` in your `.env` file. |
| Want to see what it is doing | IRIS writes a log to `~/.iris/iris.log`. View it with `tail -f ~/.iris/iris.log`. |

---

## For developers

IRIS is open source under the [MIT license](LICENSE). You are free to clone it, change it, and share it.

There are two kinds of users:

- **Developers** build it from source with Xcode and `xcodegen`, as described above.
- **Everyone else** is better off with a ready-made `IRIS.app` they can just double click. They do not need Xcode, because macOS already includes what the app needs to run.

To share a build that other people can run without any tools, the maintainer signs the app with a Developer ID certificate, gets it notarized by Apple, and uploads it to GitHub Releases. Notarization (which needs a paid Apple Developer account) is what lets others open it without a security warning. The source code stays public, while official downloads are signed by the maintainer. Note that even a downloaded copy still needs a Claude login for the brain and an OpenAI key for the live voice.

### Project layout

- `IRIS/` holds the Swift source code (core, config, UI, voice, vision, realtime, actions, AI).
- `sidecar/` is the Python background task service.
- `project.yml` is the spec that generates `IRIS.xcodeproj`.
- `plan.md` is the build plan and architecture.
- `docs/algorithms.md` lists the exact formulas and tuned numbers.
- `CLAUDE.md` is guidance for working in this repo with Claude Code.

---

## License

[MIT](LICENSE)
