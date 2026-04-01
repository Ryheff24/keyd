# Metrics

This file is machine-managed.
Do not edit it by hand.
Use `scripts/update_metrics.py` to add a new metrics entry.

Rules:
- A new metrics entry requires a unique commit ID.
- The commit ID must already exist in git before the entry is added.
- The changelog is append-only.
- Notes must stay single-line and short enough to keep table rows readable.

## Summary

| Metric | Current | Best | Goal | Status |
|--------|---------|------|------|--------|
| USB resolution width | `2752 px` | `2752 px` | `2752 px` | ✅ |
| USB resolution height | `1786 px` | `1786 px` | `1786 px` | ✅ |
| FPS | `45.9 fps` | `70.2 fps` | `60.0 fps` | ❌ |
| Frame pacing CV | `0.981` | `0.981` | `0.350` | ❌ |
| Pipeline latency median | `3717 ms` | `13 ms` | `20 ms` | ❌ |
| Pipeline latency p95 | `8795 ms` | `32 ms` | `50 ms` | ❌ |
| Pipeline latency avg | `3847 ms` | `26 ms` | `25 ms` | ❌ |
| Glass-to-glass latency median | `1991 ms` | `33 ms` | `20 ms` | ❌ |
| Glass-to-glass latency p95 | `8611 ms` | `54 ms` | `40 ms` | ❌ |
| Glass-to-glass latency avg | `2955 ms` | `47 ms` | `25 ms` | ❌ |
| Heavy-load FPS | `48.5 fps` | `48.5 fps` | `30.0 fps` | ✅ |
| Heavy-load pipeline median | `6983 ms` | `6490 ms` | `100 ms` | ❌ |
| Heavy-load pipeline p95 | `9710 ms` | `8851 ms` | `150 ms` | ❌ |
| Security rejection | `0` | `0` | `1` | ❌ |
| Overall pass rate | `75.0%` | `92.0%` | `100.0%` | ❌ |

## Changelog

| Date | Time | Commit ID | USB resolution | FPS | Frame pacing | Pipeline latency | Glass-to-glass latency | Heavy load | Security | Overall | Notes |
|------|------|-----------|----------------|-----|--------------|------------------|------------------------|------------|----------|---------|-------|
| 2026-03-30 | 21:09:44 EDT | `187c910` | `2704x1756` | `70.2 fps` | `—` | `26/32/26 ms` | `47/54/47 ms` | `—` | `0` | `23/25` | Best stable latency run found in reviewed logs; mapped to nearest prior repo commit. |
| 2026-03-31 | 15:46:35 EDT | `70f7a60` | `2752x1786` | `68.3 fps` | `1.201` | `13/1805/376 ms` | `33/1650/282 ms` | `8.3 fps, 6490/8851 ms` | `0` | `23/27` | Stricter run exposed severe tail-latency, pacing, heavy-load, and security gaps. |
| 2026-04-01 | 17:52:52 EDT | `05d8b3d` | `2752x1786` | `45.9 fps` | `0.981` | `3717/8795/3847 ms` | `1991/8611/2955 ms` | `48.5 fps, 6983/9710 ms` | `0` | `21/28` | Test Run |
