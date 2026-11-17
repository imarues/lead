# Snapchat video-call adapter (experimental)

Standalone `Snap.dylib`, built independently from Lead on branch `سناب`.
Inject into the supplied Snapchat Nobel IPA and re-sign it. This library is not a complete IPA and is not a jailbreak bypass.

Video call button: **اتصال طبيعي** calls the original handler; **رفع فيديو** picks and prepares a local movie before placing the outgoing call. Playback waits for Snapchat's native outgoing-connected state. Movie EOF invokes the native session wrapper's `dismissCall`. The app process is never terminated. Camera/mic remain suppressed until the session ends. Normal calls pass through unchanged.

Original video dimensions/orientation are preserved using AVAssetReader video composition. The encoder, network, and recipient determine actual received resolution and bitrate. Audio is decoded to 48 kHz PCM mono (call uplink), resampled to the current hardware format, and substitutes only microphone input. No remote audio capture or recording is included.

## Inspected input

- File: Snapchat_Nobel.ipa
- Display version: 13.68.1; underlying bundle build: 12.81.0.47 (modified package metadata).
- Executable: arm64, LC_ENCRYPTION_INFO_64 cryptid=0.
- Executable SHA-256: 9d5eb01d89e8ebd850c49c98f6f1f5b21db3deb6134e5afd7a72abdbaad43d21
- The uploaded application and its binary are not committed here.

Verified selectors and exact Objective-C signatures:

| Class | Selector | Type |
|---|---|---|
| SCTalkChatSessionImpl | _composerCallButtonsOnStartCallMedia: | v20@0:8i16 |
| SCTCameraServices | cameraProvider:didOutputSampleBuffer: | v32@0:8@16^{opaqueCMSampleBuffer=}24 |
| SCTV3SessionWrapper | _handleStateChange:reason: | v32@0:8@16q24 |
| SCTV3SessionWrapper | dismissCall | v16@0:8 |

Native disassembly confirms Composer call-media values 2/4 map to native video media 2. `SCTCameraServices` forwards CMSampleBuffer to its receiver's `injectFrame:`. Native `SCTV3HeadlessSession sessionWrapper:changedState:reason:` identifies an outgoing connection as local callingState=1 and connecting=false; this adapter uses the same condition.

## Verification and limits

The binary can be statically inspected and compiled in CI. There is no connected iPhone or recipient device in this workspace, so actual outgoing media, button presentation, state timing, and compatibility with the existing Nobel modification require device testing. This is an experimental build, not a claim of tested call delivery. An unsupported selector signature disables custom calls. A four-second media-path watchdog ends a custom call if frame or microphone callbacks are absent.

Device acceptance checks: normal video and voice calls; cancel picker; silent movie; portrait/landscape; accept after 10 seconds (starts at beginning); decline/no answer; hang up mid-movie; movie EOF (both devices leave call); two consecutive selected-video calls. Confirm actual recipient video and audio, not just local preview.
