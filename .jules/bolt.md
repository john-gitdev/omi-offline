## 2024-05-15 - Future.wait For Bulk Deletions
**Learning:** Sequential await loops for Bluetooth/BLE or simulated file IO deletions create massive bottlenecks due to inherent round-trip protocol delays on every individual request.
**Action:** Always map the elements to the underlying asynchronous Future and evaluate them concurrently using `Future.wait` when parallel deletions or fetch requests do not inherently depend on preceding order.
