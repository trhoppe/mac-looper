# Mac Looper app icon

Generated/edited with the built-in image generation tool using the user's AM4 icon
as style inspiration. Final direction: circular clockwise loop, crisp arrowhead
edges, cyan blue on dark navy, clean flat finish with no glow or bevel.

Masters:

- `Assets/AppIcon.png`: macOS tile with transparent exterior; also welcome artwork.
- `Assets/AppIcon-iPad.png`: full-bleed opaque navy square. iPadOS applies the mask.

`./scripts/build-icon.sh` creates native catalog sizes, universal welcome artwork,
and the macOS `.icns`. `scripts/build-icon-assets.swift` verifies the iPad master
is opaque and emits iPad PNGs without an alpha channel to avoid a white border.
The packaged SwiftPM Mac app also receives `LooperArtwork.png` in Resources.

## Final Mac prompt (built-in edit)

Precise-object-edit, final Mac Looper icon. Keep the exact circular two-arrow shape,
sharp arrowhead corners, placement and scale. Remove all glowing shade, bloom, halo,
drop shadows, glossy shine, bevel lighting and inflated/plastic effects from both
the cyan arrows and dark tile. Flat clean cyan arrows, approximately #37C9ED, with
crisp sharply defined edges, no white outlines, no gradients inside arrows, no
luminous aura. Quiet near-flat dark navy/charcoal rounded-square tile inspired by
the supplied AM4 icon. True transparent exterior outside the macOS tile. The circle
stays circular and the center stays empty. No knobs, text, waveform or decorations.

## Final iPad prompt (built-in edit)

Create the iPadOS full-bleed version of the approved flat Mac Looper icon. Keep the
same circular cyan arrows, sharp edges, shape, scale, colors and placement. Change
only the background: extend the navy material to all image edges and corners.
Remove the outer rounded-square silhouette, exterior transparency and inset padding;
the canvas is a full opaque navy square so iPadOS can apply its corner mask. No glow,
shade, halo, shine, bevel, shadow, white border, margin, text, knobs or new objects.
