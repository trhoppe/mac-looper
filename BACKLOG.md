# Mac Jams backlog

The redesign is complete. Remaining features, in priority order:

1. **Saved song setups / setlists.** Associate songs with their backing track, AM4 preset/scene, drummer settings, BPM, and volume balance so choosing a song can restore its jam setup. Support organizing these setups into setlists.
2. **Backing-track slowdown.** Add playback speed adjustment that preserves pitch. Slowing down a track is the initial requirement; the broader practice-mode UI can be decided later.

## Completed

- **Save and recall loops** (2026-11-23, original priority 1): portable `.jamloop` files with stereo audio, BPM, bars, and actual take length. Recalled loops can queue playback on Drummer’s next 4/4 beat 1. Recording retains its immediate/threshold behavior. Drummer preset saving remains in its plugin.
- **Shared loop storage** (2026-11-24): Save writes named takes into the chord library’s Loops folder; Open browses that collection on either device. Choosing the same iCloud Drive library folder shares the files. Duplicate names preserve both takes.

## Existing choices to preserve

- Use the user's saved Drummer preset with a hi-hat on the beat for metronome duties. Do not add a separate click-track metronome.
- Use the AM4's tuner. An in-app tuner is not requested.
- Looper overdubbing is also planned for later; its priority relative to the remaining items has not been assigned.

Backlog agreed with the user on 2026-11-23. Remaining items need their own implementation request.
