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
| Viewport width | `2752 px` | `2752 px` | `2752 px` | ✅ |
| Viewport height | `1548 px` | `1786 px` | `1786 px` | ❌ |
| Delivered frame width | `2496 px` | `2752 px` | `2752 px` | ❌ |
| Delivered frame height | `1404 px` | `1786 px` | `1786 px` | ❌ |
| FPS | `50.6 fps` | `120.0 fps` | `120.0 fps` | ❌ |
| Frame pacing CV | `1.429` | `0.011` | `0.007` | ❌ |
| Pipeline latency median | `26 ms` | `7 ms` | `6 ms` | ❌ |
| Pipeline latency p95 | `155 ms` | `8 ms` | `7 ms` | ❌ |
| Pipeline latency avg | `54 ms` | `7 ms` | `6 ms` | ❌ |
| Glass-to-glass latency median | `46 ms` | `26 ms` | `20 ms` | ❌ |
| Glass-to-glass latency p95 | `178 ms` | `27 ms` | `25 ms` | ❌ |
| Glass-to-glass latency avg | `68 ms` | `26 ms` | `20 ms` | ❌ |
| Heavy-load FPS | `51.4 fps` | `119.8 fps` | `120.0 fps` | ❌ |
| Heavy-load pipeline median | `24 ms` | `8 ms` | `6 ms` | ❌ |
| Heavy-load pipeline p95 | `156 ms` | `8 ms` | `7 ms` | ❌ |
| Security rejection | `1` | `1` | `1` | ✅ |
| Overall pass rate | `78.8%` | `100.0%` | `100.0%` | ❌ |

## Changelog

