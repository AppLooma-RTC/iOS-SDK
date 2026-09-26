# Changelog

## 0.5.1

- `AppVideoConfig.degradation` — `.keepResolution` / `.keepFramerate` / `.balanced` / `.auto` (what the encoder gives up first under pressure), applied through the engine's publish defaults; `AppVideoConfig.minBitrate` (reserved — the engine exposes no per-sender floor on iOS yet).
- Default bitrate caps raised when `maxBitrate` is 0: 4 Mbps at 1080p, 2.2 Mbps at 720p (was 3 / 1.7). New `height: 1440` preset (2560×1440, 5 Mbps, 30 fps).
- `AppVideoCodec.h265` — hardware on every iPhone since the 7, with the VP8 backup layer kept; `AppVideoCodec.av1` falls back to `.auto` with a warning (no iPhone encodes AV1 in hardware).
- `appEngine(_:videoQualityChanged:)` — `AppVideoQualityInfo(width, height, fps, bitrateKbps, layer, reason)` for your own camera, from sender statistics, whenever the layer, size or reason changes.
