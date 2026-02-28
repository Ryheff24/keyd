import ActivityKit
import Foundation
import SwiftUI

/// ActivityKit attributes for the Keyd connection status Live Activity.
/// Used by both the main app (KeydLiveActivityManager) and the Widget Extension.
/// NOTE: This file is added to BOTH targets in project.yml.
struct KeydConnectionAttributes: ActivityAttributes {
    public typealias ContentState = KeydConnectionContentState

    /// Dynamic content (changes during activity lifetime)
    public struct KeydConnectionContentState: Codable, Hashable, Sendable {
        /// Current transport type
        var status: Status
        /// Round-trip latency in milliseconds (nil if unknown)
        var latencyMs: Int?

        enum Status: String, Codable, Hashable, Sendable {
            case usb          = "usb"
            case awdl         = "awdl"
            case connecting   = "connecting"
            case disconnected = "disconnected"

            var color: Color {
                switch self {
                case .usb:          return .green
                case .awdl:         return .yellow
                case .connecting:   return .orange
                case .disconnected: return .red
                }
            }
            var label: String {
                switch self {
                case .usb:          return "USB"
                case .awdl:         return "AWDL"
                case .connecting:   return "Connecting"
                case .disconnected: return "Disconnected"
                }
            }
            var shortLabel: String {
                switch self {
                case .usb:          return "USB"
                case .awdl:         return "AWDL"
                case .connecting:   return "..."
                case .disconnected: return "Off"
                }
            }
        }
    }
}
