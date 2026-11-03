# AM4 Remote Kit

Imported from the user's local `am4-remote` project at commit
`7126b904c13db5590327154c5931337dcbd8e41c` (2026-11-02).
The original project is unchanged. Protocol sources, factual catalogs, personal
Amp/effect libraries and protocol tests are retained. Integration changes add a
public session/screen, app-owned connection lifetime, hidden-screen polling pause,
native Mac search presentation, and removal of the standalone USB volume UI. This package has no audio engine.

`AM4RemoteSession` owns one Core MIDI connection. `present()` connects lazily;
`dismiss()` pauses background polling without interrupting an in-flight edit;
`stop()` releases the connection on app shutdown. The UI keeps the existing
preset/scene/block editing and read-back verification. No permanent Save is sent.
The standalone USB gain slider is omitted from the integrated UI; Mac Jams'
mix controls remain available in the jam workspace. Simulator hardware access uses the original optional
localhost development helper; physical Mac/iPad use Core MIDI directly.
