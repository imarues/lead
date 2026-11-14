// Lead call audio capture. Written independently for Lead: no iQTele binary or
// code is linked. Capture is inactive until the user explicitly agrees.
#import "LeadCallAudio.h"
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
extern "C" bool LeadVirtualMediaReplaceMic(AudioBufferList *buffers,
    const AudioStreamBasicDescription *format, UInt32 frames);

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
#include <cmath>
#import <atomic>
#import <cstring>
#import <algorithm>

using std::memory_order_acquire;
using std::memory_order_release;
using std::memory_order_relaxed;

namespace {
static constexpr uint32_t kCapacity = 1 << 18;
struct Ring {
    int16_t samples[kCapacity];
    std::atomic<uint32_t> writeIndex{0};
    std::atomic<uint32_t> readIndex{0};
    std::atomic<uint32_t> sampleRate{48000};
    uint64_t writtenFrames = 0; // writer queue only
    int fd = -1;                // writer queue only
};
static Ring gMic, gRemote;
static std::atomic<bool> gActive{false};
static dispatch_queue_t gWriterQueue;
static dispatch_source_t gWriterTimer;
static NSString *gTemporaryDirectory;
static BOOL gHooksReady = NO;

typedef OSStatus (*RenderProc)(AudioUnit, AudioUnitRenderActionFlags *,
    const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
typedef OSStatus (*SetPropertyProc)(AudioUnit, AudioUnitPropertyID,
    AudioUnitScope, AudioUnitElement, const void *, UInt32);
static RenderProc gOriginalRender = nullptr;
static SetPropertyProc gOriginalSetProperty = nullptr;

struct OutputCallback {
    AURenderCallback original;
    void *context;
    AudioUnit unit;
    AudioStreamBasicDescription format;
};
static OutputCallback gCallbackSlots[128];
static std::atomic<uint32_t> gCallbackCount{0};

static inline bool isCallAudioUnit(AudioUnit unit) {
    if (!unit) return false;
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    AudioComponentDescription d = {};
    return component && AudioComponentGetDescription(component, &d) == noErr &&
        d.componentType == kAudioUnitType_Output &&
        (d.componentSubType == kAudioUnitSubType_RemoteIO ||
         d.componentSubType == kAudioUnitSubType_VoiceProcessingIO);
}

static AudioStreamBasicDescription formatFor(AudioUnit unit, AudioUnitScope scope, UInt32 bus) {
    AudioStreamBasicDescription f = {};
    UInt32 size = sizeof(f);
    if (!unit || AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
               scope, bus, &f, &size) != noErr) return {};
    return f;
}

// This runs on CoreAudio's real-time thread: no locks, allocations, UI or I/O.
static void capture(Ring &ring, const AudioBufferList *abl,
                    UInt32 frames, const AudioStreamBasicDescription &f) {
    if (!gActive.load(memory_order_relaxed) || !abl || !abl->mNumberBuffers ||
        f.mFormatID != kAudioFormatLinearPCM || f.mSampleRate < 8000 ||
        f.mSampleRate > 192000 || !std::isfinite(f.mSampleRate)) return;

    const bool flt = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool signedInt = (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const bool nonInterleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 bits = f.mBitsPerChannel;
    if (!((flt && bits == 32) || (signedInt && (bits == 16 || bits == 32)))) return;
    const AudioBuffer &b = abl->mBuffers[0];
    if (!b.mData) return;
    const UInt32 channels = nonInterleaved ? 1 : std::max((UInt32)1, f.mChannelsPerFrame);
    const UInt32 bytesPerSample = bits / 8;
    const UInt32 maxFrames = b.mDataByteSize / std::max((UInt32)1, channels * bytesPerSample);
    const UInt32 count = std::min(std::min(frames, maxFrames), (UInt32)8192);
    if (!count) return;
    ring.sampleRate.store((uint32_t)round(f.mSampleRate), memory_order_relaxed);

    uint32_t w = ring.writeIndex.load(memory_order_relaxed);
    const uint32_t read = ring.readIndex.load(memory_order_acquire);
    const uint32_t writable = kCapacity - (w - read);
    const uint32_t n = std::min(count, writable);
    for (uint32_t i=0; i<n; i++) {
        float sample=0;
        const uint32_t index=i*channels;
        if (flt) sample=((const float*)b.mData)[index];
        else if (bits==16) sample=((const int16_t*)b.mData)[index] / 32768.f;
        else sample=((const int32_t*)b.mData)[index] / 2147483648.f;
        sample=std::max(-1.f, std::min(1.f, sample));
        ring.samples[(w+i)&(kCapacity-1)] = (int16_t)lrintf(sample*32767.f);
    }
    ring.writeIndex.store(w+n, memory_order_release);
}

static OSStatus leadAudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
             const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *out) {
    OSStatus status = gOriginalRender ? gOriginalRender(unit, flags, time, bus, frames, out) : -1;
    if (status == noErr && bus == 1 && isCallAudioUnit(unit)) {
        AudioStreamBasicDescription f = formatFor(unit, kAudioUnitScope_Output, 1);
        // Replace local microphone samples only during explicitly selected movie playback.
        // Do not leak the real microphone while the movie is preparing or after it ends.
        LeadVirtualMediaReplaceMic(out,&f,frames);
        if(gActive.load(memory_order_relaxed)) capture(gMic,out,frames,f);
    }
    return status;
}

static OSStatus leadOutputCallback(void *opaque, AudioUnitRenderActionFlags *flags,
         const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    OutputCallback *binding = static_cast<OutputCallback *>(opaque);
    if (!binding || !binding->original) return -1;
    OSStatus status = binding->original(binding->context, flags, time, bus, frames, data);
    if (status == noErr && gActive.load(memory_order_relaxed)) {
        if (!binding->format.mSampleRate)
            binding->format = formatFor(binding->unit,kAudioUnitScope_Input,0);
        capture(gRemote,data,frames,binding->format);
    }
    return status;
}

static OSStatus leadAudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property,
       AudioUnitScope scope, AudioUnitElement element, const void *data, UInt32 size) {
    if (!gOriginalSetProperty) return -1;
    if (property == kAudioUnitProperty_SetRenderCallback && element == 0 &&
        size >= sizeof(AURenderCallbackStruct) && data && isCallAudioUnit(unit)) {
        uint32_t index = gCallbackCount.fetch_add(1, memory_order_relaxed);
        if (index < 128) {
            OutputCallback *binding = &gCallbackSlots[index];
            const AURenderCallbackStruct *source =
                static_cast<const AURenderCallbackStruct *>(data);
            binding->original = source->inputProc;
            binding->context = source->inputProcRefCon;
            binding->unit = unit;
            binding->format = {};
            AURenderCallbackStruct wrapped = {leadOutputCallback,binding};
            return gOriginalSetProperty(unit,property,scope,element,&wrapped,sizeof(wrapped));
        }
    }
    return gOriginalSetProperty(unit,property,scope,element,data,size);
}

