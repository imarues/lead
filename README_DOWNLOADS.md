# Lead Telegram Download Monitor — downloadtelegram

The base is feature/virtual-media-call-test. This fork preserves the virtual video-call and call-recording code; the source branch is unchanged.

## Implemented

- Tracks successful upload.getFile / upload.getCdnFile MTProto responses, without rewriting Telegram's file payloads.
- Reads Api.Document metadata from normal Telegram responses. A percentage only appears when the document ID and genuine file size are known; otherwise transferred bytes appear.
- Lead > Media: progress switch, experimental background audio switch, and a current-download status row. Both switches start ON for this experimental fork.
- ActivityKit bridge plus a WidgetKit view for iOS 17+ Live Activities / Dynamic Island.
- While downloads are active during backgrounding, tries a looping low-volume/silent WAV audio session and stops when download activity ends or Telegram becomes foreground again. Won't override active playAndRecord calls.

## Important limitations

Silent audio is not a guaranteed supported download background mode. iOS can suspend the app anyway; the App Store may reject this technique. Battery use can increase. The tweak cannot track the Rust MTProto engine. CDN redirects, cached content, and media whose document ID is unavailable may show incomplete or non-percentage data. The download engine is unchanged. This is experimental and has not passed on-device testing.

## Building

GitHub Actions workflow downloads.yml compiles the tweak and companion unsigned widget in branch downloadtelegram. Its artifact includes Lead.dylib, LeadDownloadIsland.appex, and prepare_download_ipa.py.

1. Inject the newly built Lead.dylib into a decrypted Telegram IPA using tools/inject_ipa.py. Make sure the app and its notification extension are injected as appropriate.
2. Embed the widget and the background/audio Live Activity Info.plist declarations:

    python3 tools/prepare_download_ipa.py Telegram-Lead.ipa --widget packages/LeadDownloadIsland.appex --output Telegram-Lead-Downloads-unsigned.ipa

3. Sign the main application AND its nested widget app extension together. The unsigned IPA is not installable as-is, and the island cannot work from the dylib alone.
4. On iOS 17+, open Telegram in MtProtoKit mode, download a file in a channel, and inspect Lead > Media > Current download. Confirm the same file shows in the Dynamic Island or Lock Screen, where available. Switch apps and verify that network bytes continue rising, rather than assuming the silent audio alone proves downloads continue.
5. Test iOS 17 and later, a large document, CDN file, cancellation, incoming call, battery usage, and audio interruptions before shipping.

No claim of successful device validation is made.
