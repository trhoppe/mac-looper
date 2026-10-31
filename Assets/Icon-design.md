# Mac Looper app icon

Source: `/Users/thoppe/Git/mac-looper/Assets/AppIcon.png` (1024 × 1024, transparency preserved).
Edited with the built-in image generation tool to remove the waveform and retain the cyan-blue loop arrows.
`./scripts/build-icon.sh` produces all standard macOS icon sizes and `build/AppIcon.icns`.
`./scripts/build-app.sh` bundles the icon in `build/Mac Looper.app` and sets `CFBundleIconFile`.

## Final edit prompt

Use case: precise-object-edit. Edit target: the attached existing app icon. Remove only the entire cyan audio waveform / equalizer bars and dots from the center of the loop symbol. Fill that area seamlessly with the same dark midnight navy tile background and subtle lighting. Keep the two cyan-blue circular loop arrows EXACTLY as they are: same shape, position, size, arrowheads, bevel, glow, materials, color, shadows and highlights. Preserve the rounded-square tile, its edges, framing, and transparent pixels outside the tile. The finished Mac Looper icon must consist only of the cyan loop arrows on the dark rounded-square tile, with a completely empty clean dark center. No waveform, no dots, no bars, no text, no additional objects. Preserve existing transparency.
