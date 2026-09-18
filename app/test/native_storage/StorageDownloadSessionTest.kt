import java.io.File
import java.nio.file.Files

// The runner supplies OmiBleManager with the unmodified production inner class.
// Only Android scheduling/logging and connection-priority side effects are stubbed.
private val original = ByteArray(12) { (it + 1).toByte() }

private fun data(offset: Int, bytes: ByteArray): ByteArray = byteArrayOf(
    1, offset.toByte(), (offset shr 8).toByte(), (offset shr 16).toByte(), (offset shr 24).toByte()
) + bytes

private class Download(val file: File, start: Long = 0) {
    val manager = OmiBleManager()
    val results = mutableListOf<Result<Unit>>()
    val session = manager.StorageDownloadSession("device", start, file.path, 123, results::add)

    init {
        manager.activeDownloads["device"] = session
        session.readIssued = true
    }

    fun ack() = session.onPacket(byteArrayOf(3, 0, 123, 0, 0, 0))
    fun chunk(offset: Int, end: Int) = session.onPacket(data(offset, original.copyOfRange(offset, end)))
    fun eot() = session.onPacket(byteArrayOf(2))
    fun disconnect() = session.complete(Result.failure(Exception("Stream closed without EOT")))

    fun expectGap(expected: Long, incoming: Long) {
        val error = results.single().exceptionOrNull()!!
        check(PigeonCommunicatorPigeonUtils.wrapError(error) == listOf(
            "storage-integrity", "Non-contiguous storage DATA: incoming=$incoming expected=$expected",
            mapOf("expectedOffset" to expected, "incomingOffset" to incoming)
        ))
    }

    fun replaceWriter(writer: java.io.FileOutputStream) {
        val field = session.javaClass.getDeclaredField("fos")
        field.isAccessible = true
        (field.get(session) as java.io.FileOutputStream).close()
        field.set(session, writer)
    }

    fun expect(bytes: ByteArray, success: Boolean) {
        check(results.size == 1) { "Expected one completion, got ${results.size}" }
        check(results.single().isSuccess == success) { "Unexpected completion: ${results.single()}" }
        check(file.readBytes().contentEquals(bytes)) {
            "Expected ${bytes.toList()}, got ${file.readBytes().toList()}"
        }
    }
}

