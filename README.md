<img src="docs/images/app-icon.png" alt="Codex Speed Lite icon" width="72">

# Codex Speed Lite

**English** | [简体中文](README.zh-CN.md)

A small macOS menu-bar app that shows Codex request throughput, response delay, and activity. Technical details are tucked into **Details**.

## Preview

<img src="docs/images/menu-bar.png" alt="Menu-bar speed indicator" width="120">

<img src="docs/images/menu.png" alt="Codex Speed menu showing throughput, response delay, and activity" width="310">

*Demo values—not private usage data. Preview images show the previous labels; the menu now explicitly says “Recent average”, “Last output delay”, and “Last completed”.*

## Requirements

- Apple Silicon Mac, macOS 14+
- Python 3.11+
- Xcode Command Line Tools (`xcode-select --install`)
- Codex signed in with your ChatGPT account

## Install

Keep the checkout at this location—the app uses it to find its helper:

```sh
git clone https://github.com/saslifat-gif/codex-speed-lite.git ~/.local/src/codex-speed-lite
cd ~/.local/src/codex-speed-lite
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
zsh build.sh
mkdir -p ~/Applications
ditto "build/Codex Speed Lite.app" "$HOME/Applications/Codex Speed Lite.app"
open "$HOME/Applications/Codex Speed Lite.app"
```

Close an existing menu-bar display before replacing it.

## App language

Choose **Details → Language / 语言 → English or 简体中文**. The default follows your system language. Changes apply immediately and are remembered; no monitor restart is needed.

## Start monitoring

From the checkout folder:

```sh
.venv/bin/python control.py enable
```

Finish any running tasks, then choose **Details → Reconnect Codex Desktop…** and confirm. This enables monitoring and fully quits/reopens the actual desktop app (named **ChatGPT** on some Macs). It interrupts active tasks; it never force-quits.

Restarting only `codex app-server daemon` does **not** reload the desktop app’s separate backend. Send a normal Codex message after reconnecting to get a fresh measurement. If no requests are measured, the menu waits rather than showing yesterday’s response delay.

## Stop monitoring

Choose **Details → Restore Direct Connection…**, then fully quit and reopen the Codex desktop app when your work is finished. Do not use Reconnect for this—it enables monitoring again.

Quitting the menu-bar app only hides the display; the relay stays running so current requests are not interrupted.

## What the speed means

The number is **total output tokens ÷ total request time** for requests completed in the last minute, across all observed chats.

**Recent average** is historical throughput, so it can remain visible while activity is **Idle** until the window expires. **Last output delay** is the last completed request’s time to its first observable text, reasoning-summary, or tool-input output—not total request time or necessarily the model’s first token. **Last completed** shows that sample’s age.

It includes reasoning and API/network waiting, but excludes local tool execution. It is **not pure token-generation speed**. Missing or failed samples are skipped, not guessed.

## Privacy

The helper runs locally and forwards requests to the same ChatGPT service. It keeps numerical measurements—not prompts, generated text, or credentials. Local history is available through **Details → Open History…** and is not uploaded to GitHub. It makes no extra AI requests. Cookies are forwarded as supplied but are never retained in a shared relay cookie jar.

## Tests

```sh
.venv/bin/python -m unittest discover -v
zsh build.sh
```
