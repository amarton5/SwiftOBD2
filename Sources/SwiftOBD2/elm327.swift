// MARK: - ELM327 Class Documentation

/// `Author`: Kemo Konteh
/// The `ELM327` class provides a comprehensive interface for interacting with an ELM327-compatible
/// OBD-II adapter. It handles adapter setup, vehicle connection, protocol detection, and
/// communication with the vehicle's ECU.
///
/// **Key Responsibilities:**
/// * Manages communication with a BLE OBD-II adapter
/// * Automatically detects and establishes the appropriate OBD-II protocol
/// * Sends commands to the vehicle's ECU
/// * Parses and decodes responses from the ECU
/// * Retrieves vehicle information (e.g., VIN)
/// * Monitors vehicle status and retrieves diagnostic trouble codes (DTCs)

import Combine
import Foundation
import OSLog

class ELM327 {
    private var obdProtocol: PROTOCOL = .NONE
    var canProtocol: CANProtocol?

    //private let Logger.elm327 = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.com", category: "ELM327")
    private var comm: CommProtocol

    private var cancellables = Set<AnyCancellable>()

    weak var obdDelegate: OBDServiceDelegate? {
        didSet {
            comm.obdDelegate = obdDelegate
        }
    }

    var connectionState: ConnectionState = .disconnected {
        didSet {
            obdDelegate?.connectionStateChanged(state: connectionState)
        }
    }

    init(comm: CommProtocol) {
        self.comm = comm
        comm.connectionStatePublisher
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)
    }

