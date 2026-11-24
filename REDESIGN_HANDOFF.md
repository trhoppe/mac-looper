# Mac Jams redesign — 2026-11-23

Implementation completed for review in the working tree. No commits made.
The shared components and layout rules are documented in DESIGN.md.

## Delivered

- Shared JamDesignKit palette, card surfaces, buttons, hover feedback, and headers
  across the app and AM4 Remote, including flat dial faces and matching EQ faders.
- Desktop chart plus a resizable-width Player / Drummer / Looper column. Card
  heights follow contents; obsolete vertical splitters and Looper-position setting
  are removed. Short desktop windows scroll the card column.
- iPad landscape: chart beside Player / compact Drummer / Looper in the right rail.
  Portrait: chart, slim Drummer strip, then Player / Looper side by side. Wide Looper
  cards combine bars and the four transport buttons into one row to save height.
- One shared toolbar BPM control. Mix exposes the three existing volumes with
  editable percentages and touch/mouse faders, synchronized with module controls.
- Player seek bar, file/folder browsing, imports, transport semantics, and separate
  Arm / Record / Play / Clear, threshold, and original Looper waveform preserved.
- Bordered collapsible chord strip, library diagram cards with balanced margins,
  consistent auxiliary screens, and updated README workspace documentation.
- Corrected a new Escape shortcut conflict in the AM4 screen header so Escape
  cancels inline value editing without dismissing the remote.

## Verification

- Mac release app, iPad simulator, and physical iPad builds pass.
- Root regression suite: 99 tests, 1 skipped, 0 failures.
- AM4RemoteKit regression suite: 97 tests, 0 failures.
- git diff --check passes.
- Running Mac: large and constrained workspace, right-column scrolling, bounded
  Mix/Settings/Songs, immediate song selection, editor, libraries, AM4 preset and
  block views, flat dials/EQ, inline edit cancellation checked.
- Mix: mouse and simulator touch faders, numeric replacement, arrow keys, and
  card/Mix synchronization checked. All three volumes restored to 100.
- iPad simulator portrait and landscape checked. Landscape Player and Drummer
  controls fit above the compact full-width Looper without clipping at idle.
- Physical iPad installation remains deferred at the user's request. No live
  audio recording/playback or hardware MIDI foot-controller test in this pass.
  AM4 UI inspection made no parameter writes or preset saves.

## Scope retained

Mix is the only added feature. Tap tempo, Player waveform, overdubs, count-in,
A–B loops, slowdown, tuner, metronome, and saved song setups are outside this pass.
Post-redesign priorities remain in BACKLOG.md. The prior README backlog link and
BACKLOG.md were preserved.

## Build locations and logs

- Mac: build/Mac Jams.app
- Device: build/iPadDevice/Build/Products/Debug-iphoneos/Mac Jams.app
- Simulator: build/iPadSimulator/Build/Products/Debug-iphonesimulator/Mac Jams.app
- Logs: /private/tmp/mac-jams-redesign-{mac,sim,device,tests,am4-tests}.log
- Simulator: E80980B5-7E5B-450B-A26E-BA0F52F97C0C, com.thoppe.maclooper

## Follow-up visual refinements

All eight requested follow-ups are implemented: joined font-size control; tighter
song diagram spacing and collapse-to-button; Songs music icon/caret plus shared
bounded popup code for Songs/More/Settings/Audio Files; Ready before BPM/Mix/Settings;
smaller primary Play circles (portrait Drummer preserves its size); centered
library fretboards; landscape iPad Looper in the right rail; portrait Drummer
strip above side-by-side Player and Looper. The old native Mac More-menu wrapper
was removed. Updated layouts and popup selection were checked in the simulator.

Latest build logs: /private/tmp/mac-jams-refinements-{mac,sim,device}.log.
Physical iPad installation remains deferred. No new audio or MIDI behavior added.

## Latest polish

Player and Drummer use the same square JamIconStyle as other filled icon actions;
the circular primary style was removed. Drummer Play and plugin buttons are
adjacent in both compact and regular cards. Player's title now opens its browser,
with file/folder buttons in that header; the separate Audio Files trigger row is
gone. Collapsed chord diagrams are a small button below the right-side metadata,
with less header/Intro spacing. All shared icon and BPM/bar controls are now 36
points on both platforms. Ready/BPM/Mix gaps increased from 6 to 10 points.

