import Foundation

enum RemoteInstaller {
    static func installAllWithTimeout(host: RemoteHost, timeoutSeconds: UInt64 = 25) async -> RemoteInstallReport {
        await withTaskGroup(of: RemoteInstallReport.self) { group in
            group.addTask {
                await installAll(host: host)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                let step = RemoteInstallStep(
                    name: "install timeout",
                    command: "(timeout)",
                    ok: false,
                    exitCode: 124,
                    stdout: "",
                    stderr: "install timed out after \(timeoutSeconds)s"
                )
                return RemoteInstallReport(startedAt: Date(), finishedAt: Date(), steps: [step])
            }

            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
    static func installAll(host: RemoteHost) async -> RemoteInstallReport {
        let startedAt = Date()
        var steps: [RemoteInstallStep] = []

        steps.append(contentsOf: await installClaudeHooks(host: host))
        steps.append(contentsOf: await installOpenCodePlugin(host: host))

        // Verify presence
        steps.append(await step(
            name: "verify claude hook",
            command: "test -f ~/.claude/hooks/claude-island-state.py && echo ok || echo missing",
            result: await runSSHResult(host: host, command: "test -f ~/.claude/hooks/claude-island-state.py && echo ok || echo missing")
        ))

        steps.append(await step(
            name: "verify opencode plugin",
            command: "test -f ~/.config/opencode/plugins/claude-island.js && echo ok || echo missing",
            result: await runSSHResult(host: host, command: "test -f ~/.config/opencode/plugins/claude-island.js && echo ok || echo missing")
        ))

        return RemoteInstallReport(startedAt: startedAt, finishedAt: Date(), steps: steps)
    }

    static func installClaudeHooks(host: RemoteHost) async -> [RemoteInstallStep] {
        guard let script = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") else {
            return []
        }

        var steps: [RemoteInstallStep] = []

        steps.append(await step(
            name: "mkdir ~/.claude/hooks",
            command: "mkdir -p ~/.claude/hooks",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.claude/hooks")
        ))
        // Use a path relative to $HOME for scp compatibility (newer scp uses SFTP and may not expand ~).
        steps.append(await step(
            name: "scp claude hook",
            command: "scp \"\(script.lastPathComponent)\" -> \(host.sshTarget):.claude/hooks/claude-island-state.py",
            result: await runSCPResult(host: host, localPath: script.path, remotePath: ".claude/hooks/claude-island-state.py")
        ))
        steps.append(await step(
            name: "chmod claude hook",
            command: "chmod 755 ~/.claude/hooks/claude-island-state.py",
            result: await runSSHResult(host: host, command: "chmod 755 ~/.claude/hooks/claude-island-state.py")
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
cmd = f"{python} ~/.claude/hooks/claude-island-state.py"
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
        if 'claude-island-state.py' in c:
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
            result: await runSSHResult(host: host, command: "python3 - <<'PY'\n\(py)\nPY")
        ))

        return steps
    }

    static func installOpenCodePlugin(host: RemoteHost) async -> [RemoteInstallStep] {
        guard let plugin = Bundle.main.url(forResource: "claude-island-opencode", withExtension: "js") else {
            return []
        }

        var steps: [RemoteInstallStep] = []

        // Only install if OpenCode config exists.
        let checkResult = await runSSHResult(host: host, command: "test -f ~/.config/opencode/opencode.json && echo ok || echo missing")
        steps.append(await step(name: "check opencode config", command: "test -f ~/.config/opencode/opencode.json", result: checkResult))
        guard (checkResult.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok") else {
            return steps
        }

        steps.append(await step(
            name: "mkdir ~/.config/opencode/plugins",
            command: "mkdir -p ~/.config/opencode/plugins",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.config/opencode/plugins")
        ))
        // Use a path relative to $HOME for scp compatibility (newer scp uses SFTP and may not expand ~).
        steps.append(await step(
            name: "scp opencode plugin",
            command: "scp \"\(plugin.lastPathComponent)\" -> \(host.sshTarget):.config/opencode/plugins/claude-island.js",
            result: await runSCPResult(host: host, localPath: plugin.path, remotePath: ".config/opencode/plugins/claude-island.js")
        ))

        let py = """
import json, pathlib

home = pathlib.Path.home()
cfg = home / '.config' / 'opencode' / 'opencode.json'
plugins = home / '.config' / 'opencode' / 'plugins'
plugin_file = plugins / 'claude-island.js'

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
            result: await runSSHResult(host: host, command: "python3 - <<'PY'\n\(py)\nPY")
        ))

        return steps
    }

    private static func sshBaseArgs(host: RemoteHost) -> [String] {
        var args: [String] = []
        args += [
            "-o", "BatchMode=yes",
            // Avoid hanging forever on network issues.
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            // Avoid interactive host key prompts; accept new hosts and still protect against MITM changes.
            "-o", "StrictHostKeyChecking=accept-new",
            // Prefer gssapi, but fall back to publickey if available.
            "-o", "PreferredAuthentications=gssapi-with-mic,publickey",
        ]
        if let port = host.port { args += ["-p", String(port)] }
        if let key = host.identityFile, !key.isEmpty { args += ["-i", key] }
        return args
    }

    static func runSSH(host: RemoteHost, command: String) async -> String? {
        let r = await runSSHResult(host: host, command: command)
        guard r.exitCode == 0 else { return nil }
        return r.output
    }

    static func runSSHResult(host: RemoteHost, command: String) async -> ProcessResult {
        let sshPath = "/usr/bin/ssh"
        var args = sshBaseArgs(host: host)
        args.append(host.sshTarget)
        args.append(command)

        // Run via login shell so ssh inherits the same environment as Terminal
        // (eg SSH_AUTH_SOCK / corp auth envs), which often fixes jump-proxy auth.
        let cmd = shellEnvPrefix() + shellJoin([sshPath] + args)
        return await runShellResult(cmd)
    }

    private static func runSCP(host: RemoteHost, localPath: String, remotePath: String) async -> String? {
        let r = await runSCPResult(host: host, localPath: localPath, remotePath: remotePath)
        guard r.exitCode == 0 else { return nil }
        return r.output
    }

    static func runSCPResult(host: RemoteHost, localPath: String, remotePath: String) async -> ProcessResult {
        let scpPath = "/usr/bin/scp"
        var scpArgs: [String] = []
        if let port = host.port { scpArgs += ["-P", String(port)] }
        if let key = host.identityFile, !key.isEmpty { scpArgs += ["-i", key] }
        scpArgs += ["-o", "BatchMode=yes"]
        scpArgs += [localPath, "\(host.sshTarget):\(remotePath)"]

        // scp may still need the same auth env (agent/kerberos) as ssh.
        let cmd = shellEnvPrefix() + shellJoin([scpPath] + scpArgs)
        return await runShellResult(cmd)
    }

    private static func runShellResult(_ command: String) async -> ProcessResult {
        let zsh = "/bin/zsh"
        let args = ["-lc", command]
        let res = await ProcessExecutor.shared.runWithResult(zsh, arguments: args)
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

    private static func shellEnvPrefix() -> String {
        // Make GUI-launched ssh behave more like Terminal by grabbing launchd env.
        // (Many corp auth setups populate SSH_AUTH_SOCK/KRB5CCNAME in launchd.)
        let prefix = """
SSH_AUTH_SOCK_VAL=$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true);
if [ -n \"$SSH_AUTH_SOCK_VAL\" ]; then export SSH_AUTH_SOCK=\"$SSH_AUTH_SOCK_VAL\"; fi;
KRB5CCNAME_VAL=$(launchctl getenv KRB5CCNAME 2>/dev/null || true);
if [ -n \"$KRB5CCNAME_VAL\" ]; then export KRB5CCNAME=\"$KRB5CCNAME_VAL\"; fi;
"""
        return prefix + " "
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
