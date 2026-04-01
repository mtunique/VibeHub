import Foundation

enum UnixSocketClient {
    static func sendAndReceive(
        socketPath: String,
        payload: Data,
        timeoutSeconds: Int32 = 2,
        allowNoResponse: Bool = false
    ) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { close(fd) }

                var tv = timeval(tv_sec: __darwin_time_t(timeoutSeconds), tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                socketPath.withCString { ptr in
                    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
                        guard let base = rawBuf.baseAddress else { return }
                        let buf = base.assumingMemoryBound(to: CChar.self)
                        strncpy(buf, ptr, rawBuf.count - 1)
                    }
                }

                let connectResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }

                guard connectResult == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                let writeOK = payload.withUnsafeBytes { bytes -> Bool in
                    guard let base = bytes.baseAddress else { return false }
                    return write(fd, base, payload.count) == payload.count
                }
                guard writeOK else {
                    continuation.resume(returning: nil)
                    return
                }

                shutdown(fd, SHUT_WR)

                var out = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 {
                        out.append(buffer, count: n)
                        continue
                    }
                    break
                }

                if out.isEmpty, allowNoResponse {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: out.isEmpty ? nil : out)
                }
            }
        }
    }
}
