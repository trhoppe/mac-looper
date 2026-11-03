# Reliability update — 2026-11-02

Scope: implement the four findings in `review-2026-11-02.md`, add local song-draft
recovery and explicit iCloud conflict review, and define/test iPad interruption
behavior. Preserve the existing looper, player, plugin route/gain, and AM4 editor.
No permanent AM4 preset Save has been implemented.

## Changes

- File Play has a separate intent token, reserved when the UI issues Play.
  Selection, Pause, Stop, shutdown, and interruption invalidate it. It is checked
  after graph ownership and graph construction waits. Stale errors are discarded.
  Scheduling completions retain their separate buffer-generation token.
- Audio graph mutations have FIFO ownership using continuations, replacing the
  configuration polling loop. Cancellation passes ownership to the next waiter.
- Library reads coalesce and drain the latest requested folder. Library, backing
  links and conflict state publish together after all waits pass the folder's
  revision check. Folder changes clear the old selection and displayed library;
  last-good data is retained only for refresh failures within the same folder.
  Refreshes requested during editing/saving are deferred, not lost. Portable
  backing manifests and bookmark caches remain scoped to their source folder.
- Basic audio startup does not discover or instantiate Pop Drummer. Play/Open
  load the optional instrument on demand; failures are cached until explicit
  Retry or component-registration changes. The instrument branch can attach
  upstream of the running mixer's separate gain without rebuilding the captured
  guitar loop or backing schedule. State restoration remains strictly after
  attachment/render preparation. Readiness no longer waits for an unused plugin.
- Plugin teardown detaches transport callbacks while the AVAudioUnit wrapper is
  still alive. A regression test exposed an AUv2 bridge crash from the old order.
- AM4 Remote Close clears Amp/effect page subscriptions synchronously, even while
  an edit is busy; closing never disconnects/cancels the edit's read-back. Opening
  a different Amp page remains guarded. Backgrounding pauses periodic polling.

## Song data protection

Unsaved edits get device-local atomic recovery records, with the original song
version and edited ChordPro, under Application Support / MacJams / Draft Recovery.
They are keyed by library location and song ID, never mirrored from JustChords.
Sequence numbers stop a late queued write resurrecting a saved/discarded draft.
A damaged record is kept intact and does not hide other valid records. As with
any asynchronous recovery, an abrupt failure can lose the very last edit before
its disk write completes; the last completed atomic record remains recoverable.

Reopen Edit to recover a song, or choose **Settings → Unsaved edits → Recover**.
Cancel offers **Keep draft and close**, **Discard changes**, or **Keep editing**.
The keep action stays in the editor on a recovery-write failure. Save/Discard
remove the recovery record only after their corresponding operation succeeds.
**Export ChordPro** also lets a draft be kept outside the library, including when
its original song has been deleted or concurrent edits prevent saving.

Unresolved `NSFileVersion` conflicts block library saves and migration. Settings
provides version previews and an explicit whole-library choice. Exact current and
conflicting JSON bytes are preserved in **Library Conflicts** before replacement;
unknown fields are not rebuilt from the preview. The chosen set of versions and
current bytes must still match the reviewed snapshot. Only those reviewed
versions are marked resolved, and their backup copies remain. This is an explicit
choice of a whole library, not an automatic merge of arbitrary offline branches.
Ordinary field/body three-way merging and exact before-save backups still apply.

## iPad lifecycle policy

Backgrounding or interruption stops file/drum/loop transports. Rendering pauses
before the control-thread suspension function touches the looper. Completed loops
remain in memory, stopped; armed/partial captures and old pre-roll are cancelled.
Returning/reconnecting never starts a transport automatically. Same-route audio
can reconnect; a changed route retains a completed loop until the original route
returns or the user clears it. With an empty loop, the route can rebuild normally.
A media-services reset recreates audio objects, explicitly reports loss of the
in-memory guitar loop, and requires Retry. Unsaved song drafts remain on disk.

## Regression coverage and visual checks

Deterministic tests hold configuration/library I/O at known suspension points:
Play→selection/Pause/Stop/unload, replacement during graph creation, stale setup
errors, cancelled configuration waiters, successive library changes, stale backing
links, missing folders and editor-deferred refreshes. Plugin tests cover slow and
failed loads, retry caching, live graph attachment with a captured loop, and silent
suspension/resumption. Core tests cover full command queues and partial capture.
Recovery/conflict tests check exact backups, stale choices, malformed records,
failed writes, explicit version selection, and prevention of late draft revival.
The iPad test host now includes shared app-level regression tests too.

Mac visual validation used disposable libraries under `/private/tmp`:

1. Edit song metadata, keep a draft and reopen it.
2. Change another field, verify the recovery write, forcibly terminate only the
   test process, relaunch and recover both fields through Settings.
3. Save the recovered draft; verify the original fixture remained unchanged until
   Save, its exact backup exists, and its recovery record was removed.
4. Review two simulated conflict versions, switch previews, confirm the explicit
   whole-library choice, and verify both exact copies remain afterward.

`--editor-check-folder <temporary-folder>` isolates the library and recovery store
and suppresses automatic capture startup. Adding `--simulate-library-conflict`
uses `conflicting-library.json` in that folder as a fixture; it does not manufacture
or resolve genuine iCloud file versions. These are test launch arguments, not
user-facing settings. No normal song editing was performed during visual tests.

## Hardware validation

