//
//  ProcessTreeBuilder.swift
//  VibeHub
//
//  Builds and queries process trees using ps command
//

import Foundation
import Darwin

/// Information about a process in the tree
struct ProcessInfo: Sendable {
    let pid: Int
    let ppid: Int
    let command: String
    let tty: String?

    nonisolated init(pid: Int, ppid: Int, command: String, tty: String?) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
        self.tty = tty
    }
}

/// Builds and queries the system process tree
struct ProcessTreeBuilder: Sendable {
    nonisolated static let shared = ProcessTreeBuilder()

    private nonisolated init() {}

    /// Build a process tree mapping PID -> ProcessInfo
    nonisolated func buildTree() -> [Int: ProcessInfo] {
        var tree: [Int: ProcessInfo] = [:]

        let PROC_ALL_PIDS: UInt32 = 1
        let initialSize = proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
        if initialSize <= 0 { return [:] }

        var pids = [pid_t](repeating: 0, count: Int(initialSize) / MemoryLayout<pid_t>.size)
        let actualSize = proc_listpids(PROC_ALL_PIDS, 0, &pids, initialSize)
        if actualSize <= 0 { return [:] }

        let validPids = pids.prefix(Int(actualSize) / MemoryLayout<pid_t>.size)
        let PROC_PIDTBSDINFO: Int32 = 3

        for pid in validPids {
            guard pid > 0 else { continue }

            var bsdinfo = proc_bsdinfo()
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdinfo, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard result == MemoryLayout<proc_bsdinfo>.size else { continue }

            let ppid = Int(bsdinfo.pbi_ppid)

            let command: String
            if let args = getCommandArgs(pid: pid) {
                command = args.joined(separator: " ")
            } else {
                let commTuple = bsdinfo.pbi_comm
                command = withUnsafeBytes(of: commTuple) { rawPtr in
                    if let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: CChar.self) {
                        return String(cString: ptr)
                    }
                    return ""
                }
            }

            tree[Int(pid)] = ProcessInfo(pid: Int(pid), ppid: ppid, command: command, tty: nil)
        }

        return tree
    }

    private nonisolated func getCommandArgs(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) < 0 { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) < 0 { return nil }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)

        var args = [String]()
        var ptr = MemoryLayout<Int32>.size

        // Skip executable path
        while ptr < size && buffer[ptr] != 0 { ptr += 1 }
        // Skip null padding
        while ptr < size && buffer[ptr] == 0 { ptr += 1 }

        for _ in 0..<argc {
            if ptr >= size { break }
            let start = ptr
            while ptr < size && buffer[ptr] != 0 { ptr += 1 }
            if ptr > start {
                let str = String(bytes: buffer[start..<ptr], encoding: .utf8) ?? ""
                args.append(str)
            }
            ptr += 1 // Skip null terminator
        }
        return args.isEmpty ? nil : args
    }

    /// Check if a process has tmux in its parent chain
    nonisolated func isInTmux(pid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }
            if info.command.lowercased().contains("tmux") {
                return true
            }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Walk up the process tree to find the terminal app PID
    nonisolated func findTerminalPid(forProcess pid: Int, tree: [Int: ProcessInfo]) -> Int? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }

            if TerminalAppRegistry.isTerminal(info.command) {
                return current
            }

            current = info.ppid
            depth += 1
        }

        return nil
    }

    /// Check if targetPid is a descendant of ancestorPid
    nonisolated func isDescendant(targetPid: Int, ofAncestor ancestorPid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = targetPid
        var depth = 0

        while current > 1 && depth < 50 {
            if current == ancestorPid {
                return true
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Find all descendant PIDs of a given process
    nonisolated func findDescendants(of pid: Int, tree: [Int: ProcessInfo]) -> Set<Int> {
        var descendants: Set<Int> = []
        var queue = [pid]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            for (childPid, info) in tree where info.ppid == current {
                if !descendants.contains(childPid) {
                    descendants.insert(childPid)
                    queue.append(childPid)
                }
            }
        }

        return descendants
    }

    /// Get working directory for a process using lsof
    nonisolated func getWorkingDirectory(forPid pid: Int) -> String? {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/usr/sbin/lsof", arguments: ["-p", String(pid), "-Fn"]) else {
            return nil
        }

        var foundCwd = false
        for line in output.components(separatedBy: "\n") {
            if line == "fcwd" {
                foundCwd = true
            } else if foundCwd && line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }

        return nil
    }
}
