<img src="docs/images/app-icon.png" alt="Codex Speed Lite icon" width="72">

# Codex Speed Lite

**English** | [简体中文](README.zh-CN.md)

A small macOS menu-bar app that shows Codex request throughput, response delay, and activity. Technical details are tucked into **Details**.

## Preview

<img src="docs/images/menu-bar.png" alt="Menu-bar speed indicator" width="120">

<img src="docs/images/menu.png" alt="Codex Speed menu showing throughput, response delay, and activity" width="310">

*Demo values—not private usage data. Speed is request throughput, not pure generation speed.*

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

Finish any running tasks, then restart Codex’s background service. Closing its window may not stop that service. Send a normal message to get your first measurement.

## Stop monitoring

Choose **Details → Restore Direct Connection…**, then restart Codex when your work is finished.

Quitting the menu-bar app only hides the display; the relay stays running so current requests are not interrupted.

## What the speed means

The number is **total output tokens ÷ total request time** for requests completed in the last minute, across all observed chats.

It includes reasoning and API/network waiting, but excludes local tool execution. It is **not pure token-generation speed**. Missing or failed samples are skipped, not guessed.

## Privacy

The helper runs locally and forwards requests to the same ChatGPT service. It keeps numerical measurements—not prompts, generated text, or credentials. Local history is available through **Details → Open History…** and is not uploaded to GitHub. It makes no extra AI requests.

## Tests

```sh
.venv/bin/python -m unittest discover -v
zsh build.sh
```
