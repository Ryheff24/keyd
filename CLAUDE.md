# keyd Project Instructions

## Physical Device Testing — MANDATORY for all agents

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

### Logging
- **iPad:** Use `print("[CONSOLE] ...")` — os_log doesn't stream over devicectl. Captured via `xcrun devicectl device process launch --console`.
- **macOS:** Use `os_log` — streamed natively via `log stream --predicate "subsystem == 'com.ryheff.keyd.remote.agent'"`.

### Before asking user to test on a physical device:
1. Add `print()` statements to EVERY code path (success AND failure)
2. Include state values, not just function names
3. Build and launch yourself, verify logs show the full flow
4. Only then give the user ONE specific physical action to perform

### Never ask the user to verify something — add logging instead and check yourself.
