# Mac Jams

A native Mac and iPad guitar-jamming app. Chord charts and backing playback share
one SwiftUI workspace. A full-app AM4 Remote controls the connected amp over USB MIDI. Header controls show or hide Songs, Chords, Looper, Drummer and
Player; the chart expands into the available space.
A shared C render core provides sample-accurate threshold capture. Live guitar
monitoring stays on the AM4. No DAW or recording projects are required; optional
drums use the installed Pop Drummer AUv3 instrument.

## Run

```sh
./scripts/build-app.sh
open "build/Mac Jams.app"
```

Requires macOS 14 or newer and Xcode or the Swift command line tools to build. The script
uses `/Applications/Xcode.app` when available without changing the system's developer setting.
The resulting app runs independently of Xcode. The script replaces the executable
atomically, avoiding an in-place overwrite of a running app; relaunch to use a new build. Open `MacLooper.xcodeproj` for native Mac/iPad targets, or `Package.swift` for
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
that actual buffer and shows the render size in Audio Settings.
There is no buffer selector. The Mac retains its strict 32-sample requirement.

## Chord charts, editing and iCloud library

Mac Jams owns its `library.json`, with each song's **ChordPro text as the source
of truth**. Title, artist, key, BPM, time signature, duration and capo live in
standard directives in `rawData`. The old JSON fields are maintained as
compatibility copies. **JustChords syncing is disabled**, including the
old launch-time import. Existing source bookmarks are ignored and removed; the
original JustChords library is never written. The existing own library remains
in **iCloud Drive → Mac Looper → library.json**, preserving access and data through
the app rename. On iPad, choose that same folder under **Settings → Choose library
folder…**. An iPad without a shared-folder choice uses its local Documents/Library.

The first open converts existing songs once: missing ChordPro headers are filled
from their existing details, plain section headings become labeled environments,
and unmarked tabs receive explicit tab boundaries. Existing directives win over
old JSON copies. Chords/lyrics/tab rows, IDs, playlist settings, saved transposes
and unknown data are retained. An exact `library-before-chordpro-…json` backup is
written beside the library under **Library Backups** before replacement. A
per-song `macJamsChordProVersion` marker makes later launches leave converted
source alone. Failed conversion never replaces the working file.

The own library loads at launch and when returning to the foreground, except
while editing. Each save coordinates access to the current iCloud file, reads its
latest version and patches only changed fields on the selected library song.
Other songs, playlists, tags, IDs, unknown data and settings are retained. A
concurrent change to the same edited field keeps your draft open and reports a
conflict instead of overwriting it. A missing own file does not fall back to
importing JustChords again. Choose the existing own folder in Settings.

With a chart selected, click **Edit** below the font controls. The editor fills
**the entire app workspace**, with no dimmed border, on Mac and iPad. Edit:

