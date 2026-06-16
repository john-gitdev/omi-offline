import CoreBluetooth
import Flutter

/// Native CoreBluetooth manager that handles BLE lifecycle, state restoration,
/// reconnection, and service discovery.
///
/// Replaces separate connection/discovery events with a single onDeviceReady signal.
final class OmiBleManager: NSObject {
    static let shared = OmiBleManager()
    static let restoreIdentifier = "com.omi.ble.restore"

    private var centralManager: CBCentralManager!
    private(set) var flutterApi: BleFlutterApi?

    private var peripherals: [String: CBPeripheral] = [:]
    private var readCompletions: [String: (Result<FlutterStandardTypedData, Error>) -> Void] = [:]
    private var writeCompletions: [String: (Result<Void, Error>) -> Void] = [:]
    private var manuallyDisconnected: Set<String> = []
    private var connectionEstablishedAt: [String: Date] = [:]

    private var isScanning = false
    private var scanTimer: Timer?
    private var pendingScan: (timeout: Int, serviceUuids: [String])?
    private var rssiTimer: Timer?

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: OmiBleManager.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    func setFlutterApi(_ api: BleFlutterApi) {
        self.flutterApi = api
    }

    // ── Scanning ──

    func startScan(timeout: Int, serviceUuids: [String]) {
        guard centralManager.state == .poweredOn else {
            pendingScan = (timeout: timeout, serviceUuids: serviceUuids)
            return
        }
        pendingScan = nil
        let cbuuids: [CBUUID]? = serviceUuids.isEmpty ? nil : serviceUuids.map { CBUUID(string: $0) }
        
        // Report already connected peripherals that might not be advertising
        let connected = centralManager.retrieveConnectedPeripherals(withServices: cbuuids ?? [CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")])
        for p in connected {
            peripherals[p.identifier.uuidString] = p
            p.delegate = self
            let svcs = p.services?.map { fullUuid($0.uuid) } ?? []
            let bleP = BlePeripheral(uuid: p.identifier.uuidString, name: p.name ?? "", rssi: -50, serviceUuids: svcs)
            flutterApi?.onPeripheralDiscovered(peripheral: bleP) { _ in }
        }

        isScanning = true
        centralManager.scanForPeripherals(withServices: cbuuids, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        if timeout > 0 {
            scanTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout), repeats: false) { [weak self] _ in
                self?.stopScan()
            }
        }
    }

    func stopScan() {
        guard isScanning else { return }
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
        centralManager.stopScan()
    }

    // ── Connection ──

    func connectPeripheral(uuid: String) {
        manuallyDisconnected.remove(uuid)
        if let peripheral = peripherals[uuid] {
            if peripheral.state == .connected {
                // Already connected — ensure services are ready then fire onDeviceReady
                if peripheral.services != nil && peripheral.services!.allSatisfy({ $0.characteristics != nil }) {
                    fireReady(peripheral)
                } else {
                    peripheral.discoverServices(nil)
                }
                return
            }
            centralManager.connect(peripheral, options: nil)
            return
        }
        guard let cbUuid = UUID(uuidString: uuid) else { return }
        let retrieved = centralManager.retrievePeripherals(withIdentifiers: [cbUuid])
        if let peripheral = retrieved.first {
            peripheral.delegate = self
            peripherals[uuid] = peripheral
            centralManager.connect(peripheral, options: nil)
        }
    }

    func disconnectPeripheral(uuid: String) {
        manuallyDisconnected.insert(uuid)
        guard let peripheral = peripherals[uuid] else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func isPeripheralConnected(uuid: String) -> Bool {
        return peripherals[uuid]?.state == .connected
    }

    // ── Characteristic operations ──

    func readCharacteristic(
        peripheralUuid: String,
        serviceUuid: String,
        characteristicUuid: String,
        completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
    ) {
        guard let characteristic = findChar(uuid: peripheralUuid, svc: serviceUuid, char: characteristicUuid) else {
            completion(.failure(PigeonError(code: "NOT_FOUND", message: "Characteristic not found", details: nil)))
            return
        }
        let key = "\(peripheralUuid):\(serviceUuid):\(characteristicUuid)".lowercased()
        readCompletions[key] = completion
        peripherals[peripheralUuid]?.readValue(for: characteristic)
    }

    func writeCharacteristic(
        peripheralUuid: String,
        serviceUuid: String,
        characteristicUuid: String,
        data: FlutterStandardTypedData,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let characteristic = findChar(uuid: peripheralUuid, svc: serviceUuid, char: characteristicUuid) else {
            completion(.failure(PigeonError(code: "NOT_FOUND", message: "Characteristic not found", details: nil)))
            return
        }
        let key = "\(peripheralUuid):\(serviceUuid):\(characteristicUuid)".lowercased()
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withResponse {
            writeCompletions[key] = completion
        }
        peripherals[peripheralUuid]?.writeValue(data.data, for: characteristic, type: type)
        if type == .withoutResponse {
            completion(.success(()))
        }
    }

    func subscribeCharacteristic(peripheralUuid: String, serviceUuid: String, characteristicUuid: String) {
        guard let char = findChar(uuid: peripheralUuid, svc: serviceUuid, char: characteristicUuid) else { return }
        peripherals[peripheralUuid]?.setNotifyValue(true, for: char)
    }

    func unsubscribeCharacteristic(peripheralUuid: String, serviceUuid: String, characteristicUuid: String) {
        guard let char = findChar(uuid: peripheralUuid, svc: serviceUuid, char: characteristicUuid) else { return }
        peripherals[peripheralUuid]?.setNotifyValue(false, for: char)
    }

    func getBluetoothState() -> String {
        switch centralManager.state {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        default: return "unknown"
        }
    }

    private func findChar(uuid: String, svc: String, char: String) -> CBCharacteristic? {
        guard let peripheral = peripherals[uuid], let services = peripheral.services else { return nil }
        let sUuid = CBUUID(string: svc), cUuid = CBUUID(string: char)
        return services.first { $0.uuid == sUuid }?.characteristics?.first { $0.uuid == cUuid }
    }

    private func fullUuid(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString.lowercased()
        if s.count == 4 { return "0000\(s)-0000-1000-8000-00805f9b34fb" }
        return s
    }

    private func fireReady(_ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        let services = (peripheral.services ?? []).map { svc in
            BleService(uuid: fullUuid(svc.uuid), characteristicUuids: (svc.characteristics ?? []).map { fullUuid($0.uuid) })
        }
        flutterApi?.onDeviceReady(peripheralUuid: uuid, services: services) { _ in }
    }

    private func startRssiKeepAlive(for peripheral: CBPeripheral) {
        stopRssiKeepAlive()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak peripheral] _ in
            guard let p = peripheral, p.state == .connected else {
                self?.stopRssiKeepAlive()
                return
            }
            p.readRSSI()
        }
    }

