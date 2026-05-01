# TODO

## Apple Watch Integration [minor]

The platform layer (watchOS app, iOS AppDelegate, Pigeon-generated Swift/Dart code) is complete and functional. The Dart side is never wired up.

### Issues

- **`WatchRecorderFlutterAPI.setUp()` never called** — Pigeon message channel handlers are never registered, so all incoming watch messages (audio segments, recording start/stop, battery updates) are silently dropped. Fix: instantiate `AppleWatchFlutterBridge` and call `WatchRecorderFlutterAPI.setUp(bridge)` in `ServiceManager.init()` or `main.dart`.

- **`AppleWatchFlutterBridge` never instantiated** — `app/lib/services/bridges/apple_watch_bridge.dart` exists but is never used anywhere in the app.

- **No consumer for watch audio data** — The `onSegment` callback in `AppleWatchFlutterBridge` has no handler. Watch audio frames need to be routed into the same pipeline as BLE audio.

- **No UI for watch status** — APIs exist to check pairing, reachability, battery level, and app installation (`WatchRecorderHostAPI`), but no Flutter screen or widget displays any of this.

### Relevant Files

- `app/lib/services/bridges/apple_watch_bridge.dart` — bridge class, needs instantiation + `setUp()` call
- `app/lib/gen/flutter_communicator.g.dart:468` — `WatchRecorderFlutterAPI.setUp()` defined here
- `app/lib/services/services.dart` — `ServiceManager.init()` is the right place to wire this up
- `app/ios/Runner/AppDelegate.swift` — WCSession delegate, already functional
- `app/ios/Runner/RecorderHostApiImpl.swift` — host API implementation, already functional
- `app/ios/omiWatchApp/` — watchOS app, already functional
