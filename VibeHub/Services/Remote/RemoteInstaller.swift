import Foundation

enum RemoteInstaller {
    /// Install hooks/plugins for every CLI in `CLIConfig.all` that has
    /// `supportsRemoteInstall == true`. Each CLI is first probed for its
    /// config directory on the remote; missing CLIs are skipped with a
    /// clear "not installed on remote" step.
    static func installAll(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> RemoteInstallReport {
        let startedAt = Date()
        var steps: [RemoteInstallStep] = []

        // Upload shared script once, then each CLI just symlinks to it.
        let (sharedSteps, _) = await uploadSharedScript(host: host, progress: progress)
        steps.append(contentsOf: sharedSteps)

        // Track which CLIs we actually installed so verify can skip missing ones.
        var installed: [SupportedCLI] = []

        for config in CLIConfig.all where config.capability.supportsRemoteInstall {
            let (cliSteps, didInstall) = await installRemote(
                host: host, config: config, progress: progress
            )
            steps.append(contentsOf: cliSteps)
            if didInstall {
                installed.append(config.source)
            }
        }

        if let progress { await progress("verify files") }

        // Verify the tunnel is active by checking the remote Unix socket.
        let tunnelCheck = "test -S \(host.remoteSocketPath)"
        steps.append(await step(
            name: "verify tunnel",
            command: tunnelCheck,
            result: await runSSHResult(host: host, command: tunnelCheck, timeoutSeconds: 8)
        ))

        for config in CLIConfig.all where config.capability.supportsRemoteInstall && installed.contains(config.source) {
            let name: String
            let cmd: String
            switch config.installKind {
            case .claudeStyleHook, .codexStyleHook:
                let hooksSubdir = config.hooksSubdirRelative ?? "hooks"
                let path = "~/\(config.configDirRelative)/\(hooksSubdir)/vibehub-state.py"
                name = "verify \(config.source.rawValue) hook"
                cmd = "test -f \(path) && echo ok || echo missing"
            case .opencodePlugin:
                let path = "~/\(config.configDirRelative)/plugins/vibehub.js"
                name = "verify \(config.source.rawValue) plugin"
                cmd = "test -f \(path) && echo ok || echo missing"
            }
            steps.append(await step(
                name: name,
                command: cmd,
                result: await runSSHResult(host: host, command: cmd, timeoutSeconds: 12)
            ))
        }

        return RemoteInstallReport(startedAt: startedAt, finishedAt: Date(), steps: steps)
    }

    // MARK: - Per-config dispatch

    /// Returns (steps, didInstall). `didInstall` is true only when the CLI's
    /// config directory exists on the remote AND at least one install step
    /// was executed beyond the "check" step.
    static func installRemote(
        host: RemoteHost,
        config: CLIConfig,
        progress: (@Sendable (String) async -> Void)? = nil
    ) async -> (steps: [RemoteInstallStep], didInstall: Bool) {
        switch config.installKind {
        case .claudeStyleHook:
            return await installClaudeStyleRemote(host: host, config: config, progress: progress)
        case .codexStyleHook:
            return await installCodexStyleRemote(host: host, config: config, progress: progress)
        case .opencodePlugin:
            return await installOpenCodePluginRemote(host: host, config: config, progress: progress)
        }
    }

    // MARK: - Shared script upload

    /// Upload the shared script once to ~/.vibehub/vibehub-state.py on the remote.
    /// Returns the steps and whether the upload was skipped (already up to date).
    private static func uploadSharedScript(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> (steps: [RemoteInstallStep], skipped: Bool) {
        guard let script = Bundle.main.url(forResource: "vibehub-state", withExtension: "py") else {
            return ([], true)
        }

        var steps: [RemoteInstallStep] = []

        // Check if already up to date via the shared copy.
        let checkCmd = "python3 ~/.vibehub/vibehub-state.py --version"
        let checkResult = await runSSHResult(host: host, command: checkCmd, timeoutSeconds: 8)
        if checkResult.exitCode == 0 && checkResult.output.contains(CLIInstaller.sharedScriptVersion) {
            if let progress { await progress("shared hook up to date") }
            steps.append(RemoteInstallStep(
                name: "check shared hook version", command: checkCmd,
                ok: true, exitCode: 0,
                stdout: "Up to date (\(CLIInstaller.sharedScriptVersion))", stderr: ""
            ))
            return (steps, true)
        }

        // Write socket-path override so hooks connect to the SSH tunnel socket.
        steps.append(await step(
            name: "write socket-path override",
            command: "mkdir -p ~/.vibehub && echo ... > ~/.vibehub/socket-path",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.vibehub && printf '%s\\n' '\(host.remoteSocketPath)' > ~/.vibehub/socket-path", timeoutSeconds: 12)
        ))

        if let progress { await progress("upload shared hook") }
        steps.append(await step(
            name: "upload shared hook",
            command: "base64 -d > ~/.vibehub/vibehub-state.py",
            result: await uploadFileViaSSH(host: host, localURL: script, remotePath: "~/.vibehub/vibehub-state.py", timeoutSeconds: 20)
        ))
        steps.append(await step(
            name: "chmod shared hook",
            command: "chmod 755 ~/.vibehub/vibehub-state.py",
            result: await runSSHResult(host: host, command: "chmod 755 ~/.vibehub/vibehub-state.py", timeoutSeconds: 12)
        ))

        return (steps, false)
    }

    // MARK: - Claude-style remote install

    static func installClaudeStyleRemote(
        host: RemoteHost,
        config: CLIConfig,
        progress: (@Sendable (String) async -> Void)? = nil
    ) async -> (steps: [RemoteInstallStep], didInstall: Bool) {
        await installHookStyleRemote(
            host: host,
            config: config,
            defaultSettingsFile: "settings.json",
            progress: progress,
            snippetFn: pythonMergeClaudeStyleSnippet(config:hookScriptPath:settingsPathRelative:remoteSocketPath:)
        )
    }

    // MARK: - Codex-style remote install

    static func installCodexStyleRemote(
        host: RemoteHost,
        config: CLIConfig,
        progress: (@Sendable (String) async -> Void)? = nil
    ) async -> (steps: [RemoteInstallStep], didInstall: Bool) {
        await installHookStyleRemote(
            host: host,
            config: config,
            defaultSettingsFile: "hooks.json",
            progress: progress,
            snippetFn: pythonMergeCodexStyleSnippet(config:hookScriptPath:settingsPathRelative:remoteSocketPath:)
        )
    }

    /// Shared remote install flow for any CLI whose hook is a symlink +
    /// JSON/TOML settings file merged via a Python snippet. The only
    /// per-style differences are the default settings filename and the
    /// snippet generator — everything else (probe, mkdir, symlink, run
    /// snippet) is identical.
    private static func installHookStyleRemote(
        host: RemoteHost,
        config: CLIConfig,
        defaultSettingsFile: String,
        progress: (@Sendable (String) async -> Void)?,
        snippetFn: (_ config: CLIConfig, _ hookScriptPath: String, _ settingsPathRelative: String, _ remoteSocketPath: String) -> String
    ) async -> (steps: [RemoteInstallStep], didInstall: Bool) {
        var steps: [RemoteInstallStep] = []

        let probeCmd = "test -d ~/\(config.configDirRelative)"
        let checkResult = await runSSHResult(host: host, command: probeCmd, timeoutSeconds: 12)
        let found = checkResult.exitCode == 0
        steps.append(RemoteInstallStep(
            name: found ? "check \(config.source.rawValue)" : "\(config.source.rawValue) not installed on remote",
            command: probeCmd,
            ok: true, exitCode: 0,
            stdout: found ? "found" : "not found (skipped)", stderr: ""
        ))
        guard found else { return (steps, false) }

        let hooksSubdir = config.hooksSubdirRelative ?? "hooks"
        let hookScriptPath = "~/\(config.configDirRelative)/\(hooksSubdir)/vibehub-state.py"
        let settingsRel = config.settingsFileRelative ?? defaultSettingsFile
        let settingsPathRelative = "\(config.configDirRelative)/\(settingsRel)"

        let mkdirCmd = "mkdir -p ~/\(config.configDirRelative)/\(hooksSubdir)"
        steps.append(await step(
            name: "mkdir ~/\(config.configDirRelative)/\(hooksSubdir)",
            command: mkdirCmd,
            result: await runSSHResult(host: host, command: mkdirCmd, timeoutSeconds: 12)
        ))

        if let progress { await progress("symlink \(config.source.rawValue) hook") }
        let symlinkCmd = "ln -sf ~/.vibehub/vibehub-state.py \(hookScriptPath)"
        steps.append(await step(
            name: "symlink \(config.source.rawValue) hook",
            command: symlinkCmd,
            result: await runSSHResult(host: host, command: symlinkCmd, timeoutSeconds: 12)
        ))

        let py = snippetFn(config, hookScriptPath, settingsPathRelative, host.remoteSocketPath)
        steps.append(await step(
            name: "update ~/\(settingsPathRelative)",
            command: "python3 (merge hook settings via base64)",
            result: await runSSHPython(host: host, script: py)
        ))

        return (steps, true)
    }

    // MARK: - OpenCode plugin remote install

    static func installOpenCodePluginRemote(
        host: RemoteHost,
        config: CLIConfig,
        progress: (@Sendable (String) async -> Void)? = nil
    ) async -> (steps: [RemoteInstallStep], didInstall: Bool) {
        guard let plugin = Bundle.main.url(forResource: "vibehub-opencode", withExtension: "js") else {
            return ([], false)
        }

        var steps: [RemoteInstallStep] = []

        // Use exit code (not stdout parsing) to avoid false negatives from MOTD/banner noise.
        // Also check for the opencode binary as a fallback when no config file exists yet.
        let checkResult = await runSSHResult(
            host: host,
            command: "test -d ~/\(config.configDirRelative) || which opencode >/dev/null 2>&1",
            timeoutSeconds: 12
        )
        let found = checkResult.exitCode == 0
        steps.append(RemoteInstallStep(
            name: found ? "check opencode" : "opencode not installed on remote",
            command: "test -d ~/\(config.configDirRelative) || which opencode",
            ok: true,
            exitCode: 0,
            stdout: found ? "found" : "not found (skipped)",
            stderr: ""
        ))
        guard found else { return (steps, false) }

        let pluginPath = "~/\(config.configDirRelative)/plugins/vibehub.js"
        let checkVersionCommand = "grep 'VERSION = \"1.0.2\"' \(pluginPath)"
        let versionCheckResult = await runSSHResult(host: host, command: checkVersionCommand, timeoutSeconds: 8)
        if versionCheckResult.exitCode == 0 {
            if let progress { await progress("opencode plugin up to date") }
            steps.append(RemoteInstallStep(
                name: "check opencode plugin version",
                command: checkVersionCommand,
                ok: true,
                exitCode: 0,
                stdout: "Up to date (1.0.2)",
                stderr: ""
            ))
            return (steps, true)
        }

        steps.append(await step(
            name: "mkdir ~/\(config.configDirRelative)/plugins",
            command: "mkdir -p ~/\(config.configDirRelative)/plugins",
            result: await runSSHResult(
                host: host,
                command: "mkdir -p ~/\(config.configDirRelative)/plugins",
                timeoutSeconds: 12
            )
        ))
        if let progress { await progress("upload opencode plugin") }
        steps.append(await step(
            name: "upload opencode plugin",
            command: "base64 -d > \(pluginPath)",
            result: await uploadFileViaSSH(host: host, localURL: plugin, remotePath: pluginPath, timeoutSeconds: 20)
        ))

        return (steps, true)
    }

    // MARK: - Python snippet generators

    /// Build the Python snippet that merges Claude-style hook entries into
    /// a JSON settings file. Events/matchers/timeouts come from CLIConfig so
    /// every Claude-compatible fork reuses the same code path.
    private static func pythonMergeClaudeStyleSnippet(
        config: CLIConfig,
        hookScriptPath: String,
        settingsPathRelative: String,
        remoteSocketPath: String
    ) -> String {
        // Each event row is (name, bucket) where bucket is one of:
        //   "with_matcher"          -> [{"matcher": "*", "hooks": [cmd]}]
        //   "with_matcher_timeout"  -> [{"matcher": "*", "hooks": [cmd(timeout)]}]
        //   "without_matcher"       -> [{"hooks": [cmd]}]
        //   "precompact"            -> [{"matcher": "auto", ...}, {"matcher": "manual", ...}]
        var rows: [String] = []
        for evt in config.hookEvents {
            let bucket: String
            if evt.preCompactMatchers != nil {
                bucket = "precompact"
            } else if let _ = evt.timeoutSeconds, evt.matcher != nil {
                bucket = "with_matcher_timeout"
            } else if evt.matcher != nil {
                bucket = "with_matcher"
            } else {
                bucket = "without_matcher"
            }
            rows.append("    '\(evt.name)': \(bucket),")
        }
        let eventsDict = rows.joined(separator: "\n")

        return """
import json, os, pathlib, subprocess

home = pathlib.Path.home()
settings_path = home / '\(settingsPathRelative)'
settings_path.parent.mkdir(parents=True, exist_ok=True)

data = {}
if settings_path.exists():
    try:
        data = json.loads(settings_path.read_text())
    except Exception:
        data = {}

hooks = data.get('hooks', {})

def detect_python():
    for c in ['python3', 'python']:
        try:
            subprocess.check_call(['which', c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return c
        except Exception:
            pass
    return 'python3'

python = detect_python()
cmd = f'VIBEHUB_SOURCE=\(config.envSource) VIBEHUB_SOCKET_PATH="\(remoteSocketPath)" {python} \(hookScriptPath)'
hook_entry = [{"type": "command", "command": cmd}]
hook_entry_with_timeout = [{"type": "command", "command": cmd, "timeout": 86400}]

with_matcher = [{"matcher": "*", "hooks": hook_entry}]
with_matcher_timeout = [{"matcher": "*", "hooks": hook_entry_with_timeout}]
without_matcher = [{"hooks": hook_entry}]
precompact = [
    {"matcher": "auto", "hooks": hook_entry},
    {"matcher": "manual", "hooks": hook_entry},
]

events = {
\(eventsDict)
}

def has_our_hook(entry):
    for h in entry.get('hooks', []):
        c = h.get('command', '')
        if 'vibehub-state.py' in c:
            return True
    return False

for ev, config in events.items():
    existing = hooks.get(ev)
    if isinstance(existing, list):
        ok = False
        for e in existing:
            if isinstance(e, dict) and has_our_hook(e):
                ok = True
                break
        if not ok:
            existing.extend(config)
            hooks[ev] = existing
    else:
        hooks[ev] = config

data['hooks'] = hooks
settings_path.write_text(json.dumps(data, indent=2, sort_keys=True))
"""
    }

    /// Codex-style merger: flat hook entries in hooks.json + optional TOML toggle.
    private static func pythonMergeCodexStyleSnippet(
        config: CLIConfig,
        hookScriptPath: String,
        settingsPathRelative: String,
        remoteSocketPath: String
    ) -> String {
        let eventNames = config.hookEvents.map { "'\($0.name)'" }.joined(separator: ", ")
        let toggle = config.tomlFeatureToggle
        let tomlBlock: String
        if let toggle {
            tomlBlock = """

# Enable feature toggle in \(toggle.file)
config_path = home / '\(config.configDirRelative)/\(toggle.file)'
contents = config_path.read_text() if config_path.exists() else ''
import re
if not re.search(r'(?m)^\\s*\(toggle.key)\\s*=\\s*true', contents):
    if re.search(r'(?m)^\\s*\(toggle.key)\\s*=\\s*false', contents):
        contents = re.sub(r'(?m)^\\s*\(toggle.key)\\s*=\\s*false', '\(toggle.key) = true', contents)
    else:
        lines = contents.split('\\n')
        feat_idx = next((i for i, l in enumerate(lines) if l.strip() == '[\(toggle.section)]'), None)
        if feat_idx is not None:
            lines.insert(feat_idx + 1, '\(toggle.key) = true')
        else:
            if lines and lines[-1]:
                lines.append('')
            lines.append('[\(toggle.section)]')
            lines.append('\(toggle.key) = true')
        contents = '\\n'.join(lines)
    config_path.write_text(contents)
"""
        } else {
            tomlBlock = ""
        }

        return """
import json, os, pathlib, subprocess

home = pathlib.Path.home()

def detect_python():
    for c in ['python3', 'python']:
        try:
            subprocess.check_call(['which', c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return c
        except Exception:
            pass
    return 'python3'

python = detect_python()
cmd = f'VIBEHUB_SOURCE=\(config.envSource) VIBEHUB_SOCKET_PATH="\(remoteSocketPath)" {python} \(hookScriptPath)'

hooks_path = home / '\(settingsPathRelative)'
data = {}
if hooks_path.exists():
    try:
        data = json.loads(hooks_path.read_text())
    except Exception:
        data = {}

hooks = data.get('hooks', {})

def has_our_hook(entry):
    for h in entry.get('hooks', []):
        if 'vibehub-state.py' in h.get('command', ''):
            return True
    return False

for ev in [\(eventNames)]:
    entries = hooks.get(ev, [])
    if not isinstance(entries, list):
        entries = []
    entries = [e for e in entries if isinstance(e, dict) and not has_our_hook(e)]
    entries.append({'hooks': [{'type': 'command', 'command': cmd, 'timeout': 5}]})
    hooks[ev] = entries

data['hooks'] = hooks
hooks_path.write_text(json.dumps(data, indent=2, sort_keys=True))
\(tomlBlock)
print('ok')
"""
    }

    // MARK: - SSH plumbing

    private static func sshBaseArgs(host: RemoteHost) -> [String] {
        var args: [String] = []

        // Sandbox: SSH child processes cannot read ~/.ssh/{config,known_hosts}.
        // Use the container copies prepared by sandboxSSHDir().
        #if APP_STORE
        if let ssh = SSHForwarder.sandboxSSHDir() {
            args += ["-F", ssh.config]
            args += ["-o", "UserKnownHostsFile=\(ssh.knownHosts)"]
        }
        #endif

        args += [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
        ]

        #if !APP_STORE
        let controlPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
            .appendingPathComponent("ssh-%C")
            .path
        args += ["-o", "ControlPath=\(controlPath)"]
        #endif
        if host.useGSSAPI {
            args += ["-o", "PreferredAuthentications=gssapi-with-mic"]
        }

        if let port = host.port { args += ["-p", String(port)] }
        #if !APP_STORE
        if let key = host.identityFile, !key.isEmpty { args += ["-i", key] }
        #endif
        return args
    }

    static func runSSH(host: RemoteHost, command: String) async -> String? {
        let r = await runSSHResult(host: host, command: command, timeoutSeconds: 20)
        guard r.exitCode == 0 else { return nil }
        return r.output
    }

    static func runSSHResult(host: RemoteHost, command: String, timeoutSeconds: Int) async -> ProcessResult {
        let sshPath = "/usr/bin/ssh"
        var args = sshBaseArgs(host: host)
        args.append(host.sshTarget)
        args.append(command)

        let env = getSSHEnvironment()
        let res = await ProcessExecutor.shared.runWithResult(sshPath, arguments: args, timeoutSeconds: timeoutSeconds, environment: env)
        switch res {
        case .success(let r):
            return r
        case .failure(let e):
            return ProcessResult(output: "", exitCode: (e.exitCode ?? 1), stderr: e.rawStderr ?? e.errorDescription)
        }
    }

    // Upload a local file to the remote by piping base64-encoded content through SSH stdin.
    // This avoids SCP/SFTP and command-line length limits.
    private static func uploadFileViaSSH(host: RemoteHost, localURL: URL, remotePath: String, timeoutSeconds: Int) async -> ProcessResult {
        guard let data = try? Data(contentsOf: localURL) else {
            return ProcessResult(output: "", exitCode: 1, stderr: "failed to read local file: \(localURL.path)")
        }
        let encoded = data.base64EncodedString()

        var args = sshBaseArgs(host: host)
        args.append(host.sshTarget)
        args.append("base64 -d > \(remotePath)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.environment = getSSHEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        do {
            try p.run()
        } catch {
            return ProcessResult(output: "", exitCode: 1, stderr: "failed to start ssh: \(error.localizedDescription)")
        }

        // Write base64 data to stdin then close
        if let inputData = encoded.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(inputData)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Wait with timeout
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if p.isRunning {
            p.terminate()
            return ProcessResult(output: "", exitCode: 1, stderr: "upload timed out")
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(output: stdout, exitCode: p.terminationStatus, stderr: stderr.isEmpty ? nil : stderr)
    }


    static func getSSHEnvironment() -> [String: String] {
        var env = Foundation.ProcessInfo.processInfo.environment
        if let sock = ProcessExecutor.shared.runSyncOrNil("/bin/launchctl", arguments: ["getenv", "SSH_AUTH_SOCK"])?.trimmingCharacters(in: .whitespacesAndNewlines), !sock.isEmpty {
            env["SSH_AUTH_SOCK"] = sock
        }
        if let krb = ProcessExecutor.shared.runSyncOrNil("/bin/launchctl", arguments: ["getenv", "KRB5CCNAME"])?.trimmingCharacters(in: .whitespacesAndNewlines), !krb.isEmpty {
            env["KRB5CCNAME"] = krb
        }
        return env
    }

    private static func step(name: String, command: String, result: ProcessResult) async -> RemoteInstallStep {
        RemoteInstallStep(
            name: name,
            command: command,
            ok: result.exitCode == 0,
            exitCode: result.exitCode,
            stdout: trim(result.output),
            stderr: trim(result.stderr ?? "")
        )
    }

    /// Shell-quote a single value using POSIX single-quote wrapping. Safe
    /// for any content including spaces, double quotes, and special chars.
    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Run a Python script on the remote via SSH, encoding the script as base64 to avoid
    /// shell-specific syntax (e.g. fish does not support heredocs).
    /// All `args` are shell-quoted before being appended to the command, so
    /// values containing spaces or special characters are safe.
    static func runSSHPython(host: RemoteHost, script: String, args: [String] = [], timeoutSeconds: Int = 20) async -> ProcessResult {
        let b64 = Data(script.utf8).base64EncodedString()
        var cmd = "python3 -c \"import base64;exec(base64.b64decode('\(b64)'))\""
        if !args.isEmpty {
            cmd += " " + args.map(shellQuote).joined(separator: " ")
        }
        return await runSSHResult(host: host, command: cmd, timeoutSeconds: timeoutSeconds)
    }

    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 4000 {
            return String(t.prefix(4000)) + "\n..."
        }
        return t
    }
}
