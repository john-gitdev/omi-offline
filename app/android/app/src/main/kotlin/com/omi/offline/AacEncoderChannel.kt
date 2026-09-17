package com.omi.offline

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * The `com.omi.offline/aacEncoder` channel: PCM in, an `.m4a` out, via MediaCodec.
 *
 * Lifted off MainActivity so it belongs to the ENGINE rather than the Activity. Nothing
 * here ever needed an Activity — it is MediaCodec and MediaMuxer, plus a main-thread hop
 * that used to be `runOnUiThread` and is now a Looper handler. Keeping it on the Activity
 * meant that once the OS reclaimed the Activity, every `startEncoder` from the background
 * processing isolate got MissingPluginException and the VAD processor silently fell back
 * to WAV (see its "AAC startEncoder failed, falling back to WAV" path). With the engine
 * outliving the Activity, a background sync can finish recordings as M4A the same way a
 * foreground one does.
 */
class AacEncoderChannel(messenger: BinaryMessenger) {
    companion object {
        private const val CHANNEL = "com.omi.offline/aacEncoder"
    }

    private val sessions = mutableMapOf<String, AacEncoderSession>()

    /** Single thread: MediaCodec sessions are not safe to drive concurrently. */
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startEncoder" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 16000
                    val outputPath = call.argument<String>("outputPath") ?: run {
                        result.error("INVALID_ARGS", "outputPath is required", null); return@setMethodCallHandler
                    }
                    val bitrate = call.argument<Int>("bitrate") ?: 32000
                    executor.execute {
                        try {
                            val sessionId = startEncoder(sampleRate, outputPath, bitrate)
                            main.post { result.success(sessionId) }
                        } catch (e: Exception) {
                            main.post { result.error("ENCODER_START_ERROR", e.message, null) }
                        }
                    }
                }
                "encodeBuffer" -> {
                    val sessionId = call.argument<String>("sessionId") ?: run {
                        result.error("INVALID_ARGS", "sessionId is required", null); return@setMethodCallHandler
                    }
                    val pcmBytes = call.argument<ByteArray>("pcmBytes") ?: run {
                        result.error("INVALID_ARGS", "pcmBytes is required", null); return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            encodeChunk(sessionId, pcmBytes)
                            main.post { result.success(null) }
                        } catch (e: Exception) {
                            main.post { result.error("ENCODE_CHUNK_ERROR", e.message, null) }
                        }
                    }
                }
                "finishEncoder" -> {
                    val sessionId = call.argument<String>("sessionId") ?: run {
                        result.error("INVALID_ARGS", "sessionId is required", null); return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            finishEncoder(sessionId)
                            main.post { result.success(null) }
                        } catch (e: Exception) {
                            main.post { result.error("FINISH_ENCODER_ERROR", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startEncoder(sampleRate: Int, outputPath: String, bitrate: Int): String {
        val tempPath = if (outputPath.endsWith(".m4a")) outputPath.dropLast(4) + ".tmp.m4a" else "$outputPath.tmp"

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
        sessions[sessionId] = AacEncoderSession(
            codec = codec,
            muxer = muxer,
            sampleRate = sampleRate,
            tempPath = tempPath,
            finalPath = outputPath
        )
        return sessionId
    }

    private fun encodeChunk(sessionId: String, pcmData: ByteArray) {
        val session = sessions[sessionId] ?: throw IllegalStateException("No encoder session for id $sessionId")

        // Queue all of it. This used to take one input buffer with a 10 ms wait and, if none
        // was free, drop the chunk without a word — a silent gap in the recording. That was
        // rare while the processor fed the encoder at the pace it decoded Opus; M4A is now
        // made by reading a finished WAV back (RecordingsManager._convertPendingToM4a), which
        // feeds it as fast as the file reads. So wait for room, draining output to make it,
        // and split a chunk that is larger than one input buffer.
        var offset = 0
        var waits = 0
        while (pcmData.size - offset >= 2) { // a stray odd byte is not a sample
            val inputIndex = session.codec.dequeueInputBuffer(10000L)
            if (inputIndex < 0) {
                drainOutput(session, drainToEnd = false)
                if (++waits > 500) throw IllegalStateException("AAC encoder took no input for 5 s")
                continue
            }
            waits = 0
            val buffer = session.codec.getInputBuffer(inputIndex)!!
            buffer.clear()
            // Whole 16-bit samples only.
            val n = minOf(buffer.remaining(), pcmData.size - offset) and 1.inv()
            if (n <= 0) throw IllegalStateException("AAC encoder input buffer holds no whole sample")
            buffer.put(pcmData, offset, n)
            val pts = (session.totalSamplesQueued * 1_000_000L) / session.sampleRate
            session.codec.queueInputBuffer(inputIndex, 0, n, pts, 0)
            session.totalSamplesQueued += n / 2 // 16-bit samples
            offset += n

            // Drain available output
            drainOutput(session, drainToEnd = false)
        }
    }

    private fun finishEncoder(sessionId: String) {
        val session = sessions.remove(sessionId) ?: throw IllegalStateException("No encoder session for id $sessionId")

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

            if (!session.reachedEos || !session.muxerStarted || session.samplesWritten == 0L) {
                try { session.muxer.release() } catch (_: Exception) {}
                File(session.tempPath).delete()
                throw IllegalStateException(
                    "AAC encoder failed to produce a valid stream (reachedEos=${session.reachedEos}, " +
                        "muxerStarted=${session.muxerStarted}, samples=${session.samplesWritten})"
                )
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
            try { if (session.muxerStarted && session.samplesWritten > 0) session.muxer.stop() } catch (_: Exception) {}
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
                    if (++retries > 200) break // ~2s max wait
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
                        session.samplesWritten++
                    }
                    session.codec.releaseOutputBuffer(outputIndex, false)
                    if (isEos) {
                        session.reachedEos = true
                        break
                    }
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
    var reachedEos: Boolean = false,
    var samplesWritten: Long = 0,
    var totalSamplesQueued: Long = 0L
)
