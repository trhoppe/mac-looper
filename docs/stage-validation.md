# Stages 1–3 validation

Implementation scope: shared Mac/iPad SwiftUI workspace and portable library model;
shared loop/backing audio graph with native platform routing; native ChordPro
viewing/editing and an own compatible JSON library. Pop Drummer AUv3 hosting
and the jamming controls are included. Overdub, saved loop sessions and a second guitar track remain later work.

## Current build

- Mac app: `build/Mac Jams.app` (0.3.0).
- Native Xcode project: `MacLooper.xcodeproj`; shared macOS/iPad schemes.
- Original working app preserved at `build/baseline-v0.2/Mac Looper.app`.
- Separate own iCloud Drive folder `Mac Looper` created. Initial library: 38 songs,
  3 playlists, 6 tags; exact-byte copy verified. JustChords source was not changed.
- Source/library data and backing audio are not bundled or committed.

## Historical viewer verification (November 1, 2026)

- Mac regression tests: **54 passed, 0 failures** (`build/mac-jams-tests.log`).
- Physical iPad: **38 passed, 0 failures** (`build/mac-jams-ipad-tests.log`).
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

To use the same editable iCloud library across devices, choose **Choose library
folder…** in Settings and select the own **Mac Looper** folder in Files. JustChords
source selection and syncing have been removed. Files grants access through this
folder choice; Mac absolute paths are not reused on iPad.

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
7. Edit a test chart in JustChords. Confirm Mac Jams keeps its current version
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

## Pop Drummer and jamming controls (November 1, 2026)

- Mac release build succeeds. **54 Mac tests pass**, with no failures
  (`build/drummer-tests.log`); **38 tests pass on the physical iPad**, with no
  failures (`build/drummer-ipad-tests.log`).
- Both platforms discover the current full `aumu/popd/LmBt` AUv3. The iPad signed
  host includes `inter-app-audio`, required for access to Audio Unit extensions.
  The instrument runs out of process on Mac; plugin state is stored locally.
- Real installed Pop Drummer audio rendered at **48 kHz / 32 frames** into memory
  on Mac and iPad. Both produced nonzero audio at 120 and 90 BPM, exact host beat
  positions of 6 then 9 (within floating-point precision), **zero output after
  Stop**, and a custom editor (`build/pop-drummer-final-check.log`,
  `build/pop-drummer-ipad-final.log`). These checks intentionally exit with code 0.
- Mac native-driver diagnostic also produced audio using real hardware timestamps
  at 32 frames through a silent diagnostic sink. The popup editor was checked
  directly (`build/pop-drummer-native-auto.log`).
- Combined live **AM4 input → AM4 Proxy output**, backing-file playback/restart,
  muted drummer Play/Stop and 120 → 90 BPM changes passed at **32 frames** with
  **9,599 callbacks**, without software guitar monitoring
  (`build/drummer-combined-smoke.log`). The drummer stays rendered at zero gain;
  regression tests cover muted pulls, gain ramps and latched transport changes.
- All three volumes default to 100%. Looper gain is beside Clear; drummer has its
  own slider and editable percentage. File player gains ±10-second seeking.
- BPM and bars have numeric entry and +/− buttons (120 BPM / 4 bars defaults,
  1–8 bars). Song tempos are still adopted only while loop timing is editable.
- Search icons reveal fields beside Songs and the audio-folder button; file type
  badges are removed. Stable song IDs and isolated meter subscriptions avoid
  repeatedly rebuilding the chart/browser. Eager chart layout avoids changing
  estimated row heights during scrolling.
- American idiot preview checked against the supplied examples: monospaced lyrics,
  visible spacing between adjacent verse chords, grouped monospaced raw tabs.
  Native chart changes do not modify the JustChords JSON.
- The actual MP3 that previously failed at compressed EOF now decodes fully to
  **177.672 seconds**, stereo/48 kHz. Synthetic mono/rate-conversion regressions pass.
- Normal Mac and iPad builds launched after diagnostics. AM4-on-iPad audible jamming
  and touch-layout refinement remain user checks; the connected AM4 is on the Mac.

## Mac Jams layout and final checks

- App display name and built bundle are **Mac Jams**. Existing bundle identifiers,
  signing identity, preferences and the `Mac Looper` iCloud folder are preserved.
- Songs, Looper, Drummer and Player header controls persist panel visibility.
  Manual Mac checks confirmed full-width chart expansion, either footer panel
  expanding alone, and the chart filling the workspace with every panel hidden.
  Drummer continued playing while hidden and stopped after showing it again.
- Subtle hover backgrounds are applied to header controls and song/audio rows,
  using local hover state without rebuilding the browsers.
