# InstaFakeCam — independent Instagram tweak prototype

A standalone, opt-in Instagram iOS video-call virtual-camera experiment kept on the **insta** branch of imarues/lead. The original Telegram/Lead tweak and its compiled-lead branch are untouched.

## Current implementation (0.1.0)

- Intercepts `IGDirectThreadCallButtonsCoordinator`’s two video-call button handlers on supported Instagram builds.
- Displays **Normal video call / Fake my camera / Fake both cameras** before dialing.
- Uses the system document picker (video files) and keeps imported clips in Instagram's Documents/InstaFakeCam folder.
- Wraps `AVCaptureVideoDataOutput`’s sample-buffer delegate and substitutes video frames while virtual mode is enabled. Keeps original camera timestamps/format. The actual result **depends on Instagram’s capture path**; this is not yet verified in a live Instagram call.
- Replaces the on-screen area where the other participant's video would normally appear **locally only** in dual mode. It does NOT change the real remote participant's camera/feed.
- When the outgoing video ends, tries to press Instagram’s accessible End Call control; if the control cannot be identified, displays a manual-hang-up warning.
- Regular camera capture is passed through unchanged when no fake clip is armed.

## Important limitations / truth in advertising

- **Call connection gating is not finished**: playback begins on the first video-capture callback after dialing, possibly **before the callee accepts**. A version-specific Instagram call-state hook is needed to fix this reliably.
- **Audio is NOT replaced**; the call continues using the normal microphone. Video-file audio does not transmit yet.
- **Outgoing video injection has not been verified on a device**. If the client uses a non-AVCaptureVideoDataOutput path, this implementation will not replace the video sent to the recipient.
- The dual-video preview is an overlay on *your device*, not a remote-camera modification. Its placement requires validation on the target Instagram version.
- The auto-hang-up mechanism is best-effort; a non-accessible hang-up button will require finding an Instagram-specific call-end selector.
- Avoid using this on sensitive calls or presenting prerecorded footage as live without the other participant's knowledge.

## Build

`make -C insta clean package FINALPACKAGE=1`

GitHub Actions workflow: **Build Instagram FakeCam** (only for `insta`). It produces `InstaFakeCam.dylib` and an installable jailbreak package; no Instagram IPA is bundled. The file can be injected into a user-supplied, compatible Instagram app.

## Open-source research

Original code written for this branch. Relevant publicly observable approaches:
- [SCInsta](https://github.com/SoCuul/SCInsta) — Instagram Theos tweak structure
- [Sparkle Instagram, CallConfirm](https://github.com/efibalogh/sparkle-ig/blob/main/src/Features/Messages/CallConfirm.x) — publicly documented Instagram call button selector names
- [Sparkle Instagram, Video Streamer](https://github.com/efibalogh/sparkle-ig/blob/main/src/Shared/Instants/SPKInstantsVideoStreamer.m) — AVAssetReader-based media substitution architecture
- [VCam tinysweet](https://github.com/tinysweetUwU/vCam-tinysweet) — separate virtual-camera research
- RyukGram's binary is **not** bundled; its proprietary code is **not** copied.

Instagram and related trademarks belong to Meta. This is an independent test project.
