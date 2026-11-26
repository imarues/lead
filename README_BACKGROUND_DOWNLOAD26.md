# Continue file downloads in the background — iOS 15+

Kira → Messages → Continue downloading in background is a standalone, on-demand
feature. Start a document download in a chat, open this option while that download
is in progress, and select the filename. On iOS 26+, this explicit action submits a
system BGContinuedProcessingTask; the menu displays the request/running/finished
state. The system may display real progress on its own Live Activity. On iOS 15–18
(and any supported release before iOS 26), the option instead starts experimental
silent background audio. Tap the option
again to end background processing. The original Telegram transfer is not
forcibly cancelled by Kira.

- On iOS 26+, no silent music, audio-session changes, or separate widget.
- On older releases, a looped in-memory silent PCM track uses the host's existing
  audio background mode. It is only active for the explicitly selected transfer,
  and stops on completion, cancellation, 120 seconds without verified progress,
  interruption, or audio-session changes. No microphone or external audio asset.
  This is an experimental workaround, not a guaranteed background transfer API;
  it may use extra battery, and iOS may suspend the app anyway. The app-store
  background-audio rules may restrict this use.
- The tracker uses actual document metadata, unique MTProto byte ranges (including
  CDN redirect aliases), and validated MediaBox file maps when available.
- During the explicitly requested task, only a network worker recently observed
  fetching the selected document is allowed to defer a background pause; stop,
  reconnect, normal foreground behavior and unrelated network connections remain
  under the host application's control.
- iOS may deny, queue, terminate or interrupt tasks. A task ends on completion,
  user cancellation, expiration, or lack of verified progress. This is an
  experimental integration; it must be tested on a real device. The Rust MTProto
  engine is not supported. Some already buffered/restarted files may not have
  identifiable metadata or complete tracked ranges. No progress is fabricated.
- WARP remains included by the normal main Build workflow.

## Packaging

For the older-iOS fallback the host IPA must contain `audio` in
`UIBackgroundModes`. For iOS 26+, the host IPA **must** declare its bundle-ID-prefixed
`BGTaskSchedulerPermittedIdentifiers` wildcard
`<bundle-id>.kira.download.*`. The updated `tools/inject_ipa.py` adds it,
preserving existing IDs and modes. If the signer changes the bundle ID, the
permitted identifier must be adjusted to the final signed bundle ID.

For the provided VoidGram build with existing KiraAdd.dylib:
```sh
python3 tools/inject_ipa.py "Telegram_CrashFix.ipa" --dylib packages/Kira.dylib --remove KiraAdd.dylib -o "Telegram-Kira.ipa"
```

Sign the entire resulting IPA with your normal signing tool; do not inject Kira
a second time. The separate Arabic localization dylib must not be replaced.
The source integration compiles against the project's existing older iOS SDK
by resolving the new public API at runtime.

## Device acceptance checklist
- iOS 26+ with standard MTProto mode: start a large named document, select it,
  wait for Running, leave the app for several minutes and confirm real bytes
  continue increasing.
- Test a resumed file, CDN transfer, downloads via proxy, completion, system
  cancellation, network interruption, return to foreground and normal calls.
- iOS 15–18: choose an active download, lock the screen or switch apps for several
  minutes, verify actual byte progress and check that silent playback stops on
  completion, cancellation, interruption and stalled transfers. Test existing
  music, calls, Bluetooth and the absence of audio background mode.
- Re-signing must preserve the prepared plist and correctly sign all extensions.