- A− / A+ controls adjust chart text from 12–36 points, including scaled line,
  section, tablature and wrapped-row gaps. Both controls were exercised in the
  packaged Mac app.
- Global Ready status is beside Settings; 48 kHz / 32-sample details are in
  Settings only. Mac settings confirmed AM4 input and AM4 Proxy output.
- Final signed iPad tests passed **38/38**, then the app launched normally on
  Tom’s iPad. Final Mac regression run passed **54/54**; installed-plugin audio
  checks passed separately. No test app or diagnostics are left running on iPad.
- The build script now atomically replaces the executable. A clean Mac launch
  passed repeated panel, font, volume and Settings interactions.

See [performance validation](performance-validation.md) for the routing/volume
repair, profiling evidence and the limits of those measurements.

## Immediate typography and automatic columns

- Font size is now an explicit chart presentation input and layout-cache key,
  fixing delayed redraws until song selection changed. Measured word sizes and
  column placement are invalidated immediately when typography changes.
- At sufficient width relative to font size, the chart flows down the left column
  then down the right. Measured block heights balance the columns, preferring
  nearby section/stanza boundaries. A heading stays with its first content even
  across blank lines; an entire tab block remains in one column. Larger fonts or
  narrower chart space automatically return to a single column.
- Manual Mac check used the same American idiot chart throughout: A+ immediately
  enlarged text/spacing and switched to one column; A− immediately restored the
  smaller two-column layout. The prior font size and panel visibility were restored.
- Final regression results: **60 Mac tests** (`build/chart-layout-tests.log`) and
  **44 physical-iPad tests** (`build/chart-layout-ipad-tests.log`), all passing.
  Both app builds succeeded, with the updated iPad app installed by Xcode.

## UI refinements (November 2, 2026)

- Section headings use bold light gray; chords remain cyan. Backing-player output
  text is removed, with device selection retained in Settings.
- Paired charts now read left-to-right across consecutive lyric/chord lines,
  then continue on the next row. Section headings, separators and tab blocks span
  the full chart width; odd lines before a spanning block remain on the left.
- A text-column icon beside A− / A+ switches one/two-column preference immediately
  and stores it locally. Two-column presentation falls back to one on narrow space.
- Song/artist sorting is a standard single dropdown, with a remembered choice.
  Shared tests cover natural-number ordering, artist case/diacritic comparisons,
  missing artists, title/artist search and playlist/settings preservation.
- Song rows have reduced insets; their List fills the sidebar width, putting the
  scrollbar at its border. Header controls retain margins aligned with song text.
- Chords is independently toggleable between Songs and Looper. Selecting a song
  reveals it, including repeat selection of the current song. Manual Mac checks
  exercised this and clean Player-only and Looper/Drummer-only arrangements.
- Mac welcome artwork now explicitly loads its packaged PNG; Xcode targets retain
  asset-catalog lookup. The previously missing faded Mac logo was visually verified.
- **65 Mac tests** passed (`build/ui-refinements-tests.log`); **48 physical-iPad
  tests** passed (`build/ui-refinements-ipad-tests.log`), with no failures. Both
  app packages compile; private library/audio data remain untouched.
- Final Mac visual checks confirmed the aligned, single-line Songs header, native
  single sort dropdown, restored welcome logo, immediate column switching in
  both directions and one-column persistence after a normal quit/relaunch.
  The final signed iPad package was installed and launched normally.

## Native ChordPro editing (November 2, 2026)

This supersedes the historical JustChords launch-sync checks above. The own
`library.json` is now authoritative; a legacy source bookmark is removed and is
never imported, even when the own file is missing. The original JustChords file
stays protected. Own-library loading on foreground entry skips an open draft.

- Edit is below the chart font controls. The editor fills 100% of the current
  app workspace on both platforms, with compact metadata fields and native
  monospaced source editing. The larger overlay was visually checked on Mac.
- Song name, artist, base key, BPM, time signature and existing `duration` are
  editable. Raw `[CHORD]` markup and tabs are saved without text substitutions.
  Chords highlight cyan; headings/directives gray. The current 4/4 looper core
  remains unchanged; edited song BPM reaches an empty/editable loop as before.
- Saves read the coordinated latest file and patch only explicitly changed song
  fields. Unknown data, large unknown integers, numeric IDs, other songs and
  playlist membership/settings are covered by tests. Apple's reference-date
  timestamp format and string metadata types are retained.
- Each changed save makes an exact previous-file backup under Library Backups,
  then atomically replaces the library. Unrelated remote edits merge; edited-field
  conflicts keep the draft open. Invalid, missing and no-op cases do not overwrite
  the current file. Concurrent writes to different songs preserve both changes.