Mac and both simulator orientations visually verified, including the minimum
right-column width. Latest logs: /private/tmp/mac-jams-polish-{mac,sim,device}.log.

Portrait Player and Looper now share the taller card's measured height. Player
has more header/content spacing and distributes the extra height inside the
card. Player, Drummer, and Looper share a 15-point semibold module title with
17-point regular icons; Player's dropdown title/icon are white. Drummer has more
space between its title and transport controls in compact and regular layouts.
Verified on Mac and in both iPad simulator orientations at minimum rail width.
Mac, simulator, and device builds passed; physical iPad installation is deferred.
Latest logs: /private/tmp/mac-jams-card-alignment-{mac,sim,device}.log.

## Capo, loading, and rhythm follow-up

- Drummer loading indicator is in the transport HStack immediately after the
  plugin editor button in regular and compact layouts, rather than a new row.
- Chart metadata shows bold amber Capo before Key. The displayed key, chord
  labels, and diagrams subtract the capo fret from the requested transposition;
  Dm with capo 5 displays Am shapes. Stored source/key data remain unchanged.
- Looper detail text is always present and reserves two lines, keeping the
  status area the same height through idle, armed, recording, and playback.
- Eight LibraryTests pass, including capo/key, slash-chord adjustment, legacy
  metadata, playlist transposition, and source preservation.

Read-only inspection of the installed full Pop Drummer AUv3 on 2026-11-23 found
five host parameters: Jam, Jam Effects, Swing, Groove, and Drum Kit. Groove has
307 value names, including the user's Latin Groove and Hat Beat; its final `...`
entry is not a named rhythm. Drum Kit has 11 values, also ending in `...`.
factoryPresets is empty. This supports a host rhythm/kit picker without relying
on AU factory presets.

The host already restores/saves AU fullState. A named snapshot can recall a user
rhythm setup without editing the plugin's library. Lumbeat also documents MIDI
bank/rhythm selection, fills, and Live Pads; exact mappings must be checked in
the installed plugin. No documented API for creating or overwriting its saved
user-rhythm library was found. Do not promise that capability from parameter
selection or state recall alone.
Sources: https://lumbeat.com/manual/ and https://lumbeat.com/lumbeat-faq/.
Probe output: /private/tmp/mac-jams-drummer-capabilities.json (no audio started,
no parameter writes, no library changes).

Implemented the first integration: a shared-style rhythm popup next to Play,
with the plugin button aligned right and its loading spinner immediately after
it. Read AU Groove valueStrings and retain original indices; include only names
starting with `User - ` (case insensitive), hiding that prefix in all display
labels. The user's renamed Latin Groove and Hat Beat were confirmed live.
The AU parameter observer reflects editor changes. Selecting a rhythm prepares
the muted host branch, preserves current transport, applies the AU parameter,
and saves fullState for recall. On startup the branch restores that state without
opening the editor or starting playback. No factory-name catalog or count-based
heuristics remain. The earlier factory-catalog experiment was removed at the
user's request.

Looper status spacing moved 4 points from below the persistent detail area to
above it. Mac, simulator, and device builds plus the root regression suite pass.
Mac verified: only Latin Groove / Hat Beat appear, prefix hidden, selection saves,
Hat Beat restores on relaunch; capo 5 displays Am labels and key for the Dm song.
Logs: /private/tmp/mac-jams-rhythm-{mac,sim,device,regression}.log.

Final device update installed and launched successfully. Physical iPad landscape
checked at minimum rail width: Player, Drummer controls, and Looper all fit. Its
plugin has no User-prefixed entries yet, so the popup shows the naming instruction;
the user must apply the same naming convention in Pop Drummer on iPad. Mac's
prefixed Latin Groove and Hat Beat were selected through the clean-label popup;
Hat Beat was restored as the final choice. No factory-library data is used.
User rhythms now sort alphabetically by their displayed names with the hidden
prefix removed, retaining original AU parameter indices for selection. Sorting
tests and Mac/device builds pass. Logs: /private/tmp/mac-jams-rhythm-sort-*.log.
