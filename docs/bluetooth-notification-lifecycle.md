# Bluetooth notification lifecycle

Android owns the managed BLE connection and reconnect policy. Dart retains its
transport object across reconnects, but notification readiness belongs to each
connection, not to the existence of a Dart stream controller.

`BleHostApi.subscribeCharacteristic` completes asynchronously after Android's
CCCD descriptor write succeeds. Missing GATT, characteristic or descriptor, local
registration rejection, descriptor rejection/failure and disconnect are errors.
Queued subscriptions cannot be confirmed by the descriptor callback of an
earlier operation or a previous GATT.

Native bounds subscription queue wait and descriptor confirmation with a watchdog.
Expiry fails pending operations, closes that GATT and resets its command queue,
then reports disconnection through the existing native reconnect policy. It never
advances past a missing descriptor callback on the same link: Android does not
tag descriptor acknowledgments with a request ID. Teardown and delayed callbacks
check GATT identity before touching replacement connection state.

`NativeBleTransport` waits for that result before exposing a characteristic stream.
Concurrent callers join the pending subscription. Failures invalidate readiness
so another caller can retry. Dart retains the actual native future until it
settles; it does not independently time out and abandon native subscription state.
Disconnect clears readiness and closes the old
streams. Both explicit and native reconnect paths restore notifications;
completion from an earlier connection cannot confirm a replacement subscription.
Callers still need to attach to the replacement stream after disconnect.
Explicit teardown forgets subscription intent and unmanages even an already-lost
link. A failed reconnect restore reports an unusable transport and requests a
soft disconnect, leaving native in charge of reconnect. Failed subscriptions
without listeners are discarded; a failed refresh preserves existing listeners.

Storage listing, rotation, deletion, stop, clear and byte-stream acquisition
revalidate notifications through
`refreshCharacteristicStream`, while retaining listeners already attached on the
current connection. Native downloads also wait for subscription confirmation
before issuing READ. A delayed confirmation cannot start a cancelled download.

An unanswered listing ends that sync as skipped and preserves WAL offsets and
source files. Whether it also reconnects (`DeviceService.recycleConnection()`)
depends on why nothing usable came back:

- The device replied and refused: `STORAGE_NOT_READY` (the SD card is not
  mounted, or has failed), a malformed reply, or an EOT without a count. Its
  replies are arriving, so a reconnect cannot help and none is requested
  (`DeviceConnection.lastListingHeardDevice`).
- The link is already down. Native owns that reconnect; forcing a Dart connect
  would hold DeviceService's mutex for up to the 75 s connect backstop.
- Silence on a live link, which is what a stale subscription looks like. One
  reconnect, then none until the device is heard from again. A reconnect that did
  not help will not help twice, and in the background each one is adopted as a
  due sync (the failed run recorded a skip), which fails and reconnects again.

Notification setup failure during a download is a transport error. It recycles
the link on every occurrence and cannot spend a file's poison budget.

Rotation is a state-changing command. A failure before its write is certain not
to have rotated (`StorageRotationNotStartedException`): the run is skipped and
hands the force-sync cooldown back. A write/confirmation failure after issuing
it has an unknown outcome, represented by
`StorageRotationUnconfirmedException`. The WAL layer returns a partial result,
preserves drafts and the force-sync cooldown, and does not send another rotation
in that run. A subsequent ordinary sync lists the device's actual closed files
and reconciles the backlog. Both request connection recovery under the rules
above; an acknowledged rotation counts as hearing from the device.

This does not change storage packet formats, firmware, or the one-device model.
An ACK received before the rotation write is ignored. The existing firmware's
untagged command acknowledgments remain a compatibility constraint: the native
storage keep-alive (paused only while a download is active) is acknowledged with
the same two bytes, so one landing between the rotation write and the real ACK is
taken as the rotation's. Fixing that needs the firmware to put something in the
ACK that identifies the request, as `CMD_READ_FILE`'s already does by echoing the
file timestamp.
