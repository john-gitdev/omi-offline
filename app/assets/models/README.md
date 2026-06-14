# Bundled models

## `silero_vad.onnx` — Silero VAD **v6.2.1**

On-device voice-activity detection (opt-in Silero path; see the app's Recording
Settings). Bundled as a Flutter asset and copied to a filesystem path at runtime
so the native ORT session can load it.

### Identity of the file we ship

| Field | Value |
|-------|-------|
| Upstream version | **v6.2.1** (byte-identical to v6.2 — the `.onnx` did not change between those two tags) |
| Source | [`snakers4/silero-vad`](https://github.com/snakers4/silero-vad) → `src/silero_vad/data/silero_vad.onnx` |
| Size | 2,327,524 bytes |
| git blob SHA-1 | `80c5592ef1f4c9ede3e357bbd02eb863358a6a9d` |
| SHA-256 | `1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3` |
| MD5 | `302cb198a7bb0400c62b73db2942737f` |
| Pinned in commit | `0ae14eaa0` (2026-05-23) — "bump silero_vad.onnx v3 → v6" |

The version was confirmed by matching the **git blob SHA-1** against the file at
each upstream release tag (it matches `v6.2.1` and `v6.2` exactly). The semantic
version is *not* embedded in the ONNX metadata, so this hash is the source of
truth — don't trust a filename or a guessed version string.

### I/O contract (what an update MUST preserve)

This is the post-v4 unified model. The native runner
(`app/android/app/src/main/kotlin/com/omi/offline/VadBatchRunner.kt`) and the
Dart channel (`app/lib/services/vad_batch_runner_channel.dart`) hard-code:

| | Name | Shape / type | Notes |
|---|------|--------------|-------|
| input | `input` | `[1, 576]` float32 | `[64-sample context \| 512-sample window]` at 16 kHz |
| input | `state` | `[2, 1, 128]` float32 | LSTM state, carried between windows |
| input | `sr` | scalar int64 | `16000` |
| output | `output` | float32 | speech probability for the window |
| output | `stateN` | `[2, 1, 128]` float32 | next state |

A v4-or-earlier model (1536-sample window, separate `h`/`c` inputs) will **not**
load against this code. If a future Silero release changes the I/O, update the
native runner and Dart channel together.

### How to check for / apply an update

```bash
# 1. Latest upstream release tag:
gh api repos/snakers4/silero-vad/releases/latest --jq .tag_name

# 2. Is our file already that version? Compare blob SHA-1s — equal = same file:
git hash-object app/assets/models/silero_vad.onnx
gh api "repos/snakers4/silero-vad/contents/src/silero_vad/data/silero_vad.onnx?ref=<TAG>" --jq .sha

# 3. To update: download the new onnx, replace the file, then refresh this table
#    (re-run the hashes above + `wc -c`, `sha256sum`, `md5sum`) and bump the
#    version in the root README.md ("Silero VAD vX.Y.Z").
curl -L -o app/assets/models/silero_vad.onnx \
  https://raw.githubusercontent.com/snakers4/silero-vad/<TAG>/src/silero_vad/data/silero_vad.onnx
```

After replacing the model, verify the I/O contract above still holds before
shipping — and smoke-test the Silero path on a recording.
