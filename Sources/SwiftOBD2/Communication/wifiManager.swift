//
//  wifimanager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import Foundation
import Network
import OSLog

protocol CommProtocol {
    func sendCommand(_ command: String) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval) async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
}

enum CommunicationError: Error {
    case invalidData
    case errorOccurred(Error)
}

class WifiManager: CommProtocol {
    //let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "wifiManager")

    var obdDelegate: OBDServiceDelegate?

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    func connectAsync(timeout: TimeInterval) async throws {
        Logger.wifiMgr.log("[connectAsync] IP:PORT = 192.168.0.10:35000")
        let host = NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            Logger.wifiMgr.error("[connectAsync] Invalid data")
            throw CommunicationError.invalidData
        }
        tcp = NWConnection(host: host, port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcp?.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    //print("Connected")
                    Logger.wifiMgr.log("Connected")
                    self.connectionState = .connectedToAdapter
                    continuation.resume(returning: ())
                case let .waiting(error):
                    Logger.wifiMgr.error("Waiting: \(error.localizedDescription)")
                    //print("Waiting \(error)")
                case let .failed(error):
                    //print("Failed \(error)")
                    Logger.wifiMgr.error("Failed: \(error.localizedDescription)")
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                default:
                    break
                }
            }
            tcp?.start(queue: .main)
        }
    }

    func sendCommand(_ command: String) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            Logger.wifiMgr.error("[sendCommand] Invalid data")
            throw CommunicationError.invalidData
        }
        Logger.wifiMgr.log("Sending: \(command)")

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            self.tcp?.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    //print("Error sending data \(error)")
                    Logger.wifiMgr.error("Error sending data \(error)")
                    continuation.resume(throwing: error)
                }

                self.tcp?.receive(minimumIncompleteLength: 1, maximumLength: 500, completion: { data, _, _, _ in
                    guard let response = data, let string = String(data: response, encoding: .utf8) else {
                        Logger.wifiMgr.critical("[sendCommand] will return because response cannot be gathered or encoded")
                        return
                    }
                    if string.contains(">") {
                        Logger.wifiMgr.log("Received \(string)")
                        //print("Received \(string)")

                        var lines = string
                            .components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        lines.removeLast()

                        continuation.resume(returning: lines)
                    }
                })
            })
        }
    }

    func disconnectPeripheral() {
        tcp?.cancel()
    }
}
