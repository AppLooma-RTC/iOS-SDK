# Changelog

## 0.5.4 — 2026-09-27

- Automatic codec recovery. Viewer side: a subscribed, enabled remote camera that decodes no picture for more than 6 s while its sender has it on is reported to that publisher only, on a reserved internal data topic. Internal topics (prefix `_al.`) are never delivered to the app's message or data callbacks.
- Publisher side: reports from 2 different viewers within 20 s (or from the only other person in a 1:1 call) republish the camera on a safer path: VP8 when it was on another codec, otherwise once more as a single layer. At most once per join.
- New `AppEngineDelegate.appEngine(_:videoCodecFallbackFrom:to:reason:)`; `reason` is `no_frames`, `encoder_error` or `viewers_cannot_decode`. `publishedCodec` reflects the switch.
- Anonymous device reports (model identifier, OS and SDK version, codec and outcome; no user, identity or IP address) are sent on a codec fallback or a viewer report, so the platform can tune settings per device model. Fire-and-forget; failures are silent.
- Fixed: after a codec-recovery republish the camera came back on the front camera; it now keeps the camera that was in use.

## 0.5.3

- UIKit: loudspeaker button on the live stream (host and viewer), voice room and call screens. Speaker icon when on, speaker-off when on the earpiece; while a Bluetooth or wired headset carries the audio it shows headphones, does nothing and reads "Headset in use". VoiceOver labels "Loudspeaker on"/"Loudspeaker off". Starts on the loudspeaker for live, voice rooms and video calls, on the earpiece for voice calls (iPad stays on the loudspeaker).

## 0.5.2

- `AppVideoMode` on `AppVideoConfig.mode`: `.stableHd` (new default), `.ultraHd4k` (premium, opt-in), `.adaptive` (the previous behaviour). `.stableHd` publishes one 1080p30 layer at 3.5 Mbps (no simulcast), keeps resolution under pressure and turns adaptive stream off so receivers keep the full picture.
- `.ultraHd4k`: 2160p30 (3840x2160), one layer, H.265 at 16 Mbps (25 Mbps if H.264 is forced), resolution kept. `AppEngine.isUltraHdSupported()` — true on every supported iPhone.
- Fields set explicitly still win over the mode. `AppVideoConfig.height` now defaults to 0 (= by mode) and `simulcast` to `nil` (= by mode); `degradation: .auto` means `.keepResolution` outside `.adaptive`. `height: 2160` is a new preset.
- UIKit: the call screen's quality badge no longer shows a pixel count — "HD" normally, "Weak network" after five seconds of a bandwidth-limited camera or heavy audio loss. Call and live screens no longer force 720p.

## 0.5.1

- `AppVideoConfig.degradation` — `.keepResolution` / `.keepFramerate` / `.balanced` / `.auto` (what the encoder gives up first under pressure), applied through the engine's publish defaults; `AppVideoConfig.minBitrate` (reserved — the engine exposes no per-sender floor on iOS yet).
- Default bitrate caps raised when `maxBitrate` is 0: 4 Mbps at 1080p, 2.2 Mbps at 720p (was 3 / 1.7). New `height: 1440` preset (2560×1440, 5 Mbps, 30 fps).
- `AppVideoCodec.h265` — hardware on every iPhone since the 7, with the VP8 backup layer kept; `AppVideoCodec.av1` falls back to `.auto` with a warning (no iPhone encodes AV1 in hardware).
- `appEngine(_:videoQualityChanged:)` — `AppVideoQualityInfo(width, height, fps, bitrateKbps, layer, reason)` for your own camera, from sender statistics, whenever the layer, size or reason changes.