See the final results appended below. All live parameter checks use the existing
app-owned AM4 connection and its verified editor methods. Temporary changes are
bound to the original preset/scene/channel and restored from fresh read-back;
there are no permanent Save commands, model replacements, or preset navigation.

A live AM4 Delay Expert read exposed an inherited parser issue: `BLOCK_BYPASSMODE`
returned raw=3, float=3, text=`Mute FX In`, rather than a normalized float. The
parser now accepts the captured bounded absolute-ordinal representation as well
as the existing normalized form, only for this known field. Continuous validation
and the separate Speaker stable-table-ID behavior remain intact. The exact
56-byte payload is a regression test. Reply framing/address matching is separate
from value validation, so a malformed reply produces an invalid-value error
rather than a misleading timeout. Catalogs and MIDI write opcodes are unchanged.

Repeatable opt-in checks:

```sh
"build/Mac Jams.app/Contents/MacOS/MacLooper" --am4-check
# Only on a user-selected test preset, with permission for temporary changes:
"build/Mac Jams.app/Contents/MacOS/MacLooper" --am4-check --am4-exercise-controls
# Combine MIDI with the existing silent backing/muted drum audio diagnostic:
"build/Mac Jams.app/Contents/MacOS/MacLooper" --smoke-test --smoke-drums \
  --smoke-file /path/to/silence.wav --smoke-am4 --am4-exercise-controls \
  --smoke-seconds 35 --plugin-state /path/to/isolated-plugin-state.plist
```

For any subsequent permanent Save feature: first capture the actual AM4-Edit Save
transaction on a user-chosen preset, distinguish Save from Save As, serialize it
against edits/navigation, and independently verify persistent data. Never infer
persistence from working-buffer parameter read-back or guess a related device's
Save opcode. Physical iPad/USB, multi-device iCloud conflict production behavior and a long
performance soak remain separate checks; synthetic tests do not prove these.

Implementation references: [Apple audio engine runtime graph rules](https://developer.apple.com/documentation/avfaudio/avaudioengine),
[interruption handling](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions),
and [file version conflict state](https://developer.apple.com/documentation/foundation/nsfileversion/isresolved).

## Final results

- Mac app/core/library: **120 cases, 119 passed, 1 optional private-library audit
  skipped, 0 failures**. AM4RemoteKit: **85 passed, 0 failures**, including the
  captured Delay bypass-mode reply regression.
- iPad Simulator: **119 cases, 118 passed, 1 optional private-library audit
  skipped, 0 failures**. Simulator excludes the Mac-only AUHAL/manual-input case.
  Native Mac release and signed generic iPad device builds succeeded. The signed
  iPad artifact is ready; this pass did not install it on a physical iPad.
- Live integrated Mac run: **AM4 input → AM4 Proxy, 48 kHz, strict 32 frames,
  85,611 callbacks**, no reported render error/stall, concurrent silent backing
  playback/restart and muted Pop Drummer at 120 → 90 BPM. USB MIDI reads/temporary
  edits ran in the same app session while audio continued. The configured final
  wait was 35 seconds, plus setup/MIDI checks (about 57 seconds of callback time).
- User-selected test preset V1, scene 2: all **18 pages** read successfully (8 Amp,
  2 Drive, 5 Delay, 3 Reverb). Legacy Gain **6.66 → 6.76 → 6.66** verified.
  Full Amp editor Gain and Drive/Delay/Reverb Level writes/read-backs/restores also
  passed. Remote Close was exercised both during a verified legacy edit and after
  the full editor write was sent; read-back completed and values were restored.
- User then selected W4, scene 1: both Enhancer pages and its Level round-trip
  passed. Both separate Graphic EQ pages and its Level round-trip passed too,
  along with that preset's Reverb. No Amp block was present, so Amp tests were
  appropriately skipped there. The user uses the Amp's built-in GEQ rather than
  the separate Graphic EQ block; the Amp GEQ page was already verified on V1.
- Installed Pop Drummer: **10,832 renders at 32 frames**, 120/90 BPM beat positions
  approximately 6/9, host mute exactly **0.0**, Stop exactly **0.0**, quarter/full
  gain produced nonzero/scaled output. No newly active independent plugin hardware
  output appeared, including activation of an already-existing plugin process.
- Normal Mac UI: automatic audio readiness, chart scrolling with tabs, 104-slot
  preset catalog, current preset/scene, full Amp editor, and full-app Close back
  to the chart were visually checked on the connected AM4. No UI parameter edits
  were made outside the explicitly restored diagnostic transactions.

Two fresh Time Profiler captures used the same Mac app process and active AM4
capture route, with Drummer/Player hidden and inactive:

| Capture | Duration | Sampled main-thread CPU | Approx. one-core load |
| --- | ---: | ---: | ---: |
| Chart scrolling, including tab content | 21.303 s | 6.834 s | 32.1% |
| Remote open, catalog/page reads and Amp editor | 20.846 s | 7.211 s | 34.6% |

These are different interactions with idle portions, not an identical scripted
benchmark, frame-rate measurement, before/after speedup, or audio deadline trace.
They provide a current baseline alongside the separate live callback test.

Local logs are copied into ignored `build/validation-2026-11-02/`. Profiling trace
bundles remain in `/private/tmp/mac-jams-live-validation/` and are not committed
(they include process/environment metadata). No commits, tags, pushes, permanent
AM4 saves, model replacements, or diagnostic preset/scene navigation were made.
