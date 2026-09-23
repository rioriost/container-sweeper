# Container Sweeper app icon

Generated on September 23, 2026 with the explicitly selected **gpt-image-2** model through the ImageGen skill's API/CLI workflow (high quality, 1024 × 1024, PNG). No reference image was used.

- Master artwork: [container-sweeper-icon.png](container-sweeper-icon.png)
- Exact prompt: [container-sweeper-icon.prompt.txt](container-sweeper-icon.prompt.txt)
- Packaged macOS icon: [AppIcon.icns](../../Packaging/AppIcon.icns)

Rebuild the ICNS size representations with `python3 scripts/build-icon.py`. This only resamples and packages the artwork; it does not regenerate it. Ordinary app/release builds copy the checked-in ICNS into the bundle, and archive verification checks that the resource matches the source.

The full-bleed square master is retained without an artificial rounded-corner mask. This project keeps a flattened ICNS for its existing macOS bundle workflow; it does not claim layered Icon Composer or custom dark/tinted variants. The artwork uses an original container/brush motif without Apple or Docker branding.

Design evidence: [Apple App icons HIG](https://developer.apple.com/design/human-interface-guidelines/app-icons), retrieved September 23, 2026. Applied guidance: a simple centered concept, clear edges, no nonessential text, and recognizability at small sizes. Raster output was explicitly requested; no Apple design assets are redistributed.

Verification: decoded all ICNS representations with `iconutil`; inspected the 64px representation (32pt @2x). In the signed 0.2.0 (2) app on macOS 27.0, the native About panel displays this icon with the system's rounded shape. Other OS versions and alternate icon appearances were not visually tested.
