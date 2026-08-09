# 04 — Run Tracking & Gem Collection Mechanics

The hard-problem doc: GPS pipeline, collection detection, validation/anti-spoof, and battery. Feeds docs 05 (Run entity), 06 (completion endpoint), and 07 (CoreLocationKit / GameKitCore).

## Guiding principle

> **The client is optimistic; the server is authoritative.**

Everything the phone decides mid-run (collections, pace, validity) is UX. The server re-validates the full GPS track at completion and its verdict is final (doc 06). Client-side checks exist to keep honest users' experience instant and to avoid uploading obviously-broken tracks — not to stop determined cheaters, which client code fundamentally cannot do.

## GPS pipeline

### Configuration (during an active run only)
- `CLLocationManager` with `activityType = .fitness`
- `desiredAccuracy = kCLLocationAccuracyBestForNavigation`
- `distanceFilter = 5` m
- `allowsBackgroundLocationUpdates = true` — set at run start, **unset at run stop**
- Authorization: **When In Use** only, ever (doc 07 / App Store implications in doc 08)

### Sample filtering
Drop a raw sample when any of:
- `horizontalAccuracy > 30` m or `horizontalAccuracy < 0`
- `speed < 0` (invalid fix)
- timestamp older than 5 s (stale cached fix, common on first fixes)

### Smoothing
Weighted moving average over the last 3 accepted samples (weights 0.5 / 0.3 / 0.2, newest first) applied to position; speed taken from CoreLocation's own `speed` with the same averaging. A Kalman filter is the known upgrade path — noted, not built, for MVP.

### Auto-pause
Smoothed speed < 0.5 m/s sustained 10 s → pause (timer stops, UI banner per doc 03). Speed > 1.0 m/s for 3 s → auto-resume. Manual pause always available.

### Recorded track
Every accepted sample appended as `(t, lat, lng, horizontalAccuracy, speed)` to an **append-only on-disk buffer** (crash-safe — a killed app loses at most the last write, and an in-progress run is recoverable on relaunch). Uploaded in full at completion (doc 06); promoted to SwiftData with the completed Run (doc 07).

## Collection detection

### Decision: distance threshold against the smoothed position — **not** geofences

`CLCircularRegion` monitoring was considered and rejected:
- OS limit of 20 monitored regions per app (routes can carry more gems than that).
- Practical minimum radius ~100 m — far too coarse for 25 m collection.
- Region-entry wake latency is unpredictable; collection must feel instant.

Since the app already receives continuous location updates during a run, per-sample checking is free.

### Algorithm
For each new smoothed position:
1. Consider only **upcoming** gems: those whose `position_along_route_m` is within a window ahead of the runner's current route progress (see adherence below). This makes checks O(few) regardless of gem count.
2. **Collect** when horizontal distance to the gem's coordinate ≤ **61 m (200 ft)** — the capture zone the map draws around every gem, so the rule and the visual are the same number.
3. **Hysteresis:** after a collection, no other gem can trigger until the runner has either exited an 80 m radius around that point or advanced ≥ 100 m along the route (both ~1.3–1.6× the 61 m capture radius, so the exit ring sits outside the capture zone) — prevents double-fires at gem clusters and switchback overlaps.
4. Fire UI/haptic celebration (doc 03), append to the run's claimed-collections list.

### Route adherence (what makes a run "valid")
- Each sample is **projected onto the route polyline** → cross-track distance + along-route progress.
- **Valid run:** cross-track ≤ 40 m for ≥ 90% of samples, and total route coverage ≥ 95% (start-to-finish progress, direction-agnostic loops handled by monotonic progress in either direction).
- **Per-gem rule:** a gem only awards if the runner's along-route progress passes **through** the gem's `position_along_route_m` monotonically — being 61 m away across a switchback without route progress through that point does *not* collect. This closes the "graze the parallel path" hole.
- Going off-route is not punished mid-run (gentle chip per doc 03); it just risks the validity threshold. GPS noise in urban canyons is why the thresholds are generous.

## Client-side sanity checks (advisory)

Flag (not block) the run when:
- **Teleport:** instantaneous speed > 8 m/s sustained > 5 s (world-class sprint is ~10 m/s for 10 s; 8 sustained mid-run is a vehicle or a spoofer).
- **Pace bounds:** overall pace outside 2:30–20:00 min/km (faster = vehicle; slower = not a run/walk — see doc 02 walking rule for 10:00–20:00 handling).
- **Accuracy degradation pattern:** > 50% of samples rejected, or accuracy oscillating implausibly (some spoofers emit perfect 5 m accuracy constantly — a *too-clean* track over 30+ min is itself a weak signal, recorded as a feature for the server, not judged on-device).

Flags ride along with the completion payload. The client never accuses; flagged runs show the neutral "verifying" state (doc 03).

### Device attestation
The completion request carries an **App Attest** assertion (DeviceCheck framework) binding the payload hash to a legitimate app instance on real hardware — raising the bar from "run a GPS spoofing app" to "defeat Apple's attestation too". Server verification sketch in doc 06; jailbroken-device spoofing is acknowledged as not fully solvable (risk register, doc 08).

## Battery budget

**Target: < 8% battery per hour of active run. This is a launch gate, not an aspiration** (doc 08 exit criteria).

Tactics:
- **Zero network during the run.** Track buffers locally; one upload at completion. (Also makes offline runs identical to online ones.)
- UI updates coalesced to 1 Hz; map camera updates interpolated client-side rather than per-fix.
- Map rendering suspended entirely while the screen is locked (GPS + collection logic continue; haptics fire).
- **Adaptive GPS:** when the next gem is > 500 m ahead *and* the runner is on-route, relax `distanceFilter` to 10 m; restore to 5 m within 500 m of a gem. (Accuracy setting stays constant — toggling it thrashes the GPS radio.)
- Screen-on brightness/refresh untouched — user's domain.

Measurement: instrumented test runs (45 min, screen locked, mid-tier device — e.g. iPhone 12/SE class) tracked per build in TestFlight.

## Offline behavior

- Recording, collection detection, auto-pause, and summary all work fully offline (map tiles may be stale/absent; stats band unaffected).
- Completed runs enter a **sync queue** (SwiftData, doc 07) keyed by a client-generated `idempotency_key`; retried with backoff until the server acknowledges. Duplicate submissions are safe by construction (doc 06).
- Stash/XP/streak reconcile when the verdict arrives; optimistic values shown meanwhile (doc 03 cross-cutting rules).

## Edge cases

| Case | Handling |
|---|---|
| App killed mid-run (user or OS) | On next launch, recover from the append-only buffer → offer "Resume run" (if < 30 min old) or "Save as-is" |
| Phone call mid-run | Recording continues in background; no special handling |
| GPS lost (tunnel) | Samples stop; distance freezes; no auto-pause trigger on missing data (only on low speed); gap noted in track for server |
| Run crosses midnight | Streak credited to the day the run *started* |
| Two gems within 25 m of one point | Hysteresis + monotonic-progress rule serialize them correctly |
| Airplane-mode run | Identical to offline; App Attest assertion generated at submission time, not run time |
