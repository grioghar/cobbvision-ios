#if os(iOS)
import Foundation
import CoreBluetooth
import CVCore

/// Discovers GoPro cameras advertising the FEA6 service. Hand the discovered
/// peripherals to `GoProController` for pairing/commands; register those with
/// `ExternalCameraGroup`.
public final class GoProScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public struct Discovered: Sendable, Identifiable {
        public let id: UUID
        public let name: String
    }

    private let queue = DispatchQueue(label: "co.grio.cobbvision.gopro.scan")
    private var central: CBCentralManager!
    private let lock = NSLock()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var continuation: AsyncStream<Discovered>.Continuation?
    private var shouldScanWhenReady = false

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Streams discovered GoPros; keeps scanning until the stream is dropped.
    public func discoveries() -> AsyncStream<Discovered> {
        AsyncStream { continuation in
            lock.withLock {
                self.continuation = continuation
                self.shouldScanWhenReady = true
            }
            startScanIfReady()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    self.continuation = nil
                    self.shouldScanWhenReady = false
                }
                self.central.stopScan()
            }
        }
    }

    public func makeController(for discovered: Discovered) -> GoProController? {
        guard let peripheral = lock.withLock({ peripherals[discovered.id] }) else { return nil }
        return GoProController(central: central, peripheral: peripheral, name: discovered.name)
    }

    private func startScanIfReady() {
        guard central.state == .poweredOn, lock.withLock({ shouldScanWhenReady }) else { return }
        central.scanForPeripherals(
            withServices: [CBUUID(string: OpenGoPro.advertisedServiceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        startScanIfReady()
    }

    // Connection lifecycle events arrive on the central's delegate (this
    // scanner) — relay them to the peripheral's controller.
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        (peripheral.delegate as? GoProController)?.handleConnected()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        (peripheral.delegate as? GoProController)?.handleConnectFailure(error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        (peripheral.delegate as? GoProController)?.handleConnectFailure(
            error ?? ExternalCamError.notConnected
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "GoPro"
        let isNew = lock.withLock { peripherals.updateValue(peripheral, forKey: peripheral.identifier) == nil }
        if isNew {
            lock.withLock { continuation }?.yield(Discovered(id: peripheral.identifier, name: name))
        }
    }
}

/// One GoPro over BLE (Open GoPro spec). Commands are fire-and-forget writes
/// to the command characteristic with a response notification; a keep-alive
/// setting write every 3 s stops the camera from dropping the link.
public final class GoProController: NSObject, CameraController, CBPeripheralDelegate, @unchecked Sendable {
    public let info: ExternalCameraInfo

    private let central: CBCentralManager
    private let peripheral: CBPeripheral
    private let lock = NSLock()

    private var commandChar: CBCharacteristic?
    private var settingsChar: CBCharacteristic?
    private var responseChar: CBCharacteristic?
    private var phase: ExternalCamStatus.Phase = .disconnected
    private var detail: String?
    private var keepAliveTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingCommandContinuation: CheckedContinuation<Void, Error>?

    init(central: CBCentralManager, peripheral: CBPeripheral, name: String) {
        self.central = central
        self.peripheral = peripheral
        self.info = ExternalCameraInfo(
            id: peripheral.identifier.uuidString,
            vendor: .gopro,
            name: name
        )
        super.init()
        peripheral.delegate = self
    }

    // MARK: - CameraController

    public func connect() async throws {
        guard central.state == .poweredOn else { throw ExternalCamError.bluetoothUnavailable }
        setPhase(.connecting)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { connectContinuation = cont }
            central.connect(peripheral)
        }
        startKeepAlive()
        setPhase(.ready)
    }

    public func disconnect() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        central.cancelPeripheralConnection(peripheral)
        setPhase(.disconnected)
    }

    public func startRecording() async throws {
        try await sendCommand(OpenGoPro.Command.shutterOn)
        setPhase(.recording)
    }

    public func stopRecording() async throws {
        try await sendCommand(OpenGoPro.Command.shutterOff)
        setPhase(.ready)
    }

    public func setMode(_ mode: ExternalCamMode) async throws {
        try await sendCommand(OpenGoPro.Command.loadPresetGroup(mode))
    }

    public func currentStatus() async -> ExternalCamStatus {
        let (phase, detail) = lock.withLock { (self.phase, self.detail) }
        return ExternalCamStatus(id: info.id, vendor: .gopro, name: info.name, phase: phase, detail: detail)
    }

    // MARK: - BLE plumbing

    /// Called by GoProScanner's central delegate relay on connect events.
    func handleConnected() {
        peripheral.discoverServices([CBUUID(string: OpenGoPro.GATT.controlService)])
    }

    func handleConnectFailure(_ error: Error?) {
        let hadPendingConnect = lock.withLock { connectContinuation != nil }
        if hadPendingConnect {
            setPhase(.error, detail: error?.localizedDescription ?? "connect failed")
            resumeConnect(throwing: ExternalCamError.commandFailed(error?.localizedDescription ?? "connect failed"))
        } else {
            // Mid-session drop (camera slept, went out of range): fail any
            // in-flight command and report disconnected.
            setPhase(.disconnected, detail: error?.localizedDescription)
            resumeCommand(throwing: ExternalCamError.notConnected)
        }
    }

    private func sendCommand(_ packet: Data) async throws {
        let command = lock.withLock { commandChar }
        guard let command, peripheral.state == .connected else {
            throw ExternalCamError.notConnected
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let alreadyPending = lock.withLock { () -> Bool in
                guard pendingCommandContinuation == nil else { return true }
                pendingCommandContinuation = cont
                return false
            }
            if alreadyPending {
                cont.resume(throwing: ExternalCamError.commandFailed("command already in flight"))
                return
            }
            peripheral.writeValue(packet, for: command, type: .withResponse)
            // Response notification resolves it; a 4 s fallback prevents hangs.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.resumeCommand(throwing: ExternalCamError.timeout)
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let settings = self.lock.withLock { self.settingsChar }
                if let settings, self.peripheral.state == .connected {
                    self.peripheral.writeValue(OpenGoPro.Setting.keepAlive, for: settings, type: .withResponse)
                }
            }
        }
    }

    private func setPhase(_ phase: ExternalCamStatus.Phase, detail: String? = nil) {
        lock.withLock {
            self.phase = phase
            self.detail = detail
        }
    }

    private func resumeConnect(throwing error: Error? = nil) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let c = connectContinuation
            connectContinuation = nil
            return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }

    private func resumeCommand(throwing error: Error? = nil) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let c = pendingCommandContinuation
            pendingCommandContinuation = nil
            return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            handleConnectFailure(error)
            return
        }
        for service in services where service.uuid == CBUUID(string: OpenGoPro.GATT.controlService) {
            peripheral.discoverCharacteristics([
                CBUUID(string: OpenGoPro.GATT.commandCharacteristic),
                CBUUID(string: OpenGoPro.GATT.commandResponseCharacteristic),
                CBUUID(string: OpenGoPro.GATT.settingsCharacteristic),
            ], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            handleConnectFailure(error)
            return
        }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case CBUUID(string: OpenGoPro.GATT.commandCharacteristic):
                lock.withLock { commandChar = characteristic }
            case CBUUID(string: OpenGoPro.GATT.settingsCharacteristic):
                lock.withLock { settingsChar = characteristic }
            case CBUUID(string: OpenGoPro.GATT.commandResponseCharacteristic):
                lock.withLock { responseChar = characteristic }
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        let ready = lock.withLock { commandChar != nil && responseChar != nil }
        if ready {
            resumeConnect()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: OpenGoPro.GATT.commandResponseCharacteristic),
              let data = characteristic.value,
              let response = OpenGoPro.parseCommandResponse(data) else { return }
        if response.success {
            resumeCommand()
        } else {
            resumeCommand(throwing: ExternalCamError.commandFailed("camera rejected command 0x\(String(response.commandID, radix: 16))"))
        }
    }
}
#endif
