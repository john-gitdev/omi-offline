# Storage download integrity regression tests

`run.py` extracts the production `StorageDownloadSession` inner class from
`OmiBleManager.kt` and the generated `FlutterError`/error-envelope implementation
from `PigeonCommunicator.g.kt`. It compiles them with a small outer-class shell
and runs `StorageDownloadSessionTest.kt` on the JVM. It downloads nothing and
writes compiler output and data only to temporary directories.

Run from the repository root with Python and a JDK:

```text
python app/test/native_storage/run.py --java <path-to-java>
```

The runner uses `kotlinc` on PATH or cached Gradle compiler dependencies
(Kotlin 2.1.0 by default, overridable with `--kotlin-version`). Extraction fails
if the production seam changes instead of silently testing a copied receiver.

The 19 cases cover contiguous bytes, duplicates/overlap, gaps (including the
maximum unsigned wire offset), late packets/EOT, repeated failures and correct
resume, legitimate zeros, legacy and timestamped ACKs, conditional session
removal, partial-write rollback, close failure, and serialization of a write
against completion. I/O-failure tests replace the writer with a fault-injecting
FileOutputStream subclass; production error handling still runs unchanged.

Android logging, Handler scheduling and connection-priority effects are stubbed.
Immediate posts run synchronously and delayed posts do not fire. A controlled
two-thread test verifies write/completion exclusion; this does not validate real
Binder scheduling, inactivity timing, Android lifecycle, radio behavior or SD
power-loss durability.

The companion Flutter file runs the real WAL policies and Dart native-download
wrapper. A test-only platform override selects the native wrapper on the host;
mocked Pigeon replies pass through the actual generated Dart error decoder.
Coverage includes seven failed cycles across reload/reconnect beyond the poison
threshold, no head skipping, final failure progress before polling, STOP ordering
and failure, cancellation, legacy-prefix migration, and byte-correct resume
before deletion. Shared desktop-receiver controls cover legitimate zeros and
short-file retention.

```text
cd app
flutter test --no-pub test/unit/sync_robustness_test.dart
```

These are separate native and Dart tests, not an instrumented BLE-to-firmware
run. Device deletion is mocked in Flutter and source-traced through firmware.

Notification recovery uses the same compiler runner:

```text
python app/test/native_storage/run.py --notifications --java <path-to-java>
```

It extracts production subscription setup, disconnect cleanup and the descriptor
callback. Seventeen cases exercise descriptor confirmation, missing resources,
registration/write rejection, callback failure, cleanup, retry, stale GATT and
preceding-operation callbacks, and both Android descriptor API paths. Android
objects and handler scheduling are simulated; the test does not exercise a radio.

## Extraction guards

`python -m unittest discover -s app/test/native_storage -p test_extraction.py`
checks missing, duplicated and reordered extraction boundaries and template
placeholders. Notification mode extracts the production serialized command queue
and cleanup code as well as subscription handling. The handler and Android objects
remain simulated; these tests do not establish physical BLE behavior.
