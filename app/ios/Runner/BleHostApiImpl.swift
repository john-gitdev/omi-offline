import Flutter
import UIKit

/// Bridges Pigeon BleHostApi calls to OmiBleManager.
final class BleHostApiImpl: BleHostApi {
    private let bleManager: OmiBleManager

    /// Background-execution assertion held while the VAD decode runs, so iOS
    /// doesn't suspend the app the instant it backgrounds mid-processing.
    private var processingBgTask: UIBackgroundTaskIdentifier = .invalid

    init(bleManager: OmiBleManager) {
        self.bleManager = bleManager
    }

    func startScan(timeout timeoutSeconds: Int64, serviceUuids: [String]) throws {
        bleManager.startScan(timeout: Int(timeoutSeconds), serviceUuids: serviceUuids)
    }

    func stopScan() throws {
        bleManager.stopScan()
    }

    func manageDevice(uuid: String, requiresBond: Bool) throws {
        bleManager.connectPeripheral(uuid: uuid)
    }

    func unmanageDevice(uuid: String) throws {
        bleManager.disconnectPeripheral(uuid: uuid)
    }

    func removeBond(uuid: String) throws {
        // iOS does not expose a programmatic API to remove an OS-level pairing/bond.
        // The user must "Forget This Device" from Settings > Bluetooth. No-op here so
        // the Dart forgetDevice path (which already ignores failures) stays cross-platform.
    }

    func disconnectPeripheral(uuid: String) throws {
        bleManager.disconnectPeripheral(uuid: uuid)
    }

    func requestBond(uuid: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        // iOS handles bonding automatically at the OS level when accessing an encrypted characteristic
        completion(.success(true))
    }

    func readCharacteristic(
        peripheralUuid: String,
        serviceUuid: String,
        characteristicUuid: String,
        completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
    ) {
        bleManager.readCharacteristic(
            peripheralUuid: peripheralUuid,
            serviceUuid: serviceUuid,
            characteristicUuid: characteristicUuid,
            completion: completion
        )
    }

    func writeCharacteristic(
        peripheralUuid: String,
        serviceUuid: String,
        characteristicUuid: String,
        data: FlutterStandardTypedData,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        bleManager.writeCharacteristic(
            peripheralUuid: peripheralUuid,
            serviceUuid: serviceUuid,
            characteristicUuid: characteristicUuid,
            data: data,
            completion: completion
        )
    }

    func subscribeCharacteristic(peripheralUuid: String, serviceUuid: String, characteristicUuid: String) throws {
        bleManager.subscribeCharacteristic(peripheralUuid: peripheralUuid, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    }

    func unsubscribeCharacteristic(peripheralUuid: String, serviceUuid: String, characteristicUuid: String) throws {
        bleManager.unsubscribeCharacteristic(peripheralUuid: peripheralUuid, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid)
    }

    func getBluetoothState() throws -> String {
        return bleManager.getBluetoothState()
    }

    func isPeripheralConnected(uuid: String) throws -> Bool {
        return bleManager.isPeripheralConnected(uuid: uuid)
    }

    func hasCompanionDeviceAssociation() throws -> Bool {
        return true // iOS uses state restoration
    }

    func requestCompanionDeviceAssociation(deviceAddress: String, completion: @escaping (Result<String, Error>) -> Void) {
        // No-op on iOS — state restoration handles background reconnection
        completion(.success(""))
    }

    func rescheduleBackgroundSync(intervalMinutes: Int64) throws {
        // iOS uses BGProcessingTask scheduled in AppDelegate — no-op here.
    }

    func downloadStorageFile(peripheralUuid: String, fileIndex: Int64, offset: Int64, timerStart: Int64, outputPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        bleManager.downloadStorageFile(
            peripheralUuid: peripheralUuid, fileIndex: Int(fileIndex), offset: offset,
            timerStart: timerStart, outputPath: outputPath, completion: completion)
    }

    func acquireProcessingWakeLock() throws {
        // iOS equivalent of Android's processing wakelock: request continued
        // background execution so the VAD decode isn't suspended the instant the
        // app backgrounds mid-run. iOS grants a bounded window (~30 s) and then
        // calls the expiration handler; longer decodes are covered by the
        // resumable _draft pipeline, which re-processes on the next wake. Must run
        // on the main thread (Pigeon dispatches host methods there).
        guard processingBgTask == .invalid else { return }
        processingBgTask = UIApplication.shared.beginBackgroundTask(withName: "omi.processing") { [weak self] in
            // iOS is reclaiming the window — we must end the task or it terminates us.
            self?.endProcessingBgTask()
        }
    }

    func releaseProcessingWakeLock() throws {
        endProcessingBgTask()
    }

    private func endProcessingBgTask() {
        guard processingBgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(processingBgTask)
        processingBgTask = .invalid
    }

    func setNextSyncTime(timestampMs: Int64) throws {
        // Android-only (drives the native foreground-service notification) — no-op on iOS.
    }

    func setDeviceBattery(level: Int64, timestampMs: Int64) throws {
        // Android-only — no-op on iOS.
    }

    func setSyncStatus(title: String, text: String) throws {
        // Android-only single-notification state machine — iOS has no persistent
        // notification (background work runs via BGProcessingTask).
    }

    func setPersistentNotification(enabled: Bool) throws {
        // Android-only — no-op on iOS.
    }

    func clearSyncStatus() throws {
        // Android-only — no-op on iOS.
    }
}
