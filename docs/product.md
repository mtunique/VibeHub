# Vibe Hub

Vibe Hub 是一款 macOS 菜单栏应用，为 Claude Code CLI 会话带来 Dynamic Island 风格的悬浮通知体验。

![Vibe Hub](VibeHub/Assets.xcassets/AppIcon.appiconset/icon_128x128.png)

## 功能特性

- **Dynamic Island UI** — 从 MacBook 刘海平滑展开的动画悬浮层
- **实时会话监控** — 实时追踪多个 Claude Code 会话
- **权限审批** — 直接在悬浮层审批或拒绝工具执行，无需切换到终端
- **对话历史** — 支持 Markdown 渲染的完整对话历史
- **自动安装** — 首次启动自动安装 Hook
- **远程 SSH 支持** — 通过 SSH 隧道监控远程服务器上的 Claude 会话
- **OpenCode 支持** — 与 OpenCode CLI 配合使用
- **多屏幕支持** — 支持多显示器，包括物理刘海检测
- **自动更新** — 通过 Sparkle 内置更新机制
- **通知声音** — Claude 处理完成时可自定义提示音
- **智能终端检测** — 仅在终端不可见时显示悬浮层

## 系统要求

- macOS 15.6+
- Claude Code CLI
- 带刘海的 MacBook（用于刘海 UI）或任意 Mac（回退模式）

## 下载安装

从 [GitHub Releases](https://github.com/mtunique/vibehub/releases/latest) 下载最新版本。

## 隐私政策

Vibe Hub 仅收集匿名的使用统计数据，不会收集任何个人数据或对话内容。查看完整[隐私政策](./privacy.md)。

## 开源协议

Apache 2.0 - 详见 [LICENSE](../LICENSE.md)
