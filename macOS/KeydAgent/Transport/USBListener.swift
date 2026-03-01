import Darwin
import Foundation
import SharedProtocol

private let logger = KeydLogger(category: "USBListener")

/// Opens a host-side usbmux tunnel to the iPhone app's listening TCP port.
/// Unlike the original implementation, the Mac initiates the USB tunnel and
/// keeps reconnecting while the device is attached.
actor USBListener {
    static let port: UInt16 = 12345

    private static let socketPath = "/var/run/usbmuxd"
    private static let headerLength = 16
    private static let protocolVersion: UInt32 = 1
    private static let plistMessageType: UInt32 = 8

    private var socketFD: Int32 = -1
    private var connectTask: Task<Void, Never>?
    private var stopRequested = false
    private var nextTag: UInt32 = 1
    private var lastConnectedUSBMuxDeviceID: Int?

    var onConnectionReady: (@Sendable () -> Void)?
    var onData: (@Sendable (Data) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    func start() {
        guard connectTask == nil else { return }

        stopRequested = false
        connectTask = Task { [weak self] in
            await self?.runConnectLoop()
        }
    }

    func stop() {
        stopRequested = true
        connectTask?.cancel()
        connectTask = nil
        shutdownCurrentSocket()
    }

    func disconnectCurrentConnection() {
        shutdownCurrentSocket()
    }

    func send(_ data: Data) throws {
        guard socketFD >= 0 else {
            throw USBMuxError.notConnected
        }

        try Self.writeAll(fd: socketFD, data: data)
    }

    func hasConnection() -> Bool {
        socketFD >= 0
    }

    private func runConnectLoop() async {
        while !Task.isCancelled && !stopRequested {
            do {
                let tag = nextRequestTag()
                let preferredAfterDeviceID = lastConnectedUSBMuxDeviceID
                let tunnel = try await Task.detached(priority: .userInitiated) {
                    try Self.openTunnel(
                        on: Self.port,
                        tag: tag,
                        preferAfterDeviceID: preferredAfterDeviceID
                    )
                }.value

                guard !Task.isCancelled && !stopRequested else {
                    Self.closeSocket(tunnel.fd)
                    break
                }

                socketFD = tunnel.fd
                lastConnectedUSBMuxDeviceID = tunnel.deviceID
                logger.info("Connected to USB device \(tunnel.deviceID) over usbmuxd on port \(Self.port)")
                onConnectionReady?()

                do {
                    while !Task.isCancelled && !stopRequested {
                        let chunk = try await Task.detached(priority: .userInitiated) {
                            try Self.readChunk(fd: tunnel.fd)
                        }.value
                        onData?(chunk)
                    }
                } catch {
                    if !Task.isCancelled && !stopRequested {
                        logger.warning("USB tunnel closed: \(error)")
                    }
                }

                finishSocket(tunnel.fd, notifyIfCurrent: true)
            } catch is CancellationError {
                break
            } catch {
                if !Task.isCancelled && !stopRequested {
                    logger.warning("USB unavailable: \(error)")
                }
            }

            if Task.isCancelled || stopRequested {
                break
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        connectTask = nil
    }

    private func nextRequestTag() -> UInt32 {
        defer { nextTag &+= 1 }
        return nextTag
    }

    private func shutdownCurrentSocket() {
        guard socketFD >= 0 else { return }

        let fd = socketFD
        socketFD = -1
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    private func finishSocket(_ fd: Int32, notifyIfCurrent: Bool) {
        let shouldNotify = notifyIfCurrent && socketFD == fd
        if socketFD == fd {
            socketFD = -1
        }
        Self.closeSocket(fd)
        if shouldNotify {
            onDisconnect?()
        }
    }

    private struct OpenTunnelResult {
        let fd: Int32
        let deviceID: Int
    }

    private static func openTunnel(
        on port: UInt16,
        tag: UInt32,
        preferAfterDeviceID: Int?
    ) throws -> OpenTunnelResult {
        let deviceIDs = try attachedDeviceIDs(tag: tag)
        let candidateDeviceIDs = orderedDeviceIDs(deviceIDs, preferAfter: preferAfterDeviceID)

        var lastConnectRejection: USBMuxError?

        for (index, deviceID) in candidateDeviceIDs.enumerated() {
            do {
                let fd = try connectToDevice(deviceID: deviceID, on: port, tag: tag &+ UInt32(index) &+ 1)
                return OpenTunnelResult(fd: fd, deviceID: deviceID)
            } catch let error as USBMuxError {
                if case .connectRejected = error {
                    lastConnectRejection = error
                    continue
                }
                throw error
            }
        }

        if let lastConnectRejection {
            throw lastConnectRejection
        }

        throw USBMuxError.noDevice
    }

    private static func attachedDeviceIDs(tag: UInt32) throws -> [Int] {
        let fd = try connectToUSBMuxSocket()

        defer { closeSocket(fd) }

        try sendPlist(
            [
                "BundleID": "com.keyd.agent",
                "ClientVersionString": "keyd-1.0",
                "MessageType": "ListDevices",
                "ProgName": "KeydAgent",
                "kLibUSBMuxVersion": 3
            ],
            tag: tag,
            to: fd
        )

        let response = try readPlist(from: fd)
        guard let devices = response["DeviceList"] as? [[String: Any]] else {
            throw USBMuxError.invalidResponse
        }

        var ids: [Int] = []

        for device in devices {
            let properties = device["Properties"] as? [String: Any]
            let connectionType = (properties?["ConnectionType"] as? String)
                ?? (device["ConnectionType"] as? String)

            if let connectionType, connectionType != "USB" {
                continue
            }

            if let id = (device["DeviceID"] as? NSNumber)?.intValue {
                ids.append(id)
            } else if let id = (properties?["DeviceID"] as? NSNumber)?.intValue {
                ids.append(id)
            }
        }

        guard !ids.isEmpty else {
            throw USBMuxError.noDevice
        }

        return ids
    }

    private static func orderedDeviceIDs(_ deviceIDs: [Int], preferAfter deviceID: Int?) -> [Int] {
        guard
            let deviceID,
            let currentIndex = deviceIDs.firstIndex(of: deviceID)
        else {
            return deviceIDs
        }

        let nextIndex = deviceIDs.index(after: currentIndex)
        guard nextIndex != deviceIDs.endIndex else {
            return deviceIDs
        }

        return Array(deviceIDs[nextIndex...]) + Array(deviceIDs[..<nextIndex])
    }

    private static func connectToDevice(deviceID: Int, on port: UInt16, tag: UInt32) throws -> Int32 {
        let fd = try connectToUSBMuxSocket()

        do {
            try sendPlist(
                [
                    "BundleID": "com.keyd.agent",
                    "ClientVersionString": "keyd-1.0",
                    "DeviceID": deviceID,
                    "MessageType": "Connect",
                    "PortNumber": Int(port.bigEndian),
                    "ProgName": "KeydAgent",
                    "kLibUSBMuxVersion": 3
                ],
                tag: tag,
                to: fd
            )

            let response = try readPlist(from: fd)
            let resultNumber = (response["Number"] as? NSNumber)?.intValue ?? -1
            guard resultNumber == 0 else {
                throw USBMuxError.connectRejected(resultNumber)
            }

            return fd
        } catch {
            closeSocket(fd)
            throw error
        }
    }

    private static func connectToUSBMuxSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count + 1 <= maxPathLength else {
            closeSocket(fd)
            throw USBMuxError.invalidSocketPath
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, addressLength)
            }
        }

        guard connectResult == 0 else {
            let connectError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            closeSocket(fd)
            throw connectError
        }

        return fd
    }

    private static func sendPlist(_ plist: [String: Any], tag: UInt32, to fd: Int32) throws {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        var frame = Data()
        append(UInt32(payload.count + headerLength), to: &frame)
        append(protocolVersion, to: &frame)
        append(plistMessageType, to: &frame)
        append(tag, to: &frame)
        frame.append(payload)

        try writeAll(fd: fd, data: frame)
    }

    private static func readPlist(from fd: Int32) throws -> [String: Any] {
        let header = try readExact(fd: fd, count: headerLength)
        let length = readUInt32(from: header, offset: 0)
        let messageType = readUInt32(from: header, offset: 8)

        guard length >= UInt32(headerLength), messageType == plistMessageType else {
            throw USBMuxError.invalidResponse
        }

        let payload = try readExact(fd: fd, count: Int(length) - headerLength)
        let plist = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)

        guard let dictionary = plist as? [String: Any] else {
            throw USBMuxError.invalidResponse
        }

        return dictionary
    }

    private static func readChunk(fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }

        if count > 0 {
            return Data(buffer.prefix(count))
        }

        if count == 0 {
            throw USBMuxError.connectionClosed
        }

        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func readExact(fd: Int32, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)

        while data.count < count {
            let remaining = count - data.count
            var buffer = [UInt8](repeating: 0, count: min(remaining, 4096))
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }

            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
                continue
            }

            if bytesRead == 0 {
                throw USBMuxError.connectionClosed
            }

            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return data
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let bytesWritten = try data.withUnsafeBytes { rawBuffer -> Int in
                let base = rawBuffer.baseAddress?.advanced(by: offset)
                let written = Darwin.write(fd, base, rawBuffer.count - offset)
                if written < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return written
            }

            offset += bytesWritten
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func closeSocket(_ fd: Int32) {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }
}

private enum USBMuxError: LocalizedError {
    case notConnected
    case noDevice
    case invalidResponse
    case invalidSocketPath
    case connectRejected(Int)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "USB tunnel is not connected."
        case .noDevice:
            return "No USB-connected iPhone was found."
        case .invalidResponse:
            return "usbmuxd returned an unexpected response."
        case .invalidSocketPath:
            return "The usbmuxd socket path is invalid."
        case .connectRejected(let code):
            return "usbmuxd rejected the connection request (\(code))."
        case .connectionClosed:
            return "The USB tunnel closed."
        }
    }
}
