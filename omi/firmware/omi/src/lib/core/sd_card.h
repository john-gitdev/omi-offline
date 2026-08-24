#ifndef SD_CARD_H
#define SD_CARD_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <zephyr/kernel.h>

#define MAX_STORAGE_BYTES 0x1E000000 // 480MB
#define MAX_WRITE_SIZE 440
#define MAX_FILENAME_LEN 64
#define MAX_AUDIO_FILES 150 /* 12h × 6 files/hour (10-min rotation) = 72; explicit rotations
                             * (app command, BLE connect, priority/manual stop) make real
                             * files shorter, so 150 is the headroom for that. */
#define FILE_ROTATION_INTERVAL_MS (10 * 60 * 1000) // 10 minutes in milliseconds


typedef struct {
    uint32_t timestamp;      // Primary hex value: UTC epoch for normal files, uptime ticks for TMP
    uint32_t uptime_offset;  // Secondary hex value: session_id token for both TMP_ and tokenized (%08X_%08X) files
    uint32_t file_size;      // Size in bytes
    bool is_tmp;             // true if the filename has the TMP_ prefix
    bool is_stats;           // true if the file is stats.txt (non-parseable hex name)
} AudioFileMeta_t;

// Thread-safe accessors
int sd_get_cached_file_count(void);
int sd_get_cached_file_meta(int index, AudioFileMeta_t *out_meta);
bool sd_is_current_recording_file_meta(const AudioFileMeta_t *meta);
uint64_t sd_get_cached_total_size(void);

// Utility for reconstructing the BLE-facing <ts>_<sid>.txt segment name
void build_filename_from_meta(const AudioFileMeta_t* meta, char* out_buffer, size_t max_len);

/* Why a rotation is happening, recorded when it closes an EMPTY bin (one holding
 * nothing but its 36-byte 0xFFFFFFFB header) so the benign cases can be told apart
 * from the one that means audio was lost. Most empty bins are benign — see
 * sd_get_empty_bin_rotations().
 *
 * These are WIRE VALUES: they travel as arg0 of the 0x0063 DIAG_EMPTY_BIN_ROTATION
 * event record and are decoded by name in the app. Append only; never renumber. */
typedef enum {
    ROTATE_REASON_UNKNOWN = 0,
    ROTATE_REASON_MOUNT = 1,          /* first segment after mount — closes nothing */
    ROTATE_REASON_AGE = 2,            /* FILE_ROTATION_INTERVAL_MS, evaluated on a write */
    ROTATE_REASON_BLE_CONNECT = 3,    /* early rotate so the app can fetch the last recording */
    ROTATE_REASON_APP_CMD = 4,        /* CMD_ROTATE_FILE (the app's rotate-and-sync) */
    ROTATE_REASON_PRIORITY_START = 5, /* auto-mode RECORD_START — closes the preceding auto bin */
    ROTATE_REASON_PRIORITY_STOP = 6,  /* RECORD_STOP — closes the PRIORITY bin (empty here = loss) */
    ROTATE_REASON_TIME_SYNC = 7,      /* rotate to a UTC-keyed segment once the clock is known */
    ROTATE_REASON_CLEAR = 8,          /* CMD_CLEAR_STORAGE */
    ROTATE_REASON_ACTIVE_DELETED = 9, /* the active file was deleted; reopen on BLE disconnect */
    ROTATE_REASON_SESSION_END = 10,   /* manual-mode RECORD_STOP — closes the MANUAL bin (empty here = loss,
                                       * same reading as PRIORITY_STOP: that bin holds the recording's own
                                       * 0xFFFFFFFC) */
    ROTATE_REASON_IDLE_CONNECT = 11,  /* BLE-connect rotate serviced from the flush handler because no write
                                       * ever arrived to evaluate it — see should_rotate_file() */
} rotate_reason_t;

