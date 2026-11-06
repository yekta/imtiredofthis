import CLwIP
import Darwin
import Foundation
import ProxyCore

/// The tun's packets turned back into what apps sent: TCP connections, through lwIP, and UDP
/// datagrams; and what goes back to the apps turned into packets. lwIP is one per process, and
/// everything it does happens on `queue`, where the callbacks are called too.
public final class PacketStack {
    static let queue = DispatchQueue(label: "packet-stack")
    private static let timerInterval: DispatchTimeInterval = .milliseconds(250)

    /// Packets for the tun, with their protocols (`AF_INET` or `AF_INET6`).
    public var onOutput: (([Data], [NSNumber]) -> Void)?
    /// A new TCP connection from an app.
    public var onAccept: ((StackTCPConnection) -> Void)?
    /// A UDP datagram from an app.
    public var onDatagram: ((UDPDatagram) -> Void)?

    private var packets: [Data] = []
    private var protocols: [NSNumber] = []
    private var flushScheduled = false
    private var timer: DispatchSourceTimer?
    private var context: Unmanaged<PacketStack>?

    public init() {}

    public func start() {
        Self.queue.async { [self] in
            guard context == nil else { return }
            let context = Unmanaged.passRetained(self)
            self.context = context
            stack_start(stackOutput, stackAccept, connectionReceived, connectionSent, connectionFailed, context.toOpaque())
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            timer.schedule(deadline: .now() + Self.timerInterval, repeating: Self.timerInterval)
            timer.setEventHandler { [weak self] in
                stack_check_timeouts()
                self?.flush()
            }
            timer.resume()
            self.timer = timer
        }
    }

    /// Ends every connection; the stack can be started again.
    public func stop() {
        Self.queue.async { [self] in
            guard let context else { return }
            timer?.cancel()
            timer = nil
            stack_stop()
            packets.removeAll()
            protocols.removeAll()
            self.context = nil
            context.release()
        }
    }

    /// Packets read from the tun.
    public func input(_ packets: [Data]) {
        Self.queue.async { [self] in
            guard context != nil else { return }
            for packet in packets {
                switch IPPacket.transport(of: packet) {
                case IPPacket.tcp:
                    packet.withUnsafeBytes { bytes in
                        stack_input(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
                    }
                case IPPacket.udp:
                    guard let datagram = UDPDatagram(packet: packet) else { continue }
                    onDatagram?(datagram)
                default:
                    continue
                }
            }
            flush()
        }
    }

    /// A datagram back to an app.
    public func send(_ datagram: UDPDatagram) {
        Self.queue.async { [self] in
            guard context != nil, let packet = datagram.packet else { return }
            if case .ipv4 = datagram.source.host {
                emit(packet, version: 4)
            } else {
                emit(packet, version: 6)
            }
        }
    }

    fileprivate func emit(_ packet: Data, version: Int32) {
        packets.append(packet)
        protocols.append(NSNumber(value: version == 4 ? AF_INET : AF_INET6))
        scheduleFlush()
    }

    /// Sends what has piled up once the current work on the queue is done, in one batch.
    func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Self.queue.async { [self] in
            flushScheduled = false
            flush()
        }
    }

    private func flush() {
        guard !packets.isEmpty else { return }
        let packets = packets
        let protocols = protocols
        self.packets.removeAll(keepingCapacity: true)
        self.protocols.removeAll(keepingCapacity: true)
        onOutput?(packets, protocols)
    }

    fileprivate func accept(_ pcb: OpaquePointer) {
        let connection = StackTCPConnection(pcb: pcb, stack: self)
        guard let onAccept else { return connection.close() }
        onAccept(connection)
    }
}

private let stackOutput: stack_output_fn = { context, packet, length, version in
    guard let context, let packet else { return }
    let stack = Unmanaged<PacketStack>.fromOpaque(context).takeUnretainedValue()
    stack.emit(Data(bytes: packet, count: length), version: version)
}

private let stackAccept: stack_accept_fn = { context, pcb in
    guard let context, let pcb else { return }
    Unmanaged<PacketStack>.fromOpaque(context).takeUnretainedValue().accept(pcb)
}
