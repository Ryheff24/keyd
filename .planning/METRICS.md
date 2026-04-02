# Metrics

This file is machine-managed except for the Goal column in the Summary table.
You may edit Goal values there, but do not edit computed cells or changelog rows by hand.
Use `scripts/update_metrics.py` to add a new metrics entry.

Rules:
- A new metrics entry requires a unique commit ID.
- The commit ID must already exist in git before the entry is added.
- The changelog is append-only.
- Goal values are read from the Summary table and preserved on rewrite.
- Notes must stay single-line and short enough to keep table rows readable.

## Summary

| Metric | Current | Best | Goal | Status |
|--------|---------|------|------|--------|
| USB resolution width | `2752 px` | `2752 px` | `2752 px` | ✅ |
| USB resolution height | `1786 px` | `1786 px` | `1786 px` | ✅ |
| FPS | `92.0 fps` | `120.0 fps` | `120.0 fps` | ❌ |
| Frame pacing CV | `0.329` | `0.011` | `0.007` | ❌ |
| Pipeline latency median | `14 ms` | `7 ms` | `6 ms` | ❌ |
| Pipeline latency p95 | `16 ms` | `8 ms` | `7 ms` | ❌ |
| Pipeline latency avg | `14 ms` | `7 ms` | `6 ms` | ❌ |
| Glass-to-glass latency median | `36 ms` | `26 ms` | `20 ms` | ❌ |
| Glass-to-glass latency p95 | `37 ms` | `27 ms` | `25 ms` | ❌ |
| Glass-to-glass latency avg | `34 ms` | `26 ms` | `20 ms` | ❌ |
| Heavy-load FPS | `87.1 fps` | `119.8 fps` | `120.0 fps` | ❌ |
| Heavy-load pipeline median | `14 ms` | `8 ms` | `6 ms` | ❌ |
| Heavy-load pipeline p95 | `16 ms` | `8 ms` | `7 ms` | ❌ |
| Security rejection | `0` | `0` | `1` | ❌ |
| Overall pass rate | `96.3%` | `96.3%` | `100.0%` | ❌ |

## Changelog

