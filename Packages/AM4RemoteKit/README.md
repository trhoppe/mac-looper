# AM4 Remote Kit

Imported from the user's local `am4-remote` project at commit
`7126b904c13db5590327154c5931337dcbd8e41c` (2026-11-02).
The original project is unchanged. Protocol sources, factual catalogs, personal
Amp/effect libraries and protocol tests are retained. Integration changes add a
public session/screen, app-owned connection lifetime, hidden-screen polling pause,
native dropdowns, workspace-matched styling, and removal of the standalone USB volume UI. This package has no audio engine.

`AM4RemoteSession` owns one Core MIDI connection. `present()` connects lazily;
`dismiss()` pauses background polling without interrupting an in-flight edit;
`stop()` releases the connection on app shutdown. The UI keeps the existing
preset/scene/block editing and read-back verification. Permanent Save is available only through the explicit preset-header button.
The standalone USB gain slider is omitted from the integrated UI; Mac Jams'
mix controls remain available in the jam workspace. Simulator hardware access uses the original optional
localhost development helper; physical Mac/iPad use Core MIDI directly.


The preset browser uses the same plain list, row spacing and dark background as
Songs. Buttons include their full padded label area and have a local hover
highlight. Type, library and fixed-choice controls use native menu pickers; model
menus retain stable catalog IDs and are isolated from frequent MIDI publications.
An expected-context change replaces an open picker rather than retargeting its
choice to a different preset, scene, channel or model. Block headers wrap their
selectors below the title on narrower windows. MIDI edits, verification and audio
routing are unchanged by this presentation update.


Preset Save uses PARAM_RW action `0x001B` and a uint32 LE current-slot payload.
Protocol evidence: [AM4 save codec and command acknowledgement](https://github.com/TheAndrewStaker/mcp-midi-control/blob/main/packages/fractal-midi/src/am4/setParam.ts)
and [GET_PATCH edited-state probe](https://github.com/TheAndrewStaker/mcp-midi-control/blob/main/scripts/_research/probe-am4-edit-counter.ts).
The edited bit is wire byte 21, mask `0x04`, only after our existing strict
PATCH descriptor header, length, packing, and checksum validation. Local edit
tracking bridges the first two seconds of device flag propagation; later reads
also reflect front-panel edits and saves.

Save rechecks preset/scene/name/layout and session before sending. A distinct
18-byte acknowledgement, clean edited flag, and stored-name readback must all
succeed. Missing acknowledgements, changed contexts, disconnects, or failed
verification keep a visible status; no permanent write is automatically retried.
The optional helper advertises save capability; older helpers cannot enable Save.
Offline tests cover its exact wire address, echo rejection, stale contexts,
already-clean no-op, missing acknowledgement, and post-save verification failures.