/* Request types for the SD worker */
typedef enum {
    REQ_CLEAR_AUDIO_DIR,
    REQ_WRITE_DATA,
    REQ_READ_DATA,
    REQ_CREATE_NEW_FILE,
    REQ_GET_FILE_STATS,
    REQ_DELETE_FILE,
    REQ_FLUSH_FILE,
    REQ_TIME_SYNCED,
    REQ_UNMOUNT,
    REQ_PAUSE_IO,
    REQ_INVALIDATE_CACHE,
} sd_req_type_t;

/* Read request response object */
struct read_resp {
    struct k_sem sem;
    int res;
    ssize_t read_bytes;
};

/* File statistics response */
struct file_stats_resp {
    struct k_sem sem;
    int res;
    uint32_t file_count;
    uint64_t total_size;
};

/* Generic request message passed to worker */
typedef struct {
    sd_req_type_t type;
    union {
        struct {
            uint8_t buf[MAX_WRITE_SIZE];
            size_t len;
            struct read_resp *resp;
        } write;
        struct {
            char filename[MAX_FILENAME_LEN]; // Specific file to read from
            uint32_t offset;
            uint32_t length;
            uint8_t *out_buf;
            struct read_resp *resp;
        } read;
        struct {
            struct read_resp *resp;
        } clear_dir;
        struct {
            struct read_resp *resp;
            uint8_t reason; /* rotate_reason_t — see create_new_audio_file() */
        } create_file;
        struct {
            struct file_stats_resp *resp;
        } file_stats;
        struct {
            char filename[MAX_FILENAME_LEN];
            struct read_resp *resp;
        } delete_file;
        struct {
            uint32_t utc_time;
        } time_synced;
    } u;
} sd_req_t;

/**
 * @brief Initialize the SD card module interface.
 *
 * @return 0 on success, negative error code otherwise.
 */
int app_sd_init(void);

/**
 * @brief Check if the SD card has completed boot init (card power-on + ring mount).
 *
 * Returns true once the SD worker has set sd_boot_ready. Safe to poll from any thread.
 */
bool sd_is_boot_ready(void);

/**
 * @brief Check whether the post-time-sync segment rotation is still in flight.
 *
 * Set when sd_notify_time_synced() is called; cleared by the SD worker once it has
 * rotated to a UTC-keyed segment. The storage thread polls this before responding
 * to CMD_LIST_FILES so the list is not built mid-rotation.
 *
 * It does NOT mean the list comes back free of uptime-keyed entries. Segments
 * recorded before the sync keep their uptime key permanently — the ring has no
 * directory to rename, so the app anchors them from each segment's inline
 * 0xFFFFFFFB header and shows them as "Unorganized". Only the LittleFS backend
 * ever made that guarantee, via a retroactive TMP→UTC rename walker that was
 * removed with it in oo-2.9.0.
 *
 * Safe to call from any thread.
 */
bool sd_is_timesync_rename_pending(void);

/**
 * @brief Get the number of audio frames dropped during SD boot init.
 *
 * During the SD boot phase (card power-on + ring mount), incoming audio frames
 * cannot be written and are discarded.
 * This counter tracks how many frames were dropped. Safe to call from any thread.
 *
 * @return Number of audio frames dropped during boot (0 if boot was instant or
 *         no audio was generated during boot).
 */
uint32_t sd_get_boot_dropped_frames(void);

/**
 * @brief Get the number of audio frames the SD queue rejected after boot.
 *
 * Tracks frames dropped in write_to_file() when the sd_msgq is saturated
 * (typically caused by an SD card stalling during internal maintenance).
 * Distinct from the boot-window counter. Safe to call from any thread.
 *
 * @return Cumulative stream-time dropped frames since boot.
 */
uint32_t sd_get_stream_dropped_frames(void);

/**
 * @brief Get the high-water mark of sd_msgq occupancy since boot.
 *
 * Peak number of queued write requests observed (out of SD_REQ_QUEUE_MSGS).
 * Shows how much headroom the write path keeps vs the drop edge — i.e. how
 * close write fairness is to falling behind. Safe to call from any thread.
 */
uint32_t sd_get_msgq_peak_depth(void);

