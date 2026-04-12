//
//  CLIConfig.swift
//  VibeHub
//
//  Per-CLI install + event + history configuration. The single source
//  of truth `CLIConfig.all` is what `CLIInstaller` and `RemoteInstaller`
//  iterate to install hooks/plugins, and what `SessionStore` consults for
//  history-loading strategy.
//
//  Adding a new CLI = adding one entry in `CLIConfig.all` (plus whatever
//  is needed in `vibehub-state.py`'s source-routing table).
//

import Foundation

/// How the CLI expects us to register ourselves at install time.
enum InstallKind: Sendable {
    /// `~/<configDir>/hooks/vibehub-state.py` symlink + merge into
    /// `~/<configDir>/<settingsFile>` using the Claude-compatible hook schema
    /// (hooks → event → [{matcher, hooks}]).
    case claudeStyleHook
    /// Same symlink layout as Claude, but writes nested hook entries to
    /// `hooks.json` and flips a TOML feature toggle (Codex CLI).
    case codexStyleHook
    /// Copies a JS plugin to `<configDir>/plugins/vibehub.js` plus the
    /// sidecar `vibehub.socket` file (OpenCode).
    case opencodePlugin
}

/// Describes a single hook event registration row in the CLI's settings file.
/// Mirrors the Claude Code settings.json schema:
///   "hooks": {"<event>": [{"matcher": "...", "hooks": [{type,command,timeout?}]}]}
struct HookEventSpec: Sendable {
    let name: String
    /// `"*"` for a wildcard matcher, `nil` for the no-matcher variant.
    let matcher: String?
    /// If non-nil, the emitted hook entry carries a `timeout` field.
    /// `PermissionRequest` uses `86400` to keep the socket alive for user input.
    let timeoutSeconds: Int?
    /// If non-nil, this event uses the `PreCompact` multi-matcher form
    /// (e.g. `[auto, manual]`) and `matcher` is ignored.
    let preCompactMatchers: [String]?

    init(
        _ name: String,
        matcher: String? = nil,
        timeoutSeconds: Int? = nil,
        preCompactMatchers: [String]? = nil
    ) {
        self.name = name
        self.matcher = matcher
        self.timeoutSeconds = timeoutSeconds
        self.preCompactMatchers = preCompactMatchers
    }
}

extension Array where Element == HookEventSpec {
    /// The full 10-event Claude Code hook set. All Claude-compatible forks
    /// reuse this.
    static var claudeStandard10: [HookEventSpec] {
        [
            HookEventSpec("UserPromptSubmit"),
            HookEventSpec("PreToolUse", matcher: "*"),
            HookEventSpec("PostToolUse", matcher: "*"),
            HookEventSpec("PermissionRequest", matcher: "*", timeoutSeconds: 86400),
            HookEventSpec("Notification", matcher: "*"),
            HookEventSpec("Stop"),
            HookEventSpec("SubagentStop"),
            HookEventSpec("SessionStart"),
            HookEventSpec("SessionEnd"),
            HookEventSpec("PreCompact", preCompactMatchers: ["auto", "manual"]),
        ]
    }

    /// Codex CLI's abbreviated 5-event set.
    static var codexStandard5: [HookEventSpec] {
        [
            HookEventSpec("SessionStart", timeoutSeconds: 5),
            HookEventSpec("UserPromptSubmit", timeoutSeconds: 5),
            HookEventSpec("PreToolUse", timeoutSeconds: 5),
            HookEventSpec("PostToolUse", timeoutSeconds: 5),
            HookEventSpec("Stop", timeoutSeconds: 5),
        ]
    }
}

/// TOML feature toggle (Codex-only: `[features] codex_hooks = true`).
struct TOMLFeatureToggle: Sendable {
    let file: String       // relative to configDir, e.g. "config.toml"
    let section: String    // e.g. "features"
    let key: String        // e.g. "codex_hooks"
}

struct CLIConfig: Sendable {
    let source: SupportedCLI
    let installKind: InstallKind

    /// Home-relative directory where the CLI keeps its config
    /// (e.g. `.claude`, `.codex`, `.config/opencode`, `.qoder`).
    let configDirRelative: String
    /// `"hooks"` for Claude/Codex-style, `nil` for plugin-based CLIs.
    let hooksSubdirRelative: String?
    /// Settings file relative to `configDirRelative`.
    /// - Claude/forks: `settings.json`
    /// - Codex:        `hooks.json`
    /// - OpenCode:     nil (plugin is auto-discovered)
    let settingsFileRelative: String?
    /// If non-nil, after writing the settings file the installer flips a TOML feature toggle.
    let tomlFeatureToggle: TOMLFeatureToggle?

    /// Hook events to register in the settings file. Ignored for `.opencodePlugin`.
    let hookEvents: [HookEventSpec]

    let capability: CLICapability

