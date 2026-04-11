
## $(date +%Y-%m-%d) - Optimize filename parsing in RecordingsManager

**Learning:** Chained `.split()` operations on strings within loops (e.g., `file.path.split('/').last.split('.').first`) generate significant unnecessary memory allocations by creating multiple intermediate list objects and substring copies. In this specific code path in `app/lib/services/recordings_manager.dart`, a benchmark showed these allocations effectively doubled the runtime compared to a more optimized approach.

**Action:** Whenever parsing data from file paths or strings in tight loops (or large batch processing), I will use allocation-free methods like `indexOf`, `lastIndexOf`, and `substring` to manually find offsets instead of utilizing `split`. I will also proactively write small dart benchmark scripts (like `Stopwatch()..start()`) to validate performance assumptions when making optimizations.
