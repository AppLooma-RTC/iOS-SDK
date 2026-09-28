# Changelog

## Unreleased

- Video enhancement: `AppEngine.setVideoEnhance(AppVideoEnhance(beauty:lowLight:sharpen:warmth:))` (nil turns it off; `.portrait` preset). Core Image on the camera frames before encoding: exposure and shadow lift for low light, noise reduction blend for beauty, luminance sharpening, temperature for warmth.
- Clear Voice: `AppAudioOptions.noiseSuppressionMode` (`AppNoiseSuppression.standard` default, `.clear`, `.off`). `.clear` uses the voice-chat audio session mode in every scenario; `AppEngine.showMicrophoneModes()` opens the system Voice Isolation picker (iOS 15+), `AppEngine.isVoiceIsolationActive` reports it.
- Audience latency: `AppEngineOptions.audienceLatency` (`.ultraLow` default, `.low`, `.standard`), applied only while audience. No receive-buffer control on iOS: `.low` behaves like `.ultraLow`; `.standard` turns on the `.videoLowQuality` subscribe fallback unless the app set one.
- Codec detection: `AppEngine.getSupportedVideoCodecs()` returns `AppVideoCodecCapability` (mime, hardware, encoder, decoder) for VP8, VP9, H.264 and, where VideoToolbox supports it, H.265.

## 0.5.6 — 2026-09-28

- Cloud proxy for restrictive networks: `AppEngineOptions.cloudProxy` (`AppCloudProxy.auto` default, `.forceTls443`, `.off`). `.forceTls443` joins with relay-only transport through AppLooma's relay on TLS 443; `.auto` retries a join once that way when the direct join fails with a connection or network timeout, and logs it. New `AppEngineDelegate.appEngine(_:proxyStateChanged:autoRetry:)`, `AppProxyState` (`.direct`, `.connecting`, `.connected`) and `AppEngine.proxyState`.
- Pre-call network test: `startNetworkTest(serverUrl:token:completion:)` / `stopNetworkTest()`, a separate ~5 s connection (nothing published, 10 s timeout) returning `AppNetworkTestResult` with `AppNetworkQuality`. Quality only on iOS for now (`rttMs`/`jitterMs` -1, loss 0). No echo test.
- Network fallback: `setRemoteSubscribeFallback(_:)` / `setLocalPublishFallback(_:)` with `AppFallbackOption` (`.none`, `.videoLowQuality`, `.audioOnly`); poor or lost for about 4 s falls back, good for about 10 s restores. New `appEngine(_:fallbackStateChanged:isLocal:)`. Local `.videoLowQuality` republishes the camera at 30 % bitrate.
- Device tuning: the server's per-device video config (`forceCodec`, `preferCodec`, `maxHeight`, `maxFps`, `maxBitrateKbps`, `disableSimulcast`, `denyHardware` mapped to the next safer codec) is cached on the device, applied at join and refreshed in the background (3 s timeout, ETag and ttl) for the next join.

## 0.5.5 — 2026-09-27

- Remote diagnostics: the SDK keeps its recent log lines and a stats snapshot every 10 s in memory (no audio, video or messages) and uploads them, scrubbed of names, metadata, user ids, tokens and URL parameters, after a call with a problem (codec fallback, a viewer reporting no picture, join failure, 3 or more reconnects), when support turned collection on for the device or project, or on the new `AppEngine.uploadDiagnostics(reason:)`. Opt out with `AppEngineOptions(remoteDiagnostics: false)`. Kept 14 days.
- `AppEngineOptions.region` (`AppRegion`: `.auto` default, `.bd`, `.in`, `.sa`, `.sg`, `.us`). Preparation for multi-region: today every region connects to the same server URL your token endpoint returns. Sent with anonymous device reports and logged on join.
- Token renewal: `AppEngineDelegate.appEngine(_:tokenWillExpire:)` fires about 30 s before the join token's `exp` (immediately when less is left), and `AppEngine.renewToken(_:)` stores the new token for the SDK's own later calls and re-arms the reminder. The live connection's credential is refreshed by the media server while connected.
- Not yet on iOS: network/echo test and subscribe/publish fallback options (available on other platforms).

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
