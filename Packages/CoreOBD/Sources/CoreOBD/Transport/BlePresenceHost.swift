import CoreBluetooth
import Foundation

/// Launch-time owner of the app's `CBCentralManager`, and the piece that makes
/// unattended auto-connect work on iOS.
///
/// The Android side needs a Companion Device Manager association because a
/// background app may not start a foreground service; there is nothing for iOS to
/// *start*. Instead Core Bluetooth will hold an untimed `connect` on the app's
/// behalf, and if the app is terminated while that request is outstanding it
/// relaunches the app **in the background** to hand the link back. Both halves
/// share one requirement: the central manager must exist at launch, created with
/// `CBCentralManagerOptionRestoreIdentifierKey`, and it must be the delegate that
/// receives `centralManager(_:willRestoreState:)`.
///
/// That is why this type exists. `BleTransport` creates its manager lazily, on the
/// first connect attempt — far too late to be restoration-eligible, and it stops
/// existing the moment a session is torn down. The host owns the manager for the
/// whole process lifetime and forwards delegate callbacks to whichever transport is
/// live (`forward(to:)`), handling the parked case itself when none is: that is
/// when a link needs adopting rather than driving.
///
/// What iOS cannot do, unlike Android: there is no boot receiver and no process
/// restart after a user force-quit. A force-quit app stays dead until the user
/// opens it, and the Settings copy says so rather than promising otherwise.
public final class BlePresenceHost: NSObject, @unchecked Sendable {

    /// Must be stable across launches: iOS matches a relaunched process to the
    /// session it is restoring by this string.
    public static let restoreIdentifier = "com.fmz.ioniqtelemetry.central"

    /// A GATT link that completed without a transport driving it — a standing
    /// request that finished while the app was suspended, or a restored link from
    /// a background relaunch.
    ///
    /// `@unchecked Sendable` because `CBPeripheral` carries no Sendable
    /// annotation. The value is handed across exactly once, from the BLE queue to
    /// the main actor, and only that owner touches the peripheral afterwards.
    public struct AdapterLink: @unchecked Sendable {
        public let peripheral: CBPeripheral
        public let identifier: UUID
    }

    private let queue = DispatchQueue(label: "com.fmz.ioniqtelemetry.ble.presence", qos: .userInitiated)
    private let lock = NSLock()

    /// The app's only central manager. Also handed to `BleTransport`, so there is
    /// one Bluetooth session per process rather than one per connection attempt.
    public private(set) var central: CBCentralManager!

    /// The live transport, if any. Weak: the transport is owned by `ObdManager`.
    private weak var forwarding: CBCentralManagerDelegate?

    /// The adapter a standing request is armed for. Persisted nowhere — iOS keeps
    /// the request itself, and `AppServices` re-arms from the saved address on
    /// every launch.
    private var armedIdentifier: UUID?

    /// A link that arrived before the app finished wiring its handler up.
    /// `willRestoreState` is delivered within milliseconds of the manager being
    /// created, which is *before* the composition root can install a closure.
    private var pendingLink: AdapterLink?
    private var linkHandler: ((AdapterLink) -> Void)?
    private var stateHandler: ((CBManagerState) -> Void)?

    public override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Introspection

    public var state: CBManagerState { central?.state ?? .unknown }

    /// The adapter a standing request is currently armed for, if any.
    public var armed: UUID? { lock.withLock { armedIdentifier } }

    // MARK: - Handlers

    /// Installs the link handler. A link that arrived before this call is
    /// delivered immediately, so a background relaunch never loses the link it was
    /// relaunched for.
    public func setLinkHandler(_ handler: ((AdapterLink) -> Void)?) {
        let buffered: AdapterLink? = lock.withLock {
            linkHandler = handler
            let link = pendingLink
            pendingLink = nil
            return link
        }
        if let buffered { handler?(buffered) }
    }

    public func setStateHandler(_ handler: ((CBManagerState) -> Void)?) {
        lock.withLock { stateHandler = handler }
    }

    // MARK: - Delegate forwarding

    /// Routes the manager's callbacks to a live transport. While nothing is
    /// forwarded the host is the one that acts on them.
    public func forward(to delegate: CBCentralManagerDelegate) {
        lock.withLock { forwarding = delegate }
    }

    public func stopForwarding() {
        lock.withLock { forwarding = nil }
    }

    // MARK: - Arming

