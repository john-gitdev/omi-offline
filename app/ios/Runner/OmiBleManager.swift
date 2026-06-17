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

    // Native storage file download (mirrors Android OmiBleManager.downloadStorageFile).
    static let storageServiceUuid = CBUUID(string: "30295780-4301-eabd-2904-2849adfeae43")
    static let storageCharUuid = CBUUID(string: "30295781-4301-eabd-2904-2849adfeae43")
    static let maxProtocolGapBytes: Int64 = 8 * 1024 * 1024
    private var activeDownloads: [String: StorageDownloadSession] = [:]

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

    // ── Native storage file download ──
    // Whole-file transfer in native code (mirrors Android downloadStorageFile):
    // CMD_READ_FILE → notification stream parsed in StorageDownloadSession → written
    // straight to outputPath, so the bulk data never crosses the Flutter channel per
    // packet. Dart polls the output file length for progress and awaits this
    // completion (EOT → success, disconnect/stall/error-ACK → failure).
    func downloadStorageFile(
        peripheralUuid: String,
        fileIndex: Int,
        offset: Int64,
        timerStart: Int64,
        outputPath: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let peripheral = peripherals[peripheralUuid], peripheral.state == .connected else {
            completion(.failure(PigeonError(code: "NOT_CONNECTED", message: "Not connected", details: nil)))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == OmiBleManager.storageServiceUuid }),
              let characteristic = service.characteristics?.first(where: { $0.uuid == OmiBleManager.storageCharUuid })
        else {
            completion(.failure(PigeonError(code: "NOT_FOUND", message: "Storage characteristic not found", details: nil)))
            return
        }

        // Subscribe so the notification stream fires. CoreBluetooth processes this CCCD
        // write before the CMD_READ_FILE write below (FIFO), and the firmware only starts
        // notifying after it receives the read command — so no start-ACK can be missed.
        peripheral.setNotifyValue(true, for: characteristic)

        // Register the session BEFORE writing CMD_READ_FILE so didUpdateValueFor routes
        // the very first packet to it.
        let session: StorageDownloadSession
        do {
            session = try StorageDownloadSession(
                startOffset: offset,
                outputPath: outputPath,
                completion: completion,
                onSettled: { [weak self] in self?.activeDownloads.removeValue(forKey: peripheralUuid) })
        } catch {
            completion(.failure(PigeonError(code: "FILE_OPEN_FAILED", message: "\(error)", details: nil)))
            return
        }
        activeDownloads[peripheralUuid] = session

        // CMD_READ_FILE: [0x11, fileIndex, offset(4B LE), timerStart(4B LE)]
        var cmd = Data(count: 10)
        cmd[0] = 0x11
        cmd[1] = UInt8(truncatingIfNeeded: fileIndex)
        let off = UInt32(truncatingIfNeeded: offset)
        cmd[2] = UInt8(off & 0xFF); cmd[3] = UInt8((off >> 8) & 0xFF)
        cmd[4] = UInt8((off >> 16) & 0xFF); cmd[5] = UInt8((off >> 24) & 0xFF)
        let ts = UInt32(truncatingIfNeeded: timerStart)
        cmd[6] = UInt8(ts & 0xFF); cmd[7] = UInt8((ts >> 8) & 0xFF)
        cmd[8] = UInt8((ts >> 16) & 0xFF); cmd[9] = UInt8((ts >> 24) & 0xFF)

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(cmd, for: characteristic, type: writeType)
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
        // Fail any in-flight native download — the link dropped mid-transfer.
        activeDownloads.removeValue(forKey: uuid)?.fail(
            PigeonError(code: "DISCONNECTED", message: "Stream closed without EOT", details: nil))
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
        // Route storage-data-stream notifications to an active native download session —
        // written straight to file, never forwarded to Dart (mirrors Android). When no
        // download is active the storage char still forwards to Dart (e.g. listFiles).
        if c.uuid == OmiBleManager.storageCharUuid, let session = activeDownloads[uuid] {
            if let data = c.value, !data.isEmpty { session.onPacket(data) }
            return
        }
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

