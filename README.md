# Mac Looper

A native Mac and iPad guitar-jamming app. Chord charts and backing playback share
one SwiftUI workspace, with the guitar looper always visible along the bottom.
A shared C render core provides sample-accurate threshold capture. Live guitar
monitoring stays on the AM4. No DAW, projects, MIDI, or plug-in setup is required.

## Run

```sh
./scripts/build-app.sh
open "build/Mac Looper.app"
```

Requires macOS 14 or newer and Xcode or the Swift command line tools to build. The script
uses `/Applications/Xcode.app` when available without changing the system's developer setting.
The resulting app runs independently of Xcode. Open `MacLooper.xcodeproj` for native Mac/iPad targets, or `Package.swift` for
shared-code development. Use the packaged Mac app for normal use.

### iPad

Requires iPadOS 18 or newer. Open `MacLooper.xcodeproj`, select **MacLooper-iPad**,
and choose your iPad as the destination. In Xcode Settings → Accounts, sign in to
your Apple Account; select your development team under Signing & Capabilities if
needed. Unlock the connected iPad and press Run. The iPad app uses the distinct
`com.thoppe.maclooper` identifier; it does not replace AM4 Remote.

`./scripts/build-ipad.sh` builds a signed device app after account setup. Simulator
testing does not require signing. Select the iPad scheme and an iPad simulator,
then Product → Test.

The iPad uses the connected USB interface and iPadOS audio routing. **AM4 Proxy is
a Mac driver, not an iPad output choice.** The default capture choice requires a USB
input rather than silently using the iPad microphone. The app requests and verifies
32 samples for loop capture. iPadOS can choose a larger quantum; the app accepts
that actual buffer and shows the render size in the header and Audio Settings.
There is no buffer selector. The Mac retains its strict 32-sample requirement.

## Chord charts and iCloud library

Mac Looper reads JustChords’ `library.json`, including songs, playlist/folder order,
tags, saved key/transpose and capo settings. The native read-only ChordPro viewer
shows chords over lyrics, section headings, comments and tablature. Text size is
adjustable. Chart editing and AUv3 hosting are future stages.

On this Mac, defaults are:

- **Source:** iCloud Drive → JustChords → `library.json` (read-only).
- **Own library:** iCloud Drive → **Mac Looper** → `library.json`.

At launch, the app checks the source once. It does not poll while open or sync when
returning to the foreground. Choosing a new source or library folder in Settings
loads that explicit choice immediately. A complete valid source replaces the own copy atomically. A failed
or incomplete update keeps the last good library and reports the problem. The JSON
copy retains the **exact source bytes**, including unknown fields, IDs, trash and
JustChords settings. Viewing never rewrites the JustChords file. This preserves the
format for a future return to JustChords; no two-way editing is implemented yet.

On iPad, open Settings in Mac Looper, choose **Mac Looper iCloud folder…**, and select
the same folder in Files. For launch-time sync from JustChords, also choose its
`library.json` as the source. These choices persist across launches. Without those
choices the iPad uses its own local Documents/Library folder. No private user JSON
or backing audio is included in the app bundle or Git repository.

Use **Songs** to choose a playlist or tag, search titles/artists, and select a chart.
The backing player stays available beside/below it, and the looper stays at the
bottom. Selecting a song leaves backing-track selection and playback alone. Its BPM
is adopted only while the loop is empty; an existing loop’s timing remains fixed.

Select backing audio manually in the right rail. Chart browsing and backing-track
selection are independent; there are no attachment controls in the chart.

## Jam

1. Connect the AM4. Input defaults to **AM4**, capture **Inputs 1–2** (processed stereo guitar),
   and output defaults to **AM4 Proxy**, playback **outputs 1–2**. Neither default falls back
   to the built-in microphone or speakers if unavailable. Other devices can be selected.
2. Click the **gear** in the top corner to change input, output, or capture channels.
   The audio buffer is fixed at **32 samples**.
3. Set BPM (30–240) and **2, 4, or 8 bars**. V1 uses **4/4**.
4. Click **Start Audio** in the gear popover to enable the input meter. Allow microphone access when macOS asks;
   macOS requires this for USB audio input too. There is no software input monitoring.
5. Adjust the strum threshold with the slider or type a value in the dB field (−72 to 0 dBFS).
   The orange line shows the threshold over the input meter. Put it above idle guitar noise
   and below your normal strum. You can adjust the threshold while armed.
6. Click **Arm** (or **R**). The first sample at or above the threshold on either input channel
   starts capture. It records the calculated length and automatically loops it.
7. **Space** stops/restarts a completed loop. Stopping while waiting or recording cancels the take.
   **Clear** (Delete) discards the loop and unlocks BPM/length. Stop Audio releases the devices
   and discards the loop. Closing the app also releases its audio route.

The wider volume slider changes **loop playback only**. Type a percentage beside its speaker icon
for an exact setting. The AM4 handles live guitar monitoring. Captured loops stay in memory;
there are no saved sessions. Overdub is deferred to a later version.

Set your separate drum app to the same BPM and output device. Mac Looper captures only
its selected hardware input channels; it has no system-audio capture or output-to-input
connection. The external routing/preset must likewise keep drum playback out of the selected
AM4 USB input channels. There is no transport sync; start the strum where you want the loop
in relation to the drums. Independent app clocks may drift over a long session.

## Audio-file player

The right rail (or compact player beneath the chart on a narrower iPad) plays backing audio:

1. Click the folder button or **Open Folder…** and choose your audio folder.
2. The app recursively scans its subfolders and lists audio files under their full relative
   subdirectory headings. Files directly in the chosen folder appear under that folder's name.
   Filenames use natural sorting (Take 2 before Take 10). Search matches filenames and folder headings.
   The last selected folder is remembered and automatically rescanned after reopening the app;
   security-scoped access is retained on both platforms. Playback does not start automatically.
