# BLE storage-download integrity

Android storage downloads must retain a contiguous prefix of the device file.
File length is useful for completeness only if the receiver never substitutes
bytes for a missing range.

## Failure being prevented

The previous `StorageDownloadSession` padded forward DATA offsets with zeros
(up to an 8 MiB gap), appended the later payload, and accepted EOT. A later
packet covering the missing range was ignored as already covered. For a 12-byte
file, receiving bytes `[0,4)` then `[8,12)` could therefore produce a 12-byte
file with four invented zeros. The Dart WAL completeness check accepted the
length and requested DELETE before audio decoding. Firmware deletion acknowledges
the segment through the SD worker, making its ring space reclaimable.

```text
Before:
Firmware -> Android StorageDownloadSession receives DATA with a forward gap
         -> zero padding + later payload + EOT = full-length corrupt file
         -> Dart WAL accepts length -> DELETE -> device segment reclaimable

After:
Firmware -> Android StorageDownloadSession receives DATA with a forward gap
         -> preserve contiguous prefix; close with storage-integrity error
         -> Dart WAL saves pending prefix; awaits STOP -> no DELETE
Next sync:
Firmware offset READ -> Android appends contiguous remainder
                     -> Dart WAL checks completion -> DELETE
```

This establishes a receiver defect for a supplied packet sequence, not the
frequency or cause of packet gaps on a physical BLE link. Firmware advances
its sending offset only after a notification has been accepted.

## Receiver and application contract

- `StorageDownloadSession.onPacket()` rejects every forward offset without
  writing padding or that packet's payload. Duplicates are ignored; overlaps
  append only their new suffix. Existing start-ACK and timestamp gates remain.
- Packet handling and completion share a session monitor. Completion closes the
  writer once and conditionally removes only its own active-session entry.
- A failed write rolls back to the last fully accepted packet. Failed rollback
  or close reports a safe offset of zero, requiring a fresh download.
- Failures use the existing Pigeon error envelope with code `storage-integrity`,
  `expectedOffset`, and, for gaps, `incomingOffset`. No generated API change is
  required.
- Dart bounds the reported offset by the closed file's length and publishes it
  even when the progress timer has not fired. Invalid/missing offset details or
  an unreadable file length conservatively select zero.
- Dart awaits STOP. A thrown STOP error cannot mask an integrity error. The
  existing boolean STOP result is still unchecked; awaiting it is not proof
  that the device has stopped.
- Integrity failures end the current attempt without an immediate retry.
  `syncAll()` saves a pending WAL and returns partial; `syncWal()` saves the
  supplied attempt and rethrows. The batch cannot skip the undeleted head or
  charge this error to its poison-file deletion budget.

The native and Dart pieces must ship together. The desktop stream receiver's
`ProtocolGapException` seek-ahead behavior is separate and unchanged.

## Legacy prefixes and resume

WAL JSON includes `nativeIntegrityVersion`. Missing values default to zero.
Pending native downloads with a value other than 1 restart at zero because an
old prefix may already contain padding. Version 1 is set only after discarding
the legacy prefix and follows the offset through WAL persistence and listing
rebuilds. No scan for zeros is used: zeros can be legitimate content.

Listing rebuilds reuse bookmarks only for the same device, timestamp and session
ID, independent of a shifted file index. A boot session can contain multiple
pre-clock-sync segments; one segment's integrity version cannot certify another.

Pending, untrusted native SD-card bins are protected from ordinary processing and
all source pruning even when their saved offsets equal their advertised lengths.
This protection also applies before a successful listing or device attachment,
using persisted WAL state. A failed sync must not expose the old bytes to
processing before migration runs. Already-synced legacy files retain their
existing exemption; local files and the desktop stream path are unchanged.

Versioned prefixes retain normal resume reconciliation: bytes beyond the saved
bookmark are truncated, and a missing/shorter file rewinds the bookmark. Ordinary
disconnects still use conservative polled progress and may re-fetch valid bytes.
Integrity failures use the native accepted offset. Single-WAL attempts attach
the caller's rebuilt WAL object to the internal list so the saved offset/version
belongs to the actual attempt.

Already-synced legacy WALs retain their existing completion/delete-retry behavior.
This migration cannot diagnose completed local corruption or recover a device
segment already deleted by an older app. Downgrading restores the old receiver's
behavior.

## Compatibility and limits

**The firmware protocol did not change.** No firmware source, BLE opcode, packet
layout, capability bit, stored-audio format or Pigeon method signature changes
are required. Older two-byte ACKs remain supported.

Persistent integrity failures can block newer downloads behind the retained
head. Other existing short-read and generic-failure poison policies are unchanged.
Coverage is not a checksum: overlapping bytes are not compared, and arbitrary
content corruption without an offset gap is not detected. Closing a file does
not establish power-loss durability. The session monitor may delay completion
while a disk write is blocked. WAL-save failures remain best-effort under the
existing persistence conventions.

Migration applies to the existing native-download branch, including iOS; the
receiver implementation and native validation in this change are Android-specific.

## Validation boundaries

See [the native harness README](../app/test/native_storage/README.md) for commands
and coverage. The JVM harness extracts production Kotlin and generated Pigeon
error wrapping, uses real file I/O, injects write/close failures, and checks a
controlled write/completion race. Android scheduling and connection-priority
effects are substituted.

Flutter tests use the real Dart native wrapper and generated Pigeon decoding
with mocked native replies, plus shared desktop-receiver completeness controls.
They cover both sync entry points, repeated gaps beyond the poison threshold,
reload/reconnect, STOP ordering/failure, cancellation, migration and correct
resume before mocked deletion. Kotlin and Dart run as separate test boundaries.
Migration regressions also cover distinct pre-UTC segments from the same boot,
session collisions and shifted indices, plus processing protection after a
failed listing or without a device. The disconnect regression observes an
unanswered listing while disconnected, reloads the saved WAL after reconnect,
and verifies byte-correct offset resume before deletion. Its connection lifecycle
is mocked, not an Android BLE reconnect test.

**Physical-device/hardware validation has not been performed.** These checks do
not validate real BLE delivery, Android instrumentation, SD reclamation under
fault injection, or power-loss durability.
