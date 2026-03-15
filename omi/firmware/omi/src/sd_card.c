#include "lib/core/sd_card.h"
#include <ff.h>
#include <zephyr/fs/fs.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/fs/fs.h>
#include <zephyr/fs/fs_sys.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/sys/check.h>

LOG_MODULE_REGISTER(sd_card, CONFIG_LOG_DEFAULT_LEVEL);

#define DISK_DRIVE_NAME "SD"        // Disk drive name
#define DISK_MOUNT_PT "/SD:"        // Mount point path
#define SD_WRITE_QUEUE_MSGS 60      // Write queue: 50fps * ~1.2s headroom
#define SD_READ_QUEUE_MSGS  10      // Read queue: BLE sync sends one chunk at a time
#define SD_FSYNC_THRESHOLD 20000    // Threshold in bytes to trigger fsync
#define WRITE_BATCH_COUNT 50        // Number of writes to batch before writing to SD card
                                    // Increased from 10 → 50 for battery savings (~5s flush interval vs ~1s).
                                    // Trade-off: up to 5s audio lost on sudden power cut (vs 1s).
                                    // Revert to 10 if SD write reliability issues are observed.
#define ERROR_THRESHOLD 5           // Maximum allowed write errors before taking action

// batch write buffer
static uint8_t write_batch_buffer[WRITE_BATCH_COUNT * MAX_WRITE_SIZE];
static size_t write_batch_offset = 0;
static int write_batch_counter = 0;
static uint8_t writing_error_counter = 0;

static FATFS fat_fs;

static struct fs_mount_t mp = {
    .type = FS_FATFS,
    .fs_data = &fat_fs,
    .flags = FS_MOUNT_FLAG_NO_FORMAT | FS_MOUNT_FLAG_USE_DISK_ACCESS,
    .storage_dev = (void *) DISK_DRIVE_NAME,
    .mnt_point = DISK_MOUNT_PT,
};

#define FILE_DATA_DIR "/SD:/audio"
#define FILE_DATA_PATH "/SD:/audio/a01.txt"
#define FILE_INFO_PATH "/SD:/info.txt"

static struct fs_file_t fil_data;
static struct fs_file_t fil_info;

static bool is_mounted = false;
static bool sd_enabled = false;
static uint32_t current_file_size = 0;
static uint32_t current_file_offset = 0;
static size_t bytes_since_sync = 0;

// Get the device pointer for the SDHC SPI slot from the device tree
static const struct device *const sd_dev = DEVICE_DT_GET(DT_NODELABEL(sdhc0));
static const struct gpio_dt_spec sd_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(sdcard_en_pin), gpios, {0});

// Separate queues eliminate write/read starvation: writes can no longer block
// read enqueues. Worker services writes first (recording is primary), then reads.
K_MSGQ_DEFINE(write_msgq, sizeof(sd_req_t), SD_WRITE_QUEUE_MSGS, 4);
K_MSGQ_DEFINE(read_msgq,  sizeof(sd_req_t), SD_READ_QUEUE_MSGS,  4);

void sd_worker_thread(void);

static int sd_enable_power(bool enable)
{
    int ret;
    gpio_pin_configure_dt(&sd_en, GPIO_OUTPUT);
    const struct device *spi_dev = DEVICE_DT_GET(DT_NODELABEL(spi3));
    if (enable) {
        ret = gpio_pin_set_dt(&sd_en, 1);

        if (device_is_ready(spi_dev)) {
            /* Resume SPI and SD devices */
            pm_device_action_run(spi_dev, PM_DEVICE_ACTION_RESUME);
            pm_device_action_run(sd_dev, PM_DEVICE_ACTION_RESUME);
        }
        sd_enabled = true;
    } else {
        if (device_is_ready(spi_dev)) {
            /* Suspend SPI and SD devices to save power */
            pm_device_action_run(sd_dev, PM_DEVICE_ACTION_SUSPEND);
            pm_device_action_run(spi_dev, PM_DEVICE_ACTION_SUSPEND);
        }

        /* Zephyr didn't handle CS pin in suspend, we handle it manually */
        gpio_pin_configure(DEVICE_DT_GET(DT_NODELABEL(gpio1)), 11, GPIO_DISCONNECTED);
        ret = gpio_pin_set_dt(&sd_en, 0);
        sd_enabled = false;
    }
    return ret;
}

