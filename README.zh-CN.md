<img src="docs/images/app-icon.png" alt="Codex Speed Lite 图标" width="72">

# Codex Speed Lite

[English](README.md) | **简体中文**

一个轻量的 macOS 菜单栏应用，用于查看 Codex 的请求吞吐率、响应延迟和运行状态。技术信息收在 **Details（详细信息）** 中。

## 界面预览

<img src="docs/images/menu-bar.png" alt="菜单栏速度指示器" width="120">

<img src="docs/images/menu-zh-CN.png" alt="Codex Speed 中文菜单，显示请求吞吐率、响应延迟和运行状态" width="310">

*截图使用演示数据，不包含私人使用记录。截图中的标签为旧版；当前菜单明确显示“近期均速”、“上次输出延迟”和“上次完成”。*

## 环境要求

- Apple Silicon Mac，macOS 14 或更新版本
- Python 3.11 或更新版本
- Xcode 命令行工具（`xcode-select --install`）
- 已通过 ChatGPT 账号登录 Codex

## 安装

请将项目放在以下位置，应用需要通过这个路径找到辅助程序：

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

如果已有菜单栏应用在运行，请先退出，再替换应用文件。

## 切换应用语言

选择 **Details（详细信息）→ Language / 语言 → 简体中文**。也可选择 **English** 或 **跟随系统**。切换立即生效并自动记住，无需重启监测器，也不会改变系统语言。

## 开始监测

在项目目录中运行：

```sh
.venv/bin/python control.py enable
```

等待当前任务完成后，选择 **详细信息 → 重新连接 Codex 桌面应用…** 并确认。这会启用监测，并完全退出、重新打开实际的桌面应用（部分 Mac 上显示为 **ChatGPT**）。正在进行的任务会被中断，但程序不会强制退出应用。

仅重启 `codex app-server daemon` **不会**更新桌面应用独立后台的连接设置。重新连接后，正常发送一条 Codex 消息即可获得新测量。没有请求时，菜单会显示等待状态，不再把昨天的响应延迟当作当前数据。

## 停止监测

选择 **Details → Restore Direct Connection…（恢复直接连接）**，待当前工作结束后完全退出、重新打开 Codex 桌面应用。此时不要选择“重新连接”，因为它会再次启用监测。

退出菜单栏应用只会关闭显示界面；本地转发服务仍会运行，避免中断正在进行的请求。

## 速度如何计算

统计所有被监测对话中，最近一分钟内完成的请求：

**输出 token 总数 ÷ 请求耗时总和**

**近期均速**是历史请求吞吐率，因此状态为**空闲**时仍可能显示，直到统计窗口过期。**上次输出延迟**表示上一个已完成请求首次出现可观察文本、推理摘要或工具输入的等待时间，并非请求总耗时，也不一定是模型生成首个 token 的时间。**上次完成**表示该样本完成至今的时间。

其中包含推理以及 API／网络等待时间，但不包含本地工具执行时间。它**不是纯粹的模型 token 生成速度**。失败或缺少数据的样本会被跳过，不会估算补齐。

## 隐私

辅助程序在本机运行，将请求转发到原有的 ChatGPT 服务。它只保留测量元数据，不保存提示词、生成文本或登录凭据。可通过 **Details → Open History…（打开历史记录）** 查看本地记录；这些记录不会上传到 GitHub。程序不会额外发起 AI 请求。Cookie 会按客户端提供的内容转发，但不会保存在转发服务的共享 Cookie 存储中。

## 测试

```sh
.venv/bin/python -m unittest discover -v
zsh build.sh
```