//    func switchToDemoMode(_ isDemoMode: Bool) {
//        stopConnection()
//    }

    // MARK: - Adapter and Vehicle Setup

    /// Sets up the vehicle connection, including automatic protocol detection.
    /// - Parameter preferedProtocol: An optional preferred protocol to attempt first.
    /// - Returns: A tuple containing the established OBD protocol and the vehicle's VIN (if available).
    /// - Throws:
    ///     - `SetupError.noECUCharacteristic` if the required OBD characteristic is not found.
    ///     - `SetupError.invalidResponse(message: String)` if the adapter's response is unexpected.
    ///     - `SetupError.noProtocolFound` if no compatible protocol can be established.
    ///     - `SetupError.adapterInitFailed` if initialization of adapter failed.
    ///     - `SetupError.timeout` if a response times out.
    ///     - `SetupError.peripheralNotFound` if the peripheral could not be found.
    ///     - `SetupError.ignitionOff` if the vehicle's ignition is not on.
    ///     - `SetupError.invalidProtocol` if the protocol is not recognized.
    func setupVehicle(preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        var obdProtocol: PROTOCOL?

        if let desiredProtocol = preferedProtocol {
            do {
                obdProtocol = try await manualProtocolDetection(desiredProtocol: desiredProtocol)
            } catch {
                Logger.elm327.warning("Falling back to automatic protocol detection")
                obdProtocol = nil // Fallback to autoProtocol
            }
        }

        if obdProtocol == nil {
            obdProtocol = try await connectToVehicle(autoProtocol: true)
        }

        guard let obdProtocol = obdProtocol else {
            throw SetupError.noProtocolFound
        }

        self.obdProtocol = obdProtocol
        self.canProtocol = protocols[obdProtocol]

        let vin = await requestVin()

        // try await setHeader(header: ECUHeader.ENGINE)

        let supportedPIDs = await getSupportedPIDs()

        guard let messages = canProtocol?.parce(r100) else {
            throw SetupError.invalidResponse(message: "Invalid response to 0100")
        }

        let ecuMap = populateECUMap(messages)

        connectionState = .connectedToVehicle
        return OBDInfo(vin: vin, supportedPIDs: supportedPIDs, obdProtocol: obdProtocol, ecuMap: ecuMap)
    }

    /// Establishes a connection to the vehicle's ECU.
    /// - Parameter autoProtocol: Whether to attempt automatic protocol detection.
    /// - Returns: The established OBD protocol.
    func connectToVehicle(autoProtocol: Bool) async throws -> PROTOCOL? {
        if autoProtocol {
            guard let obdProtocol = try await autoProtocolDetection() else {
                Logger.elm327.error("No protocol found")
                throw SetupError.noProtocolFound
            }
            return obdProtocol
        } else {
            guard let obdProtocol = try await manualProtocolDetection(desiredProtocol: nil) else {
                Logger.elm327.error("No protocol found")
                throw SetupError.noProtocolFound
            }
            return obdProtocol
        }
    }

    // MARK: - Protocol Selection

    /// Attempts to detect the OBD protocol automatically.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func autoProtocolDetection() async throws -> PROTOCOL? {
        _ = try await okResponse(message: "ATSP0")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        Logger.elm327.log("Sending command `0100` with timeout: 20 sec")
        _ = try await sendCommand("0100", withTimeoutSecs: 20)

        let obdProtocolNumber = try await sendCommand("ATDPN")
        Logger.elm327.log("Attempting to retrieve protocol by number: \(obdProtocolNumber)")
        guard let obdProtocol = PROTOCOL(rawValue: String(obdProtocolNumber[0].dropFirst())) else {
            Logger.elm327.critical("Invalid protocol number: \(obdProtocolNumber)")
            throw SetupError.invalidResponse(message: "Invalid protocol number: \(obdProtocolNumber)")
        }

        try await testProtocol(obdProtocol: obdProtocol)

        return obdProtocol
    }

    /// Attempts to detect the OBD protocol manually.
    /// - Parameter desiredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func manualProtocolDetection(desiredProtocol: PROTOCOL?) async throws -> PROTOCOL? {
        if let desiredProtocol = desiredProtocol {
            try? await testProtocol(obdProtocol: desiredProtocol)
            return desiredProtocol
        }
        while obdProtocol != .NONE {
            do {
                try await testProtocol(obdProtocol: obdProtocol)
                return obdProtocol /// Exit the loop if the protocol is found successfully
            } catch {
                // Other errors are propagated
                obdProtocol = obdProtocol.nextProtocol()
            }
        }
        /// If we reach this point, no protocol was found
        Logger.elm327.error("No protocol found")
        throw SetupError.noProtocolFound
    }

    // MARK: - Protocol Testing

    private var r100: [String] = []

    /// Tests a given protocol by sending a 0100 command and checking for a valid response.
    /// - Parameter obdProtocol: The protocol to test.
    /// - Throws: Various setup-related errors.
    private func testProtocol(obdProtocol: PROTOCOL) async throws {
        // test protocol by sending 0100 and checking for 41 00 response
        Logger.elm327.log("test protocol by sending 0100 and checking for 41 00 response")
        _ = try await okResponse(message: obdProtocol.cmd)

//        _ = try await sendCommand("0100", withTimeoutSecs: 10)
        let r100 = try await sendCommand("0100", withTimeoutSecs: 10)

        if r100.joined().contains("NO DATA") {
            throw SetupError.ignitionOff
        }
        self.r100 = r100

        guard r100.joined().contains("41 00") else {
            Logger.elm327.error("Invalid response to 0100")
            throw SetupError.invalidProtocol
        }

        Logger.elm327.log("Protocol \(obdProtocol.rawValue) found")
    }

    // MARK: - Adapter Initialization

    func connectToAdapter(timeout: TimeInterval) async throws {
        try await comm.connectAsync(timeout: timeout)
    }

    /// Initializes the adapter by sending a series of commands.
    /// - Parameter setupOrder: A list of commands to send in order.
    /// - Throws: Various setup-related errors.
    func adapterInitialization(setupOrder: [OBDCommand.General] = [.ATZ, .ATD, .ATL0, .ATE0, .ATH1, .ATAT1, .ATRV, .ATDPN]) async throws {
        for step in setupOrder {
            //Logger.elm327.log("Init adapter by setup: \(step.properties.command.debugDescription)")
            switch step {
            case .ATD, .ATL0, .ATE0, .ATH1, .ATAT1, .ATSTFF, .ATH0:
                _ = try await okResponse(message: step.properties.command)
            case .ATZ:
                _ = try await sendCommand(step.properties.command)
            case .ATRV:
                /// get the voltage
                _ = try await sendCommand(step.properties.command)
            case .ATDPN:
                /// Describe current protocol number
                let protocolNumber = try await sendCommand(step.properties.command)
                obdProtocol = PROTOCOL(rawValue: protocolNumber[0]) ?? .protocol9
            }
        }
    }

    private func setHeader(header: String) async throws {
        _ = try await okResponse(message: "AT SH " + header)
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
    }

    // MARK: - Message Sending

    func sendCommand(_ message: String, withTimeoutSecs _: TimeInterval = 5) async throws -> [String] {
        return try await comm.sendCommand(message)
    }

    private func okResponse(message: String) async throws -> [String] {
        let response = try await sendCommand(message)
        if response.contains("OK") {
            return response
        } else {
            print("Invalid response: \(response)")
            Logger.elm327.error("Invalid response: \(response)")
            throw SetupError.invalidResponse(message: "message: \(message), \(String(describing: response.first))")
        }
    }

    func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        Logger.elm327.info("Getting status")
        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendCommand(statusCommand.properties.command)
        Logger.elm327.debug("Status response: \(statusResponse)")
        guard let statusData = canProtocol?.parce(statusResponse).first?.data else {
            return .failure(.noData)
        }
        return statusCommand.properties.decode(data: statusData)
    }

    func scanForTroubleCodes() async throws -> [ECUID:[TroubleCode]] {
        var dtcs: [ECUID:[TroubleCode]]  = [:]
        Logger.elm327.info("Scanning for trouble codes")
        let dtcCommand = OBDCommand.Mode3.GET_DTC
        let dtcResponse = try await sendCommand(dtcCommand.properties.command)

        guard let messages = canProtocol?.parce(dtcResponse) else {
            return [:]
        }
        for message in messages {
            guard let dtcData = message.data else {
                continue
            }
            let decodedResult = dtcCommand.properties.decode(data: dtcData)

            let ecuId = message.ecu
            switch decodedResult {
            case .success(let result):
                dtcs[ecuId] = result.troubleCode

            case .failure(let error):
                Logger.elm327.error("Failed to decode DTC: \(error)")
            }
        }

        return dtcs
    }

    func clearTroubleCodes() async throws {
        let command = OBDCommand.Mode4.CLEAR_DTC
        _ = try await sendCommand(command.properties.command)
    }

    func requestVin() async -> String? {
        let command = OBDCommand.Mode9.VIN
        guard let vinResponse = try? await sendCommand(command.properties.command) else {
            return nil
        }


        guard let data = canProtocol?.parce(vinResponse).first?.data,
              var vinString = String(bytes: data, encoding: .utf8)
        else {
            return nil
        }

        vinString = vinString
            .replacingOccurrences(of: "[^a-zA-Z0-9]",
                                  with: "",
                                  options: .regularExpression)

        return vinString
    }
}