3. Select a file to load it in the bottom-right player. Selecting does **not** autoplay.
4. Use Play/Pause, Stop, the seek bar, previous/next file, repeat-one, and the file player's own volume.
   Previous/next selects the adjacent file in the complete folder listing without autoplay.

File playback uses the selected output (normally **AM4 Proxy**), even with loop audio stopped.
It has no input connection and is never mixed into loop capture. Output changes pause the file;
Play resumes on the newly selected device. Closing the app stops both players. Opening a different
folder clears the previous file selection. Hidden folders, packages, and symlinks are skipped;
unreadable folders are reported without blocking the scan.

Common audio formats are discovered by file extension and macOS audio types. Native macOS decoding
handles playback; a listed format that needs an unavailable codec reports an error when selected.
Scanning and file decoding run off the UI and looper’s realtime thread. Playback
shares one AVAudioEngine mixer with guitar-loop playback. Guitar capture is
upstream of this mixer, so neither backing audio nor future instrument buses enter
the loop. Mono or non-48 kHz backing files are decoded in bounded buffers into an
OS-purgeable local stereo/48 kHz cache, preserving the original file and avoiding a
live graph reconnect when switching file formats.

## Timing and audio path

- Loop frames = `round(sampleRate × 60 / BPM × 4 × bars)`. No timer or UI update determines
  the trigger, end of recording, or playback wrap. Non-integral durations round to the nearest
  sample (maximum error half a sample). Timing is fixed until Clear.
- The render core retains **5 ms of pre-roll** so the strum attack is inside the loop, rather
  than right on its edge. The pre-roll counts toward the exact loop length, so capture ends
  5 ms earlier than a full loop duration after the threshold crossing. Missing startup history
  is zero-padded. Playback begins on the next sample after capture finishes.
- **2 ms raised-cosine boundary fades** suppress endpoint clicks without shortening the period.
  This is a small volume dip at the seam, not a tempo-changing overlap. It cannot make an
  arbitrary sustained note musically seamless. Stop/Clear have a 3 ms release tail.
- Only previously captured loop samples go to playback. Live input is never mixed to output,
  including while armed or recording. Non-selected output channels are silent.
- One AUHAL runs duplex. When input/output are different devices, the app creates a temporary
  **private aggregate**, clocks it from the output device, and enables Core Audio drift
  compensation for the input. Actual subdevice order determines channel offsets. The aggregate
  is destroyed on stop/error/exit. System default devices are untouched.
- At startup, the app requests **32 frames** on input, output, and the private aggregate route,
  verifies the accepted values, and checks the actual render callback size. It reports a failure
  instead of silently using a larger buffer. At 48 kHz, 32 frames is about 0.67 ms per audio quantum;
  USB transport, device safety buffers, conversion, and the proxy can add latency beyond that.
  The larger preallocated AUHAL capacity is a safety limit, not the I/O buffer setting.
- V1 requires matching nominal sample rates on both devices (AM4 and AM4 Proxy are 48 kHz).
  Use Audio MIDI Setup if other devices differ. Bluetooth/virtual-driver behavior depends on
  the driver; errors are surfaced instead of silently switching hardware.
- Buffers are preallocated before starting. The C render callback does no allocation, locking,
  dispatch, logging, file I/O, or Swift/Objective-C object work. UI commands use a bounded SPSC
  queue; controls and telemetry use lock-free atomics. The UI reads atomic waveform peaks,
  never concurrently reads/writes the audio buffers. UI polling is only for display/health checks.
- Disconnects, sample-rate changes, input-render errors, and stalled callbacks stop audio and
  report a recoverable error. Reconnect and Start Audio again; old loops are discarded.

## Tests and diagnostics

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
"build/Mac Looper.app/Contents/MacOS/MacLooper" --devices
"build/Mac Looper.app/Contents/MacOS/MacLooper" --smoke-test
```

The regression suite covers exact threshold capture, pre-roll, loop duration and
wraps, no monitoring, controls and queue bounds, 32-frame quanta, the native loop
Audio Unit, four-channel manual realtime routing, and backing/capture separation
in a real AVAudioEngine graph. Additional tests cover folder scanning/search,
file transport, stale selections, disconnected outputs, rate/channel conversion,
ChordPro rendering data, lossless JSON, malformed updates and portable backing links.
Tests use synthetic chart fixtures; your private library is not committed.

The smoke diagnostic opens the selected Mac devices for three seconds without
arming a loop and checks actual callbacks. It needs microphone permission and
working hardware. Add `--smoke-file /path/to/audio.wav` to check simultaneous file
playback at zero volume. `--smoke-direct` temporarily tests direct AM4 output and
restores the saved output preference afterward. `--library-check /path/library.json`
validates all songs and exact JSON preservation without printing chart contents.
Hardware checks can fail independently of the deterministic tests; see
[stage validation](docs/stage-validation.md) for this build’s actual results.

Implementation: `Sources/JamCore` owns portable library/ChordPro logic;
`Sources/LooperCore` owns sample-accurate C DSP and the Mac AUHAL adapter;
`Sources/LooperAudioUnit` hosts that DSP in a shared Audio Unit;
`Sources/MacLooper` owns shared SwiftUI, playback and platform routing. The Mac
adapter drives AVAudioEngine manual realtime rendering through the established
AUHAL route; iPad uses AVAudioSession and native AVAudioEngine I/O. Build products,
private libraries, signing files and caches are ignored. No external dependencies.

References: [Apple AUHAL routing note](https://developer.apple.com/library/archive/technotes/tn2091/)
and [AM4 owner's manual](https://www.fractalaudio.com/downloads/manuals/AM4/AM4-Owners-Manual.pdf).
