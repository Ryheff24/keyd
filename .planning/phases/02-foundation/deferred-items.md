# Phase 2: Deferred Items

## Out-of-Scope Issues Found During Execution

### 1. USBNetworkTransport.m and WirelessTransport.m build errors
- **Found during:** 02-02 Task 2 verification build
- **Issue:** Uncommitted transport files (USBNetworkTransport.m, WirelessTransport.m) in working directory have compilation errors (`strongSelf` undeclared in weak/strong dance). These files were added by another plan execution and are not part of plan 02-02.
- **Impact:** Full project build fails, but individual file compilation of 02-02 artifacts (ScreenCapture.m, FrameCompressor.c) succeeds cleanly.
- **Resolution:** Fix in the transport plan (likely 02-04 or 02-05) that owns these files.
