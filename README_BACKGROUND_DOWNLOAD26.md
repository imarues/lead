# Continue file downloads in the background — iOS 26+

Kira → Messages → Continue downloading in background is a standalone, on-demand
feature. Start a document download in a chat, open this option while that download
is in progress, and select the filename. This explicit action submits a system
BGContinuedProcessingTask; the menu displays the request/running/finished state.
The system may display real progress on its own Live Activity. Tap the option
again to end background processing. The original Telegram transfer is not
forcibly cancelled by Kira.

- No silent music, audio-session changes, or separate widget.
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
- Older iOS releases show that the feature requires iOS 26; other features remain
  unchanged. WARP remains included by the normal main Build workflow.

## Packaging

The host IPA **must** declare its bundle-ID-prefixed
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
- iOS 15–25: ensure the option reports the limitation without crashing.
- Re-signing must preserve the prepared plist and correctly sign all extensions.
