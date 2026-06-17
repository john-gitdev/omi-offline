import Flutter
import Foundation
import onnxruntime_objc

/// Native batch runner for Silero VAD inference (iOS mirror of the Android
/// `VadBatchRunner.kt`).
///
/// Collapses the per-window Dart↔native platform-channel round-trips by keeping
/// the ORTSession, LSTM state, sample-rate tensor, and 64-sample context buffer
/// entirely native-side. A single `runVadBatch` call processes N×512-sample
/// windows and returns N probabilities.
///
/// Contract (mirrors the Dart-side per-window `_runVad` and the Kotlin runner exactly):
///   init(modelPath)             → load session, allocate zero state
///   runVadBatch(samples, reset) → Float32List of N probs
///   dispose()                   → close session, free tensors
final class VadBatchRunner: NSObject {
    private static let channelName = "com.omi.offline/vadBatchRunner"
    private static let windowSamples = 512
    private static let contextSamples = 64
    private static let inputSize = 576 // contextSamples (64) + windowSamples (512)
    private static let stateDim = 128
    private static let sampleRate: Int64 = 16000

    private let channel: FlutterMethodChannel
    // Serial worker queue — mirrors the Kotlin HandlerThread so init/run/dispose
    // never overlap and the rolling state is mutated single-threaded.
    private let worker = DispatchQueue(label: "com.omi.offline.vadBatchRunner")

    private var env: ORTEnv?
    private var session: ORTSession?

    // Rolling LSTM state — [2, 1, 128] float32. Zero → fresh.
    private var state = [Float](repeating: 0, count: 2 * VadBatchRunner.stateDim)
    // 64-sample context buffer (trailing samples from the previous window).
    private var context = [Float](repeating: 0, count: VadBatchRunner.contextSamples)

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: VadBatchRunner.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            guard let args = call.arguments as? [String: Any],
                  let modelPath = args["modelPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "modelPath is required", details: nil))
                return
            }
            worker.async {
                do {
                    try self.doInit(modelPath)
                    DispatchQueue.main.async { result(nil) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "INIT_ERROR", message: "\(error)", details: nil))
                    }
                }
            }

        case "runVadBatch":
            guard let args = call.arguments as? [String: Any],
                  let samples = args["samples"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARGS", message: "samples is required", details: nil))
                return
            }
            let resetStateFirst = (args["resetStateFirst"] as? Bool) ?? false
            worker.async {
                do {
                    let probs = try self.doRunBatch(samples.data, resetStateFirst: resetStateFirst)
                    let out = probs.withUnsafeBufferPointer { FlutterStandardTypedData(float32: Data(buffer: $0)) }
                    DispatchQueue.main.async { result(out) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "RUN_ERROR", message: "\(error)", details: nil))
                    }
                }
            }

        case "dispose":
            worker.async {
                self.doDispose()
                DispatchQueue.main.async { result(nil) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Worker-thread implementations

    private func doInit(_ modelPath: String) throws {
        doDispose() // clean up any prior session

        let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        self.env = env

        let opts = try ORTSessionOptions()
        do {
            // XNNPACK when available — faster ARM kernels, deterministic. Matches
            // the Android runner (opts.addXnnpack). Falls back to the default CPU EP.
            try opts.appendXnnpackExecutionProvider(with: ORTXnnpackExecutionProviderOptions())
        } catch {
            NSLog("[VadBatchRunner] XNNPACK unavailable, using default CPU EP: \(error)")
        }
        try opts.setIntraOpNumThreads(1)

        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: opts)

        // Zero-initialise rolling state and context.
        resetState()
        NSLog("[VadBatchRunner] Initialized ORTSession")
    }

    private func doRunBatch(_ samplesData: Data, resetStateFirst: Bool) throws -> [Float] {
        guard let session = session else {
            throw VadError.notInitialised
        }

        let samples = samplesData.toFloatArray()
        let n = samples.count / VadBatchRunner.windowSamples
        if n == 0 { return [] }

        if resetStateFirst {
            resetState()
        }

        var probs = [Float](repeating: 0, count: n)
        var inputBuf = [Float](repeating: 0, count: VadBatchRunner.inputSize) // [context64 | window512]

        // SR tensor is constant across the batch — int64 scalar, create once.
        var sr = VadBatchRunner.sampleRate
        let srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
        let srTensor = try ORTValue(tensorData: srData, elementType: .int64, shape: [])

        let runOptions = try ORTRunOptions()
        let outputNames: Set<String> = ["output", "stateN"]

        for i in 0..<n {
            let windowOffset = i * VadBatchRunner.windowSamples

            // Build [context(64) | window(512)] input.
            for j in 0..<VadBatchRunner.contextSamples { inputBuf[j] = context[j] }
            for j in 0..<VadBatchRunner.windowSamples {
                inputBuf[VadBatchRunner.contextSamples + j] = samples[windowOffset + j]
            }

            // ORTValue does not copy tensorData — keep these NSMutableData alive
            // (locals) through session.run() and the output reads below.
            let inputData = NSMutableData(bytes: inputBuf, length: inputBuf.count * MemoryLayout<Float>.size)
            let inputTensor = try ORTValue(
                tensorData: inputData, elementType: .float,
                shape: [1, NSNumber(value: VadBatchRunner.inputSize)])

            let stateData = NSMutableData(bytes: state, length: state.count * MemoryLayout<Float>.size)
            let stateTensor = try ORTValue(
                tensorData: stateData, elementType: .float,
                shape: [2, 1, NSNumber(value: VadBatchRunner.stateDim)])

            let outputs = try session.run(
                withInputs: ["input": inputTensor, "state": stateTensor, "sr": srTensor],
                outputNames: outputNames,
                runOptions: runOptions)

            // Read output probability.
            if let outputTensor = outputs["output"] {
                let d = try outputTensor.tensorData()
                probs[i] = d.bytes.bindMemory(to: Float.self, capacity: 1)[0]
            }

            // Adopt stateN as the new state for the next iteration.
            if let stateNTensor = outputs["stateN"] {
                let d = try stateNTensor.tensorData()
                let p = d.bytes.bindMemory(to: Float.self, capacity: state.count)
                for k in 0..<state.count { state[k] = p[k] }
            }

            // Keep references alive until here so ORT's view of the buffers is valid.
            withExtendedLifetime((inputData, stateData)) {}

            // Update context: trailing 64 samples of this window.
            let tail = windowOffset + VadBatchRunner.windowSamples - VadBatchRunner.contextSamples
            for j in 0..<VadBatchRunner.contextSamples { context[j] = samples[tail + j] }
        }

        withExtendedLifetime(srData) {}
        return probs
    }

    private func doDispose() {
        session = nil // ORTSession is released here
        // Don't release env — ORTEnv is process-wide.
        resetState()
    }

    private func resetState() {
        for i in 0..<state.count { state[i] = 0 }
        for i in 0..<context.count { context[i] = 0 }
    }

    enum VadError: Error {
        case notInitialised
    }
}

private extension Data {
    /// Reinterpret the raw bytes as little-endian float32 (BLE/Flutter typed-data
    /// is host-endian; iOS arm64 is little-endian, matching the Dart side).
    func toFloatArray() -> [Float] {
        let count = self.count / MemoryLayout<Float>.size
        if count == 0 { return [] }
        return self.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
