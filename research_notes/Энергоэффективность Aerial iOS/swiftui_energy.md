# Energy efficiency for Swift/SwiftUI iOS apps (iOS 26–27)

Scope: concrete techniques, APIs and measured effects for "almost zero when idle, little while browsing a catalogue".
Source quality notes: Apple WWDC transcripts (2021–2025) are primary. The Energy Efficiency Guide for iOS Apps is an
archived document (2016–2018). It is old but still the only Apple text with timer and network rules. Several third-party
items (BGR, MacRumors forum, tessl/axiom skill guides) are marked as such.

## SwiftUI: avoiding unnecessary view updates, lazy stacks, scrolling; detecting with Instruments

### Takeaway
The biggest documented wins are: build only visible items (`LazyVStack`/`LazyHStack`); keep `body` cheap (no formatters or
parsing); and make Observation dependencies narrow (per-item `@Observable`, `@ObservationIgnored` containers), so that one
change re-runs one body instead of every visible cell. Instruments 26 has a SwiftUI instrument with a Cause & Effect Graph,
used together with the Power Profiler, to confirm the result.

### Cited Findings
- WWDC25 "Profile and optimize power usage in your app" (226): a video app's Library pane built every card and thumbnail in
  a `VStack`. CPU power impact rose from baseline **1 to 21** when the pane opened. Switching to `LazyVStack` (views
  created/destroyed as they scroll in/out) cut it **from 21 to 4.3** and removed the hang — [WWDC25 226](https://developer.apple.com/videos/play/wwdc2025/226)
- Same session: hidden drain found with on-device tracing. A function re-read and `JSONDecoder`-decoded a rules JSON file on
  every location change. The fix was to parse it lazily once and cache the result. It showed in traces as a repeating
  burst/quiet pattern of CPU impact — [WWDC25 226](https://developer.apple.com/videos/play/wwdc2025/226)
- WWDC25 "Optimize SwiftUI performance with Instruments" (306): the SwiftUI instrument (Instruments 26/Xcode 26) has these
  lanes: **Update Groups** (if CPU spikes while this lane is empty, the problem is outside SwiftUI), **Long View Body
  Updates**, **Long Representable Updates** and **Other Long Updates**. Long updates are colored orange/red by how likely
  they are to cause a hitch or hang (no numeric threshold given). Triage: filter long updates, then "Set Inspection Range
  and Zoom", then Time Profiler on the main thread — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306)
- 306: `body` runs on the main thread. Even ~1 ms per body adds up when many views update, and many small updates can
  overrun the frame deadline in aggregate (hitch) — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306)
- 306: creating `NumberFormatter`/`MeasurementFormatter` inside a property read by `body` caused long updates while
  scrolling. The fix was to create formatters once and precompute strings in the model when the data changes. This
  removed the long updates during scrolling — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306)
- 306: an `isFavorite(landmark)` lookup scanned a whole array inside `@Observable`, so every visible cell depended on the
  array. Toggling one favorite re-ran all visible bodies. The fix was a per-item `@Observable ViewModel` stored in a
  dictionary marked `@ObservationIgnored`. Afterwards, 2 taps produced exactly **2 body updates** — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306)
- 306: every view that reads `@Environment` is notified on any environment change and SwiftUI then compares the value.
  Even skipped bodies cost a check. **Don't put frequently changing values (geometry, timers) in the environment** — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306)
- 306: the Cause & Effect Graph (view context menu → "Show Cause & Effect Graph") is read right to left. It has nodes for
  gesture, state change (with a backtrace of the write), External Environment and EnvironmentWriter. A dimmed node means the
  body did not run. The question to ask is "what marked my body outdated?" — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306)
