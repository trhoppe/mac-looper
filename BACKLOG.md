# Mac Jams backlog

The redesign is complete. Remaining features, in priority order:

1. **Saved song setups / setlists.** Extend Jam Setup to restore AM4 preset/scene, drummer settings, and volume balance. Support organizing setups into setlists.
2. **Looper overdubbing.** Record another layer over an existing loop.

## Completed

- **Song loop and backing-track links.** Jam Setup links either or both assets to a song and loads them stopped when the song is selected.
- **Backing-track slowdown.** The Player speed control slows tracks to 50–100% while preserving pitch.
- **Save and recall loops** (2026-11-23, original priority 1): portable `.jamloop` files with stereo audio, BPM, bars, and actual take length. Recalled loops can queue playback on Drummer’s next 4/4 beat 1. Recording retains its immediate/threshold behavior. Drummer preset saving remains in its plugin.
- **Shared loop storage** (2026-11-24): Save writes named takes into the chord library’s Loops folder; Open browses that collection on either device. Choosing the same iCloud Drive library folder shares the files. Duplicate names preserve both takes.

## Existing choices to preserve

- Use the user's saved Drummer preset with a hi-hat on the beat for metronome duties. Do not add a separate click-track metronome.
- Use the AM4's tuner. An in-app tuner is not requested.

Backlog agreed with the user on 2026-11-23. Remaining items need their own implementation request.