/**
 * @brief Get the number of times write fairness forced a write turn over reads.
 *
 * Incremented whenever a steady read stream would otherwise have starved audio
 * writes and the worker forced a write to be serviced. Safe to call from any
 * thread.
 */
uint32_t sd_get_write_fair_activations(void);

/**
 * @brief Get the number of rotations that closed a bin holding no audio.
 *
 * Incremented when create_audio_file_with_timestamp() closes a file whose size is
 * at most the inline metadata header — i.e. a bin that was opened and rotated with
 * nothing (or only the 0xFFFFFFFB header) persisted. Monotonic since boot. Safe to
 * call from any thread.
 *
 * NOT a loss signal on its own, and was read as one for a long time. An empty bin
 * means nothing at all reached the card for that segment — and a marker cannot be the
 * missing part once ACCEPTED, because write_marker_header_to_storage() force-drains
 * its partial block, so a marker the SD queue takes puts the bin well past
 * header-only. (If that drain is rejected the block stays in transport.c's assembly
 * buffer, which no rotation drains, so the marker lands in the NEXT bin and leaves
 * this one empty — needs a full SD queue, and bumps no counter of its own.) What is
 * left is a rotation that landed where nothing was being written, which in auto mode
 * is any silent stretch: CMD_ROTATE_FILE, a priority boundary or a time sync opens a
 * bin, nobody speaks, and whatever rotates next closes it empty.
 *
 * Do NOT read it against the marker-drop counter either. Both are free-running totals
 * since boot that name no segment, so a marker dropped in one recording and an empty
 * bin from an idle rotation an hour later look exactly like a correlated loss. They
 * are independent: the marker-drop counter (0x19B10062 offset 52, owned by transport.c)
 * stands on its own as the loss signal,
 * and per-segment correlation is what the 0x0063 event log is for (arg0 =
 * rotate_reason_t, with a timestamp on every record).
 */
uint32_t sd_get_empty_bin_rotations(void);

/**
 * @brief Get the number of marker-bearing storage blocks RESCUED at the
 * sd_write_paused gate (written through the pause instead of dropped).
 *
 * Incremented when process_write_data_req() keeps a paused (non-draining) block
 * that contains an inline marker header, rather than discarding it. Before oo-2.5.9
 * that block was silently dropped — the one marker-loss path that bumped NO counter
 * (the sd_write_blocked overflow path still bumps stat_dropped_frames) — so this
 * counter located the lost 0xFFFFFFFC at the pause gate; now it confirms the rescue.
 * Monotonic since boot. Safe to call from any thread.
 */
uint32_t sd_get_marker_pause_gate_saves(void);

/**
 * @brief Get the peak stack usage (bytes) of the SD worker thread since boot.
 *
 * Reads the high-water mark via k_thread_stack_space_get (needs CONFIG_INIT_STACKS +
 * CONFIG_THREAD_STACK_INFO); the sentinel fill isn't restored after use, so a single
 * read returns the peak. Returns 0 if the thread isn't up or the configs are off.
 * Compare against SD_WORKER_STACK_SIZE to gauge how much stack is reclaimable.
 * Safe to call from any thread.
 */
uint32_t sd_get_worker_stack_used(void);

/**
 * @brief Diagnostics (ring backend): slowest single SD primitive since boot,
 *        packed as (tag << 24) | duration_ms, tag 1=write 2=read 3=CTRL_SYNC.
 *        Pinpoints a queue-full drop burst to the exact stalling disk op. 0 when
 *        the ring backend is inactive. Safe to call from any thread.
 */
uint32_t sd_get_ring_max_io_ms(void);

/**
 * @brief Diagnostics (ring backend): count of write_sectors / CTRL_SYNC failures
 *        (EIO) since boot — distinguishes "NAND rejected writes" from "NAND was
 *        merely slow". 0 when the ring backend is inactive. Any thread.
 */
uint32_t sd_get_ring_io_errors(void);

