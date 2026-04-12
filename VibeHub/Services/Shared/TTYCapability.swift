import Foundation

/// Detects whether the system allows TIOCSTI ioctl for TTY keystroke injection.
/// Modern macOS (Ventura+) blocks this, so we probe once at startup with a throwaway pty.
enum TTYCapability {
    static let canInjectKeystrokes: Bool = {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return false }
        defer { close(master); close(slave) }
        var byte: UInt8 = 0
        return ioctl(slave, TIOCSTI, &byte) == 0
    }()
}