- A separate app copy and disposable JSON fixture exercised all six metadata
  fields, chord/lyric/tab typing, newline/space/arrow/delete handling, native undo,
  Save, reopen, Cancel and confirmed discard. The saved fixture was inspected for
  exact source text, unknown-field retention and byte-identical backup.
- **78 Mac tests** passed (`build/editor-tests.log`). Physical iPad validation
  results are in `build/editor-ipad-tests.log`; final device installation uses the
  native signed target. No private song edits were used for automated testing.
- Drafts are in memory until Save; saved-loop sessions, automatic draft recovery
  and general new-song/playlist management remain outside this editing phase.

## Resizable panels and full-window editing (November 2, 2026)

- Seven remembered split dimensions are implemented: Songs width, audio rail
  width, file-player height, footer height, drummer width, stacked drummer height
  and compact-player height. Drag preview is local state; preferences commit
  only when the drag ends. Audio graph/routing ownership is unchanged.
- Manual Mac mouse drags checked all five wide-layout borders, plus the compact
  player and stacked Looper/Drummer dividers. Examples included Songs 240 → 300,
  audio rail 340 → 400, player/footer 230 → 300, drummer 340 → 400, compact player
  230 → 270 and stacked drummer 150 → 210 points.
- Songs clamped correctly at its 220-point minimum. Double-click reset worked.
  Layout values survived a normal quit/relaunch and repeated hide/show changes.
  Player-only and expanded remaining-panel combinations were checked.
- Narrow and short windows were checked manually. Welcome spacing and compact
  minimum heights were adjusted after initial clipping was found. The revised
  welcome message and full compact-player volume controls fit in the checked
  window. Returning to a wide window restored saved sizes instead of keeping
  temporary constrained dimensions. Test dimensions and original visibility
  were restored afterward.
- The editor now fills the app workspace with no dimmed border or rounded inset.
  A production chart was opened for a visual check, then cancelled unchanged;
  Save remained disabled throughout that check.
- Mac regression suite: **82 tests**, no failures (`build/resizable-tests.log`).
  Final packaged Mac build succeeds (`build/resizable-mac-build.log`). Physical
  iPad suite: **64 tests**, no failures (`build/resizable-ipad-tests.log`); the
  installed signed app was launched normally. Actual touch drags remain a user
  check; manual drag verification was on Mac with the shared SwiftUI layout.
- The AM4 input was not enumerated during this UI pass (AM4 Proxy was present),
  so live guitar/drum routing was not re-tested after the laptop shutdown. The
  app correctly reports the missing input without switching to its microphone.


## ChordPro-native song data — 2026-11-02

- Audited the official ChordPro specification and directive pages. Exact supported
  and unimplemented features are listed in `chordpro-compatibility.md`; the app
  does not claim complete ChordPro 6 rendering.
- Song details now live in the ChordPro preamble in `rawData`. JSON fields remain
  compatibility copies. The editor's fields and source update each other, and
  source metadata drives song sorting, chart details and initial looper BPM.
- One-time coordinated migration fills metadata headers, converts legacy plain
  headings and wraps tabs. An exact `library-before-chordpro-…json` backup is
  required before atomic replacement; repeated launches do not rewrite it.
- Tested safe metadata/body merges, same-field conflicts, missing/corrupt and
  protected libraries, unknown nested data and 64-bit numbers, backup identity,
  version markers, and idempotence.
- Dry-run audit covered all 38 own-library songs: metadata, chord/lyric fragments,
  tab rows, section labels and saved transpositions were preserved. All converted
  songs remain editable. Live conversion completed for all 38; its backup hash
  matches the exact pre-conversion snapshot. IDs, playlists, dates, saved
  transposes and unknown fields were checked after conversion.
- Mac regression tests: **101 passed**, including the optional private-library
  audit. Release Mac app packaged successfully.
- Mac UI check used a disposable synthetic library: title/artist from directives,
  section labels, chorus recall, annotations, tab literals and comment styles
  rendered; unsupported diagrams were explicitly reported. Structured BPM 132
  appeared in source; typing 144 in source updated the field; undo/redo kept both
  consistent; Save persisted source and compatibility BPM 144. Main Mac app
  reopened and loaded a converted song normally.
- iPad validation: **82 passed, one optional private-library audit skipped**
  on both the physical iPad and simulator (83 tests in each suite, zero failures).
  Signed device update installed and launched successfully after unlocking.
- No audio engine, buffer, routing or plugin changes are included in this work.
