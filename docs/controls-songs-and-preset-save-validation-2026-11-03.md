# Controls, song creation, playlists, and AM4 Save validation

## Scope

- Padded BPM/bars fields and steppers; smaller regular-weight loop duration.
- Padded chart buttons, smaller A−/A+ labels, compact song selectors, and local hover feedback that respects disabled controls.
- Drummer BPM centered vertically between the heading and transport buttons.
- Songs + opens a blank full-workspace editor. New songs inherit the currently browsed playlist. All Songs remains the complete library.
- The editor's Playlists menu edits membership in one or more existing playlists. Retained entries keep ordering and per-song overrides; untouched remote membership changes merge independently.
- AM4 preset header has an explicitly invoked, current-slot-only Save action with gray/orange edited-state indicator.

## Automated checks

- Root `swift test`: 29 app tests, 28 DSP/audio tests, and 69 JamCore tests; no failures. The optional read-only real-library audit is skipped unless explicitly configured.
- AM4 package tests, including `AM4_SIMULATOR_HELPER`: 93 passed. Eight new tests cover save addressing, command acknowledgement versus echo, edited-state parsing, stale contexts/session, recent edit propagation, already-clean no-op, and post-write verification failures without retries.
- New-song/playlist coverage includes exact pre-save backup, canonical ChordPro metadata, idempotent retry, ID collision refusal, nested playlist entries, numeric IDs/unknown fields, concurrent edits, recovery, and legacy recovery decoding.
- Release Mac app build and signed physical iPad build succeeded.

## UI and device checks

- Mac: + opens an empty New song editor; Save stays disabled until metadata is valid.
- Mac: a temporary test song was created through the UI, assigned Electric Songs, saved, and opened as the selected chart. The resulting JSON was read back to confirm membership and ChordPro version. This used `--editor-check-folder` in `/private/tmp`; the user's library was not edited.
- Mac: padding, timing typography, compact dropdowns, chart controls, and centered Drummer BPM were visually inspected. Disabled plain buttons were corrected to remain dim and not highlight on hover.
- Mac: the final app reopened the user's normal 38-song library and reported Audio Ready.
- AM4: direct USB reads on W4 Acoustic exposed the new Save button disabled with No unsaved changes. The user then made a change to keep and pressed Save, confirming success. The running app was independently read back: Save disabled, No unsaved changes, and Saved to AM4 · W4. The agent did not initiate the permanent write.
- Physical iPad: app installed successfully. Remote launch timed out twice; the user opened it manually and confirmed the new + button. Follow-up adjustment insets the iPad song scroller by 1 point on each side to preserve the popover outline.

## Preset-store guarantees and remaining hardware check

Save captures the displayed slot, preset/scene names, scene, and block layout; the connection and fresh location/snapshot/location reads must still agree before the one permanent write. A distinct addressing-only acknowledgement, cleared device edited flag, stable context, and matching stored name are required for success. A write is never automatically retried. Older optional simulator helpers cannot enable this operation without advertising support.

The first real permanent store was confirmed on W4 Acoustic by the user and by the app’s acknowledgement/clean-state/stored-name verification. Reload/power-cycle persistence has not been separately exercised. Protocol evidence is linked in the package README. Audio routing, DSP/capture, and plugin hosting were not modified in this change.