extension ELM327 {
    private func populateECUMap(_ messages: [MessageProtocol]) -> [UInt8: ECUID]? {
        let engineTXID = 0
        let transmissionTXID = 1
        var ecuMap: [UInt8: ECUID] = [:]

        // If there are no messages, return an empty map
        guard !messages.isEmpty else {
            return nil
        }

        // If there is only one message, assume it's from the engine
        if messages.count == 1 {
            ecuMap[messages.first?.ecu.rawValue ?? 0] = .engine
            return ecuMap
        }

        // Find the engine and transmission ECU based on TXID
        var foundEngine = false

        for message in messages {
            let txID = message.ecu.rawValue

            if txID == engineTXID {
                ecuMap[txID] = .engine
                foundEngine = true
            } else if txID == transmissionTXID {
                ecuMap[txID] = .transmission
            }
        }

        // If engine ECU is not found, choose the one with the most bits
        if !foundEngine {
            var bestBits = 0
            var bestTXID: UInt8?

            for message in messages {
                guard let bits = message.data?.bitCount() else {
                    Logger.elm327.error("parse_frame failed to extract data")
                    continue
                }
                if bits > bestBits {
                    bestBits = bits
                    bestTXID = message.ecu.rawValue
                }
            }

            if let bestTXID = bestTXID {
                ecuMap[bestTXID] = .engine
            }
        }

        // Assign transmission ECU to messages without an ECU assignment
        for message in messages where ecuMap[message.ecu.rawValue ?? 0] == nil {
            ecuMap[message.ecu.rawValue ?? 0] = .transmission
        }

        return ecuMap
    }
}