// Rebind import slots in present/future Mach-O images. There are no global
// behavioral changes unless explicit recording is active. Unwritable image
// pages are left untouched (fail closed instead of risking a crash).
static void bindSection(const section_64 *sec, intptr_t slide,
   const nlist_64 *symbols, const char *strings, const uint32_t *indirect) {
    if (!sec || !symbols || !strings || !indirect) return;
    uintptr_t address=(uintptr_t)(slide+sec->addr);
    uint32_t count=(uint32_t)(sec->size/sizeof(void*));
    uint32_t page=(uint32_t)getpagesize();
    for(uint32_t i=0;i<count;i++) {
        uint32_t index=indirect[sec->reserved1+i];
        if ((index & (INDIRECT_SYMBOL_LOCAL|INDIRECT_SYMBOL_ABS)) != 0) continue;
        const char *name=strings+symbols[index].n_un.n_strx;
        void *replacement=nullptr;
        if (strcmp(name,"_AudioUnitRender")==0) replacement=(void*)&leadAudioUnitRender;
        else if (strcmp(name,"_AudioUnitSetProperty")==0) replacement=(void*)&leadAudioUnitSetProperty;
        if (!replacement) continue;
        void **slot=(void**)(address+i*sizeof(void*));
        if (*slot==replacement) continue;
        uintptr_t start=(uintptr_t)slot & ~((uintptr_t)page-1);
        if (mprotect((void*)start,page,PROT_READ|PROT_WRITE) != 0) {
            if(vm_protect(mach_task_self(),(vm_address_t)start,page,0,
                 VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY) != KERN_SUCCESS) continue;
        }
        *slot=replacement;
    }
}
static void bindImage(const mach_header *header, intptr_t slide) {
    if (!header || header->magic!=MH_MAGIC_64) return;
    const mach_header_64 *h=(const mach_header_64*)header;
    const uint8_t *cursor=(const uint8_t*)h+sizeof(*h);
    const symtab_command *syms=nullptr;
    const dysymtab_command *dys=nullptr;
    const segment_command_64 *linkedit=nullptr;
    const segment_command_64 *segments[32]={};
    uint32_t segmentCount=0;
    for(uint32_t i=0;i<h->ncmds;i++) {
        const load_command *load=(const load_command*)cursor;
        if (load->cmd == LC_SYMTAB) syms=(const symtab_command*)load;
        if (load->cmd == LC_DYSYMTAB) dys=(const dysymtab_command*)load;
        if (load->cmd == LC_SEGMENT_64) {
            const segment_command_64 *seg=(const segment_command_64*)load;
            if (strcmp(seg->segname,SEG_LINKEDIT)==0) linkedit=seg;
            if (segmentCount<32) segments[segmentCount++]=seg;
        }
        cursor+=load->cmdsize;
    }
    if (!syms || !dys || !linkedit) return;
    uintptr_t base=(uintptr_t)(slide+linkedit->vmaddr-linkedit->fileoff);
    const nlist_64 *symbolTable=(const nlist_64*)(base+syms->symoff);
    const char *stringTable=(const char*)(base+syms->stroff);
    const uint32_t *indirect=(const uint32_t*)(base+dys->indirectsymoff);
    for(uint32_t i=0;i<segmentCount;i++) {
        const segment_command_64 *seg=segments[i];
        if (strncmp(seg->segname,"__DATA",6)!=0 &&
            strncmp(seg->segname,"__AUTH",6)!=0) continue;
        const section_64 *sect=(const section_64*)((const uint8_t*)seg+sizeof(*seg));
        for(uint32_t k=0;k<seg->nsects;k++) {
            uint32_t type=(sect[k].flags & SECTION_TYPE);
            if (type==S_LAZY_SYMBOL_POINTERS || type==S_NON_LAZY_SYMBOL_POINTERS)
                bindSection(&sect[k],slide,symbolTable,stringTable,indirect);
        }
    }
}