/**
 * @brief The storage backend mounted this boot. There has been exactly one since
 *        oo-2.9.0 (STORAGE_BACKEND_RING), so this always answers the same thing; it
 *        stays on the wire because the app's Diagnostics panel reads the field and an
 *        older app still expects it. Any thread.
 */
uint8_t sd_get_active_backend(void);

/**
 * @brief Put the SD card interface (controller) into a low-power (suspend) state.
 *        Note: This typically suspends the SPI controller managing the SD card slot.
 *
 * @return 0 on success, negative error code on failure to suspend.
 */
int app_sd_off(void);

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE

/**
 * @brief Write to the current audio file specified by the write pointer
 *
 * @param data Buffer containing data to write
 * @param length Number of bytes to write
 * @return number of bytes written
 */
uint32_t write_to_file(uint8_t *data, uint32_t length);

/**
 * @brief Same as write_to_file() but tolerates a longer SD-queue stall (≤500ms)
 *        before dropping. Use for blocks that carry a marker frame, which must
 *        not be lost to transient sd_msgq saturation.
 *
 * @param data Buffer containing data to write
 * @param length Number of bytes to write
 * @return number of bytes written
 */
uint32_t write_to_file_blocking(uint8_t *data, uint32_t length);

/**
 * @brief Read from a specific audio file
 *
 * @param filename Name of the file to read from (e.g., "1234567890.txt")
 * @param buf Buffer to read data into
 * @param amount Number of bytes to read
 * @param offset Offset within the file to read from
 * @return number of bytes read, or negative error code
 */
int read_audio_data(const char *filename, uint8_t *buf, int amount, int offset);

/**
 * @brief Get the size of the current writing file
 * @return size of the file in bytes
 */
uint32_t get_file_size(void);

/**
 * @brief Get the name of the current writing file
 * @param buf Buffer to store the filename
 * @param buf_size Size of the buffer
 * @return 0 on success, negative error code otherwise
 */
int get_current_filename(char *buf, size_t buf_size);

/**
 * @brief Check whether filename matches the currently-recording file.
 *
 * Thread-safe snapshot check used by the storage thread to decide
 * whether to auto-delete a just-synced file. Returns false if either
 * name is empty or no file is currently open for recording.
 *
 * @param filename Filename to compare (basename only, e.g. "67890abc.txt")
 * @return true if filename == current recording file
 */
bool sd_is_current_recording_file(const char *filename);

/**
 * @brief Return the most recently cached free space on the SD card (bytes).
 *
 * Updated each time the file-list cache is rebuilt on the SD worker thread.
 * Returns 0 if the cache has not been populated yet.
 */
uint32_t sd_get_cached_free_bytes(void);

/**
 * @brief Clear the audio directory.
 *
 * This deletes all audio files in the audio directory.
 * @return 0 if successful, negative errno code if error
 */
int clear_audio_directory(void);

/**
 * @brief Create a new audio file with current timestamp
 *
 * This forces creation of a new file, useful when BLE connection
 * has been active for a long time.
 *
 * @param reason Why this rotation is happening (rotate_reason_t). Only read when the
 *               rotation turns out to close an EMPTY bin, where it separates the
 *               benign silent-rotate cases from a lost Priority Recording. Pass the
 *               true cause; ROTATE_REASON_UNKNOWN records an empty bin as
 *               unattributed rather than misattributing it.
 * @return 0 if successful, negative errno code if error
 */
int create_new_audio_file(uint8_t reason);