    private func stopRssiKeepAlive() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }

    private func cleanupPeripheral(_ uuid: String) {
        stopRssiKeepAlive()
        let prefix = uuid.lowercased()
        readCompletions.keys.filter { $0.hasPrefix(prefix) }.forEach { readCompletions.removeValue(forKey: $0) }
        writeCompletions.keys.filter { $0.hasPrefix(prefix) }.forEach { writeCompletions.removeValue(forKey: $0) }
    }
}

extension OmiBleManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = getBluetoothState()
        flutterApi?.onBluetoothStateChanged(state: state) { _ in }
        if central.state == .poweredOn, let p = pendingScan {
            startScan(timeout: p.timeout, serviceUuids: p.serviceUuids)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            restored.forEach { p in
                p.delegate = self
                peripherals[p.identifier.uuidString] = p
                if p.state != .connected {
                    central.connect(p, options: nil)
                }
            }
            flutterApi?.onStateRestored(peripheralUuids: restored.map { $0.identifier.uuidString }) { _ in }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        peripherals[p.identifier.uuidString] = p
        p.delegate = self
        let svcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        // CBPeripheral.name is read from the GATT GAP characteristic and is usually nil
        // until after connection. The name the firmware advertises ("Omi") lives in the
        // advertisement's local-name field, so prefer that — otherwise the Dart-side
        // name.contains('omi') discovery filter never matches during a scan.
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let bleP = BlePeripheral(uuid: p.identifier.uuidString, name: advName, rssi: Int64(rssi.intValue), serviceUuids: svcs)
        flutterApi?.onPeripheralDiscovered(peripheral: bleP) { _ in }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        connectionEstablishedAt[p.identifier.uuidString] = Date()
        p.delegate = self
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let uuid = p.identifier.uuidString
        cleanupPeripheral(uuid)
        flutterApi?.onPeripheralDisconnected(peripheralUuid: uuid, error: error?.localizedDescription) { _ in }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let uuid = p.identifier.uuidString
        let connectedAt = connectionEstablishedAt.removeValue(forKey: uuid)
        cleanupPeripheral(uuid)
        flutterApi?.onPeripheralDisconnected(peripheralUuid: uuid, error: error?.localizedDescription) { _ in }
        if !manuallyDisconnected.contains(uuid) {
            // If the connection was very short-lived (< 5 s), it likely dropped during the
            // initial bonding handshake. Delay the reconnect so iOS has time to commit the
            // link key from the first pairing attempt — without this delay, the immediate
            // reconnect triggers a second Security Request and a duplicate pairing dialog.
            let uptime = connectedAt.map { Date().timeIntervalSince($0) } ?? Double.infinity
            let delay = uptime < 5.0 ? 2.0 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.manuallyDisconnected.contains(uuid) else { return }
                self.centralManager.connect(p, options: nil)
            }
        }
    }
}

extension OmiBleManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = p.services else { return }
        svcs.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        guard let svcs = p.services, svcs.allSatisfy({ $0.characteristics != nil }) else { return }
        fireReady(p)
        startRssiKeepAlive(for: p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let uuid = p.identifier.uuidString
        let key = "\(uuid):\(fullUuid(c.service!.uuid)):\(fullUuid(c.uuid))".lowercased()
        if let comp = readCompletions.removeValue(forKey: key) {
            if let error = error { comp(.failure(error)) }
            else { comp(.success(FlutterStandardTypedData(bytes: c.value ?? Data()))) }
            return
        }
        guard let data = c.value, !data.isEmpty else { return }
        flutterApi?.onCharacteristicValueUpdated(peripheralUuid: uuid, serviceUuid: fullUuid(c.service!.uuid), characteristicUuid: fullUuid(c.uuid), value: FlutterStandardTypedData(bytes: data)) { _ in }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        let key = "\(p.identifier.uuidString):\(fullUuid(c.service!.uuid)):\(fullUuid(c.uuid))".lowercased()
        if let comp = writeCompletions.removeValue(forKey: key) {
            if let error = error { comp(.failure(error)) } else { comp(.success(())) }
        }
    }
}
