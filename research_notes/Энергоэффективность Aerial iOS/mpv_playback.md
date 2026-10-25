# Energy-efficient video playback on iOS: libmpv (MPVKit) vs native AVPlayer

Context: Aerial today (Aerial/Player/MPVCore.swift, lines 61-74) sets `profile=fast`, `vo=gpu-next`, `gpu-api=vulkan`,
`gpu-context=moltenvk`, `hwdec=videotoolbox`, `cache=yes`, `demuxer-max-bytes=64MiB`, `demuxer-max-back-bytes=16MiB`,
`demuxer-readahead-secs=30`, `network-timeout=90`, and passes a CAMetalLayer through `wid`. No `video-sync`,
`interpolation`, `deband`, `tone-mapping`, `ao` or frame-rate options are set, so mpv defaults apply to those.

Research budget note: ~19 tool calls. Primary sources reached: mpv source/docs on GitHub (builtin.conf, vo.rst,
hwdec_vt_pl.m, PR #12776, discussion #14138), MPVKit and streamyfin/MPVKit READMEs, Apple developer forums, Firecore
forum, MacRumors. Not reached: the mpv option reference for hwdec/video-sync (the manual page is ~650 KB, only the first
100 KB was read), Apple's ProMotion article (page content did not render), VLC's GitLab (blocked by bot protection).

## 1. hwdec=videotoolbox vs videotoolbox-copy; zero-copy with MoltenVK/gpu-next; 10-bit HEVC and HDR

### Takeaway
With gpu-next over MoltenVK, `hwdec=videotoolbox` (not `-copy`) is a real zero-copy path: VideoToolbox CVPixelBuffers
are wrapped plane by plane as Metal textures via CVMetalTextureCache and imported into libplacebo, with no CPU copy in
mpv's code. `videotoolbox-copy` adds a GPU-to-RAM copy per frame and should be avoided. Aerial already uses the right
mode; HDR tone mapping cost is governed by `hdr-compute-peak` (off in `profile=fast`).

### Cited Findings
- mpv's libplacebo VideoToolbox interop (`hwdec_vt_pl.m`) calls `CVMetalTextureCacheCreateTextureFromImage` for each
  plane of the CVPixelBuffer and passes the resulting MTLTexture to libplacebo with `.import_handle = PL_HANDLE_MTL_TEX`;
  it retains the pixel buffer and shows no CPU readback or memcpy. The MTLDevice is taken from the Vulkan device via
  `vkExportMetalObjectsEXT` (VK_EXT_metal_objects) when available. Planes must be UNORM; the Metal format table includes
  `r16`/`rg16` (16-bit unorm), the likely carriers for 10-bit P010 planes (inferred by the reader, not stated in code). —
  [mpv source hwdec_vt_pl.m](https://raw.githubusercontent.com/mpv-player/mpv/master/video/out/hwdec/hwdec_vt_pl.m)
- The VT + libplacebo path was merged as PR #12776 (late 2023); it adds a `videotoolbox-pl` build option that requires
  Vulkan. Akemi (mpv dev) reported "the none-copy vt works as expected now with the macvk backend". iOS status in that
  thread was contested: rcombs said Vulkan on iOS was unsupported at the time; another user reported it working on iOS
  with `vo=gpu`/`gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk`, `hwdec=videotoolbox` (Aerial's exact combo). —
  [mpv PR #12776](https://github.com/mpv-player/mpv/pull/12776)
- Same thread: low output quality on tvOS/iOS was fixed by setting the layer's `drawableSize`, and `contentsScale` matters
  — [mpv PR #12776](https://github.com/mpv-player/mpv/pull/12776)
- `videotoolbox-copy` copies decoded video back into system RAM; native modes keep frames on the GPU with lower overhead
  but only work with compatible VOs; copy modes work with all filters/VOs at the cost of a copy. —
  [mpv manual source mirror](https://git.tjdev.de/mirror/mpv/commits/commit/73a0ea4d877daae40b671b0411fa1aeb496a0a3f/DOCS/man?page=2);
  [mintlify mpv hwdec page](https://www.mintlify.com/mpv-player/mpv/av/hardware-decoding) (third-party summary)
- mpv 0.41 made gpu-next the default VO and now prefers Vulkan hardware decoding over other APIs —
  [AlternativeTo news on mpv 0.41](https://alternativeto.net/news/2025/12/mpv-0-41-switches-to-gpu-next-by-default-improves-wayland-support-and-vulkan-decoding)
- MoltenVK does not implement Vulkan Video decode; mpv's Vulkan-video guide tells macOS users to keep using videotoolbox.
  — [mpv issue #11739 via search summary](https://github.com/mpv-player/mpv/issues/11739);
  [HN discussion](https://news.ycombinator.com/item?id=38701780)
- `profile=fast` sets `hdr-compute-peak=no` and `allow-delayed-peak-detect=yes` (i.e. disables per-frame HDR peak
  detection compute); `profile=high-quality` instead sets `hdr-peak-percentile=99.995`, `hdr-contrast-recovery=0.30`. —
  [mpv etc/builtin.conf](https://raw.githubusercontent.com/mpv-player/mpv/master/etc/builtin.conf)
- A downstream mpv fork (edde746, used by Plezy) serializes HDR10+ metadata into each sample enqueued by
  `vo_avfoundation` — i.e. HDR passthrough to the system compositor is being done on the AVFoundation path, not upstream.
  — [plezy PR #152](https://github.com/AmirulAndalib/plezy/pull/152)
- MPVKit references a `libdovi-build` project, but its README says nothing about Dolby Vision support. —
  [MPVKit README](https://github.com/mpvkit/MPVKit)

### Inferences
- Since mpv 0.41 prefers Vulkan hwdec, and MoltenVK has no Vulkan Video, `hwdec=videotoolbox` must stay explicit (it is)
  and `hwdec=auto` should not be relied on. Verify in `mpv.log` that the line "Using hardware decoding (videotoolbox)"
  appears, and check `hwdec-current` at runtime; a silent fallback to software HEVC 10-bit decode would be the single
  largest possible battery regression.
- With gpu-next, HDR10/HLG and DV profile 8 are tone-mapped by libplacebo shaders into the SDR/EDR swapchain; this is per
  pixel GPU work every frame, plus Metal translation. The AVFoundation/AVSampleBufferDisplayLayer path instead hands HDR
  to the system (EDR) compositor, which is likely cheaper. DV profile 5 (IPTPQc2) needs libplacebo/libdovi reshaping —
  only possible on the gpu-next path.
- 10-bit HEVC is VT-decoded to P010 (two 16-bit planes) — double the memory bandwidth of NV12 for each sampling pass,
  so keep the number of render passes (scalers, deband, dither) minimal for 10-bit content.

### Gaps
- No measured CPU/GPU/power numbers for videotoolbox vs videotoolbox-copy on iOS were found.
- Whether MPVKit 1.0.0's build enables `videotoolbox-pl` and VK_EXT_metal_objects was not confirmed (check `mpv.log`).
- No source found on how MPVKit/gpu-next handles Dolby Vision on iOS specifically.

## 2. VO choice on iOS: gpu-next (libplacebo/MoltenVK) vs gpu vs AVFoundation (AVSampleBufferDisplayLayer)

### Takeaway
Upstream mpv has no `vo=avfoundation`; it exists only in forks (streamyfin/MPVKit, based on mpv 0.40, GPL). That VO
renders VT frames directly into AVSampleBufferDisplayLayer, gives PiP for any container, and lets the system compositor
do scaling/HDR — the architecture closest to AVPlayer and most likely the cheapest. gpu-next is the best of the GPU
renderers but carries a full shader pipeline plus MoltenVK translation and known 120 Hz timing problems.

### Cited Findings
- mpv's upstream `vo.rst` documents `gpu-next` ("Video renderer based on libplacebo... Should generally be faster and
  higher quality" than `gpu`) and has no `avfoundation` VO. —
  [mpv DOCS/man/vo.rst](https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/vo.rst)
- streamyfin/MPVKit: "a fork of MPVKit with AVFoundation video output (`vo_avfoundation`) support for iOS"; "Renders video
  directly to AVSampleBufferDisplayLayer"; "Enables Picture-in-Picture (PiP) support on iOS"; "Uses hardware-accelerated
  VideoToolbox decoding"; "Supports composite OSD for subtitle rendering in PiP". mpv v0.40.0, FFmpeg n8.0, tag
  `0.40.0-av`; license GPL v3.0 (includes GPL components such as samba). —
  [streamyfin/MPVKit](https://github.com/streamyfin/MPVKit)
- Known issues in that VO: only one of `sid`/`secondary-sid` shown until a fix compositing all OSD objects into one
  overlay — [streamyfin/MPVKit PR #4](https://github.com/streamyfin/MPVKit/pull/4); a crash on leaving the player
  because mpv holds the display layer only as a raw pointer (fix: keep layer alive until mpv teardown) —
  [streamyfin PR #2139](https://github.com/streamyfin/streamyfin/pull/2139); Catalyst build needs UIKit include path —
  [streamyfin/MPVKit PR #2](https://github.com/streamyfin/MPVKit/pull/2). Other apps (Pleya, Argus, Plezy) ship on this
  fork. — [pleya PR #185](https://github.com/michelknoop21/pleya/pull/185)
- Upstream MPVKit README: Metal support is "not officially supported", the project is "only suitable for learning
  libmpv", "will not be maintained too frequently", and it points to "AetherEngine" for production use. Default license
  LGPL-3.0; `-GPL` binaries make it GPL-3.0. — [mpvkit/MPVKit](https://github.com/mpvkit/MPVKit)
- Akemi (mpv) on MoltenVK: MoltenVK is the Vulkan driver of the gpu/gpu-next "macvk" backend; open problems include
  flicker/black screens from a MoltenVK 1x1 drawable workaround, "rendering timing on displays at 120Hz or higher is
  unstable" with vsync jitter causing mistimed/dropped frames, a crash with colour-space hinting only on MoltenVK, and
  still working out how to get direct rather than composited rendering. —
  [mpv discussion #14138](https://github.com/mpv-player/mpv/discussions/14138)
- Apple DTS: "AVSampleBufferDisplayLayer will leverage the GPU and like Core Image may optimize behavior dynamically based
  on the underlying hardware and operating system"; CAMetalLayer cannot be used in PiP; asker measured no CPU difference
  between the two. — [Apple Developer Forums 756206](https://developer.apple.com/forums/thread/756206)
- Chromium (2016) found enqueuing frames into AVSampleBufferDisplayLayer more power efficient than setting layer contents
  directly; WebKit changed MSE painting to `copyDisplayedPixelBuffer` because the old path caused "significantly
  increased power use". — [Chromium review 1828523003](https://codereview.chromium.org/1828523003);
  [WebKit commit](https://webkit.googlesource.com/WebKit/+/9d6ba2cf6c064d9cb1890583985a07452f7befa6)
- Since iOS 17 Apple discourages `AVSampleBufferDisplayLayer.enqueue(_:)` in favour of `sampleBufferRenderer.enqueue`;
  a failed layer cannot be reused and must be replaced. —
  [Apple docs: AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer.md);
  [enqueue(_:)](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:).md)
- VLC has a merge request titled "vout: new native display renderer for Apple platforms" (content not readable). —
  [VLC MR 3436](https://code.videolan.org/videolan/vlc/-/merge_requests/3436)

### Inferences
- Cost ranking (most → least power), reasoned not measured: `vo=gpu` (OpenGL-era shaders via Vulkan/MoltenVK) ≥
  `vo=gpu-next` with high-quality settings > `vo=gpu-next` + `profile=fast` > `vo_avfoundation` (VT frame → AVSBDL →
  system compositor, likely eligible for hardware overlay/direct scan-out) ≈ AVPlayer.
- `vo_avfoundation` would also remove Aerial's separate AVPlayer-based PiP (MP4-only) and the post-rotation MoltenVK
  reconfigure hack, but it is GPL (Aerial uses the LGPL build), based on mpv 0.40, and loses libplacebo features
  (shader tone mapping, DV profile 5, deband). Subtitles must be composited by mpv as an overlay.
- If staying on gpu-next: set the CAMetalLayer `drawableSize` to the screen's pixel size (not larger), keep
  `contentsScale` = screen scale, and keep the layer opaque so the compositor does not blend it.

### Gaps
- No published power comparison between gpu-next/MoltenVK and AVSampleBufferDisplayLayer on iOS.
- "AetherEngine" recommended by MPVKit was not investigated.
- Quantified MoltenVK translation overhead for mpv's workload: none found.

## 3. Display sync and refresh rate (video-sync, interpolation, ProMotion)

### Takeaway
Keep mpv's default `video-sync=audio` and `interpolation=no` (both are the defaults; `display-resample` + interpolation
is the "reduce-judder" quality preset that adds per-vsync rendering). On ProMotion, the key battery lever is letting the
panel drop to the content rate (24/25/30 → 48/50/60 Hz class) instead of presenting at 120 Hz; mpv over MoltenVK has
known unstable timing at ≥120 Hz.

### Cited Findings
- mpv's manual example `[reduce-judder]` profile = `video-sync=display-resample` + `interpolation=yes` (opt-in, not
  default). — [mpv manual](https://mpv.io/manual/stable/)
- mpv's builtin `[low-latency]` profile notes `video-sync=audio  # DS currently requires reading ahead a frame` and
  `interpolation=no  # requires reference frames (more buffering)`. —
  [mpv etc/builtin.conf](https://raw.githubusercontent.com/mpv-player/mpv/master/etc/builtin.conf)
- Rendering timing on ≥120 Hz displays is unstable on the MoltenVK backend (vsync jitter, mistimed/dropped frames). —
  [mpv discussion #14138](https://github.com/mpv-player/mpv/discussions/14138)

### Inferences
- `display-resample` makes mpv render/present on every display vsync (so at 120 Hz it may redraw each frame 5×), and
  `interpolation=yes` adds a blending pass each vsync — both multiply GPU work. With `video-sync=audio` mpv presents only
  when a new video frame is due.
- iPhone apps are capped at 60 Hz for CAMetalLayer/CADisplayLink unless Info.plist sets
  `CADisableMinimumFrameDurationOnPhone=YES` (general Apple knowledge; Apple's article could not be fetched). Do not set
  that key in Aerial. AVPlayer/AVSampleBufferDisplayLayer content gets automatic panel frame-rate matching; for a
  CAMetalLayer the system only knows the cadence of `present` calls, so presenting at exactly the content rate lets
  ProMotion drop the refresh rate. MoltenVK exposes `presentDrawable` timing only indirectly (vulkan swap mode FIFO).
- Possible levers to test: `swapchain-depth=1`/`2`, `vulkan-swap-mode=fifo` (default) vs `mailbox` (mailbox may render
  extra frames — avoid), and verifying via Metal HUD (`MTL_HUD_ENABLED=1`) or Instruments Display/Core Animation FPS
  what refresh the panel actually runs at during playback.

### Gaps
- Apple's ProMotion guidance page did not render; exact wording on frame-rate matching for video was not retrieved.
- No measurements of 120 Hz vs content-rate presentation power for video on A17 Pro.

## 4. Scaler and shader settings (scale, deband, dither, profile=fast)

### Takeaway
`profile=fast` is the cheapest gpu-next configuration and Aerial already uses it. It sets bilinear scaling, no dither,
no linear/sigmoid scaling passes, and no HDR peak detection. Deband is off by default; keep it off.

### Cited Findings
- `[fast]` profile: `scale=bilinear`, `dscale=bilinear`, `dither=no`, `correct-downscaling=no`,
  `linear-downscaling=no`, `sigmoid-upscaling=no`, `hdr-compute-peak=no`, `allow-delayed-peak-detect=yes`. —
  [mpv etc/builtin.conf](https://raw.githubusercontent.com/mpv-player/mpv/master/etc/builtin.conf)
- `[high-quality]`: `scale=ewa_lanczossharp`, `scale-antiring=0.6`, `hdr-peak-percentile=99.995`,
  `hdr-contrast-recovery=0.30`. — [mpv etc/builtin.conf](https://raw.githubusercontent.com/mpv-player/mpv/master/etc/builtin.conf)
- Deband is a toggle (`b` key), off by default; gpu-next rendering tasks listed by Akemi: scaling, HDR tone mapping,
  colour management, dithering, interpolation, debanding, custom shaders. —
  [mpv manual](https://mpv.io/manual/stable/); [mpv discussion #14138](https://github.com/mpv-player/mpv/discussions/14138)

### Inferences
- `ewa_lanczos*` is a polar (2-D) filter sampling many taps per output pixel — far costlier than bilinear; on a ~460 ppi
  phone screen the visual gain is negligible. Downscaling 4K → ~2556×1179 with bilinear may alias slightly;
  `dscale=mitchell` (separable) is a cheap compromise if needed.
- Additional candidates to evaluate: `deband=no` (explicit), `icc-profile-auto=no`, `target-colorspace-hint=no`
  (colour-space hinting is the area where MoltenVK crashed), `gpu-shader-cache` on for faster start (less shader
  compile CPU on each launch).

### Gaps
- No GPU-time measurements for these scalers on Apple GPUs found.

## 5. Demuxer/cache settings and audio output

### Takeaway
For battery, reading in larger, rarer bursts is better than a constant trickle; the network here is a local loopback
to TorrServer, so the costs are CPU wakeups in mpv's demuxer thread and in TorrServer, not radio. mpv documents a
`[big-cache]` example (512 MiB / 20 s readahead) and a `[low-latency]` profile (the opposite of what is wanted).
Audio output choice (audiounit vs avfoundation) matters more for correctness than power.

### Cited Findings
- mpv manual example `[big-cache]`: `cache=yes`, `demuxer-max-bytes=512MiB`, `demuxer-readahead-secs=20`. —
  [mpv manual](https://mpv.io/manual/stable/)
- `[low-latency]` profile sets `audio-buffer=0`, `vd-lavc-threads=1`, `cache-pause=no`, `stream-buffer-size=4k` etc.
  (minimal buffering — opposite of a battery profile). —
  [mpv etc/builtin.conf](https://raw.githubusercontent.com/mpv-player/mpv/master/etc/builtin.conf)
- Aerial's own perf.log finding (24 Oct): 150+50 MB mpv cache on top of TorrServer's 256 MB pushed memory to ~650 MB;
  reduced to 64+16 MiB. — Aerial/Player/MPVCore.swift comment (lines 67-71)
- An upstream PR fixes a misuse of the AudioUnit channel-map API in `ao_coreaudio` that breaks CoreAudio on macOS 27
  and makes mpv fall back to the avfoundation AO. — [mpv PR #18637](https://github.com/mpv-player/mpv/pull/18637)
- mpv issue: the AVFoundation AO causes video frame drops when resuming from an underrun. —
  [mpv issue #16346](https://github.com/mpv-player/mpv/issues/16346)
- Some downstream apps default mpv to `ao=avfoundation` on macOS. —
  [Argus PR #79](https://github.com/archiboltmusk/Argus/pull/79)

### Inferences
- `demuxer-readahead-secs=30` with `demuxer-max-bytes=64MiB`: for a 4K HEVC remux at ~60-80 Mbit/s, 64 MiB is only
  ~7-9 s, so the byte cap — not the 30 s — governs, and mpv will refill in small steps continuously. Hysteresis
  (`demuxer-hysteresis-secs`, e.g. 10-20) makes mpv stop reading until the buffer drains by that amount, then read in a
  burst — fewer wakeups for both mpv and TorrServer. Worth testing with `demuxer-hysteresis-secs=15`.
- Since TorrServer already caches 256 MB in-process, double buffering is the memory cost; a moderate mpv buffer plus
  hysteresis is the battery-friendly middle ground.
- Keep `ao=audiounit` (the iOS default) unless problems appear; the cost difference between AOs is not documented.
  A larger `audio-buffer` (e.g. 0.5-1 s) reduces audio callback wakeups slightly.
- Default `vd-lavc-threads` matters only for software decode; with VT it is irrelevant. Make sure subtitle rendering
  (libass) does not force per-frame OSD redraws when no subtitle is visible (mpv only redraws OSD on change).

### Gaps
- mpv's option text for `demuxer-hysteresis-secs`, `cache-secs` and `audio-buffer` was not fetched (manual too long).
- No measurements of wakeups/energy vs cache size for mpv on iOS.

## 6. Measured comparisons: mpv/VLC/Infuse vs AVPlayer; how efficient players do it

### Takeaway
No modern, controlled battery comparison of mpv-based players vs AVPlayer on recent iPhones was found. Historic data
(2013-2018) shows software decode (old VLC) costing ~3× AVPlayer, and Infuse costing up to 2× the native player on
x265/MKV before optimisations. Firecore claims Infuse with HW decoding is close to the native player. The efficient
players converge on VideoToolbox decode + AVSampleBufferDisplayLayer presentation.

### Cited Findings
- Firecore staff: Infuse uses native HW decoding, "so battery life will be very similar to what you see in the standard
  iOS video player". — [Firecore forum: Battery life](https://community.firecore.com/t/battery-life/11461)
- iPhone 7 user (2018): 7-8 h playback in Photos/Safari/iTunes vs about half in Infuse for x265; staff said an update
  added "playback optimizations". —
  [Firecore: HEVC/x265 drains battery](https://community.firecore.com/t/hevc-x265-mkv-and-mp4-drains-battery-immensely/16368)
- iPhone 6S (no full HW HEVC path in apps then): Infuse −27% in 17 min vs CnX Player −1%, ABC Player −7% for the same
  HEVC file; another tester: CnX −5%, Infuse −12% on 20 min. —
  [Firecore: HEVC performance iPhone 6S](https://community.firecore.com/t/infuse-hevc-decoding-performance-and-battery-life-iphone-6s/13243)
- Older MacRumors benchmark (iPhone 5, iOS 6 era, minimal brightness): AVPlayer 13% vs HD Player Pro 12%; VLC 2.1.3
  about 3× AVPlayer battery; the author cautions real-life differences are smaller. —
  [MacRumors benchmarks](https://forums.macrumors.com/threads/new-benchmarks-of-the-most-recommended-mkv-players.1679716/)
- Infuse "requires a lot of power" threads and a report that drain on iPad came from background syncing, not playback. —
  [Firecore: HW acceleration](https://community.firecore.com/t/hardware-acceleration-implementation-infuse-seems-to-require-a-lot-of-power/9795);
  [Firecore: iPad Air](https://community.firecore.com/t/infuse-uses-too-much-battery-power-on-my-ipad-air/29295)
- VLC on macOS: 27% CPU and energy impact 43 vs much lower for QuickTime on the same video. —
  [VLC issue 17664](https://code.videolan.org/videolan/vlc/-/issues/17664)
- Streamyfin (Jellyfin client) ships "MPV Player with hardware decoding and PiP" via the vo_avfoundation fork. —
  [Streamyfin App Store](https://apps.apple.com/gb/app/streamyfin/id6593660679);
  [streamyfin/MPVKit](https://github.com/streamyfin/MPVKit)

### Inferences
- The decisive factors for battery, in order: (1) HW decode actually engaged (VT) vs software; (2) presentation path
  (system compositor/AVSBDL vs a full GPU render pipeline every frame); (3) display refresh rate and brightness;
  (4) background work during playback (Aerial: TorrServer peers/hashing, perf sampling, UI timers, party sync).
- For Aerial, a fair A/B: same file, brightness fixed, airplane mode + local file, 30 min each, compare
  `UIDevice.batteryLevel` deltas or MetricKit `MXCPUMetric`/`MXGPUMetric`/`MXDisplayMetric` — Aerial's PerfMonitor
  already logs CPU, thermal and battery per hour, so variants (gpu-next fast vs AVPlayer PiP path for MP4) can be compared.

### Gaps
- No recent (iOS 17-27, A15+) measurements of Infuse, VLC 3.x/4.x, mpv-based apps vs AVPlayer.
- How Infuse renders (Metal vs AVSampleBufferDisplayLayer) is not publicly documented in sources found.
- VLC's Apple native display renderer MR content could not be read (bot protection).
