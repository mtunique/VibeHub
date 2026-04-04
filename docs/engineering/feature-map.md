# Feature Map

Use this file to jump directly to likely edit points before doing broad codebase exploration.

## Session Lifecycle and State

Start here when the issue is about phases, active sessions, pending sessions, or event-to-state transitions.

- `VibeHub/Models/SessionEvent.swift`
- `VibeHub/Models/SessionPhase.swift`
- `VibeHub/Models/SessionState.swift`
- `VibeHub/Services/State/SessionStore.swift`
- `VibeHub/Services/State/ToolEventProcessor.swift`
- `VibeHub/Services/Session/ClaudeSessionMonitor.swift`

## Hook and CLI Event Intake

Start here when the app is not receiving events, installation is broken, or a local CLI integration changed.

- `VibeHub/Services/Hooks/HookInstaller.swift`
- `VibeHub/Services/Hooks/HookSocketServer.swift`
- `VibeHub/Services/Hooks/HookSocketRouter.swift`
- `VibeHub/Resources/`

## OpenCode-Specific Behavior

Start here when a behavior differs between Claude Code and OpenCode.

- `VibeHub/Services/OpenCode/OpenCodePluginInstaller.swift`
- `VibeHub/Services/Hooks/HookInstaller.swift`
- `VibeHub/Services/Hooks/HookSocketServer.swift`

## Subagents, Chat History, and JSONL Watching

Start here when subagent updates, conversation sync, or interrupt detection looks wrong.

- `VibeHub/Services/Session/AgentFileWatcher.swift`
- `VibeHub/Services/Session/ConversationParser.swift`
- `VibeHub/Services/Session/JSONLInterruptWatcher.swift`
- `VibeHub/Services/Chat/ChatHistoryManager.swift`
- `VibeHub/Models/ChatMessage.swift`

## Notch Open and Close Behavior

Start here when the notch appears at the wrong time, stays open too long, or shows the wrong high-level mode.

- `VibeHub/Core/NotchViewModel.swift`
- `VibeHub/Core/NotchActivityCoordinator.swift`
- `VibeHub/Core/Settings.swift`
- `VibeHub/Utilities/SessionPhaseHelpers.swift`
- `VibeHub/Utilities/TerminalVisibilityDetector.swift`

## Notch Layout, Geometry, and Windowing

Start here when the notch is in the wrong place, wrong size, wrong screen, or has window-level issues.

- `VibeHub/Core/NotchGeometry.swift`
- `VibeHub/Core/ScreenSelector.swift`
- `VibeHub/App/WindowManager.swift`
- `VibeHub/UI/Window/NotchWindow.swift`
- `VibeHub/UI/Window/NotchWindowController.swift`
- `VibeHub/App/ScreenObserver.swift`

## Expanded UI, Session List, and Chat Rendering

Start here when content rendering is wrong but the session state itself seems correct.

- `VibeHub/UI/Views/NotchView.swift`
- `VibeHub/UI/Views/ClaudeInstancesView.swift`
- `VibeHub/UI/Views/ChatView.swift`
- `VibeHub/UI/Views/ToolResultViews.swift`
- `VibeHub/UI/Components/MarkdownRenderer.swift`
- `VibeHub/UI/Components/StatusIcons.swift`

## Permission Approval Flow

Start here when approve or deny controls, request banners, or tmux handoff break.

- `VibeHub/Services/Hooks/HookSocketServer.swift`
- `VibeHub/Services/State/SessionStore.swift`
- `VibeHub/Services/Tmux/ToolApprovalHandler.swift`
- `VibeHub/Services/Tmux/TmuxController.swift`
- `VibeHub/UI/Views/AskUserQuestionBar.swift`
- `VibeHub/UI/Views/NotchView.swift`

## Remote SSH Monitoring

Start here when remote hosts, SSH tunnel setup, or remote event forwarding break.

- `VibeHub/Services/Remote/RemoteManager.swift`
- `VibeHub/Services/Remote/RemoteInstaller.swift`
- `VibeHub/Services/Remote/SSHForwarder.swift`
- `VibeHub/Services/Remote/SSHConfigParser.swift`
- `VibeHub/Services/Remote/RemoteActions.swift`
- `VibeHub/UI/Views/RemoteHostsView.swift`

## Terminal and Focus Awareness

Start here when the app should or should not surface itself based on terminal visibility or focus.

- `VibeHub/Utilities/TerminalVisibilityDetector.swift`
- `VibeHub/Services/Window/WindowFinder.swift`
- `VibeHub/Services/Window/WindowFocuser.swift`
- `VibeHub/Services/Window/YabaiController.swift`
- `VibeHub/Services/Shared/TerminalAppRegistry.swift`

## Sound, Settings, and Preferences

Start here when the issue is about persisted settings, sound playback choice, or screen preference.

- `VibeHub/Core/Settings.swift`
- `VibeHub/Core/SoundSelector.swift`
- `VibeHub/UI/Components/SoundPickerRow.swift`
- `VibeHub/UI/Components/ScreenPickerRow.swift`
- `VibeHub/UI/Views/NotchMenuView.swift`

## App Startup, Onboarding, and Menu Bar

Start here when launch-time behavior, onboarding, or menu bar affordances are wrong.

- `VibeHub/App/VibeHubApp.swift`
- `VibeHub/App/AppDelegate.swift`
- `VibeHub/UI/Views/OnboardingView.swift`
- `VibeHub/UI/Window/MenuBarController.swift`
- `VibeHub/UI/Views/MenuBarContentView.swift`

## Updates and Release Plumbing

Start here when update prompts or release feed behavior changes.

- `VibeHub/Services/Update/NotchUserDriver.swift`
- `docs/appcast.xml`

## Quick Triage Rule

- Wrong data: inspect `Models/` and `Services/State/` first.
- Wrong timing: inspect `Core/` and terminal visibility logic first.
- Wrong rendering: inspect `UI/Views/` and `UI/Components/` first.
- Wrong integration behavior: inspect `Services/Hooks/`, `Services/OpenCode/`, or `Services/Remote/` first.
