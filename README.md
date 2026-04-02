<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Claude Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
    <br />
    <br />
    <a href="https://github.com/farouqaldori/claude-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/farouqaldori/claude-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/farouqaldori/claude-island/total?style=rounded&color=white&labelColor=000000">
    </a>
    <a href="https://opensource.org/licenses/Apache-2.0" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/License-Apache_2.0-blue?style=rounded&color=white&labelColor=000000" alt="License" />
    </a>
  </p>
</div>

## Features

- **Dynamic Island UI** — Animated overlay that expands from the MacBook notch with smooth transitions
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch without switching to terminal
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Hooks install automatically on first launch
- **Remote SSH Support** — Monitor Claude sessions running on remote servers via SSH tunneling
- **OpenCode Support** — Works with OpenCode CLI alongside Claude Code
- **Multi-Screen Support** — Detects and works with multiple monitors, including physical notch detection
- **Auto-Update** — Built-in update mechanism via Sparkle
- **Notification Sounds** — Customizable sounds when Claude finishes processing
- **Smart Terminal Detection** — Only shows notch when terminal is not visible

## Requirements

- macOS 15.6+
- Claude Code CLI
- MacBook with notch (for notch-based UI) or any Mac (fallback mode)

## Install

### Download

Download the latest release from the [Releases](https://github.com/farouqaldori/claude-island/releases/latest) page.

### Build from Source

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

The app will be built to `build/Release/Claude Island.app`.

## How It Works

Claude Island monitors your Claude Code sessions by:

1. **Hook Installation** — On first launch, installs a Python hook to `~/.claude/hooks/` and registers it in Claude Code's `settings.json`

2. **Socket Communication** — The hook sends session events to the app via a Unix socket (`/tmp/claude-island.sock`)

3. **Real-time Updates** — Events like `SessionStart`, `PreToolUse`, `PermissionRequest`, and `Stop` are processed and displayed in the notch UI

4. **Permission Control** — When a tool needs approval, the notch expands with approve/deny buttons. The decision is sent back to Claude Code instantly.

### Hook Events

| Event | Description |
|-------|-------------|
| `UserPromptSubmit` | User sent a message |
| `PreToolUse` | Tool about to execute |
| `PostToolUse` | Tool completed |
| `PermissionRequest` | Tool needs approval |
| `Stop` | Claude finished processing |
| `SessionStart/End` | Session lifecycle |
| `PreCompact` | Context compaction |

## OpenCode Support

Claude Island also monitors OpenCode sessions.

On first launch, the app installs an OpenCode plugin at `~/.config/opencode/plugins/claude-island.js` and adds it to `~/.config/opencode/opencode.json`.

The plugin forwards OpenCode events to the same Unix socket, enabling live session status and permission approvals from the notch.

## Remote SSH Support

You can monitor Claude sessions running on remote servers:

1. Open settings and add a remote host (SSH config supported)
2. The app sets up SSH tunneling to forward the Unix socket
3. Remote sessions appear alongside local ones in the notch UI

Configuration is stored in the app's settings and supports auto-connect on launch.

## Settings

Access settings by clicking the notch to expand it, then click the gear icon.

| Setting | Description |
|---------|-------------|
| **Screen** | Choose which monitor shows the notch |
| **Notification Sound** | Pick from 14 system sounds (or none) |
| **Remote Hosts** | Configure SSH connections to remote servers |

## Analytics

Claude Island uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new Claude Code session is detected

No personal data or conversation content is collected. Analytics can be disabled by building from source with Mixpanel removed.

## Architecture

```
ClaudeIsland/
├── App/              # App entry point, window management
├── Core/             # Notch geometry, settings, screen selection
├── Events/           # Event monitoring
├── Models/           # Data models (SessionState, ChatMessage, etc.)
├── Services/
│   ├── Hooks/        # Hook installation, socket server
│   ├── Session/      # Session monitoring, file watching
│   ├── State/        # Session state management (actor)
│   ├── Remote/       # SSH tunneling, remote host management
│   ├── OpenCode/     # OpenCode plugin installer
│   ├── Tmux/         # Tmux integration for tool approval
│   └── Window/       # Window focus, yabai integration
├── UI/               # SwiftUI views, components
└── Utilities/        # Terminal detection, tool formatting
```

### Key Components

- **SessionStore** — Swift actor that manages all session state
- **HookSocketServer** — Listens for hook events on Unix socket
- **NotchViewModel** — Controls notch open/close animations
- **ClaudeSessionMonitor** — MainActor wrapper for SwiftUI bindings

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Acknowledgments

- [Sparkle](https://sparkle-project.org/) — Auto-update framework
- [swift-markdown](https://github.com/swiftlang/swift-markdown) — Markdown rendering
- [Mixpanel](https://mixpanel.com/) — Analytics

## License

Apache 2.0 — See [LICENSE](LICENSE.md) for details.
