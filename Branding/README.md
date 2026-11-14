# Paper Library app icon

The master artwork is [AppIcon.png](AppIcon.png), a square 1254-pixel PNG with transparency, generated with the built-in imagegen tool on 2026-11-14. It represents stacked research papers and a red bookmark on a blue rounded tile. The original generated file is preserved separately; builds use this workspace copy.

Regenerate the native multi-resolution icon with:

```sh
bash Scripts/build-icon.sh
```

This uses macOS `sips` to resize the master without removing its alpha channel and `iconutil` to assemble the ten standard 1×/2× representations, from 16 to 1024 pixels. The generated [AppIcon.icns](../PaperLibrary/Resources/AppIcon.icns) is included in Xcode's resources phase and copied by `Scripts/build-app.sh` before signing. `CFBundleIconFile` identifies it in the app's Info.plist. The SwiftPM executable excludes this resource because the packaging script places it directly in the macOS application bundle.

## Update verification

Version 0.3.1, build 4, was packaged on 2026-11-14. Configuration/syntax validation and Xcode Debug/Release builds passed. Unpacking the ICNS confirmed all ten correctly sized RGBA representations; the 256-pixel rendition was visually inspected. The icons in both Xcode bundles and the packaged release matched the source ICNS byte for byte. `codesign --verify --deep --strict` passed for `build/release/Paper Library.app`. The existing functionality tests were not rerun for this image and packaging change. Finder/Dock rendering was not interactively reviewed.

Build logs: `/tmp/paperlibrary-icon-debug.log`, `/tmp/paperlibrary-icon-release.log`, `/tmp/paperlibrary-icon-packaging.log`.

## Generation prompt

```text
Use case: logo-brand
Asset type: production macOS application icon for Paper Library, a local research-paper library and PDF reader.
Primary request: create one polished, distinctive app icon representing a small organized stack of academic papers with a folded page corner and a single bookmark.
Style/medium: refined native macOS icon, simple sculpted forms, restrained depth, crisp edges, subtle material shading, high contrast and recognizable at 16 pixels.
Composition/framing: one centered mark inside a rounded-square tile, square canvas, generous consistent safe margin; the tile fills about 82 percent of the canvas width. Actual transparent pixels outside the rounded-square tile, including its corners. No surrounding scene or presentation mockup.
Text: none.
Constraints: deliver only the finished icon artwork, no letters, no words, no watermark, no decorative border, no additional logos or symbols, no grid of variants. Keep the page silhouette and bookmark clear at small Dock and Finder sizes.
```
