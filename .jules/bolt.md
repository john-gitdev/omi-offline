## 2024-06-25 - Parallelizing File Deletions for Performance
**Learning:** Sequential file deletions over BLE connections introduce a cumulative delay due to the protocol's inherent response time (e.g., a 500ms command delay per file). Iterating through deletions sequentially can severely degrade performance.
**Action:** Always batch I/O operations and use `Future.wait` to parallelize them whenever possible, especially over slow transports like BLE. Additionally, delay updating local state and triggering UI rebuilds until the entire batch operation is completed, instead of doing it per item.
