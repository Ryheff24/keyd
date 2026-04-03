# Wi-Fi HEVC E2E Repro

Canonical test invocation for the current Wi-Fi streaming/debugging work:

```bash
./RemoteDesktop/scripts/run-e2e-tests.sh \
  --transports wifi \
  --capture-file './RemoteDesktop/2026-04-02 10-55-42-prores.mov' \
  --sustained-stream-seconds 90
```

Notes:
- Use this exact capture file unless explicitly changing the repro.
- Use Wi-Fi-only transport selection for this issue.
- Keep the sustained stream window at 90 seconds so the late decoder/transport failures reproduce.
