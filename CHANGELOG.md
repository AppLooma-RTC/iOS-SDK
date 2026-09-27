# Changelog

## Unreleased

- `AppVideoMode` on `AppVideoConfig.mode`: `.stableHd` (new default), `.ultraHd4k` (premium, opt-in), `.adaptive` (the previous behaviour). `.stableHd` publishes one 1080p30 layer at 3.5 Mbps (no simulcast), keeps resolution under pressure and turns adaptive stream off so receivers keep the full picture.
- `.ultraHd4k`: 2160p30 (3840x2160), one layer, H.265 at 16 Mbps (25 Mbps if H.264 is forced), resolution kept. `AppEngine.isUltraHdSupported()` — true on every supported iPhone.
- Fields set explicitly still win over the mode. `AppVideoConfig.height` now defaults to 0 (= by mode) and `simulcast` to `nil` (= by mode); `degradation: .auto` means `.keepResolution` outside `.adaptive`. `height: 2160` is a new preset.
- UIKit: the call screen's quality badge no longer shows a pixel count — "HD" normally, "Weak network" after five seconds of a bandwidth-limited camera or heavy audio loss. Call and live screens no longer force 720p.

## 0.5.1

- `AppVideoConfig.degradation` — `.keepResolution` / `.keepFramerate` / `.balanced` / `.auto` (what the encoder gives up first under pressure), applied through the engine's publish defaults; `AppVideoConfig.minBitrate` (reserved — the engine exposes no per-sender floor on iOS yet).
- Default bitrate caps raised when `maxBitrate` is 0: 4 Mbps at 1080p, 2.2 Mbps at 720p (was 3 / 1.7). New `height: 1440` preset (2560×1440, 5 Mbps, 30 fps).
- `AppVideoCodec.h265` — hardware on every iPhone since the 7, with the VP8 backup layer kept; `AppVideoCodec.av1` falls back to `.auto` with a warning (no iPhone encodes AV1 in hardware).
- `appEngine(_:videoQualityChanged:)` — `AppVideoQualityInfo(width, height, fps, bitrateKbps, layer, reason)` for your own camera, from sender statistics, whenever the layer, size or reason changes.
