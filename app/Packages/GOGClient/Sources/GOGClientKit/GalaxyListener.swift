// SPDX-License-Identifier: GPL-3.0-or-later
// The local Galaxy service's socket (decision 0063): TCP on 127.0.0.1:9977, where a
// game's Galaxy SDK looks for GOG's client. Up only for one GOG play: the launch starts
// it and stops it when the game exits. Each connection is read on its own thread, its
// frames handed to the play's GalaxyService in order and the replies written back;
// a malformed or oversized frame ends that connection. Connections are logged, their
// bytes never are.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import ContentKit

public final class GalaxyListener: @unchecked Sendable {
    /// Where GOG's client listens, and every Galaxy SDK connects.
    public static let defaultPort: UInt16 = 9977
    /// Connections at once; one more is closed at once.
    static let maxConnections = 8

    let service: GalaxyService
    let log: Logger
    let port: UInt16
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var connections: Set<Int32> = []
    private var stopped = false
    private var accepted = 0

    public init(service: GalaxyService, log: Logger, port: UInt16 = GalaxyListener.defaultPort) {
        self.service = service
        self.log = log
        self.port = port
    }

    public enum StartError: Error, CustomStringConvertible {
        case socket(Int32), bind(Int32), listen(Int32)
        public var description: String {
            switch self {
            case let .socket(e): "socket: errno \(e)"
            case let .bind(e): e == EADDRINUSE ? "127.0.0.1 port in use" : "bind: errno \(e)"
            case let .listen(e): "listen: errno \(e)"
            }
        }
    }

    /// Binds 127.0.0.1 and starts accepting; throws when the port is taken.
    public func start() throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw StartError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw StartError.bind(e)
        }
        guard listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            throw StartError.listen(e)
        }
        lock.withLock { listenFD = fd }
        let t = Thread { [self] in acceptLoop(fd) }
        t.name = "galaxy-listener"
        t.start()
        log.info("galaxy", "the Galaxy service listens on 127.0.0.1:\(port) for this play")
    }

    /// Stops accepting and ends every connection; the threads leave within a quarter second.
    public func stop() {
        // Under the lock, as every close is: no descriptor here can have been reused.
        let fds: [Int32] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            let fds = [listenFD] + Array(connections)
            for fd in fds where fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }
            return fds
        }
        guard !fds.isEmpty else { return }
        let service = self.service, log = self.log, connections = lock.withLock { accepted }
        Task.detached {
            let summary = await service.summary, minted = await service.minted
            log.info("galaxy", "the Galaxy service stopped: \(connections) connection(s) in the play; \(summary); "
                     + (minted ? "a game token was minted" : "no game token minted"))
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Waits up to 250 ms for `fd` to be readable; false when it was not.
    private func readable(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 250) > 0
    }

    private func acceptLoop(_ fd: Int32) {
        defer {
            lock.withLock {
                listenFD = -1
                close(fd)
            }
        }
        while !isStopped {
            guard readable(fd) else { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            let admitted: Bool = lock.withLock {
                guard !stopped, connections.count < Self.maxConnections else { return false }
                connections.insert(c)
                accepted += 1
                return true
            }
            guard admitted else {
                close(c)
                continue
            }
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            log.info("galaxy", "a connection from the game")
            let t = Thread { [self] in serve(c) }
            t.name = "galaxy-connection"
            t.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.withLock {
                connections.remove(fd)
                close(fd)
            }
        }
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        var received = 0, frames = 0
        while !isStopped {
            guard readable(fd) else { continue }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else {
                let why = n == 0 ? "the game closed a connection" : "a connection failed (errno \(errno))"
                log.info("galaxy", "\(why) after \(received) bytes in \(frames) frame(s)")
                return
            }
            received += n
            buffer += chunk[0..<n]
            while true {
                let parsed: (GalaxyFrame, Int)?
                do {
                    parsed = try GalaxyFrame.parse(buffer)
                } catch {
                    log.warn("galaxy", "a frame the service does not read (\(error)): connection closed")
                    return
                }
                guard let (frame, used) = parsed else { break }
                buffer.removeFirst(used)
                frames += 1
                for reply in handle(frame) where !write(fd, reply.encoded) { return }
            }
        }
    }

    /// The service's replies to one frame, waited for on this connection's thread.
    private func handle(_ frame: GalaxyFrame) -> [GalaxyFrame] {
        final class Box: @unchecked Sendable { var frames: [GalaxyFrame] = [] }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let service = self.service
        Task.detached {
            box.frames = await service.handle(frame)
            done.signal()
        }
        done.wait()
        return box.frames
    }

    private func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var at = 0
        while at < bytes.count {
            #if canImport(Glibc)
            let flags = Int32(MSG_NOSIGNAL)
            #else
            let flags: Int32 = 0
            #endif
            let n = bytes[at...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, flags) }
            guard n > 0 else { return false }
            at += n
        }
        return true
    }
}