static int sd_unmount()
{
    // Ensure files are closed before unmounting
    fs_close(&fil_data);
    fs_close(&fil_info);
    int ret;
    ret = fs_unmount(&mp);
    if (ret) {
        LOG_INF("Disk unmounted error (%d) .", ret);
        return ret;
    }

    LOG_INF("Disk unmounted.");
    is_mounted = false;
    sd_enable_power(false);
    return 0;
}

static int sd_mount()
{
    int ret;
    do {
        static const char *disk_pdrv = DISK_DRIVE_NAME;
        uint64_t memory_size_mb;
        uint32_t block_count;
        uint32_t block_size;

        ret = sd_enable_power(true);
        if (ret < 0) {
            LOG_ERR("Failed to power on SD card (%d)", ret);
            return ret;
        }

        int init_ret;
        init_ret = disk_access_ioctl(disk_pdrv, DISK_IOCTL_CTRL_INIT, NULL);
        if (init_ret != 0) {
            LOG_ERR("Storage init ERROR! (%d)", init_ret);
            break;
        }

        if (disk_access_ioctl(disk_pdrv, DISK_IOCTL_GET_SECTOR_COUNT, &block_count)) {
            LOG_ERR("Unable to get sector count");
            break;
        }
        LOG_INF("Block count %u", block_count);

        if (disk_access_ioctl(disk_pdrv, DISK_IOCTL_GET_SECTOR_SIZE, &block_size)) {
            LOG_ERR("Unable to get sector size");
            break;
        }
        LOG_INF("Sector size %u", block_size);

        memory_size_mb = (uint64_t) block_count * block_size;
        LOG_INF("Memory Size(MB) %u", (uint32_t) (memory_size_mb >> 20));

        if (disk_access_ioctl(disk_pdrv, DISK_IOCTL_CTRL_DEINIT, NULL) != 0) {
            LOG_ERR("Storage deinit ERROR!");
            break;
        }
    } while (0);
    mp.mnt_point = DISK_MOUNT_PT;

    if (is_mounted) {
        LOG_INF("Disk already mounted.");
        return 0;
    }

    if (fs_mount(&mp)) {
        LOG_INF("File system not found, creating file system...");
        ret = fs_mkfs(FS_FATFS, (uintptr_t) mp.storage_dev, NULL, 0);
        if (ret != 0) {
            LOG_ERR("Error formatting filesystem [%d]", ret);
            sd_enable_power(false);
            return ret;
        }

        ret = fs_mount(&mp);
        if (ret) {
            LOG_INF("Error mounting disk %d.", ret);
            sd_enable_power(false);
            return ret;
        }
    }

    LOG_INF("Disk mounted.");
    is_mounted = true;

    return ret;
}

#define SD_WORKER_STACK_SIZE 4096
#define SD_WORKER_PRIORITY 7
K_THREAD_STACK_DEFINE(sd_worker_stack, SD_WORKER_STACK_SIZE);
static struct k_thread sd_worker_thread_data;
static k_tid_t sd_worker_tid = NULL;

int app_sd_init(void)
{
    if (!sd_worker_tid) {
        sd_worker_tid = k_thread_create(&sd_worker_thread_data, sd_worker_stack, SD_WORKER_STACK_SIZE,
                                        (k_thread_entry_t)sd_worker_thread, NULL, NULL, NULL,
                                        SD_WORKER_PRIORITY, 0, K_NO_WAIT);
        k_thread_name_set(sd_worker_tid, "sd_worker");
    }
    return 0;
}

uint32_t get_file_size()
{
    return current_file_size;
}

