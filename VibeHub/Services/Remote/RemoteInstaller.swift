import Foundation

enum RemoteInstaller {
    static func installAll(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> RemoteInstallReport {
        let startedAt = Date()
        var steps: [RemoteInstallStep] = []

        // Upload shared script once, then each CLI just symlinks to it.
        let (sharedSteps, _) = await uploadSharedScript(host: host, progress: progress)
        steps.append(contentsOf: sharedSteps)

        steps.append(contentsOf: await installClaudeHooks(host: host, progress: progress))
        let opencodeSteps = await installOpenCodePlugin(host: host, progress: progress)
        steps.append(contentsOf: opencodeSteps)
        // opencode was actually installed if more than just the config-check step ran
        let opencodeInstalled = opencodeSteps.count > 1
        let codexSteps = await installCodexHooks(host: host, progress: progress)
        steps.append(contentsOf: codexSteps)
        let codexInstalled = codexSteps.count > 1

        if let progress { await progress("verify files") }

        // Verify the tunnel is active by checking the remote Unix socket.
        let tunnelCheck = "test -S \(host.remoteSocketPath)"
        steps.append(await step(
            name: "verify tunnel",
            command: tunnelCheck,
            result: await runSSHResult(host: host, command: tunnelCheck, timeoutSeconds: 8)
        ))

        steps.append(await step(
            name: "verify claude hook",
            command: "test -f ~/.claude/hooks/vibehub-state.py && echo ok || echo missing",
            result: await runSSHResult(host: host, command: "test -f ~/.claude/hooks/vibehub-state.py && echo ok || echo missing", timeoutSeconds: 12)
        ))

        if opencodeInstalled {
            steps.append(await step(
                name: "verify opencode plugin",
                command: "test -f ~/.config/opencode/plugins/vibehub.js && echo ok || echo missing",
                result: await runSSHResult(host: host, command: "test -f ~/.config/opencode/plugins/vibehub.js && echo ok || echo missing", timeoutSeconds: 12)
            ))
        }

        if codexInstalled {
            steps.append(await step(
                name: "verify codex hook",
                command: "test -f ~/.codex/hooks/vibehub-state.py && echo ok || echo missing",
                result: await runSSHResult(host: host, command: "test -f ~/.codex/hooks/vibehub-state.py && echo ok || echo missing", timeoutSeconds: 12)
            ))
        }

        return RemoteInstallReport(startedAt: startedAt, finishedAt: Date(), steps: steps)
    }

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
        if checkResult.exitCode == 0 && checkResult.output.contains("1.0.5") {
            if let progress { await progress("shared hook up to date") }
            steps.append(RemoteInstallStep(
                name: "check shared hook version", command: checkCmd,
                ok: true, exitCode: 0, stdout: "Up to date (1.0.5)", stderr: ""
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

    static func installClaudeHooks(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> [RemoteInstallStep] {
        var steps: [RemoteInstallStep] = []

        // Symlink from ~/.claude/hooks/ to the shared script
        steps.append(await step(
            name: "mkdir ~/.claude/hooks",
            command: "mkdir -p ~/.claude/hooks",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.claude/hooks", timeoutSeconds: 12)
        ))
        steps.append(await step(
            name: "symlink claude hook",
            command: "ln -sf ~/.vibehub/vibehub-state.py ~/.claude/hooks/vibehub-state.py",
            result: await runSSHResult(host: host, command: "ln -sf ~/.vibehub/vibehub-state.py ~/.claude/hooks/vibehub-state.py", timeoutSeconds: 12)
        ))

        // Merge hook config into ~/.claude/settings.json (best effort)
        let py = """
import json, os, pathlib, subprocess

home = pathlib.Path.home()
settings_path = home / '.claude' / 'settings.json'
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
cmd = f'VIBEHUB_SOCKET_PATH="/tmp/vibehub.sock" {python} ~/.claude/hooks/vibehub-state.py'
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
    'UserPromptSubmit': without_matcher,
    'PreToolUse': with_matcher,
    'PostToolUse': with_matcher,
    'PermissionRequest': with_matcher_timeout,
    'Notification': with_matcher,
    'Stop': without_matcher,
    'SubagentStop': without_matcher,
    'SessionStart': without_matcher,
    'SessionEnd': without_matcher,
    'PreCompact': precompact,
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

        steps.append(await step(
            name: "update ~/.claude/settings.json",
            command: "python3 - <<'PY' ... PY",
            result: await runSSHResult(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeoutSeconds: 20)
        ))

        return steps
    }

    static func installCodexHooks(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> [RemoteInstallStep] {
        var steps: [RemoteInstallStep] = []

        // Only install if Codex is available on the remote.
        let checkResult = await runSSHResult(host: host, command: "test -d ~/.codex", timeoutSeconds: 12)
        let codexFound = checkResult.exitCode == 0
        steps.append(RemoteInstallStep(
            name: codexFound ? "check codex" : "codex not installed on remote",
            command: "test -d ~/.codex",
            ok: true, exitCode: 0,
            stdout: codexFound ? "found" : "not found (skipped)", stderr: ""
        ))
        guard codexFound else { return steps }

        // Symlink from ~/.codex/hooks/ to the shared script
        steps.append(await step(
            name: "mkdir ~/.codex/hooks",
            command: "mkdir -p ~/.codex/hooks",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.codex/hooks", timeoutSeconds: 12)
        ))
        if let progress { await progress("symlink codex hook") }
        steps.append(await step(
            name: "symlink codex hook",
            command: "ln -sf ~/.vibehub/vibehub-state.py ~/.codex/hooks/vibehub-state.py",
            result: await runSSHResult(host: host, command: "ln -sf ~/.vibehub/vibehub-state.py ~/.codex/hooks/vibehub-state.py", timeoutSeconds: 12)
        ))

        // Update ~/.codex/hooks.json and enable codex_hooks in config.toml
        let py = """
import json, os, pathlib, re, subprocess

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
cmd = f'VIBEHUB_SOURCE=codex VIBEHUB_SOCKET_PATH="/tmp/vibehub.sock" {python} ~/.codex/hooks/vibehub-state.py'

# Update hooks.json
hooks_path = home / '.codex' / 'hooks.json'
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

for ev in ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop']:
    entries = hooks.get(ev, [])
    if not isinstance(entries, list):
        entries = []
    entries = [e for e in entries if isinstance(e, dict) and not has_our_hook(e)]
    entries.append({'hooks': [{'type': 'command', 'command': cmd, 'timeout': 5}]})
    hooks[ev] = entries

data['hooks'] = hooks
hooks_path.write_text(json.dumps(data, indent=2, sort_keys=True))

# Enable codex_hooks in config.toml
config_path = home / '.codex' / 'config.toml'
contents = config_path.read_text() if config_path.exists() else ''
if not re.search(r'(?m)^\\s*codex_hooks\\s*=\\s*true', contents):
    if re.search(r'(?m)^\\s*codex_hooks\\s*=\\s*false', contents):
        contents = re.sub(r'(?m)^\\s*codex_hooks\\s*=\\s*false', 'codex_hooks = true', contents)
    else:
        lines = contents.split('\\n')
        feat_idx = next((i for i, l in enumerate(lines) if l.strip() == '[features]'), None)
        if feat_idx is not None:
            lines.insert(feat_idx + 1, 'codex_hooks = true')
        else:
            if lines and lines[-1]:
                lines.append('')
            lines.append('[features]')
            lines.append('codex_hooks = true')
        contents = '\\n'.join(lines)
    config_path.write_text(contents)

print('ok')
"""

        steps.append(await step(
            name: "update ~/.codex/hooks.json + config.toml",
            command: "python3 - <<'PY' ... PY",
            result: await runSSHResult(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeoutSeconds: 20)
        ))

        return steps
    }

    static func installOpenCodePlugin(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> [RemoteInstallStep] {
        guard let plugin = Bundle.main.url(forResource: "vibehub-opencode", withExtension: "js") else {
            return []
        }

        var steps: [RemoteInstallStep] = []

        // Only install if OpenCode is available on the remote.
        // Use exit code (not stdout parsing) to avoid false negatives from MOTD/banner noise.
        // Also check for the opencode binary as a fallback when no config file exists yet.
        let checkResult = await runSSHResult(host: host, command: "test -d ~/.config/opencode || which opencode >/dev/null 2>&1", timeoutSeconds: 12)
        let opencodeFound = checkResult.exitCode == 0
        // Build step manually so the name clearly reflects whether opencode is installed.
        // ok=true in both cases: not having opencode on the remote is not a failure.
        steps.append(RemoteInstallStep(
            name: opencodeFound ? "check opencode" : "opencode not installed on remote",
            command: "test -d ~/.config/opencode || which opencode",
            ok: true,
            exitCode: 0,
            stdout: opencodeFound ? "found" : "not found (skipped)",
            stderr: ""
        ))
        guard opencodeFound else {
            return steps
        }

        let checkVersionCommand = "grep 'VERSION = \"1.0.2\"' ~/.config/opencode/plugins/vibehub.js"
        let versionCheckResult = await runSSHResult(host: host, command: checkVersionCommand, timeoutSeconds: 8)
        if versionCheckResult.exitCode == 0 {
            if let progress { await progress("opencode plugin up to date") }
            steps.append(RemoteInstallStep(
                name: "check opencode plugin version",
                command: checkVersionCommand,
                ok: true,
                exitCode: 0,
                stdout: "Up to date (1.0.3)",
                stderr: ""
            ))
            return steps
        }

        steps.append(await step(
            name: "mkdir ~/.config/opencode/plugins",
            command: "ssh \(host.sshTarget) 'mkdir -p ~/.config/opencode/plugins'",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.config/opencode/plugins", timeoutSeconds: 12)
        ))
        if let progress { await progress("upload opencode plugin") }
        steps.append(await step(
            name: "upload opencode plugin",
            command: "ssh \(host.sshTarget) 'base64 -d > ~/.config/opencode/plugins/vibehub.js'",
            result: await uploadFileViaSSH(host: host, localURL: plugin, remotePath: "~/.config/opencode/plugins/vibehub.js", timeoutSeconds: 20)
        ))

        return steps
    }

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
            // Avoid hanging forever on network issues.
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            // Avoid interactive host key prompts; accept new hosts and still protect against MITM changes.
            "-o", "StrictHostKeyChecking=accept-new",
        ]

        // Reuse the ControlMaster socket from SSHForwarder when available.
        // In App Store builds ControlMaster is disabled (sandbox cannot create
        // Unix sockets outside the container), so each command opens its own connection.
        #if !APP_STORE
        let controlPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
            .appendingPathComponent("ssh-%C")
            .path
        args += ["-o", "ControlPath=\(controlPath)"]
        #endif
        // GSSAPI authentication for jump hosts, Kerberos environments, etc.
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

    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 4000 {
            return String(t.prefix(4000)) + "\n..."
        }
        return t
    }
}
