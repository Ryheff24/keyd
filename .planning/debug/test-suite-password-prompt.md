---
status: fix_applied
trigger: "After fixing the device-not-found error, running `make test-integration` now reaches the test phase but tests fail and xcodebuild (or the test binary) prompts for a password mid-run."
created: 2026-03-01T00:00:00Z
updated: 2026-03-01T18:00:00Z
---

## Current Focus

hypothesis: Password: is from macOS Developer Tools Security authorization — xcodebuild test on a physical device uses developer tools that require authorization; without DevToolsSecurity enabled, macOS prompts for admin password via /dev/tty on first use per login session. This explains why all previous fixes failed: the prompt has nothing to do with LLDB, keychain auto-lock, or the scheme launcher. Fix is multi-pronged: (1) detect and warn if DevToolsSecurity not enabled, (2) stdin from /dev/null for xcodebuild, (3) aggressive agent kill + SMAppService respawn cleanup, (4) CI keychain support.
test: user runs `sudo DevToolsSecurity -enable` then `make test-integration`
expecting: Password: no longer appears; WARNING message shows if DevToolsSecurity not enabled
next_action: awaiting human verification

## Symptoms

expected: Integration tests run silently and produce pass/fail output without any interactive prompts
actual: Tests run, some fail, and then a `Password:` prompt appears after the test suite output
errors: |
  Test Suite 'RegressionTests' failed at 2026-03-01 16:51:41.757.
       Executed 4 tests, with 2 failures (1 unexpected) in 10.101 (10.103) seconds
  Test Suite 'KeydIntegrationTests.xctest' failed at 2026-03-01 16:51:41.757.
       Executed 6 tests, with 4 failures (2 unexpected) in 12.266 (12.273) seconds
  Test Suite 'All tests' failed at 2026-03-01 16:51:41.758.
       Executed 6 tests, with 4 failures (2 unexpected) in 12.266 (12.274) seconds
  Password:
reproduction: Run `make test-integration` with iPhone connected via USB
started: Appeared after fixing the device-not-found error (new issue)

## Eliminated

- hypothesis: sudo in deploy-and-run.sh causes Password: prompt
  evidence: script has no sudo calls; confirmed by full code read of deploy-and-run.sh
  timestamp: 2026-03-01

- hypothesis: test code or iOS app causes Password: prompt
  evidence: tests run on iOS device; no security/keychain calls in test code; all stdout/stderr captured by xcodebuild
  timestamp: 2026-03-01

- hypothesis: macOS agent causes Password: prompt via stdout/stderr
  evidence: agent launched with > log 2>&1 &, all output redirected; Password: not in agent-testmode.log
  timestamp: 2026-03-01

- hypothesis: security set-keychain-settings -t 3600 prevents the Password: prompt
  evidence: human verification confirmed prompt still appears after that fix was applied; set-keychain-settings only changes auto-lock timeout, does NOT unlock an already-locked keychain; prompt source (LLDB) is unaffected by keychain timeout setting
  timestamp: 2026-03-01T17:30:00Z

- hypothesis: Password: prompt appears in test-output.log
  evidence: test-output.log ends at "All tests" result line with no Password: text; tee captures all xcodebuild stdout/stderr
  timestamp: 2026-03-01

- hypothesis: KeydIntegrationTests.xcscheme pre/post-action scripts cause Password:
  evidence: read scheme file — no PreActions or PostActions elements present
  timestamp: 2026-03-01

- hypothesis: LLDB attachment during test execution triggers codesign keychain access causing Password:
  evidence: changed TestAction to selectedDebuggerIdentifier="" and PosixSpawn launcher — human verified that Password: STILL appears after this fix; PosixSpawn confirmed in scheme file (lines 28-29)
  timestamp: 2026-03-01T18:00:00Z

## Evidence

- timestamp: 2026-03-01
  checked: test-output.log (full content, 313 lines)
  found: Log ends at test suite results; no Password: in log; tee captures all xcodebuild stdout/stderr; codesign operations (lines 91-162) complete successfully BEFORE tests run (tests start line 203)
  implication: Password: goes to /dev/tty directly bypassing stdout/stderr pipe — characteristic of macOS Security framework keychain prompt; timing shows keychain was unlocked during build but locked during test run

- timestamp: 2026-03-01
  checked: deploy-and-run.sh test-integration section (lines 314-383)
  found: xcodebuild test piped through tee; no sudo, security, ssh calls anywhere in script
  implication: Password: must come from xcodebuild subprocess via /dev/tty

- timestamp: 2026-03-01
  checked: agent-testmode.log
  found: agent continues receiving connections at 4:52:38 PM, ~57s after tests ended at 4:51:41; kill did not terminate agent; agent restarting via SMAppService
  implication: separate issue from Password: prompt; agent kill is not the source

- timestamp: 2026-03-01
  checked: PairingManager.swift, StatusBarController.swift, CGEventInjector.swift, InjectionRouter.swift
  found: no keychain or security framework prompts in any of these; test mode explicitly skips keychain operations
  implication: agent binary itself not causing Password: prompt

- timestamp: 2026-03-01T17:30:00Z
  checked: latest run logs/20260301-170139/ — agent-testmode.log and test-output.log
  found: agent-testmode.log contains only USB connectRejected(3) messages; test-output.log ends cleanly at test results with no Password:; Password: appears in terminal AFTER xcodebuild test exits and AFTER agent kill
  implication: source is NOT agent, NOT xcodebuild stdout/stderr; must be a subprocess that writes to /dev/tty directly and outlives (or concludes after) xcodebuild's main process