/**
 * @brief Request a rotation without waiting for it (fire-and-forget).
 *
 * Same rotation as create_new_audio_file(), minus the wait: that one blocks up to
 * 2 s queueing plus 25 s on the worker's semaphore, which is 27 s a caller on a
 * shared thread cannot always afford. The button workqueue is one such caller —
 * a manual RECORD_STOP rotates from there, and stalling it also stalls
 * priority_cap_work and the button FSM's own 25 Hz poll.
 *
 * The rotation is still correctly ordered: the REQ_CREATE_NEW_FILE handler drains
 * sd_msgq into the OLD bin before rotating, whoever queued it, so a session-end
 * marker enqueued just before this call still lands in the bin it closes.
 *
 * Failure is either "the priority queue is full" or -ENODEV, meaning the SD worker
 * gave up on its boot mount and no longer drains that queue — reported so the caller
 * can say what was lost. A dropped rotation is recoverable rather than fatal: the
 * BLE-connect rotate serviced from REQ_FLUSH_FILE rotates the bin at the next
 * connect (see sd_worker_thread), which is also what completes a rotation the
 * worker had to defer because its durability sync failed.
 *
 * @param reason Why this rotation is happening (rotate_reason_t) — see
 *               create_new_audio_file() for how it is used.
 * @return 0 if the request was queued, negative errno if it was not.
 */
int sd_request_rotate_async(uint8_t reason);

/**
 * @brief Notify that BLE connection state has changed
 *
 * Call this when BLE connects/disconnects to manage file rotation.
 * @param connected true if BLE is now connected, false if disconnected
 */
void sd_notify_ble_state(bool connected);

/**
 * @brief Force a fresh file-cache enumeration on the SD worker (blocking).
 *
 * Rotations during a sync session skip their cache invalidation to keep the
 * session's frozen indices stable, so the cache may be stale by the next session.
 * Call this from the CMD_LIST_FILES path (storage thread) before building the
 * list response so the app always receives a freshly enumerated list. Marshalled
 * to the SD worker — which owns all cache state — and waits for completion.
 */
void sd_invalidate_file_cache_blocking(void);

/**
 * @brief Get file statistics
 *
 * @param file_count Pointer to store the number of audio files
 * @param total_size Pointer to store the total size of all audio files
 * @return 0 on success, negative error code otherwise
 */
int get_audio_file_stats(uint32_t *file_count, uint64_t *total_size);

/**
 * @brief Delete a specific audio file by name.
 *
 * If the file is currently being recorded to, the SD worker will stop
 * using it (flushing and closing), mark it as deleted, and the next
 * BLE disconnect will trigger creation of a new file.
 *
 * @param filename Name of the audio file to delete.
 * @return 0 on success, negative error code otherwise
 */
int delete_audio_file(const char *filename);

/**
 * @brief Flush current audio file to SD card.
 *
 * Flushes the batch write buffer and syncs the file to ensure all
 * pending data is written to SD. Useful before sync operations to ensure
 * file sizes are accurate.
 *
 * @return 0 on success, negative error code otherwise
 */
int sd_flush_current_file(void);

/**
 * @brief Notify SD card module that time has been synced
 *
 * Rotates to a fresh UTC-keyed segment so subsequent audio is organized; the
 * pre-sync segments keep their uptime key and the app anchors them from each
 * segment's inline header. Safe to call from any thread (uses a message queue).
 *
 * @param utc_time The UTC timestamp that was just synced
 */
void sd_notify_time_synced(uint32_t utc_time);

/**
 * @brief Check if SD card is powered on
 *
 * @return true if SD card is on, false otherwise
 */
bool is_sd_on(void);

/**
 * @brief Mark OTA as active or inactive. 
 * 
 * When OTA is active, SPI3 is resumed and kept active.
 */
void sd_set_ota_active(bool active);

/**
 * @brief Whether a DFU/OTA image upload is currently in progress.
 *
 * Bracketed by the MGMT_EVT_OP_IMG_MGMT_DFU_STARTED / _STOPPED callbacks (see
 * main.c). The BLE idle-disconnect handler consults this so it never drops the
 * link mid-DFU: DFU traffic rides the SMP characteristic and so never calls
 * transport_mark_activity(), leaving the idle timer to expire on an otherwise
 * healthy upload.
 */
bool sd_get_ota_active(void);

/**
 * @brief Pause or resume SD card writes (for AAD power saving).
 *
 * @param pause true to pause writes and suspend SD, false to resume.
 */
void sd_write_pause(bool pause);

#endif // CONFIG_OMI_ENABLE_OFFLINE_STORAGE

#endif // SD_CARD_H
