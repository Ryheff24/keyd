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
| FPS | `43.4 fps` | `70.2 fps` | `60.0 fps` | ❌ |
| Frame pacing CV | `0.707` | `0.707` | `0.350` | ❌ |
| Pipeline latency median | `3419 ms` | `13 ms` | `20 ms` | ❌ |
| Pipeline latency p95 | `9260 ms` | `32 ms` | `50 ms` | ❌ |
| Pipeline latency avg | `3828 ms` | `26 ms` | `25 ms` | ❌ |
| Glass-to-glass latency median | `1646 ms` | `33 ms` | `20 ms` | ❌ |
| Glass-to-glass latency p95 | `9068 ms` | `54 ms` | `40 ms` | ❌ |
| Glass-to-glass latency avg | `2856 ms` | `47 ms` | `25 ms` | ❌ |
| Heavy-load FPS | `54.8 fps` | `54.8 fps` | `30.0 fps` | ✅ |
| Heavy-load pipeline median | `4550 ms` | `4550 ms` | `100 ms` | ❌ |
| Heavy-load pipeline p95 | `8016 ms` | `8016 ms` | `150 ms` | ❌ |
| Security rejection | `0` | `0` | `1` | ❌ |
| Overall pass rate | `81.5%` | `92.0%` | `100.0%` | ❌ |

## Changelog

| Date | Time | Commit ID | USB resolution | FPS | Frame pacing | Pipeline latency | Glass-to-glass latency | Heavy load | Security | Overall | Notes |
|------|------|-----------|----------------|-----|--------------|------------------|------------------------|------------|----------|---------|-------|
| 2026-03-30 | 21:09:44 EDT | `187c910` | `2704x1756` | `70.2 fps` | `—` | `26/32/26 ms` | `47/54/47 ms` | `—` | `0` | `23/25` | Best stable latency run found in reviewed logs; mapped to nearest prior repo commit. |
| 2026-03-31 | 15:46:35 EDT | `70f7a60` | `2752x1786` | `68.3 fps` | `1.201` | `13/1805/376 ms` | `33/1650/282 ms` | `8.3 fps, 6490/8851 ms` | `0` | `23/27` | Stricter run exposed severe tail-latency, pacing, heavy-load, and security gaps. |
| 2026-04-01 | 17:52:52 EDT | `05d8b3d` | `2752x1786` | `45.9 fps` | `0.981` | `3717/8795/3847 ms` | `1991/8611/2955 ms` | `48.5 fps, 6983/9710 ms` | `0` | `21/28` | Test Run |
| 2026-04-01 | 18:29:46 EDT | `6078be2` | `2752x1786` | `43.5 fps` | `0.779` | `3622/8759/3740 ms` | `1779/8522/2814 ms` | `35.2 fps, 8478/9907 ms` | `0` | `22/28` | Test Run2 |
| 2026-04-01 | 19:00:10 EDT | `50821a3` | `2752x1786` | `43.4 fps` | `0.707` | `3419/9260/3828 ms` | `1646/9068/2856 ms` | `54.8 fps, 4550/8016 ms` | `0` | `22/27` | Validate default all-transports rotation |