extension ELM327 {
    /// Get the supported PIDs
    /// - Returns: Array of supported PIDs
    func getSupportedPIDs() async -> [OBDCommand] {
        let pidGetters = OBDCommand.pidGetters
        var supportedPIDs: [OBDCommand] = []

        for pidGetter in pidGetters {
            do {
                Logger.elm327.info("Getting supported PIDs for \(pidGetter.properties.command)")
                let response = try await sendCommand(pidGetter.properties.command)
                // find first instance of 41 plus command sent, from there we determine the position of everything else
                // Ex.
                //        || ||
                // 7E8 06 41 00 BE 7F B8 13
                guard let supportedPidsByECU = try? parseResponse(response) else {
                    continue
                }

                let supportedCommands = OBDCommand.allCommands
                    .filter { supportedPidsByECU.contains(String($0.properties.command.dropFirst(2))) }
                    .map { $0 }

                supportedPIDs.append(contentsOf: supportedCommands)
            } catch {
                Logger.elm327.error("\(error.localizedDescription)")
            }
        }
        // filter out pidGetters
        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }

        // remove duplicates
        return Array(Set(supportedPIDs))
    }

    private func parseResponse(_ response: [String]) -> Set<String>? {
        guard let ecuData = canProtocol?.parce(response).first?.data else {
            return nil
        }
        let binaryData = BitArray(data: ecuData.dropFirst()).binaryArray
        return extractSupportedPIDs(binaryData)
    }

    func extractSupportedPIDs(_ binaryData: [Int]) -> Set<String> {
        var supportedPIDs: Set<String> = []

        for (index, value) in binaryData.enumerated() {
            if value == 1 {
                let pid = String(format: "%02X", index + 1)
                supportedPIDs.insert(pid)
            }
        }
        return supportedPIDs
    }
}

struct BatchedResponse {
    private var response: Data
    private var unit: MeasurementUnit
    init(response: Data, unit: MeasurementUnit) {
        self.response = response
        self.unit = unit
    }

    mutating func extractValue(_ cmd: OBDCommand) -> MeasurementResult? {
        let properties = cmd.properties
        let size = properties.bytes
        guard response.count >= size else { return nil }
        let valueData = response.prefix(size)

        response.removeFirst(size)
        //        print("Buffer: \(buffer.compactMap { String(format: "%02X ", $0) }.joined())")
        let result = cmd.properties.decode(data: valueData, unit: unit)

        switch result {
            case .success(let measurementResult):
                return measurementResult.measurementResult
        case .failure(let error):
            Logger.elm327.error("Failed to decode \(cmd.properties.command): \(error.localizedDescription)")
            return nil
        }
    }
}

extension String {
    var hexBytes: [UInt8] {
        var position = startIndex
        return (0 ..< count / 2).compactMap { _ in
            defer { position = index(position, offsetBy: 2) }
            return UInt8(self[position ... index(after: position)], radix: 16)
        }
    }

    var isHex: Bool {
        return !isEmpty && allSatisfy { $0.isHexDigit }
    }
}

extension Data {
    func bitCount() -> Int {
        return count * 8
    }
}

enum ECUHeader {
    static let ENGINE = "7E0"
}

// Possible setup errors
enum SetupError: Error {
    case noECUCharacteristic
    case invalidResponse(message: String)
    case noProtocolFound
    case adapterInitFailed
    case timeout
    case peripheralNotFound
    case ignitionOff
    case invalidProtocol
}

public struct OBDInfo: Codable, Hashable {
    public var vin: String?
    public var supportedPIDs: [OBDCommand]?
    public var obdProtocol: PROTOCOL?
    public var ecuMap: [UInt8: ECUID]?
}