int read_audio_data(uint8_t *buf, int amount, int offset)
{
    struct read_resp resp;
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_READ_DATA;
    req.u.read.out_buf = buf;
    req.u.read.length = amount;
    req.u.read.offset = offset;
    req.u.read.resp = &resp;

    LOG_INF("[SD_READ] Queuing read (offset=%u len=%u read_q=%u/%u write_q=%u/%u)",
            (unsigned)offset, (unsigned)amount,
            (unsigned)k_msgq_num_used_get(&read_msgq),  (unsigned)SD_READ_QUEUE_MSGS,
            (unsigned)k_msgq_num_used_get(&write_msgq), (unsigned)SD_WRITE_QUEUE_MSGS);
    int ret = k_msgq_put(&read_msgq, &req, K_MSEC(100));
    if (ret) {
        LOG_ERR("[SD_READ] read_msgq full — read aborted at offset %u: %d",
                (unsigned)offset, ret);
        return ret;
    }

    if (k_sem_take(&resp.sem, K_MSEC(5000)) != 0) {
        LOG_ERR("Timeout waiting for read_audio_data response");
        return -1;
    }
    if (resp.res) {
        LOG_ERR("Failed to read audio data: %d", resp.res);
        return -1;
    }
    return resp.read_bytes;
}


uint32_t write_to_file(uint8_t *data, uint32_t length)
{
    sd_req_t req = {0};
    req.type = REQ_WRITE_DATA;
    memcpy(req.u.write.buf, data, length);
    req.u.write.len = length;

    uint32_t q_used = k_msgq_num_used_get(&write_msgq);
    if (q_used >= SD_WRITE_QUEUE_MSGS - 2) {
        LOG_WRN("[SD_WRITE] write_msgq near-full (%u/%u)", (unsigned)q_used, (unsigned)SD_WRITE_QUEUE_MSGS);
    }
    int ret = k_msgq_put(&write_msgq, &req, K_MSEC(100));
    if (ret) {
        LOG_ERR("[SD_WRITE] write_msgq full (%u/%u) — audio frame dropped: %d",
                (unsigned)k_msgq_num_used_get(&write_msgq), (unsigned)SD_WRITE_QUEUE_MSGS, ret);
        return 0;
    }

    return length;
}

int clear_audio_directory(void)
{
    struct read_resp resp;
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_CLEAR_AUDIO_DIR;
    req.u.clear_dir.resp = &resp;

    int ret = k_msgq_put(&read_msgq, &req, K_MSEC(100));
    if (ret) {
        LOG_ERR("Failed to queue clear_audio_directory request: %d", ret);
        return -1;
    }

    if (k_sem_take(&resp.sem, K_MSEC(5000)) != 0) {
        LOG_ERR("Timeout waiting for clear_audio_directory response");
        return -1;
    }

    if (resp.res) {
        LOG_ERR("Failed to clear audio directory: %d", resp.res);
        return -1;
    }

    save_offset(0);

    return 0;
}

int save_offset(uint32_t offset)
{
    sd_req_t req = {0};
    req.type = REQ_SAVE_OFFSET;
    req.u.info.offset_value = offset;

    int ret = k_msgq_put(&write_msgq, &req, K_MSEC(100));
    if (ret) {
        LOG_ERR("Failed to queue save_offset request: %d", ret);
        return -1;
    }
    return 0;
}

uint32_t get_offset(void)
{
    return current_file_offset;
}

int app_sd_off(void)
{
    if (is_mounted) {
        sd_unmount();
    } else {
        sd_enable_power(false);
        sd_enabled = false;
    }
    return 0;
}

bool is_sd_on(void)
{
    return sd_enabled;
}

