package com.omi.offline

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.OrtSession.SessionOptions
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.FloatBuffer
import java.nio.LongBuffer

/**
 * Native batch runner for Silero VAD inference.
 *
 * Collapses the per-window Dart↔native platform-channel round-trips by keeping
 * the OrtSession, LSTM state, sample-rate tensor, and 64-sample context buffer
 * entirely native-side. A single `runVadBatch` call processes N×512-sample
 * windows and returns N probabilities — ~340k channel crossings/hr → ~5k.
 *
 * Contract (mirrors the Dart-side per-window `_runVad` exactly):
 *   init(modelPath)             → load session, allocate zero state
 *   runVadBatch(samples, reset) → Float32List of N probs
 *   dispose()                   → close session, free tensors
 */
class VadBatchRunner(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.omi.offline/vadBatchRunner"
        private const val WINDOW_SAMPLES = 512
        private const val CONTEXT_SAMPLES = 64
        private const val INPUT_SIZE = CONTEXT_SAMPLES + WINDOW_SAMPLES  // 576
        private const val STATE_DIM = 128
        private const val SR = 16000L
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val workerThread = HandlerThread("VadBatchRunnerWorker").apply { start() }
    private val workerHandler = Handler(workerThread.looper)

    private var env: OrtEnvironment? = null
    private var session: OrtSession? = null

    // Rolling LSTM state — [2, 1, 128] float32. Null → zero-initialised.
    private var state: FloatArray = FloatArray(2 * 1 * STATE_DIM)

    // 64-sample context buffer (trailing samples from the previous window).
    private val context = FloatArray(CONTEXT_SAMPLES)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                val modelPath = call.argument<String>("modelPath")
                    ?: return result.error("INVALID_ARGS", "modelPath is required", null)
                workerHandler.post {
                    try {
                        doInit(modelPath)
                        Handler(android.os.Looper.getMainLooper()).post { result.success(null) }
                    } catch (e: Exception) {
                        Log.e("VadBatchRunner", "init failed", e)
                        Handler(android.os.Looper.getMainLooper()).post {
                            result.error("INIT_ERROR", e.message, null)
                        }
                    }
                }
            }
            "runVadBatch" -> {
                val samples = call.argument<FloatArray>("samples")
                    ?: return result.error("INVALID_ARGS", "samples is required", null)
                val resetStateFirst = call.argument<Boolean>("resetStateFirst") ?: false
                workerHandler.post {
                    try {
                        val probs = doRunBatch(samples, resetStateFirst)
                        Handler(android.os.Looper.getMainLooper()).post { result.success(probs) }
                    } catch (e: Exception) {
                        Log.e("VadBatchRunner", "runVadBatch failed", e)
                        Handler(android.os.Looper.getMainLooper()).post {
                            result.error("RUN_ERROR", e.message, null)
                        }
                    }
                }
            }
            "dispose" -> {
                workerHandler.post {
                    try {
                        doDispose()
                        Handler(android.os.Looper.getMainLooper()).post { result.success(null) }
                    } catch (e: Exception) {
                        Log.e("VadBatchRunner", "dispose failed", e)
                        Handler(android.os.Looper.getMainLooper()).post {
                            result.error("DISPOSE_ERROR", e.message, null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun doInit(modelPath: String) {
        doDispose() // clean up any prior session

        env = OrtEnvironment.getEnvironment()
        val opts = SessionOptions()
        var usingXnnpack = false
        try {
            // XNNPACK when available — faster ARM kernels, deterministic.
            opts.addXnnpack(java.util.Collections.emptyMap())
            usingXnnpack = true
        } catch (_: Exception) {
            // XNNPACK not bundled — fall back to default CPU EP.
        }
        opts.setIntraOpNumThreads(1)
        opts.setInterOpNumThreads(1)

        session = env!!.createSession(modelPath, opts)

        // Zero-initialise rolling state and context.
        state.fill(0f)
        context.fill(0f)
        
        Log.d("VadBatchRunner", "Initialized OrtSession. XNNPACK: $usingXnnpack")
    }

    private fun doRunBatch(samples: FloatArray, resetStateFirst: Boolean): FloatArray {
        val sess = session ?: throw IllegalStateException("Session not initialised — call init first")
        val ortEnv = env!!

        val n = samples.size / WINDOW_SAMPLES
        if (n == 0) return FloatArray(0)

        if (resetStateFirst) {
            Log.d("VadBatchRunner", "Resetting state and context for new batch")
            state.fill(0f)
            context.fill(0f)
        }

        val probs = FloatArray(n)
        val inputBuf = FloatArray(INPUT_SIZE) // [context64 | window512] — reused each iteration

        // SR tensor is constant across the batch — create once.
        val srTensor = OnnxTensor.createTensor(ortEnv, LongBuffer.wrap(longArrayOf(SR)), longArrayOf())

        try {
            for (i in 0 until n) {
                val windowOffset = i * WINDOW_SAMPLES

                // Build [context(64) | window(512)] input.
                System.arraycopy(context, 0, inputBuf, 0, CONTEXT_SAMPLES)
                System.arraycopy(samples, windowOffset, inputBuf, CONTEXT_SAMPLES, WINDOW_SAMPLES)

                // Create per-iteration tensors.
                val inputTensor = OnnxTensor.createTensor(
                    ortEnv,
                    FloatBuffer.wrap(inputBuf),
                    longArrayOf(1, INPUT_SIZE.toLong())
                )
                val stateTensor = OnnxTensor.createTensor(
                    ortEnv,
                    FloatBuffer.wrap(state),
                    longArrayOf(2, 1, STATE_DIM.toLong())
                )

                try {
                    val inputs = mapOf(
                        "input" to inputTensor,
                        "state" to stateTensor,
                        "sr" to srTensor
                    )
                    sess.run(inputs).use { outputs ->
                        // Read output probability.
                        val outputTensor = outputs.get("output")?.get() as? OnnxTensor
                        if (outputTensor != null) {
                            probs[i] = outputTensor.floatBuffer.get(0)
                        }

                        // Adopt stateN as the new state for the next iteration.
                        val stateNTensor = outputs.get("stateN")?.get() as? OnnxTensor
                        if (stateNTensor != null) {
                            stateNTensor.floatBuffer.get(state)
                        }
                    }
                } finally {
                    inputTensor.close()
                    stateTensor.close()
                }

                // Update context: trailing 64 samples of this window.
                System.arraycopy(
                    samples, windowOffset + WINDOW_SAMPLES - CONTEXT_SAMPLES,
                    context, 0, CONTEXT_SAMPLES
                )
            }
        } finally {
            srTensor.close()
        }

        return probs
    }

    private fun doDispose() {
        try { session?.close() } catch (_: Exception) {}
        session = null
        // Don't close env — OrtEnvironment is a process-wide singleton.
        state.fill(0f)
        context.fill(0f)
        Log.d("VadBatchRunner", "Disposed OrtSession")
    }

    fun destroy() {
        channel.setMethodCallHandler(null)
        doDispose()
        workerThread.quitSafely()
    }
}