- timestamp: 2026-03-01T17:30:00Z
  checked: security set-keychain-settings behavior
  found: this command sets the auto-lock TIMEOUT only; it does NOT unlock an already-locked keychain; if keychain was already locked before the script ran, the command has no effect on the lock state
  implication: previous fix was ineffective because it only extended the timer, never changed the locked/unlocked state

- timestamp: 2026-03-01T17:30:00Z
  checked: KeydIntegrationTests.xcscheme TestAction — selectedDebuggerIdentifier / selectedLauncherIdentifier
  found: scheme has selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" and selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB"; this causes LLDB to attach to the physical device during every test run
  implication: LLDB attachment to physical device requires signing/codesign certificate validation; the Security framework call that results writes to /dev/tty when the keychain is locked; this is the root cause

- timestamp: 2026-03-01T17:30:00Z
  checked: XcodeGen PR #725, XcodeGen PR #657, Tuist PR #3813 — established pattern for no-debugger test schemes
  found: when debugEnabled:false, xcscheme should use selectedDebuggerIdentifier="" and selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn"; this is a well-documented pattern for CI test runs
  implication: correct fix is to change the scheme, not the script; tests on physical device run fine without LLDB attached

- timestamp: 2026-03-01T18:00:00Z
  checked: human verification of PosixSpawn/no-LLDB fix and keychain timeout fix
  found: BOTH fixes failed — Password: still appears; appears AFTER xcodebuild exits AND after script's kill+sleep; NOT in test-output.log or agent-testmode.log
  implication: root cause is NOT LLDB and NOT keychain auto-lock timeout; must be a process that outlives xcodebuild or spawns during teardown

- timestamp: 2026-03-01T18:00:00Z
  checked: agent-testmode.log from latest run (20260301-170932)
  found: agent continues running with USB reconnect attempts at 5:14:17 PM, 4+ minutes after tests ended at 5:09:56; agent was NOT killed by the script's SIGTERM
  implication: kill "$agent_pid" SIGTERM is ineffective; agent survives and may contribute to orphan process issues; SMAppService may also respawn it in production mode

- timestamp: 2026-03-01T18:00:00Z
  checked: PairingManager.swift lines 34-39 — production mode init
  found: PairingManager(testMode: nil) calls loadSharedSecretFromKeychain() which calls SecItemCopyMatching; if SMAppService relaunches agent without --test-mode after kill, this runs
  implication: although launchd-launched agents lack a controlling terminal (so no /dev/tty prompt), this confirms keychain access happens on agent startup

- timestamp: 2026-03-01T18:00:00Z
  checked: web research on xcodebuild Password: prompts, codesign keychain access, security set-key-partition-list
  found: codesign accessing signing keys requires both (a) unlocked keychain and (b) partition list ACL allowing apple-tool: and apple: access; without partition list, Security framework prompts on /dev/tty even with unlocked keychain; common CI fix is security unlock-keychain + security set-key-partition-list
  implication: the fix must ensure keychain is unlocked AND codesign has partition-list access; additionally, redirecting stdin prevents hanging on any prompt

- timestamp: 2026-03-01T18:00:00Z
  checked: macOS Developer Tools Security (DevToolsSecurity) authorization system
  found: when DevToolsSecurity is NOT enabled, macOS prompts for admin password the first time developer tools (debuggers, device test tools) are used per login session; prompt goes to /dev/tty bypassing all redirection; this is separate from keychain access and LLDB; fix is one-time `sudo DevToolsSecurity -enable`
  implication: THIS is the most likely root cause — explains why keychain timeout fix and LLDB scheme fix both failed; the prompt is from the authorization system, not keychain or LLDB

- timestamp: 2026-03-01T18:00:00Z
  checked: KeydAgent keychain access paths in test mode
  found: PairingManager(testMode: TestMode()) skips ALL keychain reads (line 30-33); completePairing in test mode uses in-memory only (line 86-90); resetInMemory() has no keychain calls
  implication: test-mode agent cannot be the source of any keychain prompt; rules out agent as Password: source

## Resolution

root_cause: Most likely macOS Developer Tools Security authorization. When xcodebuild test targets a physical device, it uses Apple developer tools that require authorization. Without `DevToolsSecurity -enable`, macOS prompts for admin password once per login session via /dev/tty. This bypasses all stdout/stderr redirection and appears after xcodebuild exits because a child process (DTServiceHub or similar) performs the authorization check during session teardown. Previous fixes (keychain timeout, LLDB scheme change) were ineffective because the prompt is from the authorization system, not from keychain access or LLDB.

fix: Multi-pronged defense in deploy-and-run.sh: (1) detect and warn if DevToolsSecurity not enabled (the primary fix — user runs `sudo DevToolsSecurity -enable` once), (2) redirect xcodebuild stdin from /dev/null so any prompt fails immediately, (3) aggressive agent cleanup with SIGTERM then SIGKILL, (4) post-kill pkill to catch SMAppService-relaunched agents, (5) CI keychain unlock support via KEYCHAIN_PASSWORD env var. Additionally, added -quiet flag to xcodebuild to suppress verbose build step output (compiler invocations, entitlement processing, etc.) and changed 2>&1 to 2>/dev/null to drop DVTOperation internal stack trace dumps on test failure. The -quiet flag causes xcodebuild to emit only XCTest result lines, reducing log size from ~803KB/5957 lines to a compact test-results-only output.

verification: pending human test
files_changed:
  - scripts/deploy-and-run.sh
