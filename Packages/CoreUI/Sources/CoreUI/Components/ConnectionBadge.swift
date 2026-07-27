import CoreDomain
import SwiftUI

/// Connection state for the OBD adapter / vehicle link.
/// Mirrors the Android dashboard status badge: Connected (green), Connecting
/// (amber), Error / Offline (red).
public enum ConnectionState: String, Sendable {
    case connected = "Connected"
    case scanning = "Scanning"
    case connecting = "Connecting"
    case initializing = "Starting"
    case error = "Error"
    case offline = "Offline"

    public var color: Color {
        switch self {
        case .connected: return .greenOk
        case .scanning, .connecting, .initializing: return .amberWarn
        case .error, .offline: return .redAlert
        }
    }

    /// Maps the OBD stack's state onto the badge vocabulary, so every surface
    /// (dashboard, settings, CarPlay) labels the link identically.
    public init(_ obd: ObdConnectionState) {
        switch obd {
        case .connected: self = .connected
        case .scanning: self = .scanning
        case .connecting: self = .connecting
        case .initializing: self = .initializing
        case .error: self = .error
        case .disconnected: self = .offline
        }
    }
}

/// A compact pill badge showing the current connection state with a colored
/// status dot. Used on the dashboard header.
public struct ConnectionBadge: View {
    private let state: ConnectionState

    public init(state: ConnectionState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.rawValue)
                .font(.ioniqCaption.weight(.medium))
                .foregroundStyle(Color.onSurface)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.surfaceNavy)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection: \(state.rawValue)")
    }
}

#Preview {
    VStack(spacing: 12) {
        ConnectionBadge(state: .connected)
        ConnectionBadge(state: .connecting)
        ConnectionBadge(state: .error)
        ConnectionBadge(state: .offline)
    }
    .padding()
    .background(Color.deepNavy)
    .preferredColorScheme(.dark)
}