fun main() {
    val dir = Files.createTempDirectory("storage-session-test").toFile()
    var passed = 0
    fun test(name: String, body: (File) -> Unit) {
        val file = File(dir, "${passed}.bin")
        body(file)
        passed++
        println("PASS $name")
    }
    try {
        test("contiguous packets produce the original file") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(4, 8); chunk(8, 12); eot(); expect(original, true) }
        }
        test("duplicate packets are ignored without duplicating bytes") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(0, 4); chunk(4, 12); eot(); expect(original, true) }
        }
        test("overlapping packet appends only its new suffix") { file ->
            Download(file).apply { ack(); chunk(0, 8); chunk(4, 12); eot(); expect(original, true) }
        }
        test("forward offset fails with a typed Pigeon error and preserves the exact prefix") { file ->
            Download(file).apply {
                ack(); chunk(0, 4); chunk(8, 12)
                expect(original.copyOfRange(0, 4), false); expectGap(4, 8)
                eot(); expect(original.copyOfRange(0, 4), false)
            }
        }
        test("late packets and EOT cannot mutate or succeed a failed session") { file ->
            Download(file).apply {
                ack(); chunk(0, 4); chunk(8, 12); chunk(4, 12); ack(); eot()
                expect(original.copyOfRange(0, 4), false)
            }
        }
        test("a leading gap fails without writing any bytes") { file ->
            Download(file).apply {
                ack(); chunk(4, 12); eot()
                expect(byteArrayOf(), false); expectGap(0, 4)
            }
        }
        test("a permanently lost final packet gives success but a short file") { file ->
            Download(file).apply { ack(); chunk(0, 8); eot(); expect(original.copyOfRange(0, 8), true) }
        }
        test("EOT before the start ACK is ignored") { file ->
            Download(file).apply {
                eot(); check(results.isEmpty())
                ack(); chunk(0, 12); eot(); expect(original, true)
            }
        }
        test("disconnect and resume from a contiguous prefix is byte-correct") { file ->
            Download(file).apply { ack(); chunk(0, 4); disconnect(); expect(original.copyOfRange(0, 4), false) }
            Download(file, file.length()).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("resume after a gap fetches the missing range and is byte-correct") { file ->
            Download(file).apply {
                ack(); chunk(0, 4); chunk(8, 10); disconnect()
                expect(original.copyOfRange(0, 4), false)
            }
            Download(file, file.length()).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("repeated gaps keep the prefix intact") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(8, 10); expectGap(4, 8) }
            repeat(7) {
                Download(file, 4).apply { ack(); chunk(8, 12); eot(); expect(original.copyOfRange(0, 4), false) }
            }
            Download(file, 4).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("a conservative earlier bookmark also resumes correctly") { file ->
            Download(file).apply { ack(); chunk(0, 4); chunk(8, 10); disconnect() }
            java.io.RandomAccessFile(file, "rw").use { it.setLength(2) }
            Download(file, 2).apply { ack(); chunk(2, 12); eot(); expect(original, true) }
        }
        test("maximum unsigned wire offset fails without allocating padding") { file ->
            Download(file).apply {
                ack(); session.onPacket(data(-1, byteArrayOf(42))); eot()
                expect(byteArrayOf(), false); expectGap(0, 0xFFFFFFFFL)
            }
        }
        test("legitimate zero content and old firmware ACK remain supported") { file ->
            Download(file).apply {
                session.onPacket(byteArrayOf(3, 0))
                session.onPacket(data(0, ByteArray(12))); eot(); expect(ByteArray(12), true)
            }
        }
        test("stale ACK DATA and EOT before READ or a matching ACK are ignored") { file ->
            Download(file).apply {
                session.readIssued = false
                ack(); chunk(0, 12); eot(); check(results.isEmpty())
                session.readIssued = true
                session.onPacket(byteArrayOf(3, 0, 124, 0, 0, 0))
                chunk(0, 12); eot(); check(results.isEmpty())
                ack(); chunk(0, 12); eot(); expect(original, true)
            }
        }
        test("an old session completion cannot remove its replacement") { file ->
            val old = Download(file)
            val next = old.manager.StorageDownloadSession("device", 0, File(file.parent, "next.bin").path, 123) {}
            old.manager.activeDownloads["device"] = next
            old.disconnect()
            check(old.manager.activeDownloads["device"] === next)
            next.complete(Result.success(Unit))
        }
        test("partial write failure rolls back and does not advance the accepted offset") { file ->
            Download(file).apply {
                ack(); chunk(0, 4)
                replaceWriter(object : java.io.FileOutputStream(file, true) {
                    override fun write(bytes: ByteArray) {
                        super.write(bytes, 0, 2)
                        throw java.io.IOException("injected partial write")
                    }
                })
                chunk(4, 12); eot(); expect(original.copyOfRange(0, 4), false)
                val error = results.single().exceptionOrNull() as FlutterError
                check(error.code == "storage-integrity")
                check(error.details == mapOf("expectedOffset" to 4L))
            }
            Download(file, 4).apply { ack(); chunk(4, 12); eot(); expect(original, true) }
        }
        test("close failure is an integrity failure requiring a fresh read") { file ->
            Download(file).apply {
                replaceWriter(object : java.io.FileOutputStream(file, true) {
                    override fun close() { super.close(); throw java.io.IOException("injected close failure") }
                })
                ack(); chunk(0, 12); eot(); expect(original, false)
                val error = results.single().exceptionOrNull() as FlutterError
                check(error.code == "storage-integrity")
                check(error.details == mapOf("expectedOffset" to 0L))
            }
        }
        test("completion waits for an in-flight packet write") { file ->
            Download(file).apply {
                val entered = java.util.concurrent.CountDownLatch(1)
                val release = java.util.concurrent.CountDownLatch(1)
                replaceWriter(object : java.io.FileOutputStream(file, true) {
                    override fun write(bytes: ByteArray) {
                        entered.countDown()
                        check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
                        super.write(bytes)
                    }
                })
                ack()
                val writer = Thread { chunk(0, 4) }.apply { start() }
                check(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
                val closer = Thread { disconnect() }.apply { start() }
                try {
                    closer.join(100)
                    check(closer.isAlive) { "Completion raced the write" }
                } finally { release.countDown() }
                writer.join(); closer.join()
                chunk(4, 12); eot(); expect(original.copyOfRange(0, 4), false)
            }
        }
        println("$passed native session regression tests passed")
    } finally {
        dir.deleteRecursively()
    }
}
