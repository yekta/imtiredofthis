import CLwIP
import Foundation
import Network
import ProxyCore

public enum StackError: Error, LocalizedError {
    case reset
    case closed

    public var errorDescription: String? {
        switch self {
        case .reset: return "The app's connection was reset."
        case .closed: return "The app's connection is closed."
        }
    }
}

/// An app's TCP connection, as lwIP took it. The completions are called on the stack's queue.
public final class StackTCPConnection {
    /// The app's end.
    public let source: Address
    /// Where the app connected to.
    public let destination: Address

    private let stack: PacketStack
    private var pcb: OpaquePointer?
    private var retained: Unmanaged<StackTCPConnection>?
    private var received = Data()
    private var receivedAll = false
    private var failure: Error?
    private var pendingRead: ((Result<Data?, Error>) -> Void)?
    /// Bytes handed to the reader that the app's window doesn't have back yet.
    private var unacknowledged = 0
    private var writes: [(data: Data, completion: (Error?) -> Void)] = []
    private var writeOffset = 0
    private var finishAfterWrites = false

    init(pcb: OpaquePointer, stack: PacketStack) {
        var local = [UInt8](repeating: 0, count: 16)
        var remote = [UInt8](repeating: 0, count: 16)
        var localPort: UInt16 = 0
        var remotePort: UInt16 = 0
        let version = stack_tcp_endpoints(pcb, &local, &localPort, &remote, &remotePort)
        destination = Address(bytes: local, version: version, port: localPort)
        source = Address(bytes: remote, version: version, port: remotePort)
        self.stack = stack
        self.pcb = pcb

        let retained = Unmanaged.passRetained(self)
        self.retained = retained
        stack_tcp_attach(pcb, retained.toOpaque())
    }

    /// The app's next data, or nil once it has finished sending. The app's window only opens
    /// again for this data at the next read, so a slow server slows the app instead of filling
    /// memory.
    public func read(_ completion: @escaping (Result<Data?, Error>) -> Void) {
        PacketStack.queue.async { [self] in
            acknowledge()
            pendingRead = completion
            deliver()
        }
    }

    /// Calls `completion` once lwIP has taken all of `data`.
    public func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        PacketStack.queue.async { [self] in
            guard pcb != nil else { return completion(failure ?? StackError.closed) }
            writes.append((data, completion))
            pump()
        }
    }

    /// Sends the app a FIN once everything written has gone out; the app can still send.
    public func finishSending() {
        PacketStack.queue.async { [self] in
            finishAfterWrites = true
            pump()
        }
    }

    public func close() {
        PacketStack.queue.async { [self] in
            guard let pcb else { return }
            acknowledge()
            stack_tcp_close(pcb)
            forget()
            fail(StackError.closed)
            stack.scheduleFlush()
        }
    }

    private func acknowledge() {
        guard let pcb, unacknowledged > 0 else { return }
        stack_tcp_received(pcb, unacknowledged)
        unacknowledged = 0
        stack.scheduleFlush()
    }

    private func deliver() {
        guard let read = pendingRead else { return }
        if !received.isEmpty {
            let data = received
            received = Data()
            unacknowledged += data.count
            pendingRead = nil
            read(.success(data))
        } else if let failure {
            pendingRead = nil
            read(.failure(failure))
        } else if receivedAll {
            pendingRead = nil
            read(.success(nil))
        }
    }

    /// Hands lwIP as much of the waiting data as it takes now; `tcp_sent` calls this again.
    private func pump() {
        guard let pcb else { return }
        while let write = writes.first {
            let remaining = write.data.count - writeOffset
            if remaining > 0 {
                let count = min(remaining, Int(stack_tcp_send_space(pcb)), Int(UInt16.max))
                guard count > 0 else { break }
                let written = write.data.withUnsafeBytes { bytes in
                    stack_tcp_write(pcb, bytes.bindMemory(to: UInt8.self).baseAddress! + writeOffset, UInt16(count))
                }
                guard written else { break }
                writeOffset += count
                guard writeOffset == write.data.count else { continue }
            }
            writes.removeFirst()
            writeOffset = 0
            write.completion(nil)
        }
        if writes.isEmpty, finishAfterWrites {
            finishAfterWrites = false
            stack_tcp_shutdown(pcb)
        }
        stack_tcp_output(pcb)
        stack.scheduleFlush()
    }

    fileprivate func received(_ data: Data?) {
        if let data {
            received.append(data)
        } else {
            receivedAll = true
        }
        deliver()
    }

    fileprivate func sent() {
        pump()
    }

    /// lwIP has already freed the connection.
    fileprivate func failed() {
        forget()
        fail(StackError.reset)
    }

    private func forget() {
        pcb = nil
        retained?.release()
        retained = nil
    }

    private func fail(_ error: Error) {
        failure = failure ?? error
        let writes = writes
        self.writes.removeAll()
        for write in writes {
            write.completion(error)
        }
        deliver()
    }
}

private func connection(_ pointer: UnsafeMutableRawPointer?) -> StackTCPConnection? {
    pointer.map { Unmanaged<StackTCPConnection>.fromOpaque($0).takeUnretainedValue() }
}

let connectionReceived: stack_received_fn = { pointer, data, length in
    connection(pointer)?.received(data.map { Data(bytes: $0, count: length) })
}

let connectionSent: stack_sent_fn = { pointer in
    connection(pointer)?.sent()
}

let connectionFailed: stack_failed_fn = { pointer in
    connection(pointer)?.failed()
}

extension Address {
    init(bytes: [UInt8], version: Int32, port: UInt16) {
        if version == 4 {
            self.init(host: .ipv4(IPv4Address(Data(bytes[0..<4]))!), port: port)
        } else {
            self.init(host: .ipv6(IPv6Address(Data(bytes))!), port: port)
        }
    }
}