- Song name and artist.
- Song key (for example C, F# or Am), BPM and time signature.
- Song length in minutes:seconds or seconds, stored as `{duration: ...}`.
- Raw ChordPro: type `[C]` before a word to place its chord above that word in
  reading mode. Type tabs as plain text; spaces and line breaks are preserved.

The detail fields and raw text edit the same ChordPro header. Changing BPM writes
`{tempo: ...}` immediately; editing that directive updates the BPM field.
The preamble supplies song-level details; later key/tempo/meter/capo directives
remain local chart instructions and do not operate audio transport. The selected
song's initial ChordPro BPM still updates the empty looper.

The monospaced native editor highlights chord brackets in cyan and headings in
gray. Smart quotes/dashes, spelling corrections and automatic replacements are
disabled for source text. Native undo works. The app's single-key looper/backing
shortcuts are disabled while editing so letters, spaces, arrows and Delete edit
text without operating the jam controls. Playing audio continues independently.

**Save** (Command-S on Mac) commits changes and immediately refreshes the chart,
song list and editable looper BPM. **Cancel** leaves the stored song unchanged;
a changed draft asks before discarding. Before each changed save, the complete
previous file is kept in **Library Backups** beside `library.json`. Drafts stay in
memory until Save; there is no automatic draft recovery. No-op saves do not
rewrite the JSON or create a backup.

The storage structure remains compatible with the imported JustChords format.
After the one-time conversion, viewing retains exact file bytes. Explicit saves reformat the JSON while retaining
unrelated values, unknown fields, trash and playlist membership/settings. The
editor changes the library song; playlist-specific overrides remain intact.
Changing Song key updates its ChordPro directive and compatibility copy, and clears an old display transpose;
it does not rewrite the chord symbols in the source. Song time signature and
length are metadata; live loop timing still uses 4/4.

The read view shows chords over lyrics, bold light-gray section headings, comments
and tablature. **A− / A+** controls adjust text from 12–36 points; spacing changes
immediately with the font size. The text-column icon switches one/paired-column
preference and remembers it. When space allows, paired lines read left-to-right
across each row, then down; headings and tabs span the full chart. Narrow space
falls back to one column. Raw tab rows stay grouped and monospaced. Adjacent
chord-only fragments have visible spacing without changing source content.

ChordPro support includes standard section labels, chorus recall, annotations,
literal tab blocks, comment styles and metadata directives. Some advanced
ChordPro 6 features are not yet rendered; the chart reports unsupported features
and keeps their source. See the [compatibility matrix](docs/chordpro-compatibility.md)
for the exact supported subset and remaining features.

Your song `library.json` and backing audio are never included in the app bundle or Git.
AM4 Remote retains its existing bundled offline amp/effect libraries.

Use **Songs** to choose a playlist and select a chart. Click its magnifying glass
to reveal title/artist search. The adjacent sort dropdown offers **Song name**
and **Artist name**, remembers the last choice, and works with search and playlist
filtering. The file-search icon sits beside the folder button.
The app opens with no chart selected and a faded logo; choose a song when ready.
The **Songs / Chords / Looper / Drummer / Player** header buttons toggle their panels.
Visibility is remembered; hiding a panel keeps its audio playing. The chart widens
when Player is hidden; Looper or Drummer fills the footer when the other is hidden.
Hiding both removes the footer. Hide Songs, Player, Looper and Drummer to let
Chords fill the workspace. Chords can also be hidden for a clean Looper/Drummer
or Player-only workspace; selecting a song automatically reveals Chords again,
including reselecting the same song. Header buttons and song/audio rows lighten subtly on hover.
The **Ready** indicator beside Settings summarizes connection readiness; output
device, sample rate and buffer details appear in Settings.

Selecting a song leaves backing-track selection and playback alone. Its BPM
is adopted only while the loop is empty; an existing loop’s timing remains fixed.

Select backing audio manually in the right rail. Chart browsing and backing-track
selection are independent; there are no attachment controls in the chart.

## AM4 Remote

Click **AM4 Remote** in the header to cover the entire app with the integrated
remote. **Close** in the upper right returns to the same jam layout, chart,
selections and panel sizes. Looper, backing player and hosted drums keep running.
The header's navigation strip scrolls horizontally when space is tight.

The remote retains preset/scene selection, block bypass, Amp/Drive/Delay/Reverb/
Graphic EQ/Enhancer editors, channel/model/library choices, knob/numeric/default
editing, EQ faders and hardware read-back verification from the original app.
Edits affect the working buffer; it does not send permanent preset Save commands.
The standalone remote's USB playback slider is omitted here; use the existing
Mac Jams mix controls.

The source lives in `Packages/AM4RemoteKit`, imported from the original local
`am4-remote` checkout without modifying that project. It includes its catalogs,
saved Amp/effect libraries and protocol tests. There is no runtime dependency on
the other checkout or on a work account. Physical Mac/iPad use Core MIDI directly;
the optional localhost helper remains a simulator development facility.

One session owns the MIDI connection. It starts on first opening the remote;
closing pauses polling without interrupting a pending verified operation. MIDI
updates stay inside the remote UI, and the Mac Jams single-key playback/loop
shortcuts are disabled while it is open. Audio routing and capture are unchanged.
Close AM4-Edit when using the remote, as with the original standalone app.

```sh
swift test --package-path Packages/AM4RemoteKit
"build/Mac Jams.app/Contents/MacOS/MacLooper" --am4-resources-check
```

## Resizable panels

Drag the small grip on a border to resize:

- Songs sidebar width and audio-files panel width.
- File-list/player height split inside the audio-files panel.
- Chart/jam-controls height split.
- Looper/Drummer widths, or their heights when stacked on a narrower screen.
- Compact backing-player height beneath the chart on a narrow screen.

Sizes are remembered on each device. Minimum sizes keep neighboring controls
usable; smaller windows temporarily clamp the layout without replacing the saved
wide-window sizes. The compact player and jam panels scroll when space is tight.
The looper waveform grows as its panel becomes taller. Hiding a panel still leaves
its playback running and lets the remaining panels expand.

Double-click a grip to reset that split, or use its **Reset size** context menu.
Mac grips show the resize cursor and a cyan hover highlight; iPad grips have a
larger touch target. Songs remains a popover in the compact layout.


## Jam

1. Connect the AM4. Input defaults to **AM4**, capture **Inputs 1–2** (processed stereo guitar),
   and output defaults to **AM4 Proxy**, playback **outputs 1–2**. Neither default falls back
   to the built-in microphone or speakers if unavailable. Other devices can be selected.
2. Click the **gear** in the top corner to change input, output, or capture channels.
   The audio buffer is fixed at **32 samples**.
3. Set BPM (30–240) and **1–8 bars** with the numeric fields or +/− buttons.
   Defaults are **120 BPM / 4 bars**. V1 uses **4/4**.
4. Audio connects automatically when the app opens. Allow microphone access when asked;
   macOS requires this for USB audio input too. There is no software input monitoring.
5. Adjust the strum threshold with the slider or type a value in the dB field (−72 to 0 dBFS).
   The orange line shows the threshold over the input meter. Put it above idle guitar noise
   and below your normal strum. You can adjust the threshold while armed.
6. Click **Arm** (or **R**). The first sample at or above the threshold on either input channel
   starts capture. It records the calculated length and automatically loops it.
7. **Space** stops/restarts a completed loop. Stopping while waiting or recording cancels the take.
   **Clear** (Delete) discards the loop and unlocks BPM/length. Closing the app releases its
   audio route. Changing devices in Settings reconnects automatically while the loop is empty.
   If the interface is unavailable, reconnect it; **Retry Connection** is available in Settings.

The volume control beside **Clear** changes **loop playback only**.
Loop, file-player and drummer volume each start at **100%**. Type a percentage beside its speaker icon
for an exact setting. The AM4 handles live guitar monitoring. Captured loops stay in memory;
there are no saved sessions. Overdub is deferred to a later version.

## Pop Drummer AUv3

The compact bottom-right panel hosts **Lumbeat → Pop Drummer → Stereo**, the full
AUv3 instrument. The older compatibility component and MIDI-only plugin are not
selected. Install Pop Drummer on each device and open its standalone app once
before using the plugin, as described in [Lumbeat’s AUv3 setup guidance](https://lumbeat.com/lumbeat-faq/).

- **Play/Stop** controls the plugin independently of backing playback and threshold
  capture. It follows the looper’s BPM and a sample-based 4/4 host transport.
- **Open…** shows the plugin’s full editor in a separate Mac window or an iPad sheet.
  Choose rhythms, kits and Jam settings there. Plugin settings are saved locally
  when the editor closes and when the app shuts down; drums never autoplay on launch.
- Its own volume slider and editable percentage balance drums against the backing
  player and guitar loop. A 3 ms gain ramp avoids clicks. The instrument continues
  to render at zero gain so it can see transport changes and restart reliably.
- Saved plugin state is restored only after the instrument is connected and its
  render resources are prepared. Restoring Lumbeat state earlier can start its
  own system-device audio path, bypassing the host volume and selected output.
  The host now keeps the instrument on its own mixer and output route.
- The plugin observes stopped transport before its first Play. Lumbeat deliberately
  waits for its own Play button when first loaded into an already-moving host.
  If you intentionally enable **Lock Play** in the editor, its own Play button is
  still required; the host does not overwrite plugin preferences.

Drums and backing audio are mixed **after** guitar capture. Neither is routed into
the loop. Your AM4 preset must likewise keep USB playback out of the selected
hardware capture channels. The looper remains threshold-triggered: play your first
strum where you want the phrase to sit against the drums; it is not quantized to
the drummer’s next bar. Both use the same audio engine and sample rate.

Plugin discovery/loading failures are reported in the drum panel while guitar and
backing playback remain available. On iPad, the signed app includes Apple’s
`inter-app-audio` host entitlement, which also grants access to Audio Unit extensions;
this integration uses AUv3, not legacy Inter-App Audio routing.

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
   **Back 10 seconds / Forward 10 seconds** seek within the current file, clamp to
   its ends, and preserve Play/Pause. Previous/next selects the adjacent file in the complete folder listing without autoplay.
   While playing, **Left Arrow** restarts the current backing track from zero and continues
   playback. This also works with an iPad hardware keyboard.

File playback uses the selected output (normally **AM4 Proxy**), even with loop audio stopped.
It has no input connection and is never mixed into loop capture. Output changes pause the file;
Play resumes on the newly selected device. Closing the app stops both players. Opening a different
folder clears the previous file selection. Hidden folders, packages, and symlinks are skipped;
unreadable folders are reported without blocking the scan.

Common audio formats are discovered by file extension and macOS audio types. Native macOS decoding
handles playback; a listed format that needs an unavailable codec reports an error when selected.
Scanning and file decoding run off the UI and looper’s realtime thread. Playback
shares one AVAudioEngine mixer with guitar-loop playback. Guitar capture is
upstream of this mixer, so neither backing audio nor the drummer bus enters
the loop. Mono or non-48 kHz backing files are decoded in bounded buffers into an
OS-purgeable local stereo/48 kHz cache, preserving the original file and avoiding a
live graph reconnect when switching file formats. Conversion uses bounded
ExtAudioFile reads through the actual compressed-file EOF, avoiding estimated MP3
length failures. File-type badges are omitted from the browser.

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
  report a recoverable error. Reconnect the interface or use Retry Connection in Settings; old loops are discarded.

## Tests and diagnostics

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
"build/Mac Jams.app/Contents/MacOS/MacLooper" --devices
"build/Mac Jams.app/Contents/MacOS/MacLooper" --smoke-test
"build/Mac Jams.app/Contents/MacOS/MacLooper" --drummer-check
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
does not change the saved output preference. `--library-check /path/library.json`
validates all songs and exact JSON preservation without printing chart contents.
`--drummer-check` renders the installed AUv3 into memory at 32 frames, verifies
120 → 90 BPM, zero/quarter/full host gain, silent Stop and the custom editor.
On Mac it also rejects a newly loaded plugin opening its own hardware output.
Use `--plugin-state /path/state.plist` for isolated saved-state checks. Add
`--smoke-seconds 35` for a longer hardware run. `--smoke-drums` adds muted drum
playback/tempo/stop verification to the AM4 hardware check. These diagnostics exit
when finished; launch without flags for normal use. The plugin’s proprietary DSP
is outside the app’s own allocation guarantees. Hardware checks can fail independently of the deterministic tests; see
[stage validation](docs/stage-validation.md) and
[performance validation](docs/performance-validation.md) for this build’s actual results.

Implementation: `Sources/JamCore` owns portable library/ChordPro logic;
`Sources/LooperCore` owns sample-accurate C DSP and the Mac AUHAL adapter;
`Sources/LooperAudioUnit` hosts that DSP in a shared Audio Unit;
`Sources/MacLooper` owns shared SwiftUI, playback and platform routing. The Mac
adapter drives AVAudioEngine manual realtime rendering through the established
AUHAL route; iPad uses AVAudioSession and native AVAudioEngine I/O. Build products,
private libraries, signing files and caches are ignored. No external dependencies.

References: [Apple AUHAL routing note](https://developer.apple.com/library/archive/technotes/tn2091/)
and [AM4 owner's manual](https://www.fractalaudio.com/downloads/manuals/AM4/AM4-Owners-Manual.pdf).

## Reliability, recovery and interruptions

Pop Drummer loads when Play/Open is used. A missing or failed instrument does not
hold up the looper/backing route; use **Retry Drummer** after fixing installation.
Pending file playback cannot autoplay another selection or override a later Stop.

Unsaved song edits have a device-local recovery copy. Reopen Edit or use Settings'
**Unsaved edits** list. Cancel can **Keep draft and close**; **Export ChordPro**
keeps a separate text file. Saved library JSON and its before-save backups keep
their existing format. JustChords syncing stays off.

If iCloud reports conflicting versions, saves pause until **Settings → Review
iCloud versions** chooses one. Preview each version first: this is a whole-library
choice. Exact copies of all versions remain in **Library Conflicts**, and recovered
song drafts remain available. Concurrent nonconflicting field/body edits still
use the existing three-way merge.

On iPad, backgrounding/interruption pauses audio transports. Completed loops stay
in memory, stopped, on the same route; unfinished captures are cancelled. Returning
never starts playback automatically. A media-services reset clears the in-memory
loop and requires Retry Connection. Draft recovery is independent of audio state.
The older disconnect description above applies to the Mac adapter.

See [the reliability validation record](docs/reliability-validation-2026-11-02.md)
for regression coverage, device-test scope, recovery storage and diagnostic flags.
AM4 permanent preset Save remains a separate, unimplemented feature.
