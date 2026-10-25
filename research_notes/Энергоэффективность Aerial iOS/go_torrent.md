# Battery cost of the embedded Go runtime (gomobile) and TorrServer (anacrolix/torrent) in Aerial iOS, and how to make it sleep

Scope and method: Go runtime docs and articles, plus a source read of TorrServer `MatriX.147.1` (the tag Aerial's `Packages/TorrServerKit/Package.swift` downloads) and of the tsynik/torrent fork it pins. The source was cloned and grepped on 2026-10-25. The source line numbers below refer to that tag.

**Version correction:** MatriX.147.1's `server/go.mod` says `github.com/anacrolix/torrent v1.59.1 => github.com/tsynik/torrent v1.2.34`, with Go 1.25.7, `anacrolix/dht/v2 v2.24.0` and `anacrolix/utp v0.2.0`. The brief said v1.2.31, but the tag pins **v1.2.34**. This matters because v1.2.34 added a faster DHT re-announce when the swarm is empty — [TorrServer go.mod](https://github.com/YouROK/TorrServer/blob/master/server/go.mod); [tsynik/torrent commit f5b56bf "fix: retry DHT announce sooner when swarm is empty"](https://github.com/tsynik/torrent/commits/master).

**What the app's wrapper exposes:** the TorrServerKit xcframework exports only `StartServer(port, dataDir)`, `StopServer()` and `IsRunning()`, in `server/mobile/torrserverkit/torrserverkit.go`. There is no Go-side hook for `debug.SetGCPercent`, `SetMemoryLimit` or `GOMAXPROCS`. To change runtime parameters, Aerial would have to rebuild the xcframework with `build-ios.sh` on macOS with Xcode, or the change would have to go upstream — [TorrServer repo, server/mobile/torrserverkit](https://github.com/YouROK/TorrServer/tree/master/server/mobile/torrserverkit); [build-ios.sh](https://github.com/YouROK/TorrServer/blob/master/build-ios.sh).

---

## Q1. Go runtime on iOS: what wakes the CPU, GC knobs, GOMAXPROCS, env vars, suspend and resume

### Takeaway
An idle Go runtime is quiet. Once every P (scheduler processor) is idle, sysmon sleeps for up to 1 minute or until the next timer, so idle wakeups come mostly from timers the application code creates. TorrServer creates many of these: 1-second tickers per torrent and 5-second watchdogs per cache. It also forces a full GC plus an OS memory release (`runtime.GC()` + `debug.FreeOSMemory()`) on every cache eviction while streaming. That is likely the biggest Go-side CPU cost during playback. GOGC and GOMEMLIMIT environment variables cannot be set reliably from Swift, because a c-archive starts the Go runtime from a load-time constructor, before Swift `main`.

### Cited Findings
- **sysmon backoff:** sysmon starts at a 20 µs sleep. After 50 idle iterations (about 1 ms) it doubles the sleep each time up to a 10 ms cap. It enters deep sleep only when GC has stopped the world or every P is idle. Deep sleep lasts the shorter of 1 minute ("half the force GC period") or the time until the next pending timer. In that state CPU use is "nearly zero" — [Understanding the Go Runtime: The System Monitor](https://internals-for-interns.com/posts/go-sysmon/)
- **Forced GC and polling:** sysmon wakes `forcegchelper` if no GC has run for 2 minutes. While active, sysmon does a non-blocking `netpoll(0)` every 10 ms and wakes the scavenger when the allocator flags it — [same source](https://internals-for-interns.com/posts/go-sysmon/)
- **Historical sysmon wakeups:** a 2013 Go code review described sysmon waking about 100 times per second in an otherwise idle process. That behaviour is fixed. Current runtimes use the deep-sleep logic above — [golang.org/cl/18080043](https://golang.org/cl/18080043)
- **Cost of a device wake:** Apple says every device wake has high overhead and background work should be as idle as possible. The guidance is archived but still valid — [Apple Energy Efficiency Guide for iOS Apps: Fundamental Concepts](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/FundamentalConcepts.html)
- **Library startup:** for c-archive and shared-library builds, the gc toolchain's linker registers the runtime entry as a global constructor, so the runtime initialises when the image loads — [go/src/runtime/asm_arm.s comment](https://go.dev/src/runtime/asm_arm.s). In gccgo, the equivalent `.init_array` code "starts a new thread to do the actual Go startup", and exported cgo functions wait for init to finish (`_cgo_wait_runtime_init_done`) — [gccgo go-libmain.c](https://gnu.googlesource.com/gcc/+/trunk/libgo/runtime/go-libmain.c); [go-cgo.c](https://git.embedded.cherry.de/ampere-computing/gcc.git/tree/libgo/runtime/go-cgo.c)
- **TorrServer's own runtime tweaks:** the only explicit call is `runtime.GOMAXPROCS(runtime.NumCPU())`, and it lives in `server/cmd/main.go`, the standalone binary, not the mobile kit. The mobile kit therefore runs with the Go default, where GOMAXPROCS equals the CPU count — TorrServer source, `grep SetGCPercent|SetMemoryLimit|GOMAXPROCS|GOGC` → only `cmd/main.go:65` [repo](https://github.com/YouROK/TorrServer)
- **`FreeOSMemGC()` in the cache path:** `utils.FreeOSMemGC()` is `runtime.GC(); debug.FreeOSMemory()` (`server/torr/utils/freemem.go`). In MatriX.147.1 it runs:
  - in `Cache.Close`: `cache.go:173`;
  - in `Cache.cleanPieces` on every eviction when `filled > capacity`: `cache.go:258`.
  `cleanPieces` is launched (`go p.piece.cache.cleanPieces()`) from `MemPiece.WriteAt` whenever a new piece buffer is allocated (`mempiece.go:25`) and from `ReadAt` when a piece is read to its end (`mempiece.go:54`) — [TorrServer server/torr/storage/torrstor](https://github.com/YouROK/TorrServer/tree/master/server/torr/storage/torrstor)
- **Periodic goroutines while a torrent is open:**
  - `Torrent.watch()` has a `time.NewTicker(time.Second)` per torrent, which runs `progressEvent` (speed stats, read-ahead, expiry check): `torrent.go:229`;
  - `Cache.priorityWatchdog()` runs `time.Sleep(5 * time.Second)` in a loop per cache until the cache closes: `cache.go:98–100`;
  - the trackers list refresh loop runs every 12 h (`trackersRefreshInterval = 12 * time.Hour`, `torr/utils/torrent.go:28`) — [TorrServer source](https://github.com/YouROK/TorrServer/tree/master/server/torr)
- **Suspension:** once iOS suspends an app, "no code is running", so timers do not fire. Timers are based on Mach absolute time, which stops while the CPU sleeps. Apple's advice is to invalidate timers when the app becomes eligible for suspension and re-create them when it resumes — [Apple Developer Forums: Regular heartbeat when app is in background (Quinn)](https://developer.apple.com/forums/thread/133294); [Timer issues whilst backgrounded](https://developer.apple.com/forums/thread/75468)

### Inferences
- **Idle with no torrents open:** Go threads should be parked in kevent or semaphores, with sysmon in deep sleep that is cut short only by Go timers. The dominant remaining wake sources would be inbound UDP packets to the DHT/uTP socket (see Q2) and the 2-minute forced GC, which is cheap with a small heap. This is not measured on device.
- **Streaming with a 256 MB memory cache — likely the largest Go-side CPU cost:** each eviction triggers a full collection plus `FreeOSMemory`. `FreeOSMemory` forces another GC and returns all free pages to the OS. The next piece allocation then page-faults the memory back in.
  - Piece data is `[]byte`, which is noscan, so marking is cheap. The cost sits in stop-the-world phases, the scavenge, madvise churn and page faults.
  - Eviction happens about once per newly downloaded piece once the cache is full. A 2–8 MB piece at a 5–10 MB/s download rate gives roughly 1–5 forced GCs per second.
  - A smaller cache does not reduce the frequency; it only reaches the "full" steady state sooner.
  - The fix needs a TorrServer rebuild or an upstream patch: drop `FreeOSMemGC` from `cleanPieces`, or rate-limit it, for example to at most once per 30 s.
- **GOGC, GOMEMLIMIT and GODEBUG are read during runtime init:** `schedinit`/`gcinit` read them at init. In a c-archive that runs from the load-time constructor (on another thread), so `setenv` in Swift `main` or `AerialApp.init` is too late, or at best racy.
  - The reliable routes are to add exported functions to `torrserverkit.go` (for example `SetGCPercent(int)`, `SetMemoryLimit(int64)`, `SetMaxProcs(int)`) and rebuild, or to call `debug.SetGCPercent`/`debug.SetMemoryLimit` inside `StartServer`.
  - A C `__attribute__((constructor))` in the app that calls `setenv` might run first, but Mach-O initializer order across object files is link-order dependent. This is unverified.
- **GOMAXPROCS:** with the default (CPU count, 6 on recent iPhones), work can spread across more cores, including P-cores. GOMAXPROCS=2 is a plausible energy setting for a localhost streaming server, since the work is I/O bound and hashing is limited (see Q2). It needs Instruments measurement before adoption.
- **GOGC and GOMEMLIMIT:** raising GOGC (for example 200) and setting GOMEMLIMIT just above the cache size plus about 100 MB would cut GC frequency on the non-cache heap. This only pays off once the forced `FreeOSMemGC` calls are removed, because those bypass GOGC.
- **On resume:** Go `time.Timer`s whose deadlines passed during suspension fire immediately, in a burst. TorrServer's 1 s tickers coalesce, because Ticker drops missed ticks. Suspension also affects sockets (Q4): Aerial already sees dead sockets after sleep, which is why `SIGPIPE` is ignored.

### Gaps
- **Go timer leeway on Darwin:** no source found on whether the Go runtime uses Darwin timer coalescing or leeway (kevent `NOTE_LEEWAY`, `dispatch` leeway). Inference: it does not, because Go sleeps with `pthread_cond_timedwait`/kevent timeouts. Unverified.
- **Battery measurements:** no published Instruments or Energy Log measurement of an idle Go c-archive on iOS was found. There is no golang/go issue specific to iOS battery.
- **Go clock across sleep:** whether Go's monotonic clock on Darwin (`mach_absolute_time` vs `mach_continuous_time`) counts time spent suspended was not verified. It affects whether `TorrentDisconnectTimeout` and announce timers count suspended time.
- **Tailscale:** its public engineering posts on iOS cover memory, not CPU or battery. The Network Extension budget was about 15 MB before iOS 15; the linker work to cut relocations saved about 1 MB; iOS 15 raised the limit — [Tailscale: Hey linker, can you spare a meg?](https://tailscale.com/blog/go-linker). No Tailscale post on Go timer or wakeup tuning was found.

---

## Q2. anacrolix/torrent (tsynik v1.2.34) and TorrServer: what generates network and CPU activity, and which settings and API calls quiet it

### Takeaway
While a torrent is open and has 50 or fewer known peers, the fork runs a near-continuous DHT get_peers/announce traversal and announces to **every tracker every 60 s**. The retracker list multiplies this. Once all readers close, TorrServer removes the torrent after `TorrentDisconnectTimeout`, which stops per-torrent traffic. The BitTorrent client itself, with its DHT node, listen sockets and uTP socket, stays up for the life of the process. The only API path that tears it down and rebuilds it is a settings change.

### Cited Findings
- **How TorrServer maps settings to anacrolix config** (`server/torr/btserver.go`, MatriX.147.1):
  - `NoDHT = DisableDHT`
  - `DisablePEX = DisablePEX`
  - `DisableTCP`/`DisableUTP` passed through
  - `NoDefaultPortForwarding = DisableUPNP`
  - `NoUpload = DisableUpload`
  - `EstablishedConnsPerTorrent = ConnectionsLimit`
  - `TotalHalfOpenConns = 500` (hard-coded)
  - an upload rate limit also sets `Seed = true`
  - LPD only when `EnableLPD`
  - public IPv4/IPv6 looked up with `publicip.Get4/Get6` with a 3 s timeout when not configured
  — [TorrServer btserver.go](https://github.com/YouROK/TorrServer/blob/master/server/torr/btserver.go)
- **All BTSets fields:** `CacheSize`, `ReaderReadAHead`, `PreloadCache`, `UseDisk`, `RemoveCacheOnDrop`, `ForceEncrypt`, `RetrackersMode` (0 don't add, 1 add, 2 remove, 3 replace), `TrackersListURL`, `DefaultTrackers`, `TorrentDisconnectTimeout`, `EnableDLNA`, `EnableBonjour`, `EnableIPv6`, `DisableTCP`, `DisableUTP`, `DisableUPNP`, `DisableDHT`, `DisablePEX`, `DisableUpload`, `DownloadRateLimit`, `UploadRateLimit`, `ConnectionsLimit`, `PeersListenPort`, `EnableLPD`, `ResponsiveMode`, and others — [TorrServer settings/btsets.go](https://github.com/YouROK/TorrServer/blob/master/server/settings/btsets.go)
- **BTSets defaults:**
  - `CacheSize` 64 MB
  - `PreloadCache` 50
  - `ConnectionsLimit` 25
  - `RetrackersMode` 1
  - `TorrentDisconnectTimeout` 30
  - `ReaderReadAHead` 95
  - `ResponsiveMode` true
  - **`EnableLPD` true and `EnableBonjour` true**: Aerial already turns LPD off; it should also verify Bonjour is off
  — [btsets.go](https://github.com/YouROK/TorrServer/blob/master/server/settings/btsets.go)
- **DHT announces in tsynik v1.2.34** (`torrent.go:1395–1407`):
  - `dhtAnnounceInterval = 5 * time.Minute` and `dhtAnnounceRetryInterval = 15 * time.Second`;
  - with peers, the next announce comes after 5 min;
  - without peers, the delay backs off 15 s → 30 s → 60 s → 120 s → 240 s → 300 s;
  - each `announceToDht` keeps the traversal running until it finishes or a 5-minute timer fires;
  - the loop waits on `wantPeersEvent`.
  In v1.2.31, `announceToDht` waited a flat `time.After(5 * time.Minute)` before `stop()`, then immediately re-announced while `wantPeers` held — tsynik/torrent source at tags v1.2.31 and v1.2.34 [repo](https://github.com/tsynik/torrent)
- **`wantPeers()`** is false if the torrent is closed or `t.peers.Len() > TorrentPeersLowWater`. Otherwise it is `needData() || seeding()` — [tsynik/torrent torrent.go](https://github.com/tsynik/torrent/blob/master/torrent.go)
- **Fork defaults:** `TorrentPeersLowWater` 50, `TorrentPeersHighWater` 500, `TotalHalfOpenConns` 100 (TorrServer overrides it to 500) — tsynik/torrent `config.go:168–170`
- **Upstream anacrolix defaults:**
  - `EstablishedConnsPerTorrent` 50
  - `HalfOpenConnsPerTorrent` 25
  - `KeepAliveTimeout` 1 min
  - `PieceHashersPerTorrent` 2
  - `NominalDialTimeout` 20 s
  - `DialRateLimiter` 10/s, burst 10
  - `PeriodicallyAnnounceTorrentsToDht` true
  These are not all present in the v1.2 fork — [anacrolix/torrent config.go](https://github.com/anacrolix/torrent/blob/master/config.go)
- **Tracker announces** (`tracker_scraper.go`):
  - the default or error interval is 5 min, and on success the tracker's own interval is used;
  - any interval below 1 min is floored to 1 min;
  - **when `wantPeers` is true, the interval is capped at 1 min**;
  - the announcer runs until the torrent closes;
  - one `trackerScraper` goroutine runs per announce URL, and `udp://` URLs are split into udp4 and udp6 variants
  — [tsynik/torrent tracker_scraper.go](https://github.com/tsynik/torrent/blob/master/tracker_scraper.go); [torrent.go](https://github.com/tsynik/torrent/blob/master/torrent.go)
- **Piece hashing:** `queuePieceCheck` runs `go t.verifyPiece(i)` per piece, with no global hasher limit in the fork. The comment says it "Currently doesn't really queue". `verifyPiece` serialises only per piece. The hash is SHA-1 (`crypto/sha1`) — [tsynik/torrent torrent.go](https://github.com/tsynik/torrent/blob/master/torrent.go)
- **DHT server:** in anacrolix/dht v2.24.0, `NewServer` starts only `serveUntilClosed`, the packet read loop. `TableMaintainer`, which runs every 1 min with re-bootstrap after 30 min, bucket refresh and questionable-node pings, must be called explicitly — [anacrolix/dht v2.24.0 server.go](https://github.com/anacrolix/dht/blob/v2.24.0/server.go); [dht master server.go](https://github.com/anacrolix/dht/blob/master/server.go). The tsynik fork's `NewAnacrolixDhtServer` only runs `s.Bootstrap()` once in a goroutine. It does not call `TableMaintainer` (`client.go:350–376`, grep finds no `TableMaintainer`). Token secret rotation is 5 min with `maxIntervalDelta` 2 — [dht server.go](https://github.com/anacrolix/dht/blob/master/server.go)
- **uTP library:** the fork uses `github.com/anacrolix/utp` v0.2.0, a pure-Go uTP implementation (`utp_go.go`). That repository is marked deprecated: "Use anacrolix/go-libutp instead". The README says it "opts for simplicity and reliability over strict adherence to the (poor) spec", has no MTU path discovery and uses a fixed 64-slot selective-ack window — [anacrolix/utp](https://github.com/anacrolix/utp)
- **Peer keepalives:** the connection writer sends a keepalive after `keepAliveTimeout` of write inactivity (`connection.go:635–681`) — tsynik/torrent
- **Torrent expiry** (`server/torr/torrent.go`):
  - `TorrentDisconnectTimeout` is capped at 1 min for the initial expiry in `NewTorrent`;
  - `CloseReader` and `GotInfo` push the expiry forward by the full setting;
  - the 1 s `watch()` ticker checks `expired()`, which requires no readers, `expiredTime` passed, and state `TorrentWorking` or `TorrentClosed`;
  - on expiry it calls `bt.RemoveTorrent`, which leads to `Torrent.Close()` and `Torrent.Drop()`;
  - `WaitInfo` gives up after `1 min + TorrentDisconnectTimeout`
  — [TorrServer torr/torrent.go](https://github.com/YouROK/TorrServer/blob/master/server/torr/torrent.go)
- **What can be stopped through the API:**
  - `DropTorrent(hash)` calls `bts.RemoveTorrent`. This is reachable as `POST /torrents {"action":"drop","hash":...}`; the endpoint name comes from the TorrServer web API and was not re-read here.
  - `SetSettings` and `SetDefSettings` call `dropAllTorrent()`, sleep 1 s, run `bts.Disconnect()` (closes the anacrolix client, sets it to nil, runs `FreeOSMemGC`), then `reconnect()`, retrying `Connect` up to 30 times at 1 s intervals because the uTP port is released lazily, and sleep another 1 s.
  - No "sleep" or "pause" setting exists, and no API keeps the HTTP server up with the BitTorrent client down.
  — TorrServer `server/torr/apihelper.go:242–300` [source](https://github.com/YouROK/TorrServer/blob/master/server/torr/apihelper.go)

### Inferences
- **Load per open torrent below 50 known peers:**
  - one get_peers/announce traversal in flight much of the time; in v1.2.34 it is re-run on 15 s → 5 min backoff when no peers are connected;
  - an announce to every tracker every 60 s;
  - a retracker list of 20–100 trackers means roughly 20–100 small UDP or HTTP(S) exchanges per minute, each with DNS. Every one wakes the radio (see Q3).
- **Retrackers:**
  - `RetrackersMode=0` keeps only the magnet's own trackers;
  - `RetrackersMode=2` strips the built-in retrackers;
  - Alternatively, `TrackersListURL`/`DefaultTrackers` can be trimmed to 5–10 reliable UDP trackers.
  These are the largest knobs for steady-state chatter. The cost is slower peer discovery on poorly seeded torrents.
- **DHT is the main peer source for many public torrents, so keep it on while streaming.** When nothing is playing, the client's DHT node remains a UDP endpoint that remote nodes query. Behind cellular CGNAT, inbound traffic dies once the NAT mapping expires, so idle cost is probably low on cellular but non-zero on home Wi-Fi with a public or forwarded port. With no `TableMaintainer`, the node sends nothing proactively when no torrents are open. This inference comes from the source and is not measured.
- **"Sleep mode" options with the current kit (no rebuild):**
  1. **Make sure torrents actually close.** Drop torrents explicitly (`POST /torrents` action `drop`) when the player closes and when the app enters the background, rather than relying on `TorrentDisconnectTimeout`. Aerial's commit cff2473 already closes the torrent when the player closes before video starts. This stops per-torrent DHT announces, tracker announces, keepalives, the 1 s ticker and the 5 s watchdog.
  2. **Idle toggle for DHT/uTP.** When idle, POST settings with `DisableDHT=true` and `DisableUTP=true`; this forces `Disconnect` and `Connect` and closes the DHT and uTP sockets. Restore them before the next playback. Costs:
     - about 2–3 s of blocking, plus up to 30 s of reconnect retries if the UDP port is busy;
     - DHT bootstrap starts from scratch each time, so the routing table is lost and the first peers arrive slower;
     - `SetSettings` always drops all torrents, so it is incompatible with active downloads.
  3. **`StopServer`/`StartServer` is not an option.** Aerial found it crashes, and `StopServer` only waits 5 s.
- **Streaming-time settings:**
  - `DisablePEX` makes little difference, because PEX messages ride existing TCP connections roughly once a minute.
  - `DisableUTP=true` is the strongest CPU candidate. The pure-Go deprecated uTP stack does congestion control, acks and retransmits in user space with Go timers per packet, while TCP is handled by the kernel with hardware offloads. The cost is fewer reachable peers; many peers prefer uTP, though TorrServer dials both.
  - `ConnectionsLimit` 25 is reasonable. 10–15 would cut handshakes, keepalives and request bookkeeping with little throughput loss for a single stream at film bitrates.
  - `TotalHalfOpenConns=500`, hard-coded, allows bursts of 500 outbound dials. Only a rebuild can change it.
- **Upload:** `DisableUpload=true` saves radio TX, the most expensive direction on cellular. It also makes the client a leecher that peers may choke. Keep it.
- **SHA-1 hashing:** on Apple silicon with Go's ARMv8 SHA1 assembly this is likely negligible compared with networking. No iOS-specific measurement was found.

### Gaps
- No anacrolix/torrent or TorrServer issue quantifies CPU per MB for uTP vs TCP; the search found none.
- Not verified: the exact `/torrents` action names and whether `/settings` POST requires the full BTSets object. The TorrServer web API source was not re-read.
- `peers.Len()` counts known peer addresses, not connections. The real share of streaming time with more than 50 known peers, when tracker and DHT announces slow to 5 min, was not measured.
- No source documents an official TorrServer "sleep" or "standby" mode. TorrServer Android front-ends (TorrServe, MatriX-based apps) were not examined in source.

---

## Q3. Radio energy: many small UDP packets (DHT, trackers) vs bursts; cellular vs Wi-Fi

### Takeaway
Radio energy depends mostly on how often the radio is woken, not on bytes. After each transfer the radio stays in a high-power tail for seconds; on LTE this tail is a key contributor to energy use. Per-minute tracker announces and DHT traversals are close to the worst case on cellular. Batch them, or keep them off when idle.

### Cited Findings
- **Apple's batching guidance:** fetching in small pieces keeps radios on almost continuously, so batch transactions. Apple's examples are downloading a whole video file rather than streaming it in pieces, and fetching several ads or several emails at once — [Apple Energy Guide: Defer Networking / Batch Transactions](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/DeferNetworking.html)
- **Radio tails:** radios power up for an activity and stay on afterwards in case more work arrives, so sporadic transactions have high overhead. Cellular uses significantly more energy than Wi-Fi, and weak signal or low throughput keeps radios on longer — [Apple Energy Guide: Energy and Networking](https://developer.apple.com/library/content/documentation/Performance/Conceptual/EnergyGuide-iOS/EnergyandNetworking.html); [Minimize Networking](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeNetworking.html)
- **LTE vs Wi-Fi:** LTE was found to be "as much as 23 times less power efficient compared with WiFi", and less efficient than 3G. The "long high power tail" is a key contributor — Huang et al., "A Close Examination of Performance and Power Characteristics of 4G LTE Networks", MobiSys 2012 [abstract](https://experts.umn.edu/en/publications/a-close-examination-of-performance-and-power-characteristics-of-4/)
- **RRC inactivity timer:** after a burst the UE remains in RRC_CONNECTED for a period set by the inactivity timer, "typically around 10 to 20 seconds" — [US patent 11419054, background section](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11419054)
- **Tailscale's experience with periodic packets:** a forum answer says that periodic DISCO probes, sent to all endpoints when a direct path fails, wake the radio and are "the main cause of battery use" in that situation — [Tailscale forum: Ways to minimize idle traffic](https://forum.tailscale.com/t/ways-to-minimize-idle-traffic/2188)

### Inferences
- **Worst case on cellular:** one tracker announce per minute per tracker, staggered because each `trackerScraper` has its own timer, keeps an LTE or 5G radio in RRC_CONNECTED almost permanently. A 10–20 s tail after every exchange plus announces spread across the minute adds up to the radio never sleeping. While streaming this is moot, because video data flows anyway.
- **Before and after playback:**
  - drop torrents promptly after playback ends;
  - keep the retracker list short;
  - on cellular (detect with `NWPathMonitor.isExpensive`), consider `RetrackersMode` 0 or 2 and a shorter `TorrentDisconnectTimeout`, for example 10 s instead of 30 s, so per-torrent chatter stops sooner.
- **Batching on the player side:** large preloads (Aerial's TorrServer `preload` and mpv cache) favour bursty downloads followed by idle radio, which is better than a constant trickle. This is a candidate for tuning with mpv `cache-secs`/`demuxer-max-bytes`.

### Gaps
- The often-quoted LTE tail of about 11.6 s and the per-state power figures in mW from the MobiSys 2012 power model were not verified: the full PDF could not be fetched.
- No current (2024–2026) measurements of 5G NR or iPhone-specific tail energy were found.

---

## Q4. Suspension and resume, and what other apps that embed Go or torrent engines do

### Takeaway
On iOS, embedded Go engines don't really get a choice: the process is suspended a few seconds after going to the background unless it holds a background mode, and then nothing runs. Syncthing ports such as Möbius Sync accept this and sync only in the foreground or in brief background windows. Aerial's approach of keeping the process alive with a silent audio session during downloads means the Go engine never sleeps then. That makes the per-torrent chatter above the real background cost.

### Cited Findings
- **Möbius Sync:** "No iOS app can run continuously in the background". It connects only while open, for a short time after, and when triggered to run briefly in the background — [Möbius Sync FAQ](https://mobiussync.com/faq/)
- **Möbius Sync background windows:** users report iOS-chosen background sync intervals of "typically every 5-15min". These are not configurable, and background sync sometimes stops entirely until the app is opened again — [Obsidian forum](https://forum.obsidian.md/t/sync-mac-pc-and-ios-using-syncthing-mobius-sync/72022); [Syncthing forum: Mobius Sync & Background Refresh](https://forum.syncthing.net/t/mobius-sync-background-refresh/16372)
- **Suspended apps run no code:** timers stop, and Apple advises re-creating timers after resume. The debugger masks this behaviour — [Apple Developer Forums thread 133294](https://developer.apple.com/forums/thread/133294)
- **Tailscale memory:** the iOS Network Extension memory limit (about 15 MB before iOS 15) drove linker work that saved about 1 MB. A 2020 leak was in the Swift wrapper, not the Go code — [Tailscale blog: go-linker](https://tailscale.com/blog/go-linker); [Tailscale June 2020 newsletter](https://tailscale.com/blog/2020-06-newsletter)

### Inferences
- **Sockets after suspension:** a suspended process's sockets can be reclaimed by the kernel, which leaves the listening and UDP sockets of the Go engine and the localhost HTTP server defunct on resume. That is consistent with Aerial's observed dead-socket SIGPIPE. Apple's networking-and-multitasking technote (TN2277) is the standard reference but was not re-fetched here. Without a Go-side rebind API, the only remedy is the settings-change reconnect path (`Disconnect`/`Connect`) or an app relaunch.
- **Before backgrounding:**
  - with no download, drop all torrents (stops every per-torrent timer and announce), so the suspended process is clean;
  - with a download, keep only that torrent; consider a lower `ConnectionsLimit`, since the background download is not latency-critical, and keep upload disabled.

### Gaps
- TN2277's exact wording on reclaimed or defunct sockets was not fetched in this session.
- No public engineering write-ups from Lantern, Outline or Android TorrServer front-ends about battery tuning of a Go or torrent engine were found within the search budget.
