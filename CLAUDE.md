# keyd Project Instructions

The user will ONLY perform simple physical actions on devices (tap buttons, scan QR codes, plug/unplug cables). They will NOT:
- Paste logs
- Build or run apps
- Verify screen states
- Read error messages
- Do anything beyond physical device interactions

**You must build, deploy, launch, read logs, and diagnose entirely on your own.**

### Debug Scripts
- **iPad:** `./RemoteDesktop/scripts/ipad-debug.sh [timeout_seconds]` — builds, installs, launches with console log capture
- **macOS:** `./RemoteDesktop/scripts/mac-debug.sh [timeout_seconds]` — builds, launches with log streaming
- iPad device ID: `00000000-0000-0000-0000-00000000000A`

### E2E Tests
- Use the canonical Wi-Fi repro when running the current streaming/debugging E2E path:
  ```bash
  ./RemoteDesktop/scripts/run-e2e-tests.sh \
    --transports wifi \
    --capture-file './RemoteDesktop/2026-04-02 10-55-42-prores.mov' \
    --sustained-stream-seconds 90 \
    --notes "brief one-line run note"
  ```
- `--notes` is required on every E2E run.
- Keep `--sustained-stream-seconds 90` for this repro unless explicitly changing the failure window.
- Use `--transports wifi` for this repro.
- Do not substitute a different capture file unless the repro itself is being changed.

### Logging
- **iPad:** Use `print("[CONSOLE] ...")` — os_log doesn't stream over devicectl. Captured via `xcrun devicectl device process launch --console`.
- **macOS:** Use `os_log` — streamed natively via `log stream --predicate "subsystem == 'com.ryheff.keyd.remote.agent'"`.

### Before asking user to test on a physical device:
1. Add `print()` statements to EVERY code path (success AND failure)
2. Include state values, not just function names
3. Build and launch yourself, verify logs show the full flow
4. Only then give the user ONE specific physical action to perform

### Never ask the user to verify something — add logging instead and check yourself.
