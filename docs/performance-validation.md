# Audio routing and performance validation

November 1, 2026. Measurements are from this Mac and the connected AM4, with
separate installed-AUv3 checks on the physical iPad. Generated logs, traces,
private audio and user library data stay under ignored build/local paths.

## Drummer volume and output repair

Restoring Pop Drummer’s saved state before its graph was prepared let Lumbeat
start its own hardware audio output on the system device. Host PCM was silent,
so the app’s gain and output selection could not affect the audible drums.
State restoration now waits until graph attachment and render-resource
allocation. The plugin then renders through the host’s dedicated gain bus.

- Final real Mac AUv3 check: `build/mac-jams-drums.log`. Nonzero audio at 120 and
  90 BPM, exact 6 → 9 beat positions, 10,832 callbacks at 32 frames, custom editor.
- While playing: 0% gain produced exactly zero output; quarter/full gain produced
  nonzero audio. Stop produced zero. These verify gain operation, not a peak
  ratio comparison across different drum-pattern moments.
- Core Audio process inspection found no independent hardware output from the
  hosted extension, including after opening its editor. System default remained
  Studio Display Speakers; normal Mac Jams used AM4 input and AM4 Proxy output.
- Saved-state restoration and isolated save/reopen checks passed without opening
  a separate plugin output (`build/drummer-state-save.log`,
  `build/drummer-state-reopen.log`). User state was preserved.
- Physical iPad plugin rendering passed zero/quarter/full gain, Stop, tempo and
  editor checks (`build/performance-ipad-drums.log`). AM4 is connected to the Mac;
  audible iPad USB-interface jamming still needs that hardware connected to iPad.

## UI work

Fast input-meter and file-position publications previously caused repeated app
Scene/command evaluation and chart layout. Session ownership and deduplicated
command/readiness subscriptions now isolate fast telemetry. Device enumeration
runs off the main thread, unchanged telemetry is not republished, and chord
layout caches measured word sizes/placements. Eager chart layout avoids lazy
row-height estimates changing during scrolling.

Time Profiler evidence:

| Capture | Duration | Main-thread sampled CPU time | Approximate one-core load |
| --- | ---: | ---: | ---: |
| Before (`Performance-before.trace`) | 15.701 s | 15.037 s | 95.8% |
| After, charts + backing/drums (`Performance-final-chart-playback.trace`) | 30.630 s | 9.553 s | 31.2% |

These were different interaction windows, not a controlled frame-rate or speedup
benchmark. The profiles identify the removed update/layout churn; they do not
prove a fixed improvement for every song/device. An idle sample after the fix
found the main thread waiting in 1,697 of 1,712 samples.

After multiple charts and playback, measured footprint was 166.2 MB, peak
197.6 MB (`build/performance-memory.txt`). This is a snapshot, not a leak test.

## Audio stress and regression checks

- 35-second concurrent guitar-input, backing and muted-drum run completed
  **58,756 callbacks, all exactly 32 frames**, without an engine error or stall
  (`build/performance-audio-soak.log`). This diagnostic used direct AM4 output;
  its older headline incorrectly says Proxy, while its detailed route identifies
  AM4 device 115. Normal routing was separately verified on AM4 Proxy.
- A 20-second Audio System Trace (`Performance-audio-final.trace`) reported all
  100 load buckets Normal and no client event markers. This describes that
  captured interval, not a guarantee against future driver/plugin dropouts.
- **54 Mac tests**, zero failures (`build/mac-jams-tests.log`).
- **38 physical-iPad tests**, zero failures (`build/mac-jams-ipad-tests.log`).
- Regression coverage includes exact capture/wrap, no live monitoring, backing
  excluded from capture, gain ramps and muted upstream pulls, sample-based
  transport, file decoding, and lossless library handling.

App code does not allocate or block in its realtime render core. Proprietary
plugin internals and hardware drivers remain outside that guarantee.
