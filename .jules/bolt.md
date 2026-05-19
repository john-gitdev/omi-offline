## $(date +%Y-%m-%d) - Prevent byte array copies and view allocations in tight loops
**Learning:** Using `sublist()` prior to `String.fromCharCodes()` creates expensive byte array copies, particularly within while/for loops when parsing binary chunks. Recreating `ByteData.sublistView()` in tight loops adds significant overhead; hoisting a single view and using offset methods is significantly faster.
**Action:** Use native positional arguments `String.fromCharCodes(data, start, end)` to read without copying memory, and hoist a single `ByteData.sublistView(data)` outside the loop.
