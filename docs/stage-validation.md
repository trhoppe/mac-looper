# Stages 1–3 validation

Implementation scope: shared Mac/iPad SwiftUI workspace and portable library model;
shared loop/backing audio graph with native platform routing; native read-only
ChordPro viewer and lossless JustChords library mirror. AUv3 hosting, chart editing,
overdub, saved loop sessions and a second guitar track remain later work.

## Current build

- Mac app: `build/Mac Looper.app` (0.3.0).
- Native Xcode project: `MacLooper.xcodeproj`; shared macOS/iPad schemes.
- Original working app preserved at `build/baseline-v0.2/Mac Looper.app`.
- Separate own iCloud Drive folder `Mac Looper` created. Initial library: 38 songs,
  3 playlists, 6 tags; exact-byte copy verified. JustChords source was not changed.
- Source/library data and backing audio are not bundled or committed.

## Verification (November 1, 2026)

- Mac regression tests: **48 passed, 0 failures** (`build/ux-tests.log`).
- Physical iPad: **32 passed, 0 failures** (`build/ux-ipad-tests.log`).
- Signed native iPad app installed and launched normally on Tom’s iPad.
- Packaged Mac release build succeeded (`build/stage-mac-build.log`).
- Real library: **38 songs, 3 playlists, 6 tags**, exact JSON bytes retained.
  Original JustChords source SHA-256 still matches the supplied file. The library
  was seeded into the iPad’s private app data, never the app bundle or Git.
- AM4 → AM4 Proxy live test: **6,230 callbacks at exactly 32 frames**, concurrent
  silent backing playback (`build/ux-audio-smoke.log`). The initial Core Audio
  35 startup error cleared after the AM4 USB reconnect.
- Synthetic four-channel Mac realtime routing and shared AVAudioEngine mixing
  passed: no monitoring, exact capture, backing excluded from capture.
- iPad accepts actual device quantum; a 128-frame native Audio Unit test preserves
  exact loop length. Mac keeps strict 32 frames. Neither has a buffer selector.
- Folder restoration test verifies automatic rescan after reopening, without autoplay.
- Launch-sync test verifies source edits stay unchanged while open, then replace
  the own library copy on the next launch. No periodic/foreground sync remains.
- iPad portrait checked with the real library loaded; chart, player and looper stay
  simultaneously available. Backing selection is manual in the rail; no attachment
  controls remain in the chart.

Device tests verify native execution and deterministic audio processing. An audible
jam and AM4 routing on the physical iPad still require connecting the AM4 to it.

## iPad iCloud setup

The installed app already has the 38-song library for immediate testing. To keep
using the same iCloud copy across devices, choose **Mac Looper iCloud folder…** in
Settings and select the folder in Files. Also choose JustChords’ `library.json` as
the source for launch-time sync on that iPad. Files grants the app access through
those choices; Mac absolute paths are not reused on iPad.

## First jam check

1. Open a chord chart and choose your audio folder in the rail. The app remembers
   that folder and rescans on the next launch; it does not autoplay.
2. Select an MP3 and verify Play/Pause, seek, repeat and independent file volume.
   Browsing charts leaves the backing selection alone.
3. Audio connects automatically at launch. On Mac check AM4 inputs 1–2, AM4 Proxy
   outputs 1–2 and 32 samples in Settings. On iPad connect AM4 via USB and check
   its actual displayed buffer. Settings reconnects after changing an empty loop’s route.
4. Set BPM and 2 bars, Arm, then strum. Confirm threshold wait, exact capture and
   automatic looping, no doubled live guitar, and no backing in the guitar loop.
5. Change/seek/stop backing while the loop plays. Clear; repeat at 4/8 bars.
6. Test iPad portrait/landscape and automatic recovery after a USB reconnect.
   Retry Connection is available in Settings if a route fails to initialize.
7. Edit a test chart in JustChords. Confirm Mac Looper keeps its current version
   while open, then loads the update after quitting/relaunching. Verify that
   JustChords’ source is unchanged and the own JSON remains byte-identical.

## Startup and icon update

- App opens with no selected chart or backing file; the library and remembered
  audio folder load independently. The welcome area shows the faded app artwork.
- Audio initializes automatically without arming/capturing a loop. New available
  hardware is detected, and changing settings reconnects the empty loop route.
- Left Arrow / Backing Track → Restart Track rewinds a playing file and continues
  playback. Live hardware diagnostic verified rewind keeps playback and capture running.
- Tags selector/filter removed; stored JustChords JSON and tags are unchanged.
- Circular cyan loop icon now has sharp arrow edges and a flat no-glow finish,
  inspired by the user's AM4 icon. iPad assets have a full-bleed navy background
  and no alpha channel, verified at 152 and 1024 pixels, avoiding the white border.
- Mac foreground UI confirmed no selected song/file, restored 28-file backing folder,
  all songs present, no Tags selector, and automatic 48 kHz / 32-sample connection.
