# Codebase Refactoring & File Splitting Instructions

## Goal
The purpose of this document is to provide a structured, step-by-step plan for breaking down the largest "God" files in the `omi-offline` Flutter application. 

## Reasoning
Over time, some files have grown exceptionally large (exceeding 1,000 to 3,000 lines). These large files generally mix multiple concerns:
1.  **Domain Models & Data Classes** mixed with business logic.
2.  **State Management & UI Building** squashed into massive `build()` methods.
3.  **Hardware Protocols & Database Access** combined with application state.

Splitting these files will significantly improve readability, simplify testing, reduce merge conflicts, and enforce a clear separation of concerns.

---

## Step-by-Step Refactoring Plan

### 1. Refactor `app/lib/services/recordings_manager.dart` (Current: ~3280 lines)
*   **Reasoning:** This file is doing too much. It stores data models, runs SQLite logic, and handles isolate background processing.
*   **Step 1.1:** Create a new directory `app/lib/models/recordings/`.
*   **Step 1.2:** Extract all data classes (`Conversation`, `Batch`, `DiscardRecord`, `MarkerConversation`) from `recordings_manager.dart` into individual files inside the new models directory.
*   **Step 1.3:** Create a `RecordingsRepository` (or `RecordingsDatabaseService`) file. Move all raw SQLite CRUD operations here.
*   **Step 1.4:** Move isolate-specific logic (e.g., `_IsolateParams` and associated global functions) into a new file named `recordings_isolate_worker.dart`.
*   **Step 1.5:** Clean up `RecordingsManager` to act merely as an orchestrator that injects and delegates to these new services.

### 2. Refactor `app/lib/services/vad_audio_processor.dart` (Current: ~1869 lines)
*   **Reasoning:** The Voice Activity Detection (VAD) processor mixes simple configuration types with heavy buffer logic and inference engine implementations.
*   **Step 2.1:** Extract `ProcessingSettings`, `VadProcessingCancelled`, and any other config/exception classes into a `vad_types.dart` file.
*   **Step 2.2:** Extract buffer and frame management (`_DeferredFrame` class and logic) into an `AudioBufferManager` class.
*   **Step 2.3:** Abstract the VAD engine. Create an interface `VadEngine` and implement it separately (e.g., `SileroVadEngine.dart`), so `VadAudioProcessor` just handles data flow rather than the math.

### 3. Refactor `app/lib/pages/recordings/recordings_controller.dart` (Current: ~1644 lines)
*   **Reasoning:** The UI state controller has absorbed the domain definitions of third-party integration statuses and API failures.
*   **Step 3.1:** Move state enums and classes (`UploadStatus`, `IntegrationUploadState`, `IntegrationStatus`, `UploadFailure`) into `app/lib/models/integration_status.dart`.
*   **Step 3.2:** Extract networking/API calls related to uploading into a dedicated `IntegrationUploadService`. The controller should simply invoke this service and update UI flags based on the response.

### 4. Refactor `app/lib/providers/device_provider.dart` (Current: ~1270 lines)
*   **Reasoning:** This is a classic "God class." It orchestrates BLE hardware, background WAL syncs, crash logging, and lifecycle events simultaneously.
*   **Step 4.1:** Extract the crash logging logic (`_loadCrashLogs`, `_saveCrashLogs`) to a `CrashLogManager` utility service.
*   **Step 4.2:** Extract the background syncing logic (`_doBackgroundSync` and timers) to a `BackgroundSyncService`.
*   **Step 4.3:** Extract all Bluetooth specific listeners (Battery, Button, VAD threshold pushing) into an `OmiBleClient` or `BleHardwareService`.
*   **Step 4.4:** Refactor `DeviceProvider` so it just consumes these services and wraps their states into getters for the UI.

### 5. Refactor `app/lib/pages/recordings/recordings_page.dart` (Current: ~1222 lines)
*   **Reasoning:** Over 700 lines of complex component state logic, capped off by a 500-line `build()` method with deeply nested inline widgets.
*   **Step 5.1:** Create a directory `app/lib/pages/recordings/widgets/`.
*   **Step 5.2:** Identify major standalone blocks in the `build()` method (e.g., Header, List Items, Empty State, Bottom Sheets) and extract them into their own Stateless or Stateful Widgets.
*   **Step 5.3:** Replace the inline code in `RecordingsPage`'s `build()` with these new widget classes, reducing the core `build()` method to < 100 lines.

### 6. Refactor `app/lib/pages/settings/sync_page.dart` (Current: ~1198 lines)
*   **Reasoning:** Massive inline localized debug widgets and direct BLE commands clutter the UI layer.
*   **Step 6.1:** Move `_DiagnosticLogRow`, `_DebugButton`, and similar inline widget classes to `app/lib/pages/settings/widgets/`.
*   **Step 6.2:** Move the actual execution of raw Bluetooth diagnostic commands out of the state class and into the new `BleHardwareService` (from Step 4).

### 7. Refactor `app/lib/services/wals/sdcard_wal_sync.dart` (Current: ~1097 lines)
*   **Reasoning:** Binary protocol parsing logic is tangled tightly with high-level sync state orchestration.
*   **Step 7.1:** Extract exceptions (`_ProtocolGapException`, `_AckException`) to a `wal_sync_exceptions.dart` file.
*   **Step 7.2:** Extract the low-level byte manipulation and payload deciphering into a `wal_protocol_parser.dart` class. 
*   **Step 7.3:** Retain only the state-machine and sync process flow within `SDCardWalSyncImpl`.

---
**Global Refactoring Rule:**
Before removing or refactoring any code, ensure you perform a global search across the entire codebase to identify and resolve all dependencies. Never assume code locality. Ensure that references and imports to extracted classes are updated gracefully.