| Date | Time | Commit ID | Viewport | Delivered frame | FPS | Frame pacing | Pipeline latency | Glass-to-glass latency | Heavy load | Security | Overall | Notes |
|------|------|-----------|----------|-----------------|-----|--------------|------------------|------------------------|------------|----------|---------|-------|
| 2026-03-30 | 21:09:44 EDT | `187c910` | `2704x1756` | `2704x1756` | `70.2 fps` | `—` | `26/32/26 ms` | `47/54/47 ms` | `—` | `0` | `23/25` | Best stable latency run found in reviewed logs; mapped to nearest prior repo commit. |
| 2026-03-31 | 15:46:35 EDT | `70f7a60` | `2752x1786` | `2752x1786` | `68.3 fps` | `1.201` | `13/1805/376 ms` | `33/1650/282 ms` | `8.3 fps, 6490/8851 ms` | `0` | `23/27` | Stricter run exposed severe tail-latency, pacing, heavy-load, and security gaps. |
| 2026-04-01 | 17:52:52 EDT | `05d8b3d` | `2752x1786` | `2752x1786` | `45.9 fps` | `0.981` | `3717/8795/3847 ms` | `1991/8611/2955 ms` | `48.5 fps, 6983/9710 ms` | `0` | `21/28` | Test Run |
| 2026-04-01 | 18:29:46 EDT | `6078be2` | `2752x1786` | `2752x1786` | `43.5 fps` | `0.779` | `3622/8759/3740 ms` | `1779/8522/2814 ms` | `35.2 fps, 8478/9907 ms` | `0` | `22/28` | Test Run2 |
| 2026-04-01 | 19:00:10 EDT | `50821a3` | `2752x1786` | `2752x1786` | `43.4 fps` | `0.707` | `3419/9260/3828 ms` | `1646/9068/2856 ms` | `54.8 fps, 4550/8016 ms` | `0` | `22/27` | Validate default all-transports rotation |
| 2026-04-01 | 19:04:09 EDT | `37407bf` | `2752x1786` | `2752x1786` | `43.9 fps` | `0.721` | `3279/8297/3510 ms` | `1498/8157/2628 ms` | `35.9 fps, 7880/9762 ms` | `0` | `19/25` | Validate usb-only transport subset |
| 2026-04-01 | 19:06:34 EDT | `d7c080b` | `2752x1786` | `2752x1786` | `45.5 fps` | `1.125` | `2896/8115/3258 ms` | `1123/7981/2418 ms` | `45.4 fps, 6238/9349 ms` | `0` | `19/25` | Revalidate usb-only after bonjour skip fix |
| 2026-04-01 | 19:10:47 EDT | `3e2ad07` | `2752x1786` | `2752x1786` | `52.0 fps` | `1.834` | `388/1653/529 ms` | `417/1675/557 ms` | `15.1 fps, 1479/3078 ms` | `0` | `20/26` | Validate wifi-only transport subset |
| 2026-04-01 | 19:13:38 EDT | `f2f6bb3` | `2752x1786` | `2752x1786` | `53.1 fps` | `0.550` | `3611/9262/3879 ms` | `1687/9012/2830 ms` | `57.3 fps, 5140/8573 ms` | `0` | `21/26` | Validate usb-plus-wifi transport subset |
| 2026-04-01 | 20:17:28 EDT | `da74d72` | `2752x1786` | `2752x1786` | `45.5 fps` | `0.452` | `11/80/19 ms` | `32/98/39 ms` | `76.9 fps, 11/84 ms` | `0` | `23/25` | TCP backpressure + mTLS graceful degradation + shorter timeouts |
| 2026-04-01 | 20:30:28 EDT | `c4b452f` | `2752x1786` | `2752x1786` | `36.5 fps` | `0.210` | `12/24/14 ms` | `33/43/33 ms` | `70.5 fps, 10/13 ms` | `0` | `24/25` | Frame size cap 2MB + TCP backpressure |
| 2026-04-01 | 20:38:39 EDT | `a1298a7` | `2752x1786` | `2752x1786` | `12.5 fps` | `8.103` | `87/186/97 ms` | `106/207/116 ms` | `10.3 fps, 82/193 ms` | `0` | `22/25` | WiFi pacing queue backpressure + size cap |
| 2026-04-01 | 20:41:30 EDT | `0c35037` | `2752x1786` | `2752x1786` | `4.1 fps` | `5.137` | `84/192/102 ms` | `99/215/121 ms` | `14.4 fps, 73/177 ms` | `0` | `22/25` | WiFi backpressure limit=5, USB limit=2 |
| 2026-04-01 | 20:44:48 EDT | `c621ba1` | `2752x1786` | `2752x1786` | `52.2 fps` | `1.844` | `394/1567/554 ms` | `426/1592/587 ms` | `15.1 fps, 1589/3992 ms` | `0` | `19/25` | WiFi no frame-level backpressure, rely on encoder+pacing |
| 2026-04-01 | 20:52:12 EDT | `1108a67` | `2752x1786` | `2752x1786` | `35.1 fps` | `0.242` | `11/25/14 ms` | `27/44/32 ms` | `68.5 fps, 10/13 ms` | `0` | `25/26` | Final: USB backpressure+size cap, WiFi natural pacing |
| 2026-04-01 | 21:53:47 EDT | `172c708` | `2752x1786` | `2752x1786` | `41.5 fps` | `0.216` | `29/34/29 ms` | `51/52/48 ms` | `41.3 fps, 29/33 ms` | `0` | `26/27` | 70pct pixel change: scrolling content + sidebar + cursor |
| 2026-04-01 | 22:01:00 EDT | `e9afaf1` | `2752x1786` | `2752x1786` | `119.8 fps` | `0.043` | `7/8/7 ms` | `29/29/29 ms` | `119.2 fps, 8/8 ms` | `0` | `26/27` | No delta-keyframe fallback + fast per-row animation |
| 2026-04-01 | 22:03:59 EDT | `bdea6cd` | `2752x1786` | `2752x1786` | `120.0 fps` | `0.011` | `9/10/8 ms` | `26/27/26 ms` | `119.8 fps, 9/11 ms` | `0` | `26/27` | 95pct pixel change: scrolling diagonal gradient, no keyframe fallback |
| 2026-04-01 | 22:13:46 EDT | `700e484` | `2752x1786` | `2752x1786` | `30.0 fps` | `0.134` | `53/60/54 ms` | `69/77/73 ms` | `31.4 fps, 53/58 ms` | `0` | `26/27` | Noisy gradient 100pct change, LZ4 acc=32, no memcpy, no keyframe fallback |
| 2026-04-01 | 22:17:01 EDT | `13eb771` | `2752x1786` | `2752x1786` | `32.1 fps` | `0.126` | `56/63/55 ms` | `75/83/75 ms` | `31.8 fps, 56/63 ms` | `0` | `26/27` | Block-noise gradient 4x4, LZ4 acc=32, no memcpy, target 1-5MB deltas |
| 2026-04-01 | 22:20:29 EDT | `84fe069` | `2752x1786` | `2752x1786` | `92.0 fps` | `0.329` | `14/16/14 ms` | `36/37/34 ms` | `87.1 fps, 14/16 ms` | `0` | `26/27` | Gradient + 20pct video window (4MB delta target), LZ4 acc=32 |
| 2026-04-01 | 22:52:09 EDT | `5a2acd1` | `2752x1786` | `2752x1786` | `100.9 fps` | `0.332` | `12/14/12 ms` | `28/29/29 ms` | `98.8 fps, 13/15 ms` | `0` | `26/27` | 15pct video window (~3MB delta), 3 TCP in-flight, branchless loops |
| 2026-04-01 | 22:54:31 EDT | `dc72aa7` | `2752x1786` | `2752x1786` | `114.5 fps` | `0.187` | `13/15/13 ms` | `34/35/34 ms` | `97.4 fps, 13/15 ms` | `0` | `26/27` | 15pct video window (~3MB delta), 3 TCP in-flight, rerun |
| 2026-04-01 | 23:43:24 EDT | `ca59267` | `2752x1786` | `2752x1786` | `10.8 fps` | `0.031` | `207/219/208 ms` | `222/238/224 ms` | `10.7 fps, 211/224 ms` | `1` | `24/27` | raw client identity payload (cert+key), no pkcs12 |
| 2026-04-02 | 00:06:13 EDT | `3268e60` | `2752x1786` | `2752x1786` | `111.7 fps` | `0.652` | `16/80/27 ms` | `37/78/42 ms` | `105.2 fps, 16/77 ms` | `1` | `23/27` | usb tcp chunked media + reconnect crash fix |
| 2026-04-02 | 00:09:14 EDT | `7e1135e` | `2752x1786` | `2752x1786` | `63.4 fps` | `1.338` | `46/91/51 ms` | `57/106/61 ms` | `75.9 fps, 41/88 ms` | `1` | `23/27` | rotation uses onFrameRendered counter; usb tcp chunked media |
| 2026-04-02 | 00:14:54 EDT | `4ce8c1a` | `2752x1786` | `2752x1786` | `76.7 fps` | `1.249` | `18/81/29 ms` | `34/84/41 ms` | `115.4 fps, 18/21 ms` | `1` | `23/27` | rotation uses decoded-or-rendered frames; usb tcp chunked media |
| 2026-04-02 | 01:26:54 EDT | `0d10900` | `2752x1786` | `2752x1786` | `3.8 fps` | `2.206` | `5548/7731/5527 ms` | `5565/7748/5548 ms` | `5.4 fps, 9475/9940 ms` | `1` | `19/26` | wifi-only baseline after usb tcp chunking |
| 2026-04-02 | 01:34:26 EDT | `ce911a4` | `2752x1786` | `2752x1786` | `19.8 fps` | `1.370` | `66/219/102 ms` | `86/236/122 ms` | `29.9 fps, 66/204 ms` | `1` | `23/26` | wifi-only after duplicate-connect fix |
| 2026-04-02 | 09:51:34 EDT | `6121952` | `2752x1786` | `2752x1786` | `119.1 fps` | `0.084` | `13/14/13 ms` | `32/33/32 ms` | `118.9 fps, 14/15 ms` | `1` | `26/26` | wifi-only stress-capture after udp startup + 1920 cap |
| 2026-04-02 | 11:37:09 EDT | `9ab2fae` | `2752x1786` | `2752x1786` | `38.0 fps` | `0.531` | `15/44/23 ms` | `37/62/41 ms` | `40.9 fps, 14/57 ms` | `1` | `25/26` | wifi full torture clip after queue-overflow tcp fallback |
| 2026-04-02 | 11:49:18 EDT | `c9608c7` | `2752x1786` | `2752x1786` | `30.4 fps` | `0.449` | `19/52/25 ms` | `39/66/44 ms` | `30.9 fps, 29/74 ms` | `1` | `24/25` | wifi sustained full torture clip after sustained-run mode + 40fps pacing alignment |
| 2026-04-02 | 12:00:41 EDT | `7e243d9` | `2752x1786` | `2752x1786` | `31.9 fps` | `0.360` | `15/40/21 ms` | `34/58/41 ms` | `31.2 fps, 23/53 ms` | `1` | `24/25` | wifi sustained full torture clip after adaptive udp pacing |
| 2026-04-02 | 12:08:45 EDT | `7128098` | `2752x1786` | `1848x1200` | `33.0 fps` | `0.397` | `17/44/23 ms` | `38/61/43 ms` | `33.0 fps, 21/43 ms` | `1` | `21/25` | test updates |
| 2026-04-03 | 22:37:16 EDT | `992889b` | `2752x1786` | `2496x1620` | `53.6 fps` | `1.656` | `34/168/64 ms` | `56/193/86 ms` | `50.6 fps, 34/171 ms` | `1` | `24/33` | validate reporting parser fix |
| 2026-04-03 | 23:36:06 EDT | `8b54805` | `2752x1786` | `2496x1620` | `54.3 fps` | `1.561` | `34/166/64 ms` | `57/190/86 ms` | `55.4 fps, 36/165 ms` | `1` | `24/33` | wifi: integrated A/B/C pairing usb wifi stabilization iteration 1b |
| 2026-04-04 | 00:03:29 EDT | `49dc8e9` | `2752x1786` | `2496x1620` | `52.5 fps` | `1.499` | `32/166/63 ms` | `54/189/80 ms` | `52.8 fps, 30/166 ms` | `1` | `26/33` | wifi: iteration 2 stale-conn-replace + tcp-media + renderer-queue2 |
| 2026-04-04 | 00:31:25 EDT | `c1ead37` | `2752x1786` | `2496x1620` | `49.7 fps` | `1.474` | `32/165/63 ms` | `51/181/75 ms` | `51.0 fps, 29/162 ms` | `1` | `26/33` | wifi: iteration 3 lane A/B/C patches (pairedHost reconnect + usb chunk all + newest-frame render) |
| 2026-04-04 | 00:53:00 EDT | `1067215` | `2752x1548` | `2496x1404` | `42.4 fps` | `3.543` | `26/156/54 ms` | `46/169/66 ms` | `49.3 fps, 23/154 ms` | `1` | `25/33` | wifi: iteration 5 throttle wifi tcp completion logs to remove instrumentation overhead |
| 2026-04-04 | 01:00:58 EDT | `5b89c85` | `2752x1548` | `2496x1404` | `48.8 fps` | `1.415` | `26/156/55 ms` | `47/170/67 ms` | `50.0 fps, 23/155 ms` | `1` | `26/33` | wifi: iteration 6 remove wifi tcp in-flight drop gate (restore contiguous seq delivery) |
| 2026-04-04 | 01:16:31 EDT | `d05d42e` | `2752x1548` | `2496x1404` | `53.3 fps` | `1.500` | `26/155/54 ms` | `49/179/74 ms` | `54.4 fps, 23/152 ms` | `1` | `26/33` | wifi iteration 7 lane-a2 lane-b2 lane-c2 integrated |
| 2026-04-04 | 01:31:10 EDT | `5d1199e` | `2752x1548` | `2496x1404` | `50.6 fps` | `1.429` | `26/155/54 ms` | `46/178/68 ms` | `51.4 fps, 24/156 ms` | `1` | `26/33` | wifi iteration 8 lane-a3 lane-b3 lane-c3 integrated |
