# TetherShot marketing assets

- `app-icon.png` — clean application icon.
- `app-icon-transparent.png` — app icon with transparent rounded corners (1024×1024).
- `logo-transparent-512.png` — transparent logo at 512×512.
- `app-screenshot.png` — native app window (legacy).
- `product-hunt/01-overview.png` — primary 1270×760 launch gallery image.
- `product-hunt/02-native-app.png` — dashboard launch gallery image.
- `product-hunt/03-local-first.png` — privacy/workflow launch gallery image.
- `product-hunt/thumbnail-240.png` — 240×240 Product Hunt thumbnail.

Regenerate gallery PNGs from the HTML sources:

```bash
./marketing/product-hunt/render.sh
```

The HTML cards live beside the PNGs and use `shared.css` plus local `app-icon.png` and `capture-beam.png`.
