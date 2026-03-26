package com.omi.offline

import android.content.Intent
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.omi.offline/notifyOnKill"
    private val AAC_CHANNEL = "com.omi.offline/aacEncoder"

    private val encoderSessions = mutableMapOf<String, AacEncoderSession>()
    private val encoderExecutor = Executors.newSingleThreadExecutor()

    private var bleHostApiImpl: BleHostApiImpl? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register WiFi Network Plugin
        WifiNetworkPlugin.registerWith(flutterEngine, this)

        // Register Phone Calls Plugin
        PhoneCallsPlugin.registerWith(flutterEngine, this)

        // Register Native BLE Pigeon APIs
        OmiBleManager.initialize(application)
        OmiBleManager.instance.flutterApi = BleFlutterApi(flutterEngine.dartExecutor.binaryMessenger)
        val hostApi = BleHostApiImpl { this }
        hostApi.initCompanionManager(this)
        bleHostApiImpl = hostApi
        BleHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, hostApi)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setNotificationOnKillService") {
                val title = call.argument<String>("title")
                val description = call.argument<String>("description")
                val serviceIntent = Intent(this, NotificationOnKillService::class.java)
                serviceIntent.putExtra("title", title)
                serviceIntent.putExtra("description", description)
                startService(serviceIntent)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AAC_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startEncoder" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 16000
                    val outputPath = call.argument<String>("outputPath") ?: run {
                        result.error("INVALID_ARGS", "outputPath is required", null); return@setMethodCallHandler
                    }
                    val bitrate = call.argument<Int>("bitrate") ?: 32000
                    encoderExecutor.execute {
                        try {
                            val sessionId = startAacEncoder(sampleRate, outputPath, bitrate)
                            runOnUiThread { result.success(sessionId) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ENCODER_START_ERROR", e.message, null) }
                        }
                    }
                }
                "encodeChunk" -> {
                    val sessionId = call.argument<String>("sessionId") ?: run {
                        result.error("INVALID_ARGS", "sessionId is required", null); return@setMethodCallHandler
                    }
                    val pcmBytes = call.argument<ByteArray>("pcmBytes") ?: run {
                        result.error("INVALID_ARGS", "pcmBytes is required", null); return@setMethodCallHandler
                    }
                    encoderExecutor.execute {
                        try {
                            encodeAacChunk(sessionId, pcmBytes)
                            runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ENCODE_CHUNK_ERROR", e.message, null) }
                        }
                    }
                }
                "finishEncoder" -> {
                    val sessionId = call.argument<String>("sessionId") ?: run {
                        result.error("INVALID_ARGS", "sessionId is required", null); return@setMethodCallHandler
                    }
                    encoderExecutor.execute {
                        try {
                            finishAacEncoder(sessionId)
                            runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("FINISH_ENCODER_ERROR", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        // Handle CompanionDeviceManager chooser result
        val address = bleHostApiImpl?.onActivityResult(requestCode, resultCode, data)
        if (address != null) {
            // Device selected — start foreground service and connect
            OmiBleForegroundService.startService(this, address)
        }
    }

    override fun onDestroy() {
        if (isFinishing) {
            OmiBleManager.instance.disconnectAllPeripherals()
        }
        super.onDestroy()
    }

    private fun startAacEncoder(sampleRate: Int, outputPath: String, bitrate: Int): String {
        val tempPath = if (outputPath.endsWith(".m4a"))
            outputPath.dropLast(4) + ".tmp.m4a"
        else
            "$outputPath.tmp"

        // Remove stale temp file
        val tempFile = File(tempPath)
        if (tempFile.exists()) tempFile.delete()

        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        val muxer = MediaMuxer(tempPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        val sessionId = UUID.randomUUID().toString()
        encoderSessions[sessionId] = AacEncoderSession(
            codec = codec,
            muxer = muxer,
            sampleRate = sampleRate,
            tempPath = tempPath,
            finalPath = outputPath
        )
        return sessionId
    }

    private fun encodeAacChunk(sessionId: String, pcmData: ByteArray) {
        val session = encoderSessions[sessionId]
            ?: throw IllegalStateException("No encoder session for id $sessionId")

        // Queue input
        val inputIndex = session.codec.dequeueInputBuffer(10000L)
        if (inputIndex >= 0) {
            val buffer = session.codec.getInputBuffer(inputIndex)!!
            buffer.clear()
            buffer.put(pcmData)
            val pts = (session.totalSamplesQueued * 1_000_000L) / session.sampleRate
            session.codec.queueInputBuffer(inputIndex, 0, pcmData.size, pts, 0)
            session.totalSamplesQueued += pcmData.size / 2  // 16-bit samples
        }

        // Drain available output
        drainOutput(session, drainToEnd = false)
    }

    private fun finishAacEncoder(sessionId: String) {
        val session = encoderSessions.remove(sessionId)
            ?: throw IllegalStateException("No encoder session for id $sessionId")

        try {
            // Signal end of stream
            val pts = (session.totalSamplesQueued * 1_000_000L) / session.sampleRate
            val inputIndex = session.codec.dequeueInputBuffer(10000L)
            if (inputIndex >= 0) {
                session.codec.queueInputBuffer(inputIndex, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }

            // Drain until EOS
            drainOutput(session, drainToEnd = true)

            session.codec.stop()
            session.codec.release()
            if (!session.muxerStarted) {
                session.muxer.release()
                File(session.tempPath).delete()
                throw IllegalStateException("AAC encoder produced no output — no audio data was written")
            }
            session.muxer.stop()
            session.muxer.release()

            // Rename temp → final
            val tempFile = File(session.tempPath)
            val finalFile = File(session.finalPath)
            if (finalFile.exists()) finalFile.delete()
            tempFile.renameTo(finalFile)
        } catch (e: Exception) {
            try { session.codec.stop() } catch (_: Exception) {}
            try { session.codec.release() } catch (_: Exception) {}
            try { if (session.muxerStarted) session.muxer.stop() } catch (_: Exception) {}
            try { session.muxer.release() } catch (_: Exception) {}
            try { File(session.tempPath).delete() } catch (_: Exception) {}
            throw e
        }
    }

    private fun drainOutput(session: AacEncoderSession, drainToEnd: Boolean) {
        val bufferInfo = MediaCodec.BufferInfo()
        var retries = 0
        while (true) {
            val timeoutUs = if (drainToEnd) 10000L else 0L
            val outputIndex = session.codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
            when {
                outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!drainToEnd) break
                    if (++retries > 200) break  // ~2s max wait
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (!session.muxerStarted) {
                        session.trackIndex = session.muxer.addTrack(session.codec.outputFormat)
                        session.muxer.start()
                        session.muxerStarted = true
                    }
                    retries = 0
                }
                outputIndex >= 0 -> {
                    retries = 0
                    val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && session.muxerStarted && bufferInfo.size > 0) {
                        val outputBuffer = session.codec.getOutputBuffer(outputIndex)!!
                        session.muxer.writeSampleData(session.trackIndex, outputBuffer, bufferInfo)
                    }
                    session.codec.releaseOutputBuffer(outputIndex, false)
                    if (isEos) break
                }
            }
        }
    }
}

private data class AacEncoderSession(
    val codec: MediaCodec,
    val muxer: MediaMuxer,
    val sampleRate: Int,
    val tempPath: String,
    val finalPath: String,
    var trackIndex: Int = -1,
    var muxerStarted: Boolean = false,
    var totalSamplesQueued: Long = 0L
)
