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
| Viewport height | `1786 px` | `1786 px` | `1786 px` | ✅ |
| Delivered frame width | `2496 px` | `2752 px` | `2752 px` | ❌ |
| Delivered frame height | `1620 px` | `1786 px` | `1786 px` | ❌ |
| FPS | `56.3 fps` | `120.0 fps` | `120.0 fps` | ❌ |
| Frame pacing CV | `0.671` | `0.011` | `0.007` | ❌ |
| Pipeline latency median | `32 ms` | `7 ms` | `6 ms` | ❌ |
| Pipeline latency p95 | `71 ms` | `8 ms` | `7 ms` | ❌ |
| Pipeline latency avg | `38 ms` | `7 ms` | `6 ms` | ❌ |
| Glass-to-glass latency median | `53 ms` | `23 ms` | `20 ms` | ❌ |
| Glass-to-glass latency p95 | `85 ms` | `27 ms` | `25 ms` | ❌ |
| Glass-to-glass latency avg | `57 ms` | `26 ms` | `20 ms` | ❌ |
| Heavy-load FPS | `56.9 fps` | `119.8 fps` | `120.0 fps` | ❌ |
| Heavy-load pipeline median | `28 ms` | `6 ms` | `6 ms` | ❌ |
| Heavy-load pipeline p95 | `46 ms` | `8 ms` | `7 ms` | ❌ |
| Security rejection | `1` | `1` | `1` | ✅ |
| Overall pass rate | `87.0%` | `100.0%` | `100.0%` | ❌ |

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
| 2026-04-04 | 01:56:45 EDT | `395f105` | `2752x1786` | `2496x1620` | `57.7 fps` | `0.995` | `27/39/28 ms` | `47/61/49 ms` | `59.8 fps, 24/34 ms` | `1` | `26/33` | wifi iteration 9 lane-a4 lane-b4 lane-c4 integrated |
| 2026-04-04 | 02:25:11 EDT | `a91358a` | `2752x1786` | `2496x1620` | `53.6 fps` | `1.072` | `31/108/45 ms` | `51/129/64 ms` | `56.1 fps, 26/95 ms` | `1` | `26/33` | wifi iteration 11 lane-a6 lane-b6 lane-c6 integrated |
| 2026-04-04 | 10:57:33 EDT | `9b1b149` | `2752x1786` | `2496x1620` | `54.3 fps` | `1.226` | `27/169/48 ms` | `48/172/64 ms` | `49.9 fps, 40/207 ms` | `1` | `26/33` | wifi iteration 12 lane-a7 lane-b7 lane-c7 integrated rerun after unlock |
| 2026-04-04 | 11:38:44 EDT | `5d458c3` | `2752x1786` | `2496x1620` | `50.8 fps` | `1.450` | `33/179/62 ms` | `52/156/77 ms` | `51.4 fps, 32/108 ms` | `1` | `26/33` | iter13 vpn-cleared verification |
| 2026-04-04 | 11:46:36 EDT | `544430b` | `2752x1786` | `2496x1620` | `55.7 fps` | `1.291` | `29/128/51 ms` | `51/137/71 ms` | `57.0 fps, 24/92 ms` | `1` | `26/33` | iter14 adaptive+renderer stutter tuning floor30 |
| 2026-04-04 | 12:01:49 EDT | `c952113` | `2752x1786` | `2496x1620` | `56.5 fps` | `1.367` | `36/111/56 ms` | `63/132/79 ms` | `57.2 fps, 31/104 ms` | `1` | `26/33` | iter15 rerun complete metrics collection |
| 2026-04-04 | 12:31:23 EDT | `bc54a2f` | `2752x1786` | `2496x1620` | `53.7 fps` | `1.262` | `31/144/50 ms` | `53/168/75 ms` | `54.0 fps, 29/146 ms` | `1` | `26/33` | iter17 integrated A/B/C stall-recovery reconnect-liveness usb-guard |
| 2026-04-04 | 12:45:25 EDT | `49ba719` | `2752x1786` | `2496x1620` | `53.2 fps` | `1.242` | `30/145/49 ms` | `52/169/73 ms` | `54.1 fps, 26/137 ms` | `1` | `29/37` | iter18 integrated rerun after compile-fix no-nw_connection_get_state |
| 2026-04-04 | 13:25:19 EDT | `3855de7` | `2752x1786` | `2496x1620` | `53.9 fps` | `0.603` | `28/53/32 ms` | `49/78/54 ms` | `54.9 fps, 25/36 ms` | `1` | `29/37` | iter19 rerun with unlocked ipad |
| 2026-04-04 | 13:36:49 EDT | `0707bce` | `2752x1786` | `2496x1620` | `57.5 fps` | `0.964` | `29/121/40 ms` | `51/150/62 ms` | `59.6 fps, 28/89 ms` | `1` | `29/37` | iter20 integrated A+B+C after bitrate-stutter focus |
| 2026-04-04 | 14:01:04 EDT | `15e860e` | `2752x1786` | `2496x1620` | `57.8 fps` | `0.794` | `29/88/36 ms` | `50/98/56 ms` | `59.1 fps, 26/73 ms` | `1` | `29/37` | iter21 hotfix tcp-drain crash |
| 2026-04-04 | 15:03:43 EDT | `967b103` | `2752x1786` | `2496x1620` | `58.6 fps` | `0.625` | `27/55/31 ms` | `48/95/54 ms` | `59.7 fps, 25/124 ms` | `1` | `29/37` | Validate keychain memory-only import |
| 2026-04-04 | 16:18:12 EDT | `87b1813` | `2752x1786` | `2496x1620` | `58.4 fps` | `1.234` | `30/143/48 ms` | `53/170/74 ms` | `59.8 fps, 27/137 ms` | `1` | `29/37` | wifi: baseline stutter+bitrate drop to >=45fps no-res-loss |
| 2026-04-04 | 16:24:19 EDT | `4cdd36c` | `2752x1786` | `2496x1620` | `58.4 fps` | `1.297` | `36/106/51 ms` | `70/129/77 ms` | `59.6 fps, 36/103 ms` | `1` | `26/33` | wifi: validate transient DTLS recv-gap backoff+rate-limited logging |
| 2026-04-04 | 16:30:25 EDT | `a004b1d` | `2752x1786` | `2496x1620` | `58.1 fps` | `1.200` | `29/140/46 ms` | `52/167/71 ms` | `59.8 fps, 26/135 ms` | `1` | `26/33` | wifi: validate less aggressive severe-downshift thresholds |
| 2026-04-04 | 16:36:59 EDT | `4ff41aa` | `2752x1786` | `2496x1620` | `57.9 fps` | `1.300` | `36/110/52 ms` | `66/132/79 ms` | `60.1 fps, 35/103 ms` | `1` | `26/33` | wifi: render cadence bottleneck follow-up |
| 2026-04-04 | 16:43:20 EDT | `3e854b6` | `2752x1786` | `2496x1620` | `57.8 fps` | `1.172` | `34/106/48 ms` | `59/129/73 ms` | `59.2 fps, 39/110 ms` | `1` | `26/33` | wifi: validate renderer early catchup + cadence telemetry |
| 2026-04-04 | 16:51:06 EDT | `5f524af` | `2752x1786` | `2496x1620` | `55.3 fps` | `1.263` | `30/146/50 ms` | `52/172/73 ms` | `58.0 fps, 27/136 ms` | `1` | `26/33` | wifi: decode handoff latency focus |
| 2026-04-04 | 17:00:35 EDT | `a5d802c` | `2752x1786` | `2496x1620` | `56.8 fps` | `1.169` | `34/106/47 ms` | `59/128/73 ms` | `58.7 fps, 38/109 ms` | `1` | `26/33` | wifi: validate hevc handoff queue telemetry |
| 2026-04-04 | 17:07:04 EDT | `c55fe1b` | `2752x1786` | `2496x1620` | `56.8 fps` | `1.296` | `38/108/52 ms` | `71/131/79 ms` | `59.5 fps, 37/110 ms` | `1` | `26/33` | wifi: baseline renderer dequeue oscillation confirm |
| 2026-04-04 | 17:13:26 EDT | `934f9d3` | `2752x1786` | `2496x1620` | `56.0 fps` | `1.231` | `40/139/59 ms` | `64/162/83 ms` | `58.1 fps, 77/237 ms` | `1` | `26/33` | wifi: validate renderer dequeue/catchup policy |
| 2026-04-04 | 17:20:36 EDT | `76fbfb3` | `2752x1786` | `2496x1620` | `55.4 fps` | `1.498` | `36/164/61 ms` | `59/191/86 ms` | `57.5 fps, 33/149 ms` | `1` | `26/33` | wifi: burst-density starvation correlation |
| 2026-04-04 | 17:29:21 EDT | `de5ee42` | `2752x1786` | `2496x1620` | `57.0 fps` | `1.181` | `31/110/48 ms` | `55/131/72 ms` | `59.7 fps, 33/103 ms` | `1` | `26/33` | wifi: validate burst/starvation fix |
| 2026-04-04 | 17:35:28 EDT | `c19f1e1` | `2752x1786` | `2496x1620` | `56.1 fps` | `1.322` | `34/107/50 ms` | `65/129/76 ms` | `59.5 fps, 33/102 ms` | `1` | `26/33` | wifi: send-scheduler burst shaping |
| 2026-04-04 | 17:42:53 EDT | `57b06be` | `2752x1786` | `2496x1620` | `55.1 fps` | `1.483` | `43/212/73 ms` | `72/223/97 ms` | `58.4 fps, 40/161 ms` | `1` | `26/33` | wifi: validate send-scheduler burst shaping |
| 2026-04-04 | 18:44:47 EDT | `fe616ab` | `2752x1786` | `2496x1620` | `56.9 fps` | `0.865` | `28/101/37 ms` | `50/134/58 ms` | `58.6 fps, 28/135 ms` | `1` | `26/33` | wifi: iteration4 launch-retry diagnostics |
| 2026-04-04 | 18:52:14 EDT | `fa4d643` | `2752x1786` | `2496x1620` | `55.4 fps` | `1.475` | `44/141/64 ms` | `77/159/90 ms` | `55.8 fps, 65/328 ms` | `1` | `26/33` | wifi: iteration5 burst-severe escalation guard |
| 2026-04-04 | 18:59:13 EDT | `2547d7b` | `2752x1786` | `2496x1620` | `57.4 fps` | `1.297` | `37/106/51 ms` | `69/129/77 ms` | `60.1 fps, 34/104 ms` | `1` | `26/33` | wifi: iteration6 tcp-scheduler recovery spacing under completion-tail pressure |
| 2026-04-04 | 19:07:55 EDT | `5936ba5` | `2752x1786` | `2496x1620` | `57.9 fps` | `1.296` | `37/107/51 ms` | `69/129/77 ms` | `59.0 fps, 39/107 ms` | `1` | `26/33` | wifi: iteration7 fast adaptive recovery ramp after transient completion-tail |
| 2026-04-04 | 19:16:52 EDT | `8c1db57` | `2752x1786` | `2496x1620` | `57.0 fps` | `1.149` | `32/107/47 ms` | `56/130/72 ms` | `59.4 fps, 35/105 ms` | `1` | `26/33` | wifi: iteration8 synthetic timer catch-up after capture cadence lag |
| 2026-04-04 | 19:25:40 EDT | `ef9e343` | `2752x1786` | `2496x1620` | `57.5 fps` | `1.296` | `36/107/51 ms` | `69/129/77 ms` | `59.6 fps, 36/105 ms` | `1` | `26/33` | wifi: iteration9 synthetic emit-accounting guard for failed frame emission |
| 2026-04-04 | 19:33:14 EDT | `6cf29a0` | `2752x1786` | `2496x1620` | `58.0 fps` | `1.306` | `37/108/51 ms` | `69/130/78 ms` | `59.3 fps, 33/106 ms` | `1` | `26/33` | wifi: iteration10 tcp completion-guard spacing to prevent saturation starvation |
| 2026-04-04 | 19:41:18 EDT | `02daed7` | `2752x1786` | `2496x1620` | `56.8 fps` | `0.968` | `28/120/39 ms` | `50/151/61 ms` | `59.7 fps, 26/80 ms` | `1` | `26/33` | wifi: iteration11 hevc pending saturation retry guard to reduce starvation tails |
| 2026-04-04 | 19:47:33 EDT | `e3800d7` | `2752x1786` | `2496x1620` | `57.4 fps` | `1.267` | `33/112/53 ms` | `59/133/77 ms` | `59.6 fps, 32/102 ms` | `1` | `26/33` | wifi: iteration12 hevc adaptive saturation retry budget to reduce clustered skip tails |
| 2026-04-04 | 19:54:08 EDT | `7fbb27d` | `2752x1786` | `2496x1620` | `58.1 fps` | `1.104` | `30/104/44 ms` | `53/126/69 ms` | `59.5 fps, 32/105 ms` | `1` | `26/33` | wifi: iteration13 hevc soft-hard saturation guard reduce pending2 skip tails |
| 2026-04-04 | 20:02:02 EDT | `64ed33e` | `2752x1786` | `2496x1620` | `58.1 fps` | `0.533` | `28/43/30 ms` | `48/65/51 ms` | `60.0 fps, 25/39 ms` | `1` | `27/33` | wifi: iteration14 hevc hard-to-soft relief admit reduces hard skip tails |
| 2026-04-04 | 20:08:30 EDT | `82317db` | `2752x1786` | `2496x1620` | `57.5 fps` | `1.189` | `32/105/47 ms` | `57/128/72 ms` | `59.6 fps, 37/109 ms` | `1` | `26/33` | wifi: iteration15 hard-first-hit relief grace reduce residual hard skip stutter |
| 2026-04-04 | 20:24:31 EDT | `21faecf` | `2752x1786` | `2496x1620` | `56.9 fps` | `1.268` | `31/113/50 ms` | `55/134/74 ms` | `58.6 fps, 40/127 ms` | `1` | `24/33` | wifi: iteration15.2 pairing-connection retain + state-lifecycle instrumentation |
| 2026-04-04 | 20:29:41 EDT | `02876bb` | `2752x1786` | `2496x1620` | `58.2 fps` | `1.275` | `35/105/50 ms` | `67/129/76 ms` | `60.2 fps, 34/102 ms` | `1` | `26/33` | wifi: iteration15.3 tcp scheduler sleep-cap + clamp instrumentation |
| 2026-04-04 | 20:36:23 EDT | `af9a475` | `2752x1786` | `2496x1620` | `57.8 fps` | `1.288` | `33/104/48 ms` | `67/127/75 ms` | `59.6 fps, 31/102 ms` | `1` | `26/33` | wifi: iteration15.4 completion-derived scheduler guard validation |
| 2026-04-04 | 20:43:25 EDT | `9b1257d` | `2752x1786` | `2496x1620` | `57.8 fps` | `1.203` | `30/115/51 ms` | `53/135/74 ms` | `59.6 fps, 28/99 ms` | `1` | `26/33` | wifi: iteration15.5 completion-derived sleep-cap override validation |
| 2026-04-04 | 20:51:11 EDT | `e86d6bf` | `2752x1786` | `2496x1620` | `55.0 fps` | `1.088` | `32/105/45 ms` | `54/127/67 ms` | `54.6 fps, 40/109 ms` | `1` | `26/33` | wifi: iteration15.6 renderer catchup escalation + decision telemetry |
| 2026-04-04 | 21:00:03 EDT | `b11f628` | `2752x1786` | `2496x1620` | `56.9 fps` | `0.922` | `28/113/38 ms` | `50/131/58 ms` | `58.9 fps, 25/84 ms` | `1` | `26/33` | wifi: iteration15.7 shallow-depth soft-catchup threshold guard + telemetry |
| 2026-04-04 | 21:09:24 EDT | `5f52812` | `2752x1786` | `2496x1620` | `54.9 fps` | `1.275` | `32/107/50 ms` | `56/129/73 ms` | `55.1 fps, 31/111 ms` | `1` | `26/33` | wifi: iteration15.8 deep-depth hard-trim escalation + aggressive-trim telemetry |
| 2026-04-04 | 21:16:13 EDT | `8d85d02` | `2752x1786` | `2496x1620` | `54.6 fps` | `1.346` | `32/150/55 ms` | `54/161/76 ms` | `51.1 fps, 75/356 ms` | `1` | `26/33` | wifi: iteration15.9 deep-cooldown soft-suppression validation |
| 2026-04-04 | 21:24:14 EDT | `6baf1e6` | `2752x1786` | `2496x1620` | `53.6 fps` | `1.276` | `32/119/52 ms` | `53/141/75 ms` | `55.0 fps, 33/107 ms` | `1` | `26/33` | wifi: iteration16.0 deep-backlog soft-threshold + cooldown suppression widening |
| 2026-04-04 | 21:31:42 EDT | `fac97ff` | `2752x1786` | `2496x1620` | `52.1 fps` | `1.551` | `38/174/64 ms` | `63/192/87 ms` | `56.0 fps, 36/109 ms` | `1` | `26/33` | wifi: iteration16.1 mid-depth soft-threshold + cooldown suppression alignment |
| 2026-04-04 | 21:38:19 EDT | `0f007ae` | `2752x1786` | `2496x1620` | `52.2 fps` | `1.532` | `45/143/65 ms` | `77/164/90 ms` | `56.0 fps, 47/124 ms` | `1` | `26/33` | wifi: iteration16.2 hard-depth aggressive trim threshold guard |
| 2026-04-04 | 21:47:41 EDT | `473c320` | `2752x1786` | `2496x1620` | `51.9 fps` | `1.467` | `42/128/60 ms` | `75/150/85 ms` | `55.9 fps, 35/108 ms` | `1` | `26/33` | wifi: iteration16.3 aggressive relief threshold 22ms + legacy 24ms telemetry |
| 2026-04-04 | 21:55:04 EDT | `5351f87` | `2752x1786` | `2496x1620` | `54.4 fps` | `1.358` | `39/119/59 ms` | `66/138/83 ms` | `57.3 fps, 35/106 ms` | `1` | `26/33` | wifi: iteration16.4 mid-depth cooldown release valve @24ms |
| 2026-04-05 | 12:36:34 EDT | `a32f314` | `2752x1786` | `2496x1620` | `54.4 fps` | `1.001` | `27/104/41 ms` | `47/120/58 ms` | `55.1 fps, 26/96 ms` | `1` | `27/34` | full run |
| 2026-04-05 | 13:29:11 EDT | `48e111a` | `2752x1786` | `2496x1620` | `49.8 fps` | `1.404` | `40/132/67 ms` | `56/138/80 ms` | `50.5 fps, 35/105 ms` | `1` | `26/33` | user testing wifi |
| 2026-04-06 | 14:21:09 EDT | `c93571e` | `2752x1786` | `2496x1620` | `59.2 fps` | `0.369` | `28/39/29 ms` | `49/59/49 ms` | `59.4 fps, 24/32 ms` | `1` | `26/33` | Transport fallback fix: no-op disconnectCurrent, immediate WiFi fallback, remove 300ms delay |
| 2026-05-08 | 11:40:59 EDT | `f017d17` | `2752x1786` | `2496x1620` | `59.9 fps` | `0.259` | `24/29/24 ms` | `43/50/44 ms` | `60.1 fps, 21/26 ms` | `1` | `28/33` | make run wiring test |
| 2026-11-15 | 16:38:03 EST | `c25f687` | `2752x1786` | `2496x1620` | `59.8 fps` | `0.274` | `24/29/24 ms` | `42/52/43 ms` | `60.0 fps, 21/24 ms` | `1` | `29/34` | baseline 2026-11-15: usb main stream via wifi peer-address bootstrap, OS 27.2 |
| 2026-11-15 | 16:49:11 EST | `fa94785` | `2752x1786` | `2752x1786` | `29.4 fps` | `2.009` | `198/920/294 ms` | `216/969/317 ms` | `25.0 fps, 243/576 ms` | `1` | `26/33` | AddrOnLink USB discovery + iPad TCP frame cap 4MB->32MB (LZ4 keyframes) + probe echo overflow guard; usb-only baseline |
| 2026-11-15 | 17:20:25 EST | `52cd800` | `2752x1786` | `2752x1786` | `84.8 fps` | `0.644` | `10/37/15 ms` | `29/54/33 ms` | `78.9 fps, 9/41 ms` | `1` | `29/33` | usb-only baseline at 10Gb/s link after replug; LZ4 gate-before-compress + frame-hash check |
| 2026-11-15 | 17:33:24 EST | `ab163df` | `2752x1786` | `2752x1786` | `52.1 fps` | `1.426` | `10/103/24 ms` | `26/124/42 ms` | `30.0 fps, 8/202 ms` | `1` | `26/33` | usb: striped parallel LZ4 (8 stripes, Mac dispatch_apply + iPad striped_decode, tla/StripeSync) |
| 2026-11-15 | 17:39:36 EST | `62906a2` | `2752x1786` | `2752x1786` | `99.7 fps` | `0.468` | `7/26/10 ms` | `27/44/29 ms` | `101.2 fps, 6/21 ms` | `1` | `31/33` | usb: striped LZ4 x8 + Mac Release code coverage off (counter contention made parallel LZ4 5x slower) |
| 2026-11-15 | 17:53:46 EST | `d328f4f` | `2752x1786` | `2752x1786` | `89.2 fps` | `0.528` | `7/26/10 ms` | `23/46/27 ms` | `97.5 fps, 7/23 ms` | `1` | `31/33` | usb: remove iPad tcp-recv log spam (718k lines/run) + RENDER-CADENCE display-link counters |
| 2026-11-15 | 18:04:38 EST | `c7db83b` | `2752x1786` | `2752x1786` | `102.1 fps` | `0.440` | `8/28/12 ms` | `30/51/32 ms` | `108.7 fps, 7/22 ms` | `1` | `29/33` | USB: iPad 4-slot texture ring + FIFO queue (one new frame per tick, K=2 drain), tla/FrameRing |
| 2026-11-15 | 18:12:39 EST | `061f6a0` | `2752x1786` | `2752x1786` | `94.5 fps` | `0.549` | `8/28/12 ms` | `27/50/30 ms` | `100.5 fps, 7/23 ms` | `1` | `30/33` | USB control: ring kept, queue cap 1 (newest wins); FIFO cap 2 backed out after c7db83b latency rise |
| 2026-11-15 | 20:26:08 EST | `e304223` | `2752x1786` | `2496x1620` | `52.2 fps` | `1.176` | `39/128/58 ms` | `58/142/75 ms` | `53.3 fps, 36/120 ms` | `1` | `39/45` | input E2E: fix duplicate test chain (pre-pairing checkBothDone fired twice); 12 input tests |
| 2026-11-15 | 20:45:21 EST | `558ac03` | `2752x1786` | `2496x1620` | `52.0 fps` | `1.237` | `38/136/59 ms` | `57/148/75 ms` | `54.0 fps, 34/113 ms` | `1` | `38/46` | baseline before queue split: LANE-BLOCK logging + input-during-reconfig (pointer moves during eco on/off) |
| 2026-11-15 | 20:54:23 EST | `02f587c` | `2752x1786` | `2496x1620` | `50.0 fps` | `1.294` | `50/136/65 ms` | `63/150/81 ms` | `51.1 fps, 51/137 ms` | `1` | `40/46` | Mac session queue split (SessionLanes): input stays on transport queue, session work on serial S; scroll check by sumDy |
| 2026-11-15 | 20:59:53 EST | `bc6e7d8` | `2752x1786` | `2496x1620` | `47.9 fps` | `1.606` | `48/265/88 ms` | `64/267/102 ms` | `41.2 fps, 91/391 ms` | `1` | `40/46` | SessionLanes follow-up: startAdvertising/beginReconnectWindow hop to Wi-Fi transport queue (S now calls them) |
| 2026-11-15 | 21:14:30 EST | `5f4b88c` | `2752x1786` | `2496x1620` | `49.3 fps` | `1.550` | `52/188/77 ms` | `66/197/92 ms` | `50.3 fps, 50/123 ms` | `1` | `39/46` | wifi stutter diag: log iPad PEER-ADDR; external 10Hz ping iPad+router during run (no behavior change) |
| 2026-11-15 | 21:20:43 EST | `630998b` | `2752x1786` | `2496x1620` | `48.6 fps` | `1.588` | `64/299/100 ms` | `74/294/112 ms` | `50.4 fps, 53/130 ms` | `1` | `39/46` | wifi stutter A/B: --no-peer-to-peer (AWDL excluded both sides) + external ping probe |
| 2026-11-15 | 21:27:24 EST | `bdc2ee5` | `2752x1786` | `2496x1620` | `59.9 fps` | `0.307` | `27/33/27 ms` | `47/55/48 ms` | `60.0 fps, 24/30 ms` | `1` | `40/46` | wifi stutter: interactive-video service class (WMM AC_VI) on Wi-Fi TCP/UDP both sides; --no-peer-to-peer |
| 2026-11-15 | 21:54:09 EST | `2a077a9` | `2752x1786` | `2496x1620` | `48.7 fps` | `1.337` | `65/198/83 ms` | `78/208/98 ms` | `50.4 fps, 48/118 ms` | `1` | `38/46` | DIAG: iPad Continuity off; log Wi-Fi TCP connect states/path (prior run hung at connect, no retry) |
| 2026-11-15 | 22:25:51 EST | `4540d26` | `2752x1786` | `2496x1620` | `27.0 fps` | `2.625` | `102/855/233 ms` | `77/796/199 ms` | `42.6 fps, 49/256 ms` | `1` | `37/46` | per-frame timeline FT-M/FT-I instrumentation (logging only) to locate Wi-Fi stalls |
| 2026-11-15 | 23:28:09 EST | `8148018` | `2752x1786` | `2496x1620` | `44.0 fps` | `1.556` | `68/334/106 ms` | `79/348/120 ms` | `42.2 fps, 79/378 ms` | `1` | `39/46` | link liveness+infra-first dial, compressor live resize, USB 120fps restore; on en0, 0 silence trips; bw 14.8Mb/s |
| 2026-11-16 | 00:08:13 EST | `cfe6597` | `2752x1786` | `2496x1620` | `40.4 fps` | `1.185` | `39/125/57 ms` | `58/143/75 ms` | `39.2 fps, 39/120 ms` | `1` | `39/46` | Wi-Fi ack gate: iPad frame acks, encode only while unacked<3, no post-encode drop or stall reset |
| 2026-11-16 | 00:21:07 EST | `ddfd000` | `2752x1786` | `2496x1620` | `28.9 fps` | `1.314` | `45/222/78 ms` | `61/243/96 ms` | `37.3 fps, 31/110 ms` | `1` | `38/46` | Wi-Fi rate: gate holds no longer congestion; bitrate follows half ack-measured delivery rate; fps kept at 60 |
| 2026-11-16 | 00:29:29 EST | `b95e17d` | `2752x1786` | `2496x1620` | `34.5 fps` | `1.199` | `45/153/69 ms` | `63/171/87 ms` | `38.0 fps, 40/125 ms` | `1` | `39/46` | Wi-Fi rate: ack gate keeps 60fps, fixed 10 Mbps target; capacity estimator removed (burst-inflated) |
| 2026-11-16 | 00:39:38 EST | `1247cc4` | `2752x1786` | `2496x1620` | `40.1 fps` | `1.283` | `57/167/75 ms` | `68/184/92 ms` | `42.7 fps, 50/127 ms` | `1` | `39/46` | Wi-Fi ack gate depth 3 -> 5 (slow windows were capped at 3/RTT); 60fps, fixed 10 Mbps |
| 2026-11-16 | 00:49:36 EST | `251f328` | `2752x1786` | `2496x1620` | `42.6 fps` | `1.241` | `42/149/66 ms` | `60/165/83 ms` | `42.7 fps, 46/129 ms` | `1` | `39/46` | Diagnostic: --no-peer-to-peer, same build as 1247cc4; does our AWDL use drive the 512 TU iPad rx holds? |
| 2026-11-16 | 01:04:35 EST | `565c38c` | `2752x1786` | `2496x1620` | `50.4 fps` | `1.187` | `36/135/49 ms` | `56/143/67 ms` | `52.1 fps, 37/137 ms` | `1` | `36/46` | Diagnostic: --awdl-only (infra prohibited); do AWDL frames flow in the 512 TU infra holds? gate 5, 10 Mbps |
| 2026-11-16 | 01:20:12 EST | `5dd5a0f` | `2752x1786` | `2496x1620` | `53.6 fps` | `0.982` | `32/91/41 ms` | `52/100/60 ms` | `56.0 fps, 29/52 ms` | `1` | `40/46` | AWDL-first wireless (AwdlFirst; infra Wi-Fi prohibited on AWDL dial), infra fallback; gate 5, 10 Mbps |
| 2026-11-16 | 01:33:09 EST | `7993138` | `2752x1786` | `2496x1620` | `47.8 fps` | `1.222` | `34/153/51 ms` | `54/166/68 ms` | `44.8 fps, 34/161 ms` | `1` | `39/46` | AWDL dial prohibits wired types; LZ4 keyframe on USB connect, iPad drops wireless LZ4 (DeltaSync T4) |
| 2026-11-16 | 01:58:06 EST | `a470989` | `2752x1786` | `2496x1620` | `53.1 fps` | `1.036` | `40/90/49 ms` | `60/104/68 ms` | `52.6 fps, 57/93 ms` | `1` | `39/46` | replug/agent-restart fixes: iPad USB liveness+redial, LZ4 only on USB, codec resync, capture resize, HEVC slice fix |
| 2026-11-16 | 02:20:10 EST | `4cc1c70` | `2752x1786` | `2496x1620` | `56.3 fps` | `0.671` | `32/71/38 ms` | `53/85/57 ms` | `56.9 fps, 28/46 ms` | `1` | `40/46` | AWDL target 20 Mbps (infra 10); ENC-SPLIT encode timing; iPad camera stops when QR pane hidden |
