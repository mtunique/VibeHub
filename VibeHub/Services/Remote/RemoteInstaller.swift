import Foundation

enum RemoteInstaller {
    static func installAll(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> RemoteInstallReport {
        let startedAt = Date()
        var steps: [RemoteInstallStep] = []

        steps.append(contentsOf: await installClaudeHooks(host: host, progress: progress))
        let opencodeSteps = await installOpenCodePlugin(host: host, progress: progress)
        steps.append(contentsOf: opencodeSteps)
        // opencode was actually installed if more than just the config-check step ran
        let opencodeInstalled = opencodeSteps.count > 1

        if let progress { await progress("verify files") }

        // Verify the SSH reverse tunnel socket exists on the remote side.
        // If AllowStreamLocalForwarding is disabled on the remote sshd, this socket
        // won't be created and events will never flow regardless of plugin status.
        steps.append(await step(
            name: "verify tunnel socket",
            command: "test -S \(host.remoteSocketPath)",
            result: await runSSHResult(host: host, command: "test -S \(host.remoteSocketPath)", timeoutSeconds: 8)
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

        return RemoteInstallReport(startedAt: startedAt, finishedAt: Date(), steps: steps)
    }

    static func installClaudeHooks(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> [RemoteInstallStep] {
        guard let script = Bundle.main.url(forResource: "vibehub-state", withExtension: "py") else {
            return []
        }

        var steps: [RemoteInstallStep] = []

        steps.append(await step(
            name: "mkdir ~/.claude/hooks",
            command: "ssh \(host.sshTarget) 'mkdir -p ~/.claude/hooks'",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.claude/hooks", timeoutSeconds: 12)
        ))
        if let progress { await progress("upload claude hook") }
        steps.append(await step(
            name: "upload claude hook",
            command: "ssh \(host.sshTarget) 'base64 -d > ~/.claude/hooks/vibehub-state.py'",
            result: await uploadFileViaSSH(host: host, localURL: script, remotePath: "~/.claude/hooks/vibehub-state.py", timeoutSeconds: 20)
        ))
        steps.append(await step(
            name: "chmod claude hook",
            command: "ssh \(host.sshTarget) 'chmod 755 ~/.claude/hooks/vibehub-state.py'",
            result: await runSSHResult(host: host, command: "chmod 755 ~/.claude/hooks/vibehub-state.py", timeoutSeconds: 12)
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
cmd = f"{python} ~/.claude/hooks/vibehub-state.py"
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

    static func installOpenCodePlugin(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> [RemoteInstallStep] {
        guard let plugin = Bundle.main.url(forResource: "vibehub-opencode", withExtension: "js") else {
            return []
        }

        var steps: [RemoteInstallStep] = []

        // Only install if OpenCode config exists.
        let checkResult = await runSSHResult(host: host, command: "test -f ~/.config/opencode/opencode.json && echo ok || echo missing", timeoutSeconds: 12)
        steps.append(await step(name: "check opencode config", command: "test -f ~/.config/opencode/opencode.json", result: checkResult))
        guard (checkResult.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok") else {
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

        let py = """
import json, pathlib

home = pathlib.Path.home()
cfg = home / '.config' / 'opencode' / 'opencode.json'
plugins = home / '.config' / 'opencode' / 'plugins'
plugin_file = plugins / 'vibehub.js'

data = json.loads(cfg.read_text())
uri = plugin_file.absolute().as_uri()

existing = data.get('plugin')
arr = []
if isinstance(existing, list):
    arr = existing
elif isinstance(existing, str):
    arr = [existing]

if uri not in arr:
    arr.append(uri)

data['plugin'] = arr
cfg.write_text(json.dumps(data, indent=2, sort_keys=True))
"""

        steps.append(await step(
            name: "update opencode.json plugins",
            command: "python3 - <<'PY' ... PY",
            result: await runSSHResult(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeoutSeconds: 20)
        ))

        return steps
    }

    private static func sshBaseArgs(host: RemoteHost) -> [String] {
        var args: [String] = []

        let controlPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
            .appendingPathComponent("ssh-%C")
            .path

        args += [
            "-o", "BatchMode=yes",
            // Avoid hanging forever on network issues.
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            // Avoid interactive host key prompts; accept new hosts and still protect against MITM changes.
            "-o", "StrictHostKeyChecking=accept-new",
            // ControlPath: reuse the ControlMaster socket created by SSHForwarder.
            // Must match the path in SSHForwarder.buildArgs exactly.
            "-o", "ControlPath=\(controlPath)",
        ]
        // GSSAPI authentication for jump hosts, Kerberos environments, etc.
        if host.useGSSAPI {
            args += ["-o", "PreferredAuthentications=gssapi-with-mic"]
        }

        if let port = host.port { args += ["-p", String(port)] }
        if let key = host.identityFile, !key.isEmpty { args += ["-i", key] }
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

        // Run via login shell so ssh inherits the same environment as Terminal
        // (eg SSH_AUTH_SOCK / corp auth envs), which often fixes jump-proxy auth.
        let cmd = shellJoin([sshPath] + args)
        return await runShellResult(cmd, timeoutSeconds: timeoutSeconds)
    }

    // Upload a local file to the remote by base64-encoding its content and piping it through SSH.
    // This avoids SCP/SFTP entirely and works with any standard SSH connection.
    private static func uploadFileViaSSH(host: RemoteHost, localURL: URL, remotePath: String, timeoutSeconds: Int) async -> ProcessResult {
        guard let data = try? Data(contentsOf: localURL) else {
            return ProcessResult(output: "", exitCode: 1, stderr: "failed to read local file: \(localURL.path)")
        }
        // base64 output uses only A-Za-z0-9+/= — safe inside single quotes on the remote shell
        let encoded = data.base64EncodedString()
        let command = "printf '%s' '\(encoded)' | base64 -d > \(remotePath)"
        return await runSSHResult(host: host, command: command, timeoutSeconds: timeoutSeconds)
    }

    private static func runShellResult(_ command: String, timeoutSeconds: Int) async -> ProcessResult {
        let zsh = "/bin/zsh"
        let args = ["-lc", command]
        let env = getSSHEnvironment()
        let res = await ProcessExecutor.shared.runWithResult(zsh, arguments: args, timeoutSeconds: timeoutSeconds, environment: env)
        switch res {
        case .success(let r):
            return r
        case .failure(let e):
            return ProcessResult(output: "", exitCode: (e.exitCode ?? 1), stderr: e.rawStderr ?? e.errorDescription)
        }
    }

    nonisolated private static func shellJoin(_ args: [String]) -> String {
        args.map(shellQuote).joined(separator: " ")
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
