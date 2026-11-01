# Mac Looper

A small standalone macOS guitar looper. SwiftUI interface, Core Audio device routing,
and a C render core with sample-accurate threshold capture. No DAW, plug-ins, projects,
MIDI, or software monitoring. Live guitar stays on the AM4.

## Run

```sh
./scripts/build-app.sh
open "build/Mac Looper.app"
```

Requires macOS 14 or newer and Xcode or the Swift command line tools to build. The script
uses `/Applications/Xcode.app` when available without changing the system's developer setting.
The resulting app runs independently of Xcode. Open `Package.swift` in Xcode to edit/debug;
use the packaged app for microphone permission and normal use.

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

The right rail is a separate backing-track player:

1. Click the folder button or **Open Folder…** and choose your audio folder.
2. The app recursively scans its subfolders and lists audio files under their full relative
   subdirectory headings. Files directly in the chosen folder appear under that folder's name.
   Filenames use natural sorting (Take 2 before Take 10). Search matches filenames and folder headings.
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
Scanning and native file decoding/player operations run off the UI and looper's realtime thread.

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

The 17 deterministic DSP tests cover bar math, exact threshold sample and pre-roll, attack
preservation, stereo/right-channel triggering, callback-size independence, long playback,
wrap endpoints, no live monitoring, Stop/Play/Clear/cancel, queue overflow, invalid settings,
and non-finite input, including exact capture in 32-sample blocks. Ten additional tests cover
recursive scanning, natural sorting, folder/filename search, exclusions, cancellation, native file
loading/seeking/stopping, stale selections, corrupt files, and disconnected output rejection.
The smoke test opens the selected devices for three seconds without
arming or playing audio and checks that audio callbacks advance at exactly 32 samples. It requires macOS
microphone permission. Add `--smoke-file /path/to/audio.wav` to verify simultaneous file playback at zero volume.
The current build passed 4,771 real AM4 → AM4 Proxy callbacks at 32 frames while playing a silent
WAV in the same process, plus native file play/pause/seek/resume/stop through AM4 Proxy. This checks
routing and timing; the silent diagnostic does not assess audible file quality.

Implementation: `Sources/MacLooper` contains UI/device lifecycle; `Sources/LooperCore` contains
AUHAL callbacks and DSP. Build products and SwiftPM caches are ignored. No external dependencies.

References: [Apple AUHAL routing note](https://developer.apple.com/library/archive/technotes/tn2091/)
and [AM4 owner's manual](https://www.fractalaudio.com/downloads/manuals/AM4/AM4-Owners-Manual.pdf).
