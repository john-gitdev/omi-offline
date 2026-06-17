import UIKit
import Flutter
import UserNotifications
import AVFoundation
import Speech
import BackgroundTasks

extension FlutterError: Error {}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var methodChannel: FlutterMethodChannel?
  private var appleRemindersChannel: FlutterMethodChannel?
  private var appleHealthChannel: FlutterMethodChannel?
  private let appleRemindersService = AppleRemindersService()
  private let appleHealthService = AppleHealthService()
  private var notificationTitleOnKill: String?
  private var notificationBodyOnKill: String?
  private var vadBatchRunner: VadBatchRunner?

  fileprivate var aacEncoderSessions: [String: AacEncoderSession] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

      // Native BLE module — register Pigeon APIs
      NSLog("[OmiBle] Registering BLE Pigeon APIs")
      let bleController = window?.rootViewController as? FlutterViewController
      if let messenger = bleController?.binaryMessenger {
          let bleFlutterApi = BleFlutterApi(binaryMessenger: messenger)
          OmiBleManager.shared.setFlutterApi(bleFlutterApi)
          let bleHostApi = BleHostApiImpl(bleManager: OmiBleManager.shared)
          BleHostApiSetup.setUp(binaryMessenger: messenger, api: bleHostApi)
          NSLog("[OmiBle] BLE Pigeon APIs registered successfully")
      } else {
          NSLog("[OmiBle] ERROR: Could not get FlutterBinaryMessenger")
      }

    //Creates a method channel to handle notifications on kill
    let controller = window?.rootViewController as? FlutterViewController
    methodChannel = FlutterMethodChannel(name: "com.omi.offline/notifyOnKill", binaryMessenger: controller!.binaryMessenger)
    methodChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.handleMethodCall(call, result: result)
    }
    
    // Create Apple Reminders method channel
    appleRemindersChannel = FlutterMethodChannel(name: "com.omi.apple_reminders", binaryMessenger: controller!.binaryMessenger)
    appleRemindersChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.handleAppleRemindersCall(call, result: result)
    }

    // Create Apple Health method channel
    appleHealthChannel = FlutterMethodChannel(name: "com.omi.apple_health", binaryMessenger: controller!.binaryMessenger)
    appleHealthChannel?.setMethodCallHandler { [weak self] (call, result) in
      self?.handleAppleHealthCall(call, result: result)
    }

    // Create Speech Recognition method channel
    let speechChannel = FlutterMethodChannel(name: "com.omi.ios/speech", binaryMessenger: controller!.binaryMessenger)
    let speechHandler = SpeechRecognitionHandler()
    speechChannel.setMethodCallHandler { (call, result) in
        speechHandler.handle(call, result: result)
    }

    // TestFlight environment detection
    let envChannel = FlutterMethodChannel(name: "com.omi/environment", binaryMessenger: controller!.binaryMessenger)
    envChannel.setMethodCallHandler { (call, result) in
        if call.method == "isTestFlight" {
            let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            result(isTestFlight)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    // Audio session configuration for Bluetooth microphone support
    let audioSessionChannel = FlutterMethodChannel(name: "com.omi.ios/audioSession", binaryMessenger: controller!.binaryMessenger)
    audioSessionChannel.setMethodCallHandler { (call, result) in
        if call.method == "configureForBluetooth" {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
                )
                try audioSession.setActive(true)
                result(true)
            } catch {
                result(FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil))
            }
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    // AAC encoder channel
    setupAacEncoderChannel(controller!.binaryMessenger)

    // Native VAD batch runner (iOS mirror of Android VadBatchRunner). Registered on
    // the main-isolate messenger; the Dart VadBatchRunnerChannel bounces calls from
    // the background processing isolate to here. Held so the channel handler lives.
    vadBatchRunner = VadBatchRunner(messenger: controller!.binaryMessenger)

    // Create WiFi Network plugin for device AP connection
    _ = WifiNetworkPlugin(messenger: controller!.binaryMessenger)

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    // Background sync BGProcessingTask — fires when iOS has spare capacity and
    // a sync interval has elapsed. Calls onBackgroundSyncRequested() so Dart's
    // DeviceProvider handles the sync exactly as a Dart timer tick would.
    if #available(iOS 13.0, *) {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.omi.offline.sync", using: nil) { task in
        self.handleBackgroundSync(task: task as! BGProcessingTask)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @available(iOS 13.0, *)
  private func handleBackgroundSync(task: BGProcessingTask) {
    scheduleBackgroundSync() // re-arm for next interval before doing any work
    task.expirationHandler = { task.setTaskCompleted(success: false) }
    guard let api = OmiBleManager.shared.flutterApi else {
      task.setTaskCompleted(success: false)
      return
    }
    api.onBackgroundSyncRequested { _ in task.setTaskCompleted(success: true) }
  }

  @available(iOS 13.0, *)
  private func scheduleBackgroundSync() {
    let prefs = UserDefaults.standard
    let intervalMinutes = prefs.integer(forKey: "flutter.backgroundSyncIntervalMinutes")
    guard intervalMinutes > 0 else { return }
    let request = BGProcessingTaskRequest(identifier: "com.omi.offline.sync")
    request.requiresNetworkConnectivity = false
    request.requiresExternalPower = false
    request.earliestBeginDate = Date(timeIntervalSinceNow: Double(intervalMinutes) * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    if #available(iOS 13.0, *) {
      scheduleBackgroundSync()
    }
    super.applicationDidEnterBackground(application)
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
      case "setNotificationOnKillService":
        handleSetNotificationOnKillService(call: call)
      default:
        result(FlutterMethodNotImplemented)
    }
  }

  private func handleSetNotificationOnKillService(call: FlutterMethodCall) {
    NSLog("handleMethodCall: setNotificationOnKillService")
    
    if let args = call.arguments as? Dictionary<String, Any> {
      notificationTitleOnKill = args["title"] as? String
      notificationBodyOnKill = args["description"] as? String
    }
    
  }
  
  private func handleAppleRemindersCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    appleRemindersService.handleMethodCall(call, result: result)
  }

  private func handleAppleHealthCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    appleHealthService.handleMethodCall(call, result: result)
  }

  // MARK: - Silent Push for Apple Reminders Auto-Sync

  override func application(
      _ application: UIApplication,
      didReceiveRemoteNotification userInfo: [AnyHashable: Any],
      fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
      // Check if it's Apple Reminders sync
      if let type = userInfo["type"] as? String, type == "apple_reminders_sync" {
          handleAppleRemindersSync(userInfo: userInfo, completionHandler: completionHandler)
          return
      }

      // Also check nested under "data" key (some FCM configurations)
      if let data = userInfo["data"] as? [String: Any],
         let type = data["type"] as? String,
         type == "apple_reminders_sync" {
          handleAppleRemindersSync(userInfo: data, completionHandler: completionHandler)
          return
      }

      super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
  }

  private func handleAppleRemindersSync(
      userInfo: [AnyHashable: Any],
      completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
      guard let itemsJson = userInfo["items"] as? String else {
          completionHandler(.failed)
          return
      }

      let exportedIds = appleRemindersService.syncBatchFromJSON(itemsJson)

      if !exportedIds.isEmpty {
          DispatchQueue.main.async {
              self.appleRemindersChannel?.invokeMethod("markExportedBatch", arguments: ["action_item_ids": exportedIds])
          }
      }

      completionHandler(exportedIds.isEmpty ? .noData : .newData)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    // If title and body are nil, then we don't need to show notification.
    if notificationTitleOnKill == nil || notificationBodyOnKill == nil {
      return
    }

    let content = UNMutableNotificationContent()
    content.title = notificationTitleOnKill!
    content.body = notificationBodyOnKill!
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    let request = UNNotificationRequest(identifier: "notification on app kill", content: content, trigger: trigger)

    NSLog("Running applicationWillTerminate")

    UNUserNotificationCenter.current().add(request) { (error) in
      if let error = error {
        NSLog("Failed to show notification on kill service => error: \(error.localizedDescription)")
      } else {
        NSLog("Show notification on kill now")
      }
    }
    }

}

