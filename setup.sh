#!/usr/bin/env bash
#
# IRIS setup — bootstraps a clean checkout for building and running.
#
# What it does:
#   1. Verifies this is macOS 13 (Ventura) or newer.
#   2. Ensures the build/runtime tools exist: Xcode CLT, xcodegen, node, claude CLI.
#   3. Copies .env.example -> .env on first run (never overwrites an existing .env).
#   4. Prints the next steps (generate project, build, grant permissions).
#
# Safe to re-run: every step is idempotent and only installs what's missing.
# Usage:  ./setup.sh

set -euo pipefail

# --- pretty output ---------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=''; GREEN=''; YELLOW=''; RED=''; BLUE=''; RESET=''
fi
info()  { printf '%s==>%s %s\n' "$BLUE"   "$RESET" "$*"; }
ok()    { printf '%s ✓ %s%s %s\n' "$GREEN" "$RESET" "" "$*"; }
warn()  { printf '%s ! %s%s %s\n' "$YELLOW" "$RESET" "" "$*"; }
fail()  { printf '%s ✗ %s%s %s\n' "$RED"   "$RESET" "" "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

printf '%s\n' "${BOLD}IRIS setup${RESET}"

# --- 1. macOS version ------------------------------------------------------
info "Checking macOS version…"
if [ "$(uname -s)" != "Darwin" ]; then
  fail "IRIS is a macOS app; this host is $(uname -s)."
fi
os_ver="$(sw_vers -productVersion)"
os_major="${os_ver%%.*}"
if [ "$os_major" -lt 13 ]; then
  fail "macOS 13 (Ventura) or newer required; found $os_ver."
fi
ok "macOS $os_ver"

# --- 2. tooling ------------------------------------------------------------
# Xcode command-line tools (provide xcodebuild, swift, git).
info "Checking Xcode command-line tools…"
if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode tools at $(xcode-select -p)"
else
  warn "Xcode command-line tools not found — launching the installer."
  warn "Re-run ./setup.sh after the GUI installer finishes."
  xcode-select --install || true
  exit 1
fi

# Homebrew is how we install xcodegen (and, if needed, node).
have_brew=0
if command -v brew >/dev/null 2>&1; then
  have_brew=1
  ok "Homebrew $(brew --version | head -n1 | awk '{print $2}')"
else
  warn "Homebrew not found. Install it from https://brew.sh to auto-install xcodegen/node."
fi

# xcodegen — generates IRIS.xcodeproj from project.yml.
info "Checking xcodegen…"
if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen $(xcodegen --version 2>/dev/null | awk '{print $2}')"
elif [ "$have_brew" -eq 1 ]; then
  info "Installing xcodegen via Homebrew…"
  brew install xcodegen && ok "xcodegen installed"
else
  fail "xcodegen missing and Homebrew unavailable. Install Homebrew, then: brew install xcodegen"
fi

# node — required by the claude CLI / API fallback tooling.
info "Checking node…"
if command -v node >/dev/null 2>&1; then
  ok "node $(node --version)"
elif [ "$have_brew" -eq 1 ]; then
  info "Installing node via Homebrew…"
  brew install node && ok "node installed"
else
  warn "node not found and Homebrew unavailable. Install node from https://nodejs.org for full AI support."
fi

# claude CLI — the default (subscription) AI path. Not on the GUI PATH by
# design; the app resolves it at runtime, but it must be installed.
info "Checking claude CLI…"
claude_bin=""
for p in "$(command -v claude 2>/dev/null || true)" \
         "$HOME/.local/bin/claude" \
         "/opt/homebrew/bin/claude" \
         "/usr/local/bin/claude"; do
  if [ -n "$p" ] && [ -x "$p" ]; then claude_bin="$p"; break; fi
done
if [ -n "$claude_bin" ]; then
  ok "claude at $claude_bin"
else
  warn "claude CLI not found."
  if command -v npm >/dev/null 2>&1; then
    info "Installing Claude Code via npm…"
    if npm install -g @anthropic-ai/claude-code; then
      ok "claude installed"
    else
      warn "npm install failed. Install manually: npm install -g @anthropic-ai/claude-code"
      warn "Or set ANTHROPIC_API_KEY in .env to use the API path instead."
    fi
  else
    warn "npm unavailable; cannot auto-install claude."
    warn "Either install Claude Code (npm install -g @anthropic-ai/claude-code)"
    warn "or set ANTHROPIC_API_KEY in .env to use the API path instead."
  fi
fi

# --- 3. .env ---------------------------------------------------------------
info "Setting up .env…"
if [ -f .env ]; then
  ok ".env already exists — leaving it untouched"
elif [ -f .env.example ]; then
  cp .env.example .env
  ok "Created .env from .env.example — edit it to add ANTHROPIC_API_KEY (optional)"
else
  warn ".env.example missing; skipping .env creation"
fi

# --- 4. next steps ---------------------------------------------------------
printf '\n%sSetup complete.%s Next steps:\n' "$BOLD" "$RESET"
cat <<'EOF'
  1. (optional) Edit .env — add ANTHROPIC_API_KEY for true screen vision.
  2. Generate the Xcode project:   xcodegen generate
  3. Build & run via XcodeBuildMCP (never `xcodebuild` directly — see CLAUDE.md).
  4. On first launch, grant Microphone + Speech Recognition when prompted.
     Screen Recording must be enabled manually:
       System Settings → Privacy & Security → Screen Recording → enable IRIS, then relaunch.
EOF