static void wavHeader(int fd, uint64_t frames, uint32_t rate) {
    if(fd<0)return;
    unsigned char header[44]={};
    uint32_t bytes=(uint32_t)std::min(frames*2,(uint64_t)0xffffffe0);
    uint32_t chunk=bytes+36, fmtSize=16, byteRate=rate*2, dataSize=bytes;
    uint16_t pcm=1,ch=1,block=2,bits=16;
    memcpy(header,"RIFF",4);memcpy(header+4,&chunk,4);
    memcpy(header+8,"WAVEfmt ",8);memcpy(header+16,&fmtSize,4);
    memcpy(header+20,&pcm,2);memcpy(header+22,&ch,2);
    memcpy(header+24,&rate,4);memcpy(header+28,&byteRate,4);
    memcpy(header+32,&block,2);memcpy(header+34,&bits,2);
    memcpy(header+36,"data",4);memcpy(header+40,&dataSize,4);
    lseek(fd,0,SEEK_SET);write(fd,header,sizeof(header));
}
static void drain(Ring &ring) {
    if(ring.fd<0)return;
    uint32_t r=ring.readIndex.load(memory_order_relaxed);
    uint32_t w=ring.writeIndex.load(memory_order_acquire);
    while(r<w) {
        uint32_t length=std::min(w-r,kCapacity-(r&(kCapacity-1)));
        const uint8_t *ptr=(const uint8_t*)&ring.samples[r&(kCapacity-1)];
        ssize_t bytes=write(ring.fd,ptr,length*sizeof(int16_t));
        if(bytes<=0) break;
        uint32_t done=(uint32_t)bytes/sizeof(int16_t);
        if(!done)break;
        r+=done;ring.writtenFrames+=done;
    }
    ring.readIndex.store(r,memory_order_release);
}
static NSError *recordingError(NSString *message) {
    return [NSError errorWithDomain:@"Lead.CallAudio" code:1
      userInfo:@{NSLocalizedDescriptionKey:message}];
}
} // namespace

extern "C" void LeadCallAudioInstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        gWriterQueue=dispatch_queue_create("lead.calls.audio.writer",DISPATCH_QUEUE_SERIAL);
        gOriginalRender=(RenderProc)dlsym(RTLD_DEFAULT,"AudioUnitRender");
        gOriginalSetProperty=(SetPropertyProc)dlsym(RTLD_DEFAULT,"AudioUnitSetProperty");
        if(gOriginalRender && gOriginalSetProperty) {
            _dyld_register_func_for_add_image(bindImage);
            gHooksReady=YES;
        }
    });
}