/* SD worker thread */
void sd_worker_thread(void)
{
    sd_req_t req;
    int res;
    ssize_t bw = 0, br = 0;

    /* Attempt to mount FS - board-specific mount code may be needed */
    res = sd_mount();
    if (res != 0) {
        LOG_ERR("[SD_WORK] mount failed: %d\n", res);
        return;
    }

    struct fs_dirent dirent;
    int stat_res = fs_stat(FILE_DATA_DIR, &dirent);
    if (stat_res < 0) {
        int mk_res = fs_mkdir(FILE_DATA_DIR);
        if (mk_res < 0) {
            LOG_ERR("[SD_WORK] mkdir %s failed: %d\n", FILE_DATA_DIR, mk_res);
        }
    }

    /* Open data file (append) */
    fs_file_t_init(&fil_data);
    res = fs_open(&fil_data, FILE_DATA_PATH, FS_O_CREATE | FS_O_RDWR);
    if (res < 0) {
        LOG_ERR("[SD_WORK] open data failed: %d\n", res);
        return;
    } else {
        /* move to end for append writes by default */
        res = fs_seek(&fil_data, 0, FS_SEEK_END);
    }

    struct fs_dirent data_stat;
    int stat_res_data = fs_stat(FILE_DATA_PATH, &data_stat);
    if (stat_res_data == 0) {
        current_file_size = data_stat.size;
    } else {
        current_file_size = 0;
    }

    /* Open info file (read/write, create if not exists) */
    struct fs_dirent info_stat;
    int info_exists = fs_stat(FILE_INFO_PATH, &info_stat);
    fs_file_t_init(&fil_info);
    res = fs_open(&fil_info, FILE_INFO_PATH, FS_O_CREATE | FS_O_RDWR);
    if (res < 0) {
        LOG_ERR("[SD_WORK] open info failed: %d\n", res);
        return;
    } else {
        bool need_init_offset = false;
        if (info_exists < 0) {
            need_init_offset = true;
        } else if (info_stat.size < sizeof(uint32_t)) {
            need_init_offset = true;
        }
        if (need_init_offset) {
            current_file_offset = 0;
            uint32_t zero_offset = 0;
            ssize_t bw = fs_write(&fil_info, &zero_offset, sizeof(zero_offset));
            if (bw != sizeof(zero_offset)) {
                LOG_ERR("[SD_WORK] init info.txt failed to write offset 0: %d\n", (int)bw);
            } else {
                fs_sync(&fil_info);
            }
        } else {
            /* Read existing offset from info.txt */
            fs_seek(&fil_info, 0, FS_SEEK_SET);
            ssize_t rbytes = fs_read(&fil_info, &current_file_offset, sizeof(current_file_offset));
            if (rbytes != sizeof(current_file_offset)) {
                LOG_ERR("[SD_WORK] Failed to read offset at boot: %d\n", (int)rbytes);
                current_file_offset = 0;
            } else {
                LOG_INF("[SD_WORK] Loaded offset from info.txt: %u\n", current_file_offset);
            }
        }

        fs_seek(&fil_data, 0, FS_SEEK_END);

        /* If data file is empty but info.txt has a non-zero offset, it's a stale
         * leftover (e.g. from a reflash or a crash after DELETE). Reset to 0 so
         * the app characteristic doesn't show a false bad-state. */
        if (current_file_size == 0 && current_file_offset > 0) {
            LOG_WRN("[SD_WORK] Stale offset %u with empty data file — resetting info.txt to 0",
                    current_file_offset);
            current_file_offset = 0;
            uint32_t zero = 0;
            fs_seek(&fil_info, 0, FS_SEEK_SET);
            bw = fs_write(&fil_info, &zero, sizeof(zero));
            if (bw == sizeof(zero)) {
                fs_sync(&fil_info);
            }
        }
    }

    // k_poll lets the thread sleep until either queue has data, with no periodic
    // wakeups. This means zero CPU overhead when muted (no writes) and no sync
    // is active. Write-priority is maintained by trying write_msgq first after wakeup.
    struct k_poll_event poll_events[2] = {
        K_POLL_EVENT_STATIC_INITIALIZER(K_POLL_TYPE_MSGQ_DATA_AVAILABLE,
                                        K_POLL_MODE_NOTIFY_ONLY, &write_msgq, 0),
        K_POLL_EVENT_STATIC_INITIALIZER(K_POLL_TYPE_MSGQ_DATA_AVAILABLE,
                                        K_POLL_MODE_NOTIFY_ONLY, &read_msgq, 0),
    };

    while (1) {
        // True sleep until at least one queue has data.
        k_poll(poll_events, 2, K_FOREVER);
        poll_events[0].state = K_POLL_STATE_NOT_READY;
        poll_events[1].state = K_POLL_STATE_NOT_READY;

        // Drain all available items before sleeping again.
        // Writes are serviced before reads so audio frames are never delayed
        // by a pending BLE sync read. Reads are still bounded by the 5s
        // semaphore timeout in read_audio_data() — worst case latency is one
        // full batch-flush cycle (~1-2s on slow cards).
        while (1) {
            if (k_msgq_get(&write_msgq, &req, K_NO_WAIT) != 0 &&
                k_msgq_get(&read_msgq,  &req, K_NO_WAIT) != 0) {
                break; // both queues empty — go back to sleep
            }
        switch (req.type) {
            case REQ_WRITE_DATA:
                LOG_DBG("[SD_WORK] Buffering %u bytes to batch write\n", (unsigned)req.u.write.len);

                memcpy(write_batch_buffer + write_batch_offset, req.u.write.buf, req.u.write.len);
                write_batch_offset += req.u.write.len;
                write_batch_counter++;

                if (write_batch_counter >= WRITE_BATCH_COUNT) {
                    LOG_INF("[SD_WORK] WRITE_BATCH_COUNT reached. Flushing batch write.");
                    res = fs_seek(&fil_data, 0, FS_SEEK_END);
                    if (res < 0) {
                        LOG_ERR("[SD_WORK] seek end before write failed: %d\n", res);
                    }
                    bw = fs_write(&fil_data, write_batch_buffer, write_batch_offset);
                    if (bw < 0 || (size_t)bw != write_batch_offset) {
                        writing_error_counter++;

                        LOG_ERR("[SD_WORK] batch write error %d bw=%d wanted=%u\n", (int)bw, (int)bw, (unsigned)write_batch_offset);
                        if (bw > 0) {
                            LOG_INF("Attempting to truncate to correct packet position");
                            uint32_t truncate_offset = current_file_size + bw - bw % MAX_WRITE_SIZE;
                            int ret = fs_truncate(&fil_data, truncate_offset);
                            if (ret < 0) {
                                LOG_ERR("Failed to truncate to next packet position: %d", ret);
                                break;
                            }
                            LOG_INF("Shifted file pointer to correct packet position: %u", truncate_offset);
                            current_file_size += bw - bw % MAX_WRITE_SIZE;
                        }

                        if (writing_error_counter >= ERROR_THRESHOLD) {
                            LOG_ERR("[SD_WORK] Too many write errors (%d). Stopping SD worker.\n", writing_error_counter);
                            fs_close(&fil_data);
                            fs_file_t_init(&fil_data);
                            LOG_INF("[SD_WORK] Re-opening data file after too many errors.\n");
                            int reopen_res = fs_open(&fil_data, FILE_DATA_PATH, FS_O_CREATE | FS_O_RDWR);
                            if (reopen_res == 0) {
                                writing_error_counter = 0;
                                fs_seek(&fil_data, 0, FS_SEEK_END);
                            } else {
                                LOG_ERR("[SD_WORK] open new data file failed: %d. Terminating operation", reopen_res);
                            }
                        }

                        write_batch_offset = 0;
                        write_batch_counter = 0;
                        break;
                    }

                    bytes_since_sync += bw > 0 ? bw : 0;
                    current_file_size += bw > 0 ? bw : 0;
                    write_batch_offset = 0;
                    write_batch_counter = 0;
                }

                if (bytes_since_sync >= SD_FSYNC_THRESHOLD) {
                    uint32_t t0 = k_uptime_get_32();
                    LOG_INF("[SD_WORK] fs_sync start (write_q=%u read_q=%u)",
                            (unsigned)k_msgq_num_used_get(&write_msgq),
                            (unsigned)k_msgq_num_used_get(&read_msgq));
                    res = fs_sync(&fil_data);
                    LOG_INF("[SD_WORK] fs_sync done in %u ms (write_q=%u read_q=%u)",
                            (unsigned)(k_uptime_get_32() - t0),
                            (unsigned)k_msgq_num_used_get(&write_msgq),
                            (unsigned)k_msgq_num_used_get(&read_msgq));
                    if (res < 0) {
                        LOG_ERR("[SD_WORK] fs_sync data failed: %d\n", res);
                    }
                    bytes_since_sync = 0;
                }

                break;

            case REQ_READ_DATA:
                LOG_DBG("[SD_WORK] Reading %u bytes from data file at offset %u\n",
                        (unsigned)req.u.read.length, (unsigned)req.u.read.offset);

                res = fs_seek(&fil_data, req.u.read.offset, FS_SEEK_SET);
                if (res < 0) {
                    LOG_ERR("[SD_WORK] lseek failed: %d\n", res);
                    if (req.u.read.resp) {
                        req.u.read.resp->res = res;
                        req.u.read.resp->read_bytes = 0;
                        k_sem_give(&req.u.read.resp->sem);
                    }
                    break;
                }
                br = fs_read(&fil_data, req.u.read.out_buf, req.u.read.length);
                if (req.u.read.resp) {
                    req.u.read.resp->res = (br < 0) ? br : 0;
                    req.u.read.resp->read_bytes = (br < 0) ? 0 : br;
                    k_sem_give(&req.u.read.resp->sem);
                }
                break;

            case REQ_SAVE_OFFSET:
                LOG_DBG("[SD_WORK] Saving offset %u to info file\n", (unsigned)req.u.info.offset_value);
                /* Overwrite info.txt with 4-byte offset value (binary) */
                res = fs_seek(&fil_info, 0, FS_SEEK_SET);
                if (res == 0) {
                    bw = fs_write(&fil_info, &req.u.info.offset_value, sizeof(req.u.info.offset_value));
                    if (bw < 0 || bw != sizeof(req.u.info.offset_value)) {
                        LOG_ERR("[SD_WORK] info write err %d\n", (int)bw);
                    } else {
                        res = fs_sync(&fil_info);
                        if (res < 0) {
                            LOG_ERR("[SD_WORK] fs_sync of info file failed: %d", res);
                        } else {
                            current_file_offset = req.u.info.offset_value;
                        }
                    }
                }
                break;

            case REQ_CLEAR_AUDIO_DIR:
                LOG_DBG("[SD_WORK] Clearing audio directory (delete files only)");
                // Close fil_data before clearing directory
                fs_close(&fil_data);
                int unlink_res = fs_unlink(FILE_DATA_PATH);
                if (unlink_res != 0 && unlink_res != -2) {
                    LOG_ERR("[SD_WORK] Cannot unlink data file: %s, err: %d", FILE_DATA_PATH, unlink_res);
                }
                {
                    int reopen_res;
                    int reopen_attempt = 0;
                    while (1) {
                        fs_file_t_init(&fil_data);
                        reopen_res = fs_open(&fil_data, FILE_DATA_PATH, FS_O_CREATE | FS_O_RDWR | FS_O_TRUNC);
                        if (reopen_res == 0) {
                            fs_seek(&fil_data, 0, FS_SEEK_SET);
                            if (reopen_attempt > 0) {
                                LOG_INF("[SD_WORK] Data file reopened after %d retries.", reopen_attempt);
                            }
                            break;
                        }
                        reopen_attempt++;
                        LOG_ERR("[SD_WORK] open new data file failed (attempt %d): %d. Retrying in 5s.", reopen_attempt,
                                reopen_res);
                        k_msleep(5000);
                    }
                }
                current_file_size = 0;
                current_file_offset = 0;
                // Return result to resp if available
                if (req.u.clear_dir.resp) {
                    req.u.clear_dir.resp->res = 0;
                    k_sem_give(&req.u.clear_dir.resp->sem);
                }
                break;

            default:
                LOG_ERR("[SD_WORK] unknown req type\n");
            } // switch
        } // drain loop
    } // k_poll loop
}