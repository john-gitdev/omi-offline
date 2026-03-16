import UIKit
import Flutter
import UserNotifications
import app_links
import WatchConnectivity
import AVFoundation
import Speech

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

  var session: WCSession?
    var flutterWatchAPI: WatchRecorderFlutterAPI?
  private var audioChunks: [Int: (Data, Double)] = [:] // (audioData, sampleRate)
  fileprivate var aacEncoderSessions: [String: AacEncoderSession] = [:]
  private var nextExpectedChunkIndex: Int = 0
  private var isRecordingActive: Bool = false // Track recording state to handle app restarts

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
      
      
      if WCSession.isSupported() {
          session = WCSession.default
          session?.delegate = self
          session?.activate();

          let controller = window?.rootViewController as? FlutterViewController
            flutterWatchAPI = WatchRecorderFlutterAPI(binaryMessenger: controller!.binaryMessenger)
            let api: WatchRecorderHostAPI = RecorderHostApiImpl(session: session!, flutterWatchAPI: flutterWatchAPI)

            WatchRecorderHostAPISetup.setUp(binaryMessenger: controller!.binaryMessenger, api: api)
      }

      // Retrieve the link from parameters
    if let url = AppLinks.shared.getLink(launchOptions: launchOptions) {
      // We have a link, propagate it to your Flutter app or not
      AppLinks.shared.handleLink(url: url)
      return true // Returning true will stop the propagation to other packages
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

    // Create WiFi Network plugin for device AP connection
    _ = WifiNetworkPlugin(messenger: controller!.binaryMessenger)

    // Register Phone Calls plugin
    PhoneCallsPlugin.register(with: self.registrar(forPlugin: "PhoneCallsPlugin")!)

    // here, Without this code the task will not work.
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

    private func handleAudioChunk(_ message: [String: Any]) {
        guard isRecordingActive else {
            print("Ignoring audio chunk - recording not active") // probably started recording with main omi app closed
            return
        }

        guard let audioChunk = message["audioChunk"] as? Data,
              let chunkIndex = message["chunkIndex"] as? Int,
              let isLast = message["isLast"] as? Bool,
              let sampleRate = message["sampleRate"] as? Double else {
            return
        }

        audioChunks[chunkIndex] = (audioChunk, sampleRate)

        if isLast {
            reassembleAndSendAudioData()
        } else {
            // Prepend 3 dummy bytes so downstream can uniformly strip headers
            var prefixedChunk = Data([0x00, 0x00, 0x00])
            prefixedChunk.append(audioChunk)
            let flutterData = FlutterStandardTypedData(bytes: prefixedChunk)
            self.flutterWatchAPI?.onAudioChunk(audioChunk: flutterData, chunkIndex: Int64(chunkIndex), isLast: isLast, sampleRate: sampleRate) { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    print("Audio chunk \(chunkIndex) sent to Flutter - Error: \(error.message)")
                }
            }
        }
    }

    private func reassembleAndSendAudioData() {
        // Sort chunks by index and combine them
        let sortedChunks = audioChunks.sorted(by: { $0.key < $1.key })
        var combinedData = Data()
        var sampleRate: Double = 48000.0 // Default fallback

        for (_, chunkTuple) in sortedChunks {
            let (chunkData, chunkSampleRate) = chunkTuple
            combinedData.append(chunkData)
            sampleRate = chunkSampleRate
        }

        // Prepend 3 dummy bytes for full buffer as well
        var prefixed = Data([0x00, 0x00, 0x00])
        prefixed.append(combinedData)
        let flutterData = FlutterStandardTypedData(bytes: prefixed)
        self.flutterWatchAPI?.onAudioData(audioData: flutterData) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                print("Complete audio data sent to Flutter - Error: \(error.message)")
            }
        }

        audioChunks.removeAll()
        nextExpectedChunkIndex = 0
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
      case "encodeChunk":
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
      result(FlutterError(code: "INVALID_ARGS", message: "encodeChunk requires sessionId and pcmBytes", details: nil))
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

