# InstaFakeCam — independent Instagram tweak prototype

A standalone, opt-in Instagram iOS video-call virtual-camera experiment kept on the **insta** branch of imarues/lead. The original Telegram/Lead tweak and its compiled-lead branch are untouched.

## Current implementation (0.2.0 — post-test safety fix)

- Intercepts `IGDirectThreadCallButtonsCoordinator`’s two video-call button handlers on supported Instagram builds.
- Displays **Normal video call / Fake my camera / Fake both cameras** before dialing.
- Uses **PHPicker / Photos gallery**, filtered to videos only, and copies imported clips to Instagram's Documents/InstaFakeCam folder.
- Wraps `AVCaptureVideoDataOutput`’s sample-buffer delegate and substitutes video frames while virtual mode is enabled. Keeps original camera timestamps/format. The actual result **depends on Instagram’s capture path**; this is not yet verified in a live Instagram call.
- Replaces the on-screen area where the other participant's video would normally appear **locally only** in dual mode. It does NOT change the real remote participant's camera/feed.
- Waits for Instagram's answered-call indication (when exposed by its session class) and checks that the visible 'Calling...' screen has cleared before starting the selected clip. At the clip's duration, requests native hang-up and falls back to the red End Call UI control if needed.
- **Fail-closed:** keeps blocking/replacing live camera frames while the fake clip is armed, even if the clip is finished or decoding fails. Regular capture passes through only after native call end.

## Important limitations / truth in advertising

- **Connection gating is version-dependent**: uses the legacy Instagram `IGVideoCallSession.isAnswered` indicator plus participant-join and 'Calling...' UI checks. These selectors are not confirmed for the installed Sparkle Instagram version; an updated call-state hook could still be required.
- **Audio is NOT replaced**; the call continues using the normal microphone. Video-file audio does not transmit yet.
- **Outgoing video injection has not been verified on a device**. If the client uses a non-AVCaptureVideoDataOutput path, this implementation will not replace the video sent to the recipient.
- The dual-video preview is an overlay on *your device*, not a remote-camera modification. Its placement requires validation on the target Instagram version.
- Auto-hang-up first calls a known `IGVideoCallManager` method and falls back to the accessible/recognizable red hang-up button; neither method is guaranteed on all Instagram builds. Camera replacement remains active until confirmed teardown.
- Avoid using this on sensitive calls or presenting prerecorded footage as live without the other participant's knowledge.
- Audio remains microphone-only. Use a second consenting test account to verify start timing and the actual video received.

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
