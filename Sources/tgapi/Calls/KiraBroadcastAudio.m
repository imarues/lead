#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ReplayKit/ReplayKit.h>
#import <objc/runtime.h>

// Telegram's broadcast converter reads a single AudioBuffer. Pack planar PCM
// before it reaches that converter so it can use its usual call transport.
static CMSampleBufferRef KiraPackedAudio(CMSampleBufferRef sample) {
    if (!sample || !CMSampleBufferDataIsReady(sample)) return NULL;
    CMAudioFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sample);
    if (!desc) return NULL;
    const AudioStreamBasicDescription *input = CMAudioFormatDescriptionGetStreamBasicDescription(desc);
    if (!input || input->mFormatID != kAudioFormatLinearPCM ||
        !(input->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ||
        input->mChannelsPerFrame < 2) return NULL;

    CMItemCount count = CMSampleBufferGetNumSamples(sample);
    if (count <= 0 || count > INT32_MAX || input->mFramesPerPacket != 1 ||
        !input->mBytesPerFrame || input->mBytesPerFrame > UINT32_MAX / input->mChannelsPerFrame)
        return NULL;
    AudioStreamBasicDescription packed = *input;
    packed.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
    packed.mBytesPerFrame *= packed.mChannelsPerFrame;
    packed.mBytesPerPacket = packed.mBytesPerFrame;
    if (count > UINT32_MAX / packed.mBytesPerFrame) return NULL;

    AVAudioFormat *from = [[AVAudioFormat alloc] initWithStreamDescription:input];
    AVAudioFormat *to = [[AVAudioFormat alloc] initWithStreamDescription:&packed];
    if (!from || !to) return NULL;
    AVAudioPCMBuffer *planes = [[AVAudioPCMBuffer alloc] initWithPCMFormat:from frameCapacity:(AVAudioFrameCount)count];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:to frameCapacity:(AVAudioFrameCount)count];
    if (!planes || !output) return NULL;
    planes.frameLength = (AVAudioFrameCount)count;
    if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, 0, (int32_t)count, planes.mutableAudioBufferList) != noErr)
        return NULL;
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:from toFormat:to];
    if (![converter convertToBuffer:output fromBuffer:planes error:NULL] || output.frameLength != count)
        return NULL;

    const AudioBuffer *audio = &output.audioBufferList->mBuffers[0];
    CMBlockBufferRef data = NULL;
    size_t size = audio->mDataByteSize;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, kCFAllocatorDefault, NULL, 0, size, 0, &data) != noErr)
        return NULL;
    CMSampleBufferRef result = NULL;
    if (CMBlockBufferReplaceDataBytes(audio->mData, data, 0, size) == noErr) {
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, to.formatDescription, count,
            CMSampleBufferGetPresentationTimeStamp(sample), NULL, &result);
    }
    CFRelease(data);
    return result;
}

typedef void (*KiraSampleHandler)(id, SEL, CMSampleBufferRef, RPSampleBufferType);
static KiraSampleHandler originalHandler;

static void KiraProcessSample(id self, SEL cmd, CMSampleBufferRef sample, RPSampleBufferType type) {
    CMSampleBufferRef packed = type == RPSampleBufferTypeAudioApp ? KiraPackedAudio(sample) : NULL;
    originalHandler(self, cmd, packed ?: sample, type);
    if (packed) CFRelease(packed);
}

__attribute__((constructor)) static void KiraInstallBroadcastAudio(void) {
    @autoreleasepool {
        NSDictionary *ext = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSExtension"];
        if (![ext[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.broadcast-services-upload"]) return;
        NSString *name = ext[@"NSExtensionPrincipalClass"];
        Class cls = name.length ? NSClassFromString(name) : Nil;
        SEL selector = @selector(processSampleBuffer:withType:);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) return;
        originalHandler = (KiraSampleHandler)method_getImplementation(method);
        if (!class_addMethod(cls, selector, (IMP)KiraProcessSample, method_getTypeEncoding(method)))
            method_setImplementation(method, (IMP)KiraProcessSample);
    }
}