    /// Home-relative directory where JSONL per-session history is stored
    /// (e.g. `.claude/projects`). Nil for non-jsonl history kinds.
    let jsonlProjectsDirRelative: String?

    /// Value passed as `VIBEHUB_SOURCE=<envSource>` in the hook command.
    /// Always matches `source.rawValue` so Python can parse it without a table.
    var envSource: String { source.rawValue }
}

// MARK: - Built-in table

extension CLIConfig {
    /// Look up a config by source. Returns `.claude` as a safety net so
    /// callers never have to handle `nil` (missing entries would be a build
    /// bug we'd catch in tests).
    static func forSource(_ source: SupportedCLI) -> CLIConfig {
        all.first(where: { $0.source == source }) ?? claude
    }

    /// All currently enabled CLIs. `CLIInstaller` only touches a CLI when
    /// its `configDirRelative` already exists on disk, so enabling an entry
    /// here is safe even when the user hasn't installed that CLI yet.
    static let all: [CLIConfig] = [
        .claude,
        .opencode,
        .codex,
        // Phase 1 — Claude forks. Installed on demand when their config
        // directory is present. Expected layouts:
        //   qoder      → ~/.qoder/{hooks,settings.json,projects/}
        //   droid      → ~/.factory/{hooks,settings.json,projects/}
        //   codebuddy  → ~/.codebuddy/{hooks,settings.json,projects/}
        .qoder,
        .droid,
        .codebuddy,
    ]

    // MARK: Claude Code

    static let claude = CLIConfig(
        source: .claude,
        installKind: .claudeStyleHook,
        configDirRelative: ".claude",
        hooksSubdirRelative: "hooks",
        settingsFileRelative: "settings.json",
        tomlFeatureToggle: nil,
        hookEvents: .claudeStandard10,
        capability: CLICapability(
            historyKind: .jsonl,
            canApprove: true,
            canSendInput: true,
            supportsRemoteInstall: true
        ),
        jsonlProjectsDirRelative: ".claude/projects"
    )

    // MARK: OpenCode

    static let opencode = CLIConfig(
        source: .opencode,
        installKind: .opencodePlugin,
        configDirRelative: ".config/opencode",
        hooksSubdirRelative: nil,
        settingsFileRelative: nil,
        tomlFeatureToggle: nil,
        hookEvents: [],
        capability: CLICapability(
            historyKind: .sqlite,
            canApprove: true,
            canSendInput: true,
            supportsRemoteInstall: true
        ),
        jsonlProjectsDirRelative: nil
    )

    // MARK: Codex

    static let codex = CLIConfig(
        source: .codex,
        installKind: .codexStyleHook,
        configDirRelative: ".codex",
        hooksSubdirRelative: "hooks",
        settingsFileRelative: "hooks.json",
        tomlFeatureToggle: TOMLFeatureToggle(
            file: "config.toml",
            section: "features",
            key: "codex_hooks"
        ),
        hookEvents: .codexStandard5,
        capability: CLICapability(
            historyKind: .codexRollout,
            canApprove: false,    // Codex CLI has no PermissionRequest hook yet
            canSendInput: true,
            supportsRemoteInstall: true
        ),
        jsonlProjectsDirRelative: nil
    )

    // MARK: Phase 1 — Claude forks (paths to verify before enabling)

    static let qoder = CLIConfig(
        source: .qoder,
        installKind: .claudeStyleHook,
        configDirRelative: ".qoder",
        hooksSubdirRelative: "hooks",
        settingsFileRelative: "settings.json",
        tomlFeatureToggle: nil,
        hookEvents: .claudeStandard10,
        capability: CLICapability(
            historyKind: .jsonl,
            canApprove: true,
            canSendInput: true,
            supportsRemoteInstall: true
        ),
        jsonlProjectsDirRelative: ".qoder/projects"
    )

    static let droid = CLIConfig(
        source: .droid,
        installKind: .claudeStyleHook,
        configDirRelative: ".factory",
        hooksSubdirRelative: "hooks",
        settingsFileRelative: "settings.json",
        tomlFeatureToggle: nil,
        hookEvents: .claudeStandard10,
        capability: CLICapability(
            historyKind: .jsonl,
            canApprove: true,
            canSendInput: true,
            supportsRemoteInstall: true
        ),
        jsonlProjectsDirRelative: ".factory/projects"
    )

    static let codebuddy = CLIConfig(
        source: .codebuddy,
        installKind: .claudeStyleHook,
        configDirRelative: ".codebuddy",
        hooksSubdirRelative: "hooks",
        settingsFileRelative: "settings.json",
        tomlFeatureToggle: nil,
        hookEvents: .claudeStandard10,
        capability: CLICapability(
            historyKind: .jsonl,
            canApprove: true,
            canSendInput: true,
            supportsRemoteInstall: true
        ),
        jsonlProjectsDirRelative: ".codebuddy/projects"
    )
}