| Date | Time | Commit ID | USB resolution | FPS | Frame pacing | Pipeline latency | Glass-to-glass latency | Heavy load | Security | Overall | Notes |
|------|------|-----------|----------------|-----|--------------|------------------|------------------------|------------|----------|---------|-------|
| 2026-03-30 | 21:09:44 EDT | `187c910` | `2704x1756` | `70.2 fps` | `—` | `26/32/26 ms` | `47/54/47 ms` | `—` | `0` | `23/25` | Best stable latency run found in reviewed logs; mapped to nearest prior repo commit. |
| 2026-03-31 | 15:46:35 EDT | `70f7a60` | `2752x1786` | `68.3 fps` | `1.201` | `13/1805/376 ms` | `33/1650/282 ms` | `8.3 fps, 6490/8851 ms` | `0` | `23/27` | Stricter run exposed severe tail-latency, pacing, heavy-load, and security gaps. |
| 2026-04-01 | 17:52:52 EDT | `05d8b3d` | `2752x1786` | `45.9 fps` | `0.981` | `3717/8795/3847 ms` | `1991/8611/2955 ms` | `48.5 fps, 6983/9710 ms` | `0` | `21/28` | Test Run |
| 2026-04-01 | 18:29:46 EDT | `6078be2` | `2752x1786` | `43.5 fps` | `0.779` | `3622/8759/3740 ms` | `1779/8522/2814 ms` | `35.2 fps, 8478/9907 ms` | `0` | `22/28` | Test Run2 |
| 2026-04-01 | 19:00:10 EDT | `50821a3` | `2752x1786` | `43.4 fps` | `0.707` | `3419/9260/3828 ms` | `1646/9068/2856 ms` | `54.8 fps, 4550/8016 ms` | `0` | `22/27` | Validate default all-transports rotation |
| 2026-04-01 | 19:04:09 EDT | `37407bf` | `2752x1786` | `43.9 fps` | `0.721` | `3279/8297/3510 ms` | `1498/8157/2628 ms` | `35.9 fps, 7880/9762 ms` | `0` | `19/25` | Validate usb-only transport subset |
| 2026-04-01 | 19:06:34 EDT | `d7c080b` | `2752x1786` | `45.5 fps` | `1.125` | `2896/8115/3258 ms` | `1123/7981/2418 ms` | `45.4 fps, 6238/9349 ms` | `0` | `19/25` | Revalidate usb-only after bonjour skip fix |
| 2026-04-01 | 19:10:47 EDT | `3e2ad07` | `2752x1786` | `52.0 fps` | `1.834` | `388/1653/529 ms` | `417/1675/557 ms` | `15.1 fps, 1479/3078 ms` | `0` | `20/26` | Validate wifi-only transport subset |
| 2026-04-01 | 19:13:38 EDT | `f2f6bb3` | `2752x1786` | `53.1 fps` | `0.550` | `3611/9262/3879 ms` | `1687/9012/2830 ms` | `57.3 fps, 5140/8573 ms` | `0` | `21/26` | Validate usb-plus-wifi transport subset |
| 2026-04-01 | 20:17:28 EDT | `da74d72` | `2752x1786` | `45.5 fps` | `0.452` | `11/80/19 ms` | `32/98/39 ms` | `76.9 fps, 11/84 ms` | `0` | `23/25` | TCP backpressure + mTLS graceful degradation + shorter timeouts |
| 2026-04-01 | 20:30:28 EDT | `c4b452f` | `2752x1786` | `36.5 fps` | `0.210` | `12/24/14 ms` | `33/43/33 ms` | `70.5 fps, 10/13 ms` | `0` | `24/25` | Frame size cap 2MB + TCP backpressure |
| 2026-04-01 | 20:38:39 EDT | `a1298a7` | `2752x1786` | `12.5 fps` | `8.103` | `87/186/97 ms` | `106/207/116 ms` | `10.3 fps, 82/193 ms` | `0` | `22/25` | WiFi pacing queue backpressure + size cap |
| 2026-04-01 | 20:41:30 EDT | `0c35037` | `2752x1786` | `4.1 fps` | `5.137` | `84/192/102 ms` | `99/215/121 ms` | `14.4 fps, 73/177 ms` | `0` | `22/25` | WiFi backpressure limit=5, USB limit=2 |
| 2026-04-01 | 20:44:48 EDT | `c621ba1` | `2752x1786` | `52.2 fps` | `1.844` | `394/1567/554 ms` | `426/1592/587 ms` | `15.1 fps, 1589/3992 ms` | `0` | `19/25` | WiFi no frame-level backpressure, rely on encoder+pacing |
| 2026-04-01 | 20:52:12 EDT | `1108a67` | `2752x1786` | `35.1 fps` | `0.242` | `11/25/14 ms` | `27/44/32 ms` | `68.5 fps, 10/13 ms` | `0` | `25/26` | Final: USB backpressure+size cap, WiFi natural pacing |
| 2026-04-01 | 21:53:47 EDT | `172c708` | `2752x1786` | `41.5 fps` | `0.216` | `29/34/29 ms` | `51/52/48 ms` | `41.3 fps, 29/33 ms` | `0` | `26/27` | 70pct pixel change: scrolling content + sidebar + cursor |
| 2026-04-01 | 22:01:00 EDT | `e9afaf1` | `2752x1786` | `119.8 fps` | `0.043` | `7/8/7 ms` | `29/29/29 ms` | `119.2 fps, 8/8 ms` | `0` | `26/27` | No delta-keyframe fallback + fast per-row animation |
| 2026-04-01 | 22:03:59 EDT | `bdea6cd` | `2752x1786` | `120.0 fps` | `0.011` | `9/10/8 ms` | `26/27/26 ms` | `119.8 fps, 9/11 ms` | `0` | `26/27` | 95pct pixel change: scrolling diagonal gradient, no keyframe fallback |
| 2026-04-01 | 22:13:46 EDT | `700e484` | `2752x1786` | `30.0 fps` | `0.134` | `53/60/54 ms` | `69/77/73 ms` | `31.4 fps, 53/58 ms` | `0` | `26/27` | Noisy gradient 100pct change, LZ4 acc=32, no memcpy, no keyframe fallback |
| 2026-04-01 | 22:17:01 EDT | `13eb771` | `2752x1786` | `32.1 fps` | `0.126` | `56/63/55 ms` | `75/83/75 ms` | `31.8 fps, 56/63 ms` | `0` | `26/27` | Block-noise gradient 4x4, LZ4 acc=32, no memcpy, target 1-5MB deltas |
| 2026-04-01 | 22:20:29 EDT | `84fe069` | `2752x1786` | `92.0 fps` | `0.329` | `14/16/14 ms` | `36/37/34 ms` | `87.1 fps, 14/16 ms` | `0` | `26/27` | Gradient + 20pct video window (4MB delta target), LZ4 acc=32 |