    /// Asks iOS to hold an untimed connect for `identifier`.
    ///
    /// There is no timeout and no retry loop here on purpose: a request for an
    /// adapter whose car is switched off simply stays pending, which costs nothing
    /// and is completed the moment the adapter powers up — whether or not this
    /// process is still alive by then.
    ///
    /// - Returns: true when the request was issued or queued for `poweredOn`.
    @discardableResult
    public func arm(identifier: UUID) -> Bool {
        lock.withLock { armedIdentifier = identifier }
        queue.async { [weak self] in self?.connectArmedPeripheral() }
        return true
    }

    /// Drops the standing request. Called when the user connects or disconnects by
    /// hand, and when the adapter is forgotten: someone who taps Disconnect should
    /// not be reconnected a minute later by a request they cannot see.
    public func disarm() {
        let identifier = lock.withLock { () -> UUID? in
            let id = armedIdentifier
            armedIdentifier = nil
            return id
        }
        guard let identifier else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for peripheral in self.central.retrievePeripherals(withIdentifiers: [identifier])
            where peripheral.state != .disconnected {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    // MARK: - Private

    /// Runs on `queue`.
    private func connectArmedPeripheral() {
        // Before `poweredOn` there is nothing to connect to; `centralManagerDidUpdateState`
        // calls back in here once the radio is ready.
        guard central.state == .poweredOn,
              let identifier = lock.withLock({ armedIdentifier }) else { return }

        guard let target = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            // iOS has never seen this identifier — the saved address belongs to a
            // different install or the adapter was replaced. Drop the request
            // rather than holding one that can never complete.
            lock.withLock { armedIdentifier = nil }
            return
        }
        // No peripheral delegate here: the host only needs the *central* callbacks
        // (didConnect / didDisconnect). Service discovery belongs to the transport
        // that adopts the link.
        if target.state != .connected {
            central.connect(target, options: nil)
        }
    }

    /// Hands a link to whoever wants to build a session on it, buffering it when
    /// no handler is installed yet.
    private func deliver(_ link: AdapterLink) {
        let handler: ((AdapterLink) -> Void)? = lock.withLock {
            guard linkHandler == nil else { return linkHandler }
            // Only the newest matters: a second restored link replaces a stale one
            // that no session ever picked up.
            pendingLink = link
            return nil
        }
        handler?(link)
    }

    /// Re-issues an armed request after the link dropped or failed. An adapter
    /// that is switched off leaves the request pending rather than failing, so this
    /// only runs for genuine failures and does not spin.
    private func reissueIfArmed(_ peripheral: CBPeripheral) {
        guard lock.withLock({ armedIdentifier == peripheral.identifier }) else { return }
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate

extension BlePresenceHost: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let (delegate, handler) = lock.withLock { (forwarding, stateHandler) }
        delegate?.centralManagerDidUpdateState(central)
        handler?(central.state)
        guard central.state == .poweredOn else { return }
        connectArmedPeripheral()
    }

    /// The app was relaunched in the background to service a connection.
    ///
    /// Deliberately never forwarded: a transport created moments ago has no
    /// context to adopt a link from a delegate callback, and the session rebuild
    /// has to go through `AppServices` (which knows the saved adapter, the profile
    /// and the trip pipeline) rather than through the transport layer.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            let link = AdapterLink(peripheral: peripheral, identifier: peripheral.identifier)
            if peripheral.state == .connected {
                // Fully restored: there is nothing left for iOS to do.
                lock.withLock { armedIdentifier = nil }
                deliver(link)
            } else {
                // Restored as a pending request. Keep it armed so the link is
                // completed whenever the adapter powers up, and let the same
                // delivery path take over if it is already reachable.
                lock.withLock { armedIdentifier = peripheral.identifier }
                if central.state == .poweredOn {
                    central.connect(peripheral, options: nil)
                }
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let delegate = lock.withLock { () -> CBCentralManagerDelegate? in
            // The link is up, so no standing request is outstanding any more.
            armedIdentifier = nil
            return forwarding
        }
        if let delegate {
            delegate.centralManager?(central, didConnect: peripheral)
            return
        }
        deliver(AdapterLink(peripheral: peripheral, identifier: peripheral.identifier))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let delegate = lock.withLock { forwarding }
        if let delegate {
            delegate.centralManager?(central, didFailToConnect: peripheral, error: error)
            return
        }
        reissueIfArmed(peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let delegate = lock.withLock { forwarding }
        if let delegate {
            delegate.centralManager?(central, didDisconnectPeripheral: peripheral, error: error)
            return
        }
        reissueIfArmed(peripheral)
    }
}