func registerPlugins(registry: FlutterPluginRegistry) {
  GeneratedPluginRegistrant.register(with: registry)
}

// MARK: - AAC Encoder

private class AacEncoderSession {
  var audioFile: AVAudioFile?   // Optional so finishEncoder can nil it to force-close
  let pcmFormat: AVAudioFormat
  let tempPath: String
  let finalPath: String
  let queue: DispatchQueue

  init(audioFile: AVAudioFile, pcmFormat: AVAudioFormat, tempPath: String, finalPath: String, queue: DispatchQueue) {
    self.audioFile = audioFile
    self.pcmFormat = pcmFormat
    self.tempPath = tempPath
    self.finalPath = finalPath
    self.queue = queue
  }
}

extension AppDelegate {
  fileprivate func setupAacEncoderChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.omi.offline/aacEncoder", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "startEncoder":
        self.aacStartEncoder(call: call, result: result)
      case "encodeBuffer":
        self.aacEncodeChunk(call: call, result: result)
      case "finishEncoder":
        self.aacFinishEncoder(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func aacStartEncoder(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let sampleRate = args["sampleRate"] as? Int,
          let outputPath = args["outputPath"] as? String,
          let bitrate = args["bitrate"] as? Int else {
      result(FlutterError(code: "INVALID_ARGS", message: "startEncoder requires sampleRate, outputPath, bitrate", details: nil))
      return
    }

    // Derive temp path: insert ".tmp" before ".m4a"
    let tempPath = outputPath.hasSuffix(".m4a")
      ? String(outputPath.dropLast(4)) + ".tmp.m4a"
      : outputPath + ".tmp"
    let tempUrl = URL(fileURLWithPath: tempPath)

    // Remove stale temp file if present
    try? FileManager.default.removeItem(at: tempUrl)

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: bitrate,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
    ]

    let queue = DispatchQueue(label: "com.omi.aac.\(UUID().uuidString)", qos: .utility)
    let sessionId = UUID().uuidString

    queue.async {
      do {
        let audioFile = try AVAudioFile(forWriting: tempUrl, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let pcmFormat = audioFile.processingFormat
        let session = AacEncoderSession(audioFile: audioFile, pcmFormat: pcmFormat, tempPath: tempPath, finalPath: outputPath, queue: queue)
        self.aacEncoderSessions[sessionId] = session
        DispatchQueue.main.async { result(sessionId) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "ENCODER_START_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func aacEncodeChunk(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String,
          let pcmFlutter = args["pcmBytes"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "INVALID_ARGS", message: "encodeBuffer requires sessionId and pcmBytes", details: nil))
      return
    }

    guard let session = aacEncoderSessions[sessionId] else {
      result(FlutterError(code: "NO_SESSION", message: "No encoder session for id \(sessionId)", details: nil))
      return
    }

    let pcmData = pcmFlutter.data

    session.queue.async {
      do {
        let frameCount = pcmData.count / 2  // 16-bit samples
        guard frameCount > 0 else {
          DispatchQueue.main.async { result(nil) }
          return
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: session.pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
          throw NSError(domain: "AacEncoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let floatData = pcmBuffer.floatChannelData![0]
        pcmData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
          let int16Ptr = ptr.bindMemory(to: Int16.self)
          for i in 0..<frameCount {
            floatData[i] = Float(int16Ptr[i]) / 32768.0
          }
        }
        guard let audioFile = session.audioFile else {
          throw NSError(domain: "AacEncoder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Session already closed"])
        }
        try audioFile.write(from: pcmBuffer)
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "ENCODE_CHUNK_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func aacFinishEncoder(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String else {
      result(FlutterError(code: "INVALID_ARGS", message: "finishEncoder requires sessionId", details: nil))
      return
    }

    guard let session = aacEncoderSessions.removeValue(forKey: sessionId) else {
      result(FlutterError(code: "NO_SESSION", message: "No encoder session for id \(sessionId)", details: nil))
      return
    }

    session.queue.async {
      let tempUrl = URL(fileURLWithPath: session.tempPath)
      let finalUrl = URL(fileURLWithPath: session.finalPath)

      // Nil out audioFile so ARC immediately releases it → AVAudioFile flushes on dealloc.
      session.audioFile = nil

      do {
        if FileManager.default.fileExists(atPath: session.finalPath) {
          try FileManager.default.removeItem(at: finalUrl)
        }
        try FileManager.default.moveItem(at: tempUrl, to: finalUrl)
        DispatchQueue.main.async { result(nil) }
      } catch {
        try? FileManager.default.removeItem(at: tempUrl)
        DispatchQueue.main.async {
          result(FlutterError(code: "FINISH_ENCODER_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

class SpeechRecognitionHandler: NSObject {
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "transcribe" {
            guard let args = call.arguments as? [String: Any],
                  let path = args["filePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
                return
            }
            
            let language = args["language"] as? String ?? "en-US"
            transcribe(filePath: path, language: language, result: result)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func transcribe(filePath: String, language: String, result: @escaping FlutterResult) {
        // Request authorization first
        SFSpeechRecognizer.requestAuthorization { authStatus in
            if authStatus != .authorized {
                result(FlutterError(code: "UNAUTHORIZED", message: "Speech recognition not authorized", details: nil))
                return
            }
            
            let fileUrl = URL(fileURLWithPath: filePath)
            let localeIdentifier = language.isEmpty ? "en-US" : language
            let locale = Locale(identifier: localeIdentifier)
            
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                result(FlutterError(code: "UNAVAILABLE", message: "Speech recognizer not available for locale \(localeIdentifier)", details: nil))
                return
            }
            
            if !recognizer.isAvailable {
                result(FlutterError(code: "UNAVAILABLE", message: "Speech recognizer service is currently unavailable", details: nil))
                return
            }
            
            let request = SFSpeechURLRecognitionRequest(url: fileUrl)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = true // Force on-device
            
            let task = recognizer.recognitionTask(with: request) { (recognitionResult, error) in
                if let error = error {
                    // Check if it's just "No speech identified" which might happen with silence
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                         result("") // Treat as empty
                    } else {
                         result(FlutterError(code: "RECOGNITION_ERROR", message: error.localizedDescription, details: nil))
                    }
                    return
                }
                
                if let recognitionResult = recognitionResult, recognitionResult.isFinal {
                    let text = recognitionResult.bestTranscription.formattedString
                    result(text)
                }
            }
        }
    }
}
