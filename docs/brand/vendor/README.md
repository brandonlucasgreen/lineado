# Vendored brand assets

## Microsoft Fluent Emoji — "Backhand index pointing right"

The app icon is derived from Microsoft's Fluent Emoji — the same family, variant
and construction as Inbox & Chill's ✌️ icon, so the two apps read as siblings.

- **Source:** <https://github.com/microsoft/fluentui-emoji>
- **Asset path:** `assets/Backhand index pointing right/Default/Flat/`
- **Pinned commit:** `1ffb34c752ec` (2026-08-24). The vendored file was checked
  byte-identical on fetch: 1,403 bytes, git blob `02c3bbfbb14a`.
- **Licence:** MIT — see [LICENSE-fluent-emoji](LICENSE-fluent-emoji). Keep it
  shipped alongside the art in any distribution.

| File | Fluent variant | Used for |
|---|---|---|
| `backhand_index_pointing_right_flat_default.svg` | Flat | The app icon |

### How the shipped art is derived

[`../icon.svg`](../icon.svg) inlines the Flat SVG at 640/1024 —
`translate(192,169) scale(20)` from its native 32×32 viewBox — on a rounded
square 824×824 inset at (100,100) with a 185.4 corner radius: Apple's macOS icon
grid, identical to Inbox & Chill's.

The one difference from I&C is the vertical offset: 169, not 192. The 👉 is
drawn low within Fluent's 32×32 canvas, so I&C's placement left it 23px below
the squircle's centre. Measured on the rendered ink (2026-10-21), it is now
centred to within a pixel both ways.

Recoloured, by Brandon's call (2026-10-21), from Fluent's yellow on Inbox &
Chill's plum to **silver over black**, to sit near Linear's palette:

| Part | Fluent original | Lineado |
|---|---|---|
| Hand body | `#FFC83D` | `#F6F7F9` → `#C6CAD1`, a gentle top-to-bottom sheen |
| Shading strokes | `#D67D00` | `#91979F` |
| Ground | — (I&C: plum) | `#1E1F23` → `#0A0A0C` |

Brightened a little on 2026-10-21 (Brandon: the grey should be *a bit*
brighter) — body and strokes lifted by the same amount, so the shading keeps
its contrast. The two-tone structure is kept exactly: the three shading strokes are what keep
the fingers distinct, and they survive down to 16px.

Rendered into `Sources/App/Resources/Assets.xcassets/AppIcon.appiconset/` with:

```bash
for s in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $s -h $s docs/brand/icon.svg \
    -o Sources/App/Resources/Assets.xcassets/AppIcon.appiconset/icon_$s.png
done
```

### Why not the menu bar's SF Symbol

The menu bar glyph is the SF Symbol `hand.point.right`. Apple's SF Symbols licence
does not permit symbols in app icons or logos, so the app icon cannot reuse it.
Fluent is MIT, which permits exactly this. (Inbox & Chill also derives its menu
bar glyphs from Fluent. Lineado could follow, but the SF Symbol is a native
template image and needs no asset pipeline.)
