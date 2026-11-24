# Mac Jams design system

Shared SwiftUI components live in `Packages/JamDesignKit`. Both the app and
AM4RemoteKit depend on that package, so surfaces, colors, button feedback, and
screen headers stay consistent across macOS and iPadOS.

## Tokens

| Role | Value |
| --- | --- |
| Ground | `#121214` |
| Card | `#1B1B1F` |
| Control | `#26262C` |
| Text | `#F2F2F5` |
| Secondary | `#A3A3AD` |
| Active / chords | `#5AB8F5` |
| Recording | `#FF4D4F` |
| Loop playing | `#34D399` |
| Armed | `#F5A524` |

Cards have a 14-point radius, a subtle border, and 12-point gaps. Controls use an
8-point radius. Selection rows remain neutral gray. State indicators include
text or icons alongside color.

## Controls

- Use SF Symbols at regular weight; fill transport glyphs where appropriate.
- `JamIconStyle`: neutral filled square icon button, including Player and Drummer
  Play/Pause/Stop; blue tint when selected. Other Player transport controls remain plain.
- `JamControlStyle`: text and menu actions on a neutral filled surface.
- Plain navigation/utility icons use the shared hover treatment.
- Numeric steppers share one surface with compact minus/value/plus controls.
- Icon and BPM/bar control heights are 36 points on both Mac and iPad.
- Hover and press feedback must honor disabled state.

AM4 dial faces and faders use these tokens, while preserving their original
parameter ranges, gestures, context checks, and inline editing behavior. The
AM4 screen header has no Escape shortcut: Escape belongs to the inline editor.

## Workspace

Desktop uses a chart plus a resizable-width right column containing Player,
Drummer, then Looper. Card heights follow their content; the rail scrolls in
short windows. iPad landscape places all three modules in the right column, using a compact
Drummer strip. Portrait puts a slim Drummer row above side-by-side Player and
Looper cards.

Songs, More, Audio Files, and Settings share `JamDropdownLabel`,
`JamDropdownRequest`, and `JamDropdownPopup` across both platforms. They use the
same caret, surface, outline, and dismissal behavior. Volume popups also stay
within the app. Navigation
labels collapse to icons at constrained widths. The global BPM control edits
the existing shared tempo. Mix and each module's volume controls bind to the
same three volumes; Mix adds no new signal path or master level.

## Scope

This pass preserves the Player seek bar, distinct Looper Arm/Record/Play/Clear,
threshold, and original waveform. New audio features remain in `BACKLOG.md`.

Chart font sizing uses a joined two-button control with a hairline divider.
The song diagram strip uses compact left/bottom insets and collapses to an
compact “Chord charts” button under the right-aligned key/duration metadata,
allowing lyrics to move upward. Library
fretboards are visually centered after compensating for their fret-label inset.

Player's title is its file-browser dropdown. Open-file and open-folder buttons sit
beside it in the same header row as volume. Drummer's Play and plugin buttons
remain adjacent, including in the compact iPad strip. Ready, BPM, and Mix have
10-point gaps between them in the toolbar.
