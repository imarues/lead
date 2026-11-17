#import "Media.h"
#import <Foundation/Foundation.h>
#import <AudioUnit/AudioUnit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <unistd.h>
#include <atomic>
#include <cstring>

// Import rebinding adapted from LeadCallAudio; no recording/downlink changes.
static std::atomic<unsigned> bound{0};
using Render=OSStatus(*)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*);
static Render originalRender=nullptr;
static OSStatus RenderMic(AudioUnit unit,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *out) {
    OSStatus result=originalRender?originalRender(unit,flags,time,bus,frames,out):-1;
    if(result==noErr && bus==1 && out) {
        AudioComponent component=AudioComponentInstanceGetComponent(unit);
        AudioComponentDescription desc={};
        if(component && AudioComponentGetDescription(component,&desc)==noErr && desc.componentType==kAudioUnitType_Output &&
          (desc.componentSubType==kAudioUnitSubType_RemoteIO || desc.componentSubType==kAudioUnitSubType_VoiceProcessingIO)) {
            AudioStreamBasicDescription format={};UInt32 size=sizeof(format);
            AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&format,&size);
            if(SnapReplaceMic(out,&format,frames) && flags)*flags&=~kAudioUnitRenderAction_OutputIsSilence;
        }
    }
    return result;
}
static void BindSection(const section_64 *sec,intptr_t slide,const nlist_64 *symbols,const char *strings,const uint32_t *indirect) {
    uintptr_t address=(uintptr_t)(slide+sec->addr);uint32_t page=(uint32_t)getpagesize();
    for(uint32_t i=0;i<sec->size/sizeof(void*);i++) {
        uint32_t index=indirect[sec->reserved1+i];
        if(index&(INDIRECT_SYMBOL_LOCAL|INDIRECT_SYMBOL_ABS))continue;
        if(strcmp(strings+symbols[index].n_un.n_strx,"_AudioUnitRender"))continue;
        void **slot=(void**)(address+i*sizeof(void*));
        if(*slot==(void*)&RenderMic)continue;
        uintptr_t start=(uintptr_t)slot&~((uintptr_t)page-1);
        // Restore the original protection after replacing just this import.
        vm_address_t region=(vm_address_t)start;vm_size_t regionSize=0;
        vm_region_basic_info_data_64_t info={};mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t object=MACH_PORT_NULL;
        kern_return_t query=vm_region_64(mach_task_self(),&region,&regionSize,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
        if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
        if(query!=KERN_SUCCESS)continue;
        if(vm_protect(mach_task_self(),(vm_address_t)start,page,false,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS)continue;
        *slot=(void*)&RenderMic;bound.fetch_add(1);
        vm_protect(mach_task_self(),(vm_address_t)start,page,false,info.protection);
    }
}
static void BindImage(const mach_header *header,intptr_t slide) {
    if(!header || header->magic!=MH_MAGIC_64)return;
    // Rebind only the app executable: never alter system frameworks or our own calls.
    Dl_info image={};if(!dladdr(header,&image) || !image.dli_fname)return;
    const char *base=strrchr(image.dli_fname,'/');base=base?base+1:image.dli_fname;
    if(strcmp(base,"Snapchat"))return;
    const mach_header_64 *h=(const mach_header_64*)header;
    const uint8_t *cursor=(const uint8_t*)h+sizeof(*h);
    const symtab_command *syms=nullptr;const dysymtab_command *dys=nullptr;
    const segment_command_64 *linkedit=nullptr,*segments[32]={};uint32_t n=0;
    for(uint32_t i=0;i<h->ncmds;i++) {
        const load_command *load=(const load_command*)cursor;
        if(load->cmd==LC_SYMTAB)syms=(const symtab_command*)load;
        if(load->cmd==LC_DYSYMTAB)dys=(const dysymtab_command*)load;
        if(load->cmd==LC_SEGMENT_64){const auto *seg=(const segment_command_64*)load;if(!strcmp(seg->segname,SEG_LINKEDIT))linkedit=seg;if(n<32)segments[n++]=seg;}
        cursor+=load->cmdsize;
    }
    if(!syms||!dys||!linkedit)return;
    uintptr_t baseAddress=(uintptr_t)(slide+linkedit->vmaddr-linkedit->fileoff);
    auto *symbols=(const nlist_64*)(baseAddress+syms->symoff);
    auto *strings=(const char*)(baseAddress+syms->stroff);
    auto *indirect=(const uint32_t*)(baseAddress+dys->indirectsymoff);
    for(uint32_t i=0;i<n;i++) {
        const auto *seg=segments[i];if(strncmp(seg->segname,"__DATA",6))continue;
        const auto *sections=(const section_64*)((const uint8_t*)seg+sizeof(*seg));
        for(uint32_t j=0;j<seg->nsects;j++) {
            uint32_t type=sections[j].flags&SECTION_TYPE;
            if(type==S_LAZY_SYMBOL_POINTERS || type==S_NON_LAZY_SYMBOL_POINTERS)BindSection(&sections[j],slide,symbols,strings,indirect);
        }
    }
}
void SnapInstallAudio(void) {
    static dispatch_once_t once;dispatch_once(&once,^{originalRender=(Render)dlsym(RTLD_DEFAULT,"AudioUnitRender");if(originalRender)_dyld_register_func_for_add_image(BindImage);});
}
bool SnapAudioReady(void) {return bound.load()>0;}
