// Kira Ogg codec support. stb_vorbis is permissively licensed and vendored
// with the original license in codec/stb_vorbis.c.
#import "KiraOggSupport.h"
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wconversion"
#include "codec/stb_vorbis.c"
#pragma clang diagnostic pop

static uint64_t kiraReadLE64(const uint8_t *b) {
    uint64_t result = 0;
    for (int i = 7; i >= 0; --i) result = (result << 8) | b[i];
    return result;
}
static void kiraWriteLE16(uint8_t *b, uint16_t n) {
    b[0] = (uint8_t)n;
    b[1] = (uint8_t)(n >> 8);
}
static void kiraWriteLE32(uint8_t *b, uint32_t n) {
    for (int i = 0; i < 4; ++i) b[i] = (uint8_t)(n >> (i * 8));
}

BOOL KiraOggOpusDuration(NSURL *url, NSInteger *duration) {
    if (!url.isFileURL) return NO;
    FILE *f = fopen(url.path.fileSystemRepresentation, "rb");
    if (!f) return NO;
    BOOL opus = NO, valid = YES;
    uint16_t preSkip = 0;
    uint64_t lastGranule = 0;
    NSInteger pages = 0;
    uint8_t header[27], segments[255], body[65025];
    while (pages++ < 1000000) {
        size_t count = fread(header, 1, sizeof(header), f);
        if (count == 0) break;
        if (count != sizeof(header) || memcmp(header, "OggS", 4) ||
            header[4] != 0) { valid = NO; break; }
        uint8_t segmentCount = header[26];
        if (fread(segments, 1, segmentCount, f) != segmentCount) {
            valid = NO; break;
        }
        size_t bodyLength = 0;
        for (int i = 0; i < segmentCount; ++i) bodyLength += segments[i];
        if (bodyLength > sizeof(body) ||
            fread(body, 1, bodyLength, f) != bodyLength) {
            valid = NO; break;
        }
        if (pages == 1 && bodyLength >= 19 &&
            memcmp(body, "OpusHead", 8) == 0) {
            opus = YES;
            preSkip = (uint16_t)(body[10] | (body[11] << 8));
        }
        uint64_t granule = kiraReadLE64(header + 6);
        if (granule != UINT64_MAX && granule > lastGranule) {
            lastGranule = granule;
        }
    }
    if (pages >= 1000000) valid = NO;
    fclose(f);
    if (!valid || !opus || lastGranule <= preSkip) return NO;
    double seconds = ((double)(lastGranule - preSkip)) / 48000.0;
    if (!isfinite(seconds) || seconds <= 0 || seconds > 172800) return NO;
    if (duration) *duration = MAX((NSInteger)1, (NSInteger)llround(seconds));
    return YES;
}

NSURL *KiraDecodeOggVorbisToWAV(NSURL *url, NSString *directory) {
    if (!url.isFileURL || !directory.length) return nil;
    int decodeError = 0;
    stb_vorbis *decoder = stb_vorbis_open_filename(
        url.path.fileSystemRepresentation, &decodeError, NULL);
    if (!decoder) return nil;
    stb_vorbis_info info = stb_vorbis_get_info(decoder);
    int channels = info.channels;
    uint32_t sampleRate = (uint32_t)info.sample_rate;
    if (channels < 1 || channels > 2 || sampleRate < 8000 || sampleRate > 192000) {
        stb_vorbis_close(decoder);
        return nil;
    }
    NSString *path = [directory stringByAppendingPathComponent:@"decoded.wav"];
    FILE *out = fopen(path.fileSystemRepresentation, "wb");
    if (!out) { stb_vorbis_close(decoder); return nil; }
    uint8_t riff[44] = {0};
    BOOL ok = fwrite(riff, 1, sizeof(riff), out) == sizeof(riff);
    const int sampleFrames = 2048;
    int16_t *pcm = (int16_t *)calloc(sampleFrames * channels, sizeof(int16_t));
    uint64_t dataBytes = 0;
    if (!pcm) ok = NO;
    while (ok) {
        int frames = stb_vorbis_get_samples_short_interleaved(
            decoder, channels, pcm, sampleFrames * channels);
        if (frames <= 0) break;
        size_t bytes = (size_t)frames * channels * sizeof(int16_t);
        if (dataBytes + bytes > 0x7fffffffU || fwrite(pcm, 1, bytes, out) != bytes) {
            ok = NO; break;
        }
        dataBytes += bytes;
    }
    if (stb_vorbis_get_error(decoder) != VORBIS__no_error) ok = NO;
    if (!dataBytes) ok = NO;
    free(pcm);
    stb_vorbis_close(decoder);
    if (ok) {
        memcpy(riff, "RIFF", 4);
        kiraWriteLE32(riff + 4, (uint32_t)(36 + dataBytes));
        memcpy(riff + 8, "WAVEfmt ", 8);
        kiraWriteLE32(riff + 16, 16);
        kiraWriteLE16(riff + 20, 1);
        kiraWriteLE16(riff + 22, (uint16_t)channels);
        kiraWriteLE32(riff + 24, sampleRate);
        kiraWriteLE32(riff + 28, sampleRate * channels * 2);
        kiraWriteLE16(riff + 32, (uint16_t)(channels * 2));
        kiraWriteLE16(riff + 34, 16);
        memcpy(riff + 36, "data", 4);
        kiraWriteLE32(riff + 40, (uint32_t)dataBytes);
        ok = fseek(out, 0, SEEK_SET) == 0 &&
             fwrite(riff, 1, sizeof(riff), out) == sizeof(riff);
    }
    if (fclose(out) != 0) ok = NO;
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}
