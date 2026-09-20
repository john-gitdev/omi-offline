# Bluetooth-toggle recovery follow-up to PR 404

PR 404 was merged into main at `16320d785bfeeb9cc15c3325b6eeb06cfaa2601d`.
This branch implements the separate recovery fix investigated with the user's
0.37.4 / oo-3.1.4 logs.

## Evidence and limits

The test with other accessories disconnected showed Bluetooth off at 22:30:27 UTC,
device-ready at 22:30:36, three unanswered listings, and rotation confirmation
timeouts. Reinitializing Dart connection state at 22:33:06 was followed by a
successful listing at 22:33:15. A later transfer stalled once and recovered.
All five listed files eventually reached their advertised sizes and were processed.

The historical log does not contain the failed subscription's native completion.
It supports stale notification state but does not prove the precise Android
trigger. The fix establishes readiness explicitly and makes failures observable;
it does not claim to resolve every possible radio or Android GATT failure.

## Validation

Focused Dart coverage exercises subscription completion/failure, concurrent
callers, refresh, explicit/native reconnect, stale completions, rotation timeout,
disconnect before/after issue, and the WAL partial-result/no-repeat policy.
The existing WAL integrity suite also runs against these changes.

The native JVM harness extracts the production subscription methods and descriptor
callback, with simulated Android objects, to verify success/failure and stale
callback handling. The existing production receiver harness covers file writes
and byte-integrity policy. Android Kotlin compilation checks the real bindings
and platform types.

Final validation passed: 132 Dart tests, 12 native notification tests, and 19
native storage-session tests. Static analysis reported no issues, and Android
`compileDevDebugKotlin` succeeded. This was not a full APK build. Rotation tests
use actual asynchronous stream scheduling and one real confirmation timeout.

## Required device check

Start a download, turn Bluetooth off mid-file, then turn it back on. Confirm a
fresh notification-ready message, resumed listing/download, and no repeated
rotation after an unknown outcome. Repeat with the app backgrounded and with
Force Sync active. Check final audio and device-source deletion after completion.
These hardware checks have not been performed by this task.