extern "C" BOOL LeadCallAudioStart(NSString *directory) {
    LeadCallAudioInstallHooks();
    if(!gHooksReady || !directory.length || gActive.load())return NO;
    NSError *error=nil;
    if(![[NSFileManager defaultManager] createDirectoryAtPath:directory
          withIntermediateDirectories:YES attributes:nil error:&error])return NO;
    gTemporaryDirectory=directory.copy;
    for(Ring *ring : {&gMic,&gRemote}) {
        ring->writeIndex.store(0);ring->readIndex.store(0);
        ring->writtenFrames=0;ring->sampleRate.store(48000);
    }
    NSString *mic=[directory stringByAppendingPathComponent:@"mic.wav"];
    NSString *remote=[directory stringByAppendingPathComponent:@"remote.wav"];
    gMic.fd=open(mic.fileSystemRepresentation,O_CREAT|O_TRUNC|O_RDWR,0600);
    gRemote.fd=open(remote.fileSystemRepresentation,O_CREAT|O_TRUNC|O_RDWR,0600);
    if(gMic.fd<0 || gRemote.fd<0) {
        if(gMic.fd>=0)close(gMic.fd);if(gRemote.fd>=0)close(gRemote.fd);
        gMic.fd=gRemote.fd=-1;return NO;
    }
    wavHeader(gMic.fd,0,48000);wavHeader(gRemote.fd,0,48000);
    lseek(gMic.fd,44,SEEK_SET);lseek(gRemote.fd,44,SEEK_SET);
    gWriterTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,gWriterQueue);
    dispatch_source_set_timer(gWriterTimer,dispatch_time(DISPATCH_TIME_NOW,0),
                  (uint64_t)(0.07*NSEC_PER_SEC),(uint64_t)(0.02*NSEC_PER_SEC));
    dispatch_source_set_event_handler(gWriterTimer,^{ drain(gMic);drain(gRemote); });
    gActive.store(true,memory_order_release);
    dispatch_resume(gWriterTimer);
    return YES;
}

extern "C" void LeadCallAudioStop(void (^completion)(NSURL *,NSError *)) {
    if(!gActive.exchange(false)) {
        if(completion) completion(nil,recordingError(@"No recording is in progress."));
        return;
    }
    if(gWriterTimer){dispatch_source_cancel(gWriterTimer);gWriterTimer=nil;}
    dispatch_async(gWriterQueue,^{
        drain(gMic);drain(gRemote);
        const uint64_t micFrames=gMic.writtenFrames,remoteFrames=gRemote.writtenFrames;
        wavHeader(gMic.fd,micFrames,gMic.sampleRate.load());
        wavHeader(gRemote.fd,remoteFrames,gRemote.sampleRate.load());
        close(gMic.fd);close(gRemote.fd);gMic.fd=gRemote.fd=-1;
        if(micFrames==0 || remoteFrames==0) {
            NSError *error=recordingError(@"The call audio paths were not captured on this Telegram version. No valid two-sided recording was produced.");
            dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(nil,error);});
            return;
        }
        NSURL *mic=[NSURL fileURLWithPath:[gTemporaryDirectory stringByAppendingPathComponent:@"mic.wav"]];
        NSURL *remote=[NSURL fileURLWithPath:[gTemporaryDirectory stringByAppendingPathComponent:@"remote.wav"]];
        AVMutableComposition *composition=[AVMutableComposition composition];
        NSMutableArray *mixParameters=[NSMutableArray array];
        NSError *composeError=nil;
        for(NSURL *url in @[mic,remote]) {
            AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
            AVAssetTrack *source=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if(!source) { composeError=recordingError(@"Audio track is missing.");break; }
            AVMutableCompositionTrack *track=[composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                preferredTrackID:kCMPersistentTrackID_Invalid];
            if(![track insertTimeRange:CMTimeRangeMake(kCMTimeZero,source.timeRange.duration)
                            ofTrack:source atTime:kCMTimeZero error:&composeError])break;
            AVMutableAudioMixInputParameters *params=[AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
            // Preserve full captured voice levels; do not attenuate each side to 80%.
            [params setVolume:1.0 atTime:kCMTimeZero];[mixParameters addObject:params];
        }
        if(composeError) {
            dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(nil,composeError);});
            return;
        }
        AVMutableAudioMix *mix=[AVMutableAudioMix audioMix];mix.inputParameters=mixParameters;
        NSURL *output=[NSURL fileURLWithPath:[gTemporaryDirectory stringByAppendingPathComponent:@"mixed.m4a"]];
        [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
        AVAssetExportSession *exporter=[[AVAssetExportSession alloc] initWithAsset:composition
                                                                     presetName:AVAssetExportPresetAppleM4A];
        exporter.audioMix=mix;exporter.outputURL=output;exporter.outputFileType=AVFileTypeAppleM4A;
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            NSError *e=exporter.status==AVAssetExportSessionStatusCompleted?nil:
                (exporter.error ?: recordingError(@"Could not export the call audio."));
            dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(e?nil:output,e);});
        }];
    });
}
