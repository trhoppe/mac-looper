# Mac Jams backlog

Design and polish come next. Implement these features **after the redesign**, in this order:

1. **Save and recall loops.** Add loop persistence to the existing Looper so a saved loop can be loaded for another jam without recording it again. Keep this within the Looper; a separate jam recorder is not requested. Drummer preset saving already lives in its plugin.
2. **Saved song setups / setlists.** Associate songs with their backing track, AM4 preset/scene, drummer settings, BPM, and volume balance so choosing a song can restore its jam setup. Support organizing these setups into setlists.
3. **Backing-track slowdown.** Add playback speed adjustment that preserves pitch. Slowing down a track is the initial requirement; the broader practice-mode UI can be decided later.

## Existing choices to preserve

- Use the user's saved Drummer preset with a hi-hat on the beat for metronome duties. Do not add a separate click-track metronome.
- Use the AM4's tuner. An in-app tuner is not requested.
- Looper overdubbing is also planned for later; its priority relative to the three items above has not been assigned.

Agreed with the user on 2026-11-23. This is a planning backlog, not authorization to begin these features before the redesign.
