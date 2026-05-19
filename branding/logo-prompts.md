# Brave-Portable-Updater - Logo Prompts

Five prompts for generating brand artwork. Run each through your preferred image model; pick the one that fits best, then drop the result into the repo root as `logo.png` (square) and `banner.png` (wide). Update README badges/headers accordingly.

Color palette suggestion: Brave-adjacent orange (`#FB542B`) with a refresh / cycle accent in cool blue or teal (`#5391FE`) on a deep neutral background. Avoid leaning on the literal Brave lion (trademark).

---

## 1. Minimal

```
A minimalist flat vector icon representing a software updater for a portable
browser. Geometric shapes only: a stylized circular arrow forming a refresh
loop, with a small shield silhouette nested inside. Solid colors, no
gradients, two-tone palette (warm orange #FB542B and cool slate blue
#5391FE) on a deep neutral background. Centered composition, 1:1 aspect
ratio, no text, no shadows, no glow effects. Modern, clean, suitable for
a small Windows app icon at 32x32 to 256x256.

Background/output requirements: The final image must be a true transparent
PNG in RGBA format with a real alpha channel. Everything outside the icon
must be fully transparent, alpha = 0. Do not render a checkerboard pattern.
Do not render a white, gray, black, colored, or textured background. Do not
simulate transparency. Only the icon should contain visible pixels. If the
generated image includes a checkerboard or any visible background, remove it
with image processing and export a corrected transparent PNG artifact.

Final output: 1024x1024 PNG, RGBA, true transparent background, alpha
channel enabled, no checkerboard, no solid background, no watermark, no
text, only the main icon visible.
```

## 2. App icon

```
A modern Windows 11-style app icon for a portable browser updater. A
glossy rounded square tile (8-12 px radius equivalent, never fully
rounded or pill-shaped) in deep charcoal with a subtle internal bevel.
On top: a thick circular refresh arrow in vivid orange (#FB542B) wrapping
around a small lock icon in white. Slight depth from a soft drop shadow
inside the tile only. No external glow. 1:1 aspect ratio, sharp at small
sizes.

Background/output requirements: The final image must be a true transparent
PNG in RGBA format with a real alpha channel. Everything outside the tile
must be fully transparent, alpha = 0. Do not render a checkerboard pattern.
Do not render a white, gray, black, colored, or textured background. Do not
simulate transparency. Only the tile should contain visible pixels. If the
generated image includes a checkerboard or any visible background, remove it
with image processing and export a corrected transparent PNG artifact.

Final output: 1024x1024 PNG, RGBA, true transparent background, alpha
channel enabled, no checkerboard, no solid background, no watermark, no
text, only the main tile visible.
```

## 3. Wordmark

```
A horizontal wordmark logo reading "Brave-Portable-Updater" in a clean,
geometric sans-serif typeface (Inter, Geist, or similar). To the left of
the text, a small mark: a 24 px circular refresh arrow in vivid orange
(#FB542B). Text in soft off-white (#F2F2F2). Tight letter-spacing. 4:1
aspect ratio. No tagline, no underline, no decorative flourishes.

Background/output requirements: The final image must be a true transparent
PNG in RGBA format with a real alpha channel. Everything outside the mark
and text must be fully transparent, alpha = 0. Do not render a checkerboard
pattern. Do not render a white, gray, black, colored, or textured
background. Do not simulate transparency. Only the wordmark should contain
visible pixels. If the generated image includes a checkerboard or any
visible background, remove it with image processing and export a corrected
transparent PNG artifact.

Final output: 2048x512 PNG, RGBA, true transparent background, alpha
channel enabled, no checkerboard, no solid background, no watermark, only
the wordmark visible.
```

## 4. Emblem

```
A heraldic emblem-style mark for a software updater. A circular badge
with a thin double-stroke outline in orange (#FB542B). Inside: an upward
chevron flanked by two small dots, evoking a "level up" or "update
applied" motif. Centered composition, 1:1 aspect ratio. Use only orange,
charcoal, and off-white. No text inside the emblem, no scrollwork, no
gradients.

Background/output requirements: The final image must be a true transparent
PNG in RGBA format with a real alpha channel. Everything outside the emblem
must be fully transparent, alpha = 0. Do not render a checkerboard pattern.
Do not render a white, gray, black, colored, or textured background. Do not
simulate transparency. Only the emblem should contain visible pixels. If
the generated image includes a checkerboard or any visible background,
remove it with image processing and export a corrected transparent PNG
artifact.

Final output: 1024x1024 PNG, RGBA, true transparent background, alpha
channel enabled, no checkerboard, no solid background, no watermark, no
text, only the emblem visible.
```

## 5. Abstract

```
An abstract iconographic representation of "portable browser refresh".
Three concentric circular arcs in graduated orange tones (deep #C7401E,
mid #FB542B, light #FFB89A), arranged as a stylized download/refresh
spiral, with a small solid white dot at the spiral's terminus. 1:1 aspect
ratio, asymmetric tension, modern and slightly dynamic. No literal
browser, no literal arrow, no text.

Background/output requirements: The final image must be a true transparent
PNG in RGBA format with a real alpha channel. Everything outside the
spiral must be fully transparent, alpha = 0. Do not render a checkerboard
pattern. Do not render a white, gray, black, colored, or textured
background. Do not simulate transparency. Only the spiral should contain
visible pixels. If the generated image includes a checkerboard or any
visible background, remove it with image processing and export a
corrected transparent PNG artifact.

Final output: 1024x1024 PNG, RGBA, true transparent background, alpha
channel enabled, no checkerboard, no solid background, no watermark, no
text, only the spiral visible.
```

---

## Integration checklist

After picking a winner:

- [ ] Save the chosen logo as `logo.png` at repo root (1024x1024, RGBA).
- [ ] Save a wide banner version as `banner.png` at repo root (~2048x512 or 1500x500, RGBA).
- [ ] Reference both in README (`![logo](logo.png)`, optional banner above the badges).
- [ ] Generate a 256x256 `.ico` for any Windows tooling that wants it (e.g. ImageMagick: `magick logo.png -define icon:auto-resize=256,128,64,48,32,16 favicon.ico`).
- [ ] Verify the PNG is actually RGBA, not a flattened white background. Quick check: `magick identify -format "%[channels]\n" logo.png` should print `srgba` or `rgba`.
