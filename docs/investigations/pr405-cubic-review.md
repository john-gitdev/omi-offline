# PR 405: Cubic reachability review

Reviewed all 14 inline findings Cubic raised on head `c9415ede` (its first pass).
The dispositions describe the fixes as they landed afterwards, in `a1a12516` and
later commits, so read each row as "reported at `c9415ede`, resolved since" rather
than as a description of that head. IDs below identify the GitHub review comments
(`https://github.com/john-gitdev/omi-offline/pull/405#discussion_r<ID>`).
All findings were traced to their callers and consequences; related reports share
one fix where they describe the same fault.

| Comment | Reachability and disposition |
| --- | --- |
| 4055942298 | Reachable if Android dispatches an old disconnect after reconnect. The foreground service already checks GATT identity, but manager cleanup ran first and could clear the new queue/services/subscription. Guard callback entry and identity-aware cleanup; serialize connection-state dispatch on the main handler. Test stale teardown with a live replacement subscription and service state. |
| 4055942301 | Reachable when a descriptor callback is lost or a prior queued operation stalls. Native pending state and the queue previously had no expiry. A native watchdog now closes the affected GATT, fails pending work, resets the queue, and invokes the existing foreground-service recovery path. It deliberately does not advance the same link past an untagged missing callback. |
| 4055942303 | Test-harness defect, not an app-runtime path. Missing/duplicated/reordered extraction markers and placeholders now fail explicitly. Mutation tests exercise these failures. |
| 4055942307 | Reachable on reconnect descriptor rejection. The restore previously logged while consumers saw connected. A current-generation restore failure now requests soft disconnect and publishes disconnection, without unmanaging or introducing another reconnect loop. |
| 4055942309 | Same reachable native/Dart ownership problem as 2301. Dart now retains the actual native future; the native watchdog owns expiry and teardown before allowing a new link. |
| 4055942314 | Test blind spot: the old queue fake let commands run without retiring their predecessor. Notification tests now extract the actual production queue, including processing state, completion and reset. Cases cover a queued subscription behind a stalled read and late old-GATT callbacks. |
| 4055942316 | Overlaps 2301/2309, but the claim that a retry is guaranteed to fail after native completion is incorrect: native completion removes its pending entry. The real exposure was a retry before completion. Retaining the raw native future and bounding it in native prevents that overlap; a virtual-time Dart test crosses the former timeout and verifies one shared request. |
| 4055942319 | Harness-only coupling confirmed. Notification extraction no longer reads or validates the unrelated Pigeon/session seams; a test removes the session class and still extracts notification code. |
| 4055942322 | Vacuous assertion confirmed. The WAL mock now tracks acquisition/release and rejects double acquisition/unheld release. Existing sync tests verify release after unknown rotation, cancellation, failures and normal completion. |
| 4055942326 | Test-runtime cost confirmed. Rotation confirmation timeout is an instance constructor option with the same 25-second production default. Tests use 50 ms and real async stream scheduling. |
| 4055950271 | Reachable after auto reconnect followed by explicit teardown; prior keys survived. Explicit disconnect now forgets them and unmanages even if the physical link is already down. Tests cover both connected and disconnected teardown. |
| 4055950274 | The logs do not prove spontaneous CCCD loss without disconnect. However, standalone delete/clear/stop can bypass fresh listing, so their cached-readiness gap is reachable. All storage entry points now revalidate before sending. Native download already confirms before READ. Tests reject refresh and verify no destructive command is issued. |
| 4055950277 | Harness-only lookup weakness confirmed. Stubs now match actual service, characteristic and descriptor UUIDs; wrong-UUID tests exercise rejection. |
| 4055950279 | Reachable after failed initial subscription followed by disconnect: abandoned controllers entered restore intent. Failed attempts now discard a controller only if it is still current and has no listener. A live listener survives failed refresh and successful retry; tests cover both paths. |

## End-to-end data safety

Storage commands remain under the existing Omi storage lock. Subscription expiry
fails an active native download, leaving its accepted file prefix and WAL pending.
The `notification-subscription` error remains a transport error, excluded from the
poison/deletion budget. Generic disconnect errors follow the existing disconnected
transport handling. No new success or deletion path was added. Native receiver
tests separately check byte integrity and resume; WAL tests cover eventual
deletion, failed deletion, partial sync, and unknown rotation outcomes.

Firmware storage command dispatch and the CCCD notification contract are unchanged.
Rotation still sends at most one command after an unknown outcome and lets a later
ordinary listing reconcile files. iOS and old-app migration are outside this fix.

Physical Bluetooth-toggle validation remains outstanding. JVM Android stubs and
mocked Pigeon responses establish software behavior, not a radio/firmware run.

## Validation results

- 139 focused Dart tests passed, followed by all three added adversarial tests:
  142 distinct passing tests in total.
- 17 native notification/queue tests and 19 native storage-integrity tests passed.
- Four harness extraction-drift tests passed.
- Static analysis passed for the changed Dart implementation and regressions.
- Android `compileDevDebugKotlin` succeeded; no full APK build was performed.
