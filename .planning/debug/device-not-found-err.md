---
status: awaiting_human_verify
trigger: "xcodebuild cannot find the physical iOS device by ID when running `make test-integration`"
created: 2026-03-01T00:00:00Z
updated: 2026-03-01T00:00:00Z
---

## Current Focus

hypothesis: device-config.mk stores the CoreDevice UUID (00000000-0000-0000-0000-00000000000B) which is the identifier from `devicectl`, but xcodebuild requires the traditional UDID format (00000000-00000000000000B1). Line 361 of deploy-and-run.sh passes IPHONE_DEVICE directly as the xcodebuild -destination id.
test: read device-config.mk and deploy-and-run.sh to confirm the ID being passed
expecting: device-config.mk contains CoreDevice UUID, script passes it verbatim to xcodebuild
next_action: update device-config.mk with xcodebuild-compatible UDID

## Symptoms

expected: `make test-integration` runs integration tests on the connected physical iPhone (My iPhone, iPhone 15 Pro)
actual: xcodebuild errors with "Unable to find a device matching the provided destination specifier: { platform:iOS, id:00000000-0000-0000-0000-00000000000B }"
errors: |
  xcodebuild: error: Unable to find a device matching the provided destination specifier:
    { platform:iOS, id:00000000-0000-0000-0000-00000000000B }
  Available destinations for the "KeydIntegrationTests" scheme:
    { platform:iOS, arch:arm64, id:00000000-00000000000000B1, name:My iPhone }
reproduction: Run `make test-integration` with a physical iPhone connected
started: New issue — integration test scheme recently set up (Phase 1.1)

## Eliminated

(none — root cause found on first investigation)

## Evidence

- timestamp: 2026-03-01T00:00:00Z
  checked: device-config.mk
  found: IPHONE_DEVICE := 00000000-0000-0000-0000-00000000000B (CoreDevice UUID from devicectl)
  implication: This is the wrong identifier format for xcodebuild

- timestamp: 2026-03-01T00:00:00Z
  checked: scripts/deploy-and-run.sh line 361
  found: xcodebuild test ... -destination "platform=iOS,id=$IPHONE_DEVICE" — passes IPHONE_DEVICE verbatim
  implication: Whatever is in device-config.mk goes directly to xcodebuild as the device id

- timestamp: 2026-03-01T00:00:00Z
  checked: xcodebuild error message (available destinations)
  found: xcodebuild knows the device as id:00000000-00000000000000B1 (traditional UDID/ECID format)
  implication: The traditional UDID is what xcodebuild requires; CoreDevice UUIDs are only understood by devicectl

## Resolution

root_cause: |
  device-config.mk stores the CoreDevice UUID (00000000-0000-0000-0000-00000000000B) obtained
  from `devicectl list devices`. The deploy-and-run.sh test-integration path passes this value
  directly to xcodebuild via `-destination "platform=iOS,id=$IPHONE_DEVICE"`. However xcodebuild
  only recognises the traditional UDID format (00000000-00000000000000B1) visible in
  `xcrun xctrace list devices` / `instruments -s devices`. These are two different identifier
  namespaces for the same physical device.
fix: Updated device-config.mk IPHONE_DEVICE from CoreDevice UUID 00000000-0000-0000-0000-00000000000B to xcodebuild-compatible UDID 00000000-00000000000000B1
verification: awaiting human confirmation — run `make test-integration` to verify xcodebuild now finds the device
files_changed:
  - device-config.mk