extension AppDelegate: WCSessionDelegate {
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("Session Watch Become Inactive")
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        print("Session Watch Deactivate")
    }
    
    // Receive a message from watch (foreground/active)
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task {
            guard let method = message["method"] as? String else {
                return
            }

            switch method {
            case "startRecording":
                self.isRecordingActive = true
                self.audioChunks.removeAll()
                self.nextExpectedChunkIndex = 0
                
                DispatchQueue.main.async {
                    self.flutterWatchAPI?.onRecordingStarted() { result in
                        switch result {
                        case .success:
                            break
                        case .failure(let error):
                            print("iOS: Recording started notification sent to Flutter - Error: \(error.message)")
                        }
                    }
                }
            case "stopRecording":
                self.isRecordingActive = false
                self.flutterWatchAPI?.onRecordingStopped() { result in
                    switch result {
                    case .success:
                        break
                    case .failure(let error):
                        print("Recording stopped on Flutter - Error: \(error.message)")
                    }
                }
            case "sendAudioData":
                if let audioData = message["audioData"] as? Data {
                    // Prepend 3 dummy bytes for single-shot audio data
                    var prefixed = Data([0x00, 0x00, 0x00])
                    prefixed.append(audioData)
                    let flutterData = FlutterStandardTypedData(bytes: prefixed)
                    self.flutterWatchAPI?.onAudioData(audioData: flutterData) { result in
                        switch result {
                        case .success:
                            break
                        case .failure(let error):
                            print("Audio data sent to Flutter - Error: \(error.message)")
                        }
                    }
                } else {
                    print("Failed to cast audioData as Data - received type: \(type(of: message["audioData"]))")
                }
            case "sendAudioChunk":
                self.handleAudioChunk(message)
            case "recordingError":
                if let error = message["error"] as? String {
                    self.flutterWatchAPI?.onRecordingError(error: error) { result in
                        switch result {
                        case .success:
                            break
                        case .failure(let error):
                            print("Recording error sent to Flutter - Error: \(error.message)")
                        }
                    }
                }
            case "microphonePermissionResult":
                if let granted = message["granted"] as? Bool {
                    self.flutterWatchAPI?.onMicrophonePermissionResult(granted: granted) { result in
                        switch result {
                        case .success:
                            break
                        case .failure(let error):
                            print("Microphone permission result sent to Flutter - Error: \(error.message)")
                        }
                    }
                }
            case "batteryUpdate":
                if let batteryLevel = message["batteryLevel"] as? Double,
                   let batteryState = message["batteryState"] as? Int {
                    UserDefaults.standard.set(batteryLevel, forKey: "watch_battery_level")
                    UserDefaults.standard.set(batteryState, forKey: "watch_battery_state")
                    UserDefaults.standard.set(Date(), forKey: "watch_battery_last_updated")
                    
                    DispatchQueue.main.async {
                        self.flutterWatchAPI?.onWatchBatteryUpdate(batteryLevel: batteryLevel, batteryState: Int64(batteryState)) { result in
                            switch result {
                            case .success:
                                break
                            case .failure(let error):
                                print("iOS: Battery update sent to Flutter - Error: \(error.message)")
                            }
                        }
                    }
                }
            case "watchInfoUpdate":
                if let name = message["name"] as? String,
                   let model = message["model"] as? String,
                   let systemVersion = message["systemVersion"] as? String,
                   let localizedModel = message["localizedModel"] as? String {

                    UserDefaults.standard.set(name, forKey: "watch_device_name")
                    UserDefaults.standard.set(model, forKey: "watch_device_model")
                    UserDefaults.standard.set(systemVersion, forKey: "watch_system_version")
                    UserDefaults.standard.set(localizedModel, forKey: "watch_localized_model")
                    UserDefaults.standard.set(Date(), forKey: "watch_info_last_updated")
                }
            default:
                print("Unknown method: \(method)")
            }
        }
    }
    
    // Receive user info from watch (background/offline)
    // Used for 1.5 second audio chunks when screen is off or app is backgrounded
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        
        Task {
            guard let method = userInfo["method"] as? String else {
                return
            }
            
            switch method {
            case "sendAudioChunk":
                self.handleAudioChunk(userInfo)
            case "stopRecording":
                self.isRecordingActive = false
                    self.flutterWatchAPI?.onRecordingStopped() { result in
                    switch result {
                    case .success:
                        break
                    case .failure(let error):
                        print("Stop recording (background) sent to Flutter - Error: \(error.message)")
                    }
                }
            case "recordingError":
                if let error = userInfo["error"] as? String {
                    self.flutterWatchAPI?.onRecordingError(error: error) { result in
                        switch result {
                        case .success:
                            break
                        case .failure(let error):
                            print("Recording error (background) sent to Flutter - Error: \(error.message)")
                        }
                    }
                }
            case "batteryUpdate":
                if let batteryLevel = userInfo["batteryLevel"] as? Double,
                   let batteryState = userInfo["batteryState"] as? Int {
                    UserDefaults.standard.set(batteryLevel, forKey: "watch_battery_level")
                    UserDefaults.standard.set(batteryState, forKey: "watch_battery_state")
                    UserDefaults.standard.set(Date(), forKey: "watch_battery_last_updated")
                    
                    DispatchQueue.main.async {
                        self.flutterWatchAPI?.onWatchBatteryUpdate(batteryLevel: batteryLevel, batteryState: Int64(batteryState)) { result in
                            switch result {
                            case .success:
                                break
                            case .failure(let error):
                                print("iOS: Background battery update sent to Flutter - Error: \(error.message)")
                            }
                        }
                    }
                }
            case "watchInfoUpdate":
                if let name = userInfo["name"] as? String,
                   let model = userInfo["model"] as? String,
                   let systemVersion = userInfo["systemVersion"] as? String,
                   let localizedModel = userInfo["localizedModel"] as? String {
                    UserDefaults.standard.set(name, forKey: "watch_device_name")
                    UserDefaults.standard.set(model, forKey: "watch_device_model")
                    UserDefaults.standard.set(systemVersion, forKey: "watch_system_version")
                    UserDefaults.standard.set(localizedModel, forKey: "watch_localized_model")
                    UserDefaults.standard.set(Date(), forKey: "watch_info_last_updated")
                }
            default:
                print("Unknown background method: \(method)")
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
