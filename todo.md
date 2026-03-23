# TODO

## UI/UX

### Unknown Timestamp Handling

Files recorded before the device ever synced time (drained battery before first BLE connection)
will have no valid UTC and appear as `TMP_` on the filesystem. These recordings should surface
in the app with an "Unknown date" state rather than silently failing or being dropped.

**Tasks:**
- [ ] Detect recordings with `timestamp == 0` (TMP_ files that were never renamed) in the WAL/recordings list
- [ ] Show these in a dedicated "Unknown date" section or with a placeholder label in the daily batch UI
- [ ] Allow the user to manually set a date/time for an unknown-timestamp recording
  - Tapping sets `StorageFile.timestamp` (or equivalent metadata) and re-slots the recording into the correct day
  - Persist the user-set timestamp so it survives app restart
- [ ] Consider showing a one-time prompt when unknown recordings are detected ("Some recordings have no date — tap to assign")
