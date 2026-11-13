#import <Foundation/Foundation.h>

// Detect valid Opus-in-Ogg and derive duration from page granule positions.
FOUNDATION_EXPORT BOOL KiraOggOpusDuration(NSURL *url, NSInteger *duration);
// Stream Vorbis-in-Ogg to 16-bit PCM WAV for the iOS M4A exporter.
FOUNDATION_EXPORT NSURL *KiraDecodeOggVorbisToWAV(NSURL *url, NSString *directory);