/// Native SD-card file download session (iOS mirror of the Android
/// StorageDownloadSession). Parses the storage notification stream and writes
/// straight to a file, so the bulk transfer never crosses the Flutter channel.
///
/// Packet framing on the storage characteristic:
///   0x03 <code>            ACK (code 0 = start ok; non-zero = error)
///   0x01 <off 4B LE> <...>  DATA chunk at absolute file offset
///   0x02                   EOT (transfer complete)
final class StorageDownloadSession {
    private var expectedOffset: Int64
    private let fileHandle: FileHandle
    private var completed = false
    private var hasReceivedStartAck = false
    private let completion: (Result<Void, Error>) -> Void
    private let onSettled: () -> Void

    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "com.omi.ble.download.timeout")
    private var timeoutTimer: DispatchSourceTimer?
    private var lastActivity: UInt64 = 0
    private static let inactivityTimeoutNs: UInt64 = 15_000_000_000 // 15 s

    init(startOffset: Int64,
         outputPath: String,
         completion: @escaping (Result<Void, Error>) -> Void,
         onSettled: @escaping () -> Void) throws {
        self.expectedOffset = startOffset
        self.completion = completion
        self.onSettled = onSettled

        let fm = FileManager.default
        let dir = (outputPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        // Fresh file when starting at 0; on resume the Dart side has already truncated
        // the file to `startOffset`, so keep it and append. Create it if missing.
        if startOffset <= 0 || !fm.fileExists(atPath: outputPath) {
            fm.createFile(atPath: outputPath, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: outputPath) else {
            throw PigeonError(code: "FILE_OPEN_FAILED", message: "Cannot open \(outputPath)", details: nil)
        }
        self.fileHandle = fh
        if startOffset > 0 {
            _ = try? fh.seekToEnd()
        } else {
            try? fh.truncate(atOffset: 0)
        }

        lastActivity = DispatchTime.now().uptimeNanoseconds
        startTimeoutTimer()
    }

    private func startTimeoutTimer() {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let done = self.completed
            let last = self.lastActivity
            self.lock.unlock()
            if done { return }
            if DispatchTime.now().uptimeNanoseconds &- last > StorageDownloadSession.inactivityTimeoutNs {
                self.fail(PigeonError(code: "TIMEOUT", message: "Transfer stalled: 15s inactivity timeout", details: nil))
            }
        }
        t.resume()
        timeoutTimer = t
    }

    /// Feed one notification packet. Called on the CoreBluetooth (main) queue.
    func onPacket(_ value: Data) {
        lock.lock()
        if completed { lock.unlock(); return }
        let bytes = [UInt8](value)
        if bytes.isEmpty { lock.unlock(); return }
        lastActivity = DispatchTime.now().uptimeNanoseconds

        var settle: Result<Void, Error>?
        switch bytes[0] {
        case 0x03: // ACK
            if bytes.count >= 2 {
                if bytes[1] == 0 { hasReceivedStartAck = true } else {
                    settle = .failure(PigeonError(code: "ACK_ERROR", message: "Error ACK: \(bytes[1])", details: nil))
                }
            }
        case 0x01: // DATA
            if hasReceivedStartAck && bytes.count >= 5 {
                do { try handleData(bytes) } catch { settle = .failure(error) }
            }
        case 0x02: // EOT
            settle = .success(())
        default:
            break
        }

        if let result = settle {
            finishLocked(result)
        } else {
            lock.unlock()
        }
    }

    private func handleData(_ bytes: [UInt8]) throws {
        let incoming = Int64(bytes[1]) | (Int64(bytes[2]) << 8) | (Int64(bytes[3]) << 16) | (Int64(bytes[4]) << 24)
        let payload = Data(bytes[5...])
        if incoming > expectedOffset {
            let gap = incoming - expectedOffset
            if gap > OmiBleManager.maxProtocolGapBytes {
                throw PigeonError(code: "PROTOCOL_GAP",
                                  message: "Protocol gap too large: incoming=\(incoming) expected=\(expectedOffset)",
                                  details: nil)
            }
            try fileHandle.write(contentsOf: Data(count: Int(gap))) // pad
            expectedOffset += gap
            try fileHandle.write(contentsOf: payload)
            expectedOffset += Int64(payload.count)
        } else if incoming < expectedOffset {
            let skip = Int(expectedOffset - incoming)
            if skip < payload.count {
                let tail = payload.subdata(in: skip..<payload.count)
                try fileHandle.write(contentsOf: tail)
                expectedOffset += Int64(tail.count)
            }
        } else {
            try fileHandle.write(contentsOf: payload)
            expectedOffset += Int64(payload.count)
        }
    }

    /// Fail from outside the packet path (disconnect, inactivity timeout).
    func fail(_ error: Error) {
        lock.lock()
        if completed { lock.unlock(); return }
        finishLocked(.failure(error))
    }

    // Must be called with `lock` held; releases it.
    private func finishLocked(_ result: Result<Void, Error>) {
        completed = true
        timeoutTimer?.cancel()
        timeoutTimer = nil
        try? fileHandle.close()
        lock.unlock()
        // Settle on main: onSettled mutates OmiBleManager.activeDownloads (main-queue
        // state) and completion is the Pigeon callback (expects the platform thread).
        DispatchQueue.main.async {
            self.onSettled()
            self.completion(result)
        }
    }
}