- Hangs: the Instruments tools report hangs from **250 ms** by default. The ideal is no main-thread work > **100 ms**. A hang
  is either a busy main thread (CPU) or a blocked one (waiting, little CPU) — [wwdcnotes summary of WWDC23 10248](https://wwdcnotes.com/notes/wwdc23/10248) (third-party summary of [WWDC23 10248](https://developer.apple.com/videos/play/wwdc2023/10248))
- A third-party guide recommends the Cause & Effect Graph for cases such as "a timer that invalidates a whole list" — [tessl swiftui-performance reference](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.9.0/files/skills/swiftui-performance/references/optimizing-swiftui-performance-instruments.md)

### Inferences
- For a catalogue app, shelves of posters should be `LazyHStack` inside a `LazyVStack`. Per-poster state (in list, rating,
  progress) should be observed per item, not through one big `Library` array or dictionary that every cell reads.
- A clock or progress value that ticks (playback time, download speed, "now" for countdowns) should live in a small
  observable read only by the leaf view that shows it, never in the environment or in a root model that many views read.
- `TimelineView` (not covered by the sources found) redraws on its schedule. Use `.periodic(from:by:)` with the coarsest
  interval needed, or `.explicit`, and keep it in a leaf view. This is general knowledge, unverified here.
- `Equatable` views / `.equatable()` were not covered in 2023–2025 primary material found. With Observation, fine-grained
  dependencies are Apple's demonstrated fix.

### Gaps
- No Apple numeric thresholds for orange vs. red long updates.
- No primary 2023–2026 source quantifying `TimelineView` or `.equatable()` energy cost.

## Timers, polling and wakeups

### Takeaway
Every wakeup takes the CPU out of its idle state and has a fixed cost. Replace polling with events. When a timer is
unavoidable, give it tolerance of at least 10% of the interval, so the system can coalesce it with other wakeups, and
invalidate or cancel it when it is not needed (e.g. on background or when the screen is not visible).

### Cited Findings
- Waking the system from idle costs energy as the CPU and other systems leave low-power states. "If there are many
  timer-invoked wakeups, the energy impact is high." — [Energy Efficiency Guide: Minimize Timer Use (archived)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html)
- Guideline: **tolerance ≥ 10% of the interval** for repeating timers. "Even a small tolerance has a significant positive
  effect." Examples: `NSTimer` 3.0 s / tolerance 0.3. Dispatch timer 1 s with leeway `NSEC_PER_SEC/10`. CFRunLoop timer 2.0 s
  / 0.2. A tolerant timer never fires early. Repeating fire dates are computed from the original schedule. The system's
  default tolerance is usually too small to batch timers — [same](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html)
- Replace polling with events: dispatch source `DISPATCH_SOURCE_TYPE_VNODE` for file changes, APNs/Bonjour for network
  events, and serial queues instead of `usleep` loops (the anti-pattern example woke every 100 ms). Any API with a timeout is
  a timer: prefer `DISPATCH_TIME_FOREVER`. Audit list: `sleep`, `usleep`, `nanosleep`, `pthread_cond_timedwait`, `select`,
  `poll`, `kevent`, `dispatch_after`, `dispatch_semaphore_wait`, `performSelector:afterDelay:` — [same](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html)
- Swift concurrency: `Task.sleep(for:tolerance:clock:)` (iOS 16+). Tolerance allows a later wakeup "to maximize power
  efficiency". The sleep never ends early. The default clock is `.continuous` — [Apple doc](https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:).md), [Hacking with Swift](https://hackingwithswift.com/swift/5.9/sleep-for-clock)
- The clock implementation may use the tolerance to coalesce with the nearest scheduled deadline. There is no contract
  that execution resumes right at expiry — [Swift Forums SE-0329](https://forums.swift.org/t/se-0329-second-review-clock-instant-and-duration/54509?page=2)
- `.continuous` vs `.suspending` clock debate (`.suspending` doesn't count time while the device sleeps) — [Swift Forums](https://forums.swift.org/t/why-was-continuousclock-chosen-as-the-default-for-task-sleep-for/81047/1)
- Low-priority pushes (`apns-priority: 5`) are delayed until the device is awake, which reduces wakeups from sleep — [WWDC22 10083](https://developer.apple.com/videos/play/wwdc2022/10083/)

### Inferences
- Every `while true { … try await Task.sleep(…) }` loop should pass `tolerance:` (≥10–20% of the period). It should also be
  cancelled on `scenePhase != .active` unless the work is needed in the background.
- Periodic diagnostics (e.g. a perf sampler every 15 s) is itself a wakeup source. Coalesce it with tolerance, stop it when
  idle in the background, or sample only while something is playing.
- "Watchdog" style checks of the main thread (pinging every N ms) cost a wakeup each tick. Prefer MetricKit hang diagnostics
  in release builds.

### Gaps
- No Apple figure for the energy cost (mJ) of a single wakeup on current hardware.

## Display and rendering: ProMotion, frame-rate ranges, blur/materials, Liquid Glass, dark mode

### Takeaway
The display runs at the rate of the fastest animation on screen, so one small decorative 60/120 fps animation holds the
whole panel high. Cap secondary animations with `CAFrameRateRange`. Dark UI on OLED saves up to 70% display power. Liquid
Glass has no Apple-published power figures. Third-party tests suggest a measurable GPU/heat cost, so keep glass surfaces
few, static and grouped.

### Cited Findings
- "Power down: Improve battery consumption" (WWDC22 10083): **Dark Mode on OLED → up to 70% display power savings**
  (greater at high brightness). A **frame rate audit → up to 20% battery savings**: lowering one secondary text animation from
  60 to 30 fps let the whole screen render at 30 fps. The refresh rate is set by the **highest** frame rate of any on-screen
  animation. Find these with the Core Animation FPS instrument and cap them with `CADisplayLink.preferredFrameRateRange =
  CAFrameRateRange(minimum: 10, maximum: 60, preferred: 30)` — [WWDC22 10083](https://developer.apple.com/videos/play/wwdc2022/10083/)
- WWDC21 "Optimize for variable refresh rate displays": the frame rate is a hint and the system picks the nearest available
  rate. Limit Frame Rate (Accessibility), thermal state and Low Power Mode cap it at 60 Hz. `UIScreen.maximumFramesPerSecond`
  always reports 120. Use `1/link.duration` for the actual rate, and `targetTimestamp` for drawing — [WWDC21 10147](https://developer.apple.com/videos/play/wwdc2021/10147/)
- On iPhone, rates above 60 Hz require `CADisableMinimumFrameDurationOnPhone` in Info.plist. Without it, higher
  `preferredFrameRateRange` hints are ignored. 30 and 60 Hz get priority in iOS 15+ — [axiom display-performance guide (third-party)](https://skills.cat/skills/charleswiltgen/axiom/axiom-display-performance)
- DTS: the system weighs various factors when choosing a rate, so code must work at any rate in the range — [Apple Developer Forums](https://developer.apple.com/forums/thread/761616)
- Liquid Glass: `GlassEffectContainer` merges multiple glass shapes into one and morphs them. Apple's doc gives no power
  data — [Apple doc](https://developer.apple.com/documentation/swiftui/glasseffectcontainer.md). Third-party claims that the
  container "improves rendering performance" because glass sampling is expensive are unverified — [DEV Community](https://dev.to/arshtechpro/understanding-glasseffectcontainer-in-ios-26-2n8p), [Medium](https://medium.com/@veersr9/ios-26-liquid-glass-in-swiftui-a-practical-reference-demo-app-liquidglassreference-69b8d46dc055)
- Third-party test: iPhone 16 Pro Max, iOS 26 vs iOS 18.5, 150 repetitions each of Notification Center, Safari open/close,
  Photos scroll and unlock. Result: **13% vs 1%** battery used, and the iOS 26 phone ran hotter. Caveats: not run side by
  side (July vs September), not scientific, transparent icons — [BGR](https://bgr.com/1975304/ios-26-vs-ios-18-battery-life-test-liquid-glass/)
- A forum claim says Reduce Transparency did not reduce drain (about +1 W, Control Center about 10–11 W). This is anecdotal
  and the methodology is unknown — [MacRumors forum](https://spy.macrumors.com/threads/reduce-transparency-actually-drains-battery.2467830/)

### Inferences
- In a poster catalogue the main levers are: static glass (no continuous animated glass or blur behind moving content);
  one container for neighbouring glass controls; no `repeatForever` shimmer or placeholder animations on idle screens; and a
  dark default background (helps on OLED iPhones).
- A live blur (`.blur`, `Material`, `UIVisualEffectView`) over scrolling content must be recomposited every frame while
  scrolling. A pre-blurred static image (blur computed once, cached) costs nothing after the first frame. This is general
  knowledge, not measured in the sources.
- SwiftUI-only apps have no `CADisplayLink`. Any custom animation driven by `TimelineView(.animation)` should use
  `.animation(minimumInterval:)` to cap its rate (general knowledge, unverified here).

### Gaps
- No Apple-published GPU or power numbers for `glassEffect`, `Material` or offscreen rendering on iOS 26.
- No primary source on the default frame-rate behavior of SwiftUI/UIView animations under ProMotion in iOS 26.

## Networking: batching, reuse, discretionary sessions, Low Data Mode, radio tail, caching

### Takeaway
The radio stays powered for a while after each transfer (the tail), so scattered small requests cost far more than one
batch. Cellular costs more than Wi-Fi. Batch, cache aggressively, honor Low Data Mode, and push deferrable bulk work to
discretionary background sessions.

### Cited Findings
- Radios are off by default. Each activity powers them up and keeps them up "for an additional period of time in
  anticipation of more work". Sporadic transactions cause high overhead and "can quickly deplete the device's battery".
  Cellular needs significantly more energy than Wi-Fi. Poor signal causes retries and low throughput keeps radios on
  longer — [Energy Guide: Energy and Networking (archived)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/EnergyandNetworking.html)
- Discretionary background `URLSession` (`URLSessionConfiguration.background`, `isDiscretionary = true`,
  `earliestBeginDate`, `countOfBytesClientExpectsToSend/Receive`): the system runs it when the device is plugged in and on
  Wi-Fi, and the app need not run. Note: set config properties **before** creating the session — [WWDC22 10083](https://developer.apple.com/videos/play/wwdc2022/10083/)
- Low Data Mode: `allowsConstrainedNetworkAccess` (iOS 13+, default true). On constrained networks, limit transfers to small
  user-initiated payloads, with no bulk transfers or background prefetch. Defer discretionary tasks until an unconstrained
  interface is available — [Apple doc](https://developer.apple.com/tutorials/data/documentation/foundation/urlsessionconfiguration/allowsconstrainednetworkaccess.md), [WWDC19 Advances in Networking notes](https://mackuba.eu/notes/wwdc19/advances-in-networking-part1)
- `waitsForConnectivity` holds tasks until a suitable network is available instead of failing and retrying — [URLSessionConfiguration guide](https://useyourloaf.com/blog/urlsessionconfiguration-quick-guide/)
- Power Profiler shows a separate **networking power impact** lane per app — [WWDC25 226](https://developer.apple.com/videos/play/wwdc2025/226)

### Inferences
- Reuse one `URLSession` (HTTP/2/3 multiplexing on one connection avoids new TLS handshakes and extra radio time). Don't
  create a session per request.
- Prefetch a shelf page in one burst rather than a trickle of per-poster requests. A disk cache with long TTLs plus
  `ETag`/`If-None-Match` (304s are tiny) cuts both bytes and radio-on time.
- Periodic polling (presence, "who is watching") is the worst case for the tail. Prefer push or WebSocket only while the
  feature is on screen, and back off when idle.

### Gaps
- No current Apple numbers for tail duration (seconds) on 5G/LTE/Wi-Fi.
- No primary source found quantifying HTTP/3 vs HTTP/2 energy on iOS.

## Images: downsampling, off-main decoding, cache sizing

### Takeaway
Decoded bitmap size follows source pixel dimensions, not view size. Downsample with ImageIO to the view's pixel size
(points × scale) off the main thread, and cache the small result.

### Cited Findings
- WWDC18 "Image and Graphics Best Practices" (219, older guidance, still valid): decoded memory ∝ image pixels. Never decode
  at full resolution for a small view. `CGImageSourceCreateThumbnailAtIndex` streams just enough data to produce the
  thumbnail — [tessl image-loading reference summarising WWDC18 219](https://tessl.io/registry/ivan-magda/uikit-expert/files/references/image-loading.md)
- Options: create the source with `kCGImageSourceShouldCache: false`. For the thumbnail, use
  `kCGImageSourceCreateThumbnailFromImageAlways: true`, `kCGImageSourceThumbnailMaxPixelSize: pointSize × scale` and
  `kCGImageSourceShouldCacheImmediately: true` (decode happens inside that call, so run it on a background queue). Decoding
  is CPU-heavy, so prefetch and decode in the background to avoid scroll stutter — [tessl](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.9.0/files/skills/photokit/references/image-loading-caching.md), [juejin WWDC18 notes](https://juejin.cn/post/6844903618429059086)
- `CGImageSourceCreateThumbnailAtIndex` creates a thumbnail of the image at an index — [Apple CGImageSource doc](https://developer.apple.com/documentation/imageio/cgimagesource.md)
- Eager thumbnail loading for off-screen items was the root cause of the 21→4.3 CPU impact case — [WWDC25 226](https://developer.apple.com/videos/play/wwdc2025/226)

### Inferences
- Request TMDb sizes close to the display size (e.g. w342 for a ~120 pt poster at 3×) rather than downscaling w780/original.
  This saves bytes, radio time and decode CPU.
- Use an `NSCache` with `totalCostLimit` set by decoded bytes (w×h×4), and clear it on memory warning or background.

### Gaps
- No primary 2023–2026 measurements of decode energy per megapixel.

## Background: background tasks, BGTaskScheduler, silent audio, location; Low Power Mode and thermal state

### Takeaway
Finish background work promptly. Use `BGProcessingTask` (with power/network requirements) or discretionary URLSession for
deferrable work. Stop location and audio engines when not needed. Silent-audio keep-alive is a known App Review rejection
(2.5.4) and keeps audio hardware active. Adapt to `isLowPowerModeEnabled` and `thermalState` by reducing animations, frame
rate, prefetch and sync.

### Cited Findings
- `BGProcessingTaskRequest` with `requiresExternalPower`/`requiresNetworkConnectivity` defers long work (cleanup, backup,
  ML) to when the device is charging. The system grants several minutes — [WWDC22 10083](https://developer.apple.com/videos/play/wwdc2022/10083/)
- Stop location with `stopUpdatingLocation()` as soon as done. MetricKit `cumulativeBackgroundLocationTime` measures it.
  Stop `AVAudioEngine` when playback stops, or set `autoShutdownEnabled` so audio hardware powers down when idle — [WWDC22 10083](https://developer.apple.com/videos/play/wwdc2022/10083/)
- Silent-audio tracks played only to stay in memory have been rejected under Guideline 2.5.4. The audio background mode is
  for apps delivering audible content. This comes from forum anecdotes, not official text — [Apple Developer Forums](https://developer.apple.com/forums/thread/105443), [Cult of Mac (Pastebot)](https://www.cultofmac.com/?p=53686), [Zoom dev forum](https://devforum.zoom.us/t/ios-app-was-rejected-from-apple-appstore/37734)
- In Low Power Mode, the system reduces CPU/GPU performance, pauses discretionary and background activity including
  networking, dims the screen and disables motion effects. Apps should reduce animations, lower frame rates, stop location,
  and disable syncs/backups. APIs: `ProcessInfo.processInfo.isLowPowerModeEnabled` and
  `.NSProcessInfoPowerStateDidChange` (posted on a global queue) — [Energy Guide: Low Power Mode (archived)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LowPowerMode.html)
- Low Power Mode and thermal state cap ProMotion at 60 Hz — [WWDC21 10147](https://developer.apple.com/videos/play/wwdc2021/10147/)
- `ProcessInfo.thermalState` (`nominal/fair/serious/critical`) and `thermalStateDidChangeNotification`. At serious/critical,
  reduce CPU/GPU load (frame rate, quality) and defer optional work. Exact Apple wording not captured — [Apple doc](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum)

### Inferences
- If a keep-alive audio session is needed for a legitimate long download, run it only while the download is active, stop
  it the moment the queue empties, and log it. Every minute it runs keeps the process and audio route awake. Sideloaded
  builds are not subject to App Review, but the energy cost remains.
- On Low Power Mode: skip AI/recommendation refreshes, poster prefetch beyond the visible page, presence polling and
  decorative animations. Lower perf-sampling frequency.

### Gaps
- No measured figure for the battery cost of a silent `AVAudioSession` keep-alive on current iPhones.

## Logging, diagnostics overhead, MetricKit, Organizer, Power Profiler

### Takeaway
Measure with the Power Profiler (Instruments and on-device Performance Trace) and the field data in MetricKit and the
Organizer. Keep in-app diagnostics cheap: buffered writes, `os.Logger` for verbose logs, and no periodic sampling when idle.

### Cited Findings
- Power Profiler (Instruments 26): a system power lane (demo: **10.5%/hr**) and per-app CPU, GPU, display and networking
  impact lanes. Workflow: Product → Profile → Blank template + Power Profiler + CPU Profiler. On-device use: Developer Mode
  → Performance Trace → Power Profiler. Pick the app (Xcode/TestFlight/enterprise installs only), start and stop from a
  Control Center button, and share the trace to a Mac. On-device Time Profiler samples at a lower rate to reduce observer
  effect — [WWDC25 226](https://developer.apple.com/videos/play/wwdc2025/226)
- When comparing implementations, control thermals, device state, data volume and network, then average multiple runs. Use
  Xcode energy gauges while coding, XCTest for regressions, and Organizer/MetricKit/App Store Connect API in the field — [WWDC25 226](https://developer.apple.com/videos/play/wwdc2025/226)
- `MXCPUExceptionDiagnostic`: excessive CPU over a short period (fatal or nonfatal). Shown as "energy logs" in the Xcode
  Organizer, with CPU time, sampled time and backtraces — [Apple doc](https://developer.apple.com/documentation/metrickit/mxcpuexceptiondiagnostic.md), [WWDC20 10081 notes](https://wwdcnotes.com/documentation/wwdc20-10081-whats-new-in-metrickit/), [SwiftRocks](https://swiftrocks.com/debug-cpu-exceptions-xcode-energy-reports)
- `MXDiagnosticPayload.cpuExceptionDiagnostics` and `hangDiagnostics` (`[MXHangDiagnostic]`). Metric payloads arrive at most
  daily. Since iOS 15, diagnostics arrive immediately. Stacks are unsymbolicated and sometimes shallow — [Apple doc](https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload/hangdiagnostics.md), [Sentry](https://docs.sentry.io/platforms/apple/guides/ios/configuration/metric-kit/)
- Core Animation FPS instrument to find secondary animations holding the frame rate up — [WWDC22 10083](https://developer.apple.com/videos/play/wwdc2022/10083/)

### Inferences
- File logging: open the handle once and append through a buffered serial queue. Don't do an open/write/close or `fsync`
  per line. Don't log per frame or per progress tick. `os.Logger` defers formatting and is cheap for debug and info levels.
- A self-made "main thread stalled > 250 ms" detector needs a periodic ping. In release, it duplicates `MXHangDiagnostic` at
  a wakeup cost.

### Gaps
- No primary source quantifying file-logging vs OSLog energy cost.
- Sideloaded (non-TestFlight) builds cannot be traced by on-device Power Profiler per 226's list. Organizer energy reports
  need App Store/TestFlight distribution.
