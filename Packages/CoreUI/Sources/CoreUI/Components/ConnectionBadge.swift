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
        case .connected: return .appGreen
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

    public enum Style {
        /// Standalone pill with its own surface. For use inside content.
        case pill
        /// No background — for toolbars and other chrome that already supplies one,
        /// where a pill would read as a capsule inside a capsule.
        case plain
    }

    private let state: ConnectionState
    private let style: Style

    public init(state: ConnectionState, style: Style = .pill) {
        self.state = state
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.rawValue)
                .font(.ioniqCaption.weight(.medium))
                .foregroundStyle(Color.appOnSurface)
                .lineLimit(1)
        }
        .padding(.horizontal, style == .pill ? 10 : 8)
        .padding(.vertical, style == .pill ? 5 : 2)
        .background {
            if style == .pill {
                Capsule().fill(Color.appSurface)
            }
        }
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
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
