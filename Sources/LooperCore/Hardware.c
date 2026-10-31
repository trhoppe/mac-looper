#include "LooperCore.h"
#include <stdatomic.h>
#include <CoreServices/CoreServices.h>
#include <stdlib.h>
#include <string.h>

struct TLHardware {
    AudioUnit unit;
    TLCore *core;
    AudioBufferList *input;
    float *inputStorage, *outputLeft, *outputRight;
    uint32_t maxFrames, inputs, outputs, il, ir, ol, or;
    _Atomic int error;
    _Atomic uint64_t callbacks;
};
static OSStatus render(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                       UInt32 bus, UInt32 frames, AudioBufferList *output) {
    (void)bus;
    TLHardware *h = context;
    if (!output) return kAudio_ParamError;
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
    if (frames > h->maxFrames) {
        atomic_store_explicit(&h->error, kAudioUnitErr_TooManyFramesToProcess, memory_order_relaxed);
        return noErr;
    }
    for (uint32_t ch = 0; ch < h->inputs; ch++) {
        h->input->mBuffers[ch].mData = h->inputStorage + ch * h->maxFrames;
        h->input->mBuffers[ch].mDataByteSize = frames * sizeof(float);
    }
    OSStatus err = AudioUnitRender(h->unit, flags, time, 1, frames, h->input);
    if (err) {
        atomic_store_explicit(&h->error, err, memory_order_relaxed);
        // Don't capture invented silence into an in-progress loop. UI stops this engine.
        return noErr;
    }
    tl_process(h->core, h->input->mBuffers[h->il].mData, h->input->mBuffers[h->ir].mData,
               h->outputLeft, h->outputRight, frames);
    if (output->mNumberBuffers >= h->outputs) {
        memcpy(output->mBuffers[h->ol].mData, h->outputLeft, frames * sizeof(float));
        if (h->ol != h->or) memcpy(output->mBuffers[h->or].mData, h->outputRight, frames * sizeof(float));
    }
    atomic_fetch_add_explicit(&h->callbacks, 1, memory_order_relaxed);
    return noErr;
}
TLHardware *tl_hardware_create(TLCore *core, AudioDeviceID device, double rate,
                              uint32_t inputs, uint32_t outputs, uint32_t il, uint32_t ir,
                              uint32_t ol, uint32_t or, OSStatus *error) {
    OSStatus err = kAudio_ParamError;
    TLHardware *h = NULL;
    if (!core || !inputs || !outputs || inputs > 128 || outputs > 128 ||
        il >= inputs || ir >= inputs || ol >= outputs || or >= outputs) goto fail;
    h = calloc(1, sizeof(*h));
    if (!h) { err = memFullErr; goto fail; }
    atomic_init(&h->error, 0); atomic_init(&h->callbacks, 0);
    h->core = core; h->inputs = inputs; h->outputs = outputs;
    h->il = il; h->ir = ir; h->ol = ol; h->or = or;
    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
        kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    if (!component) { err = kAudioUnitErr_FailedInitialization; goto fail; }
    if ((err = AudioComponentInstanceNew(component, &h->unit))) goto fail;
    UInt32 yes = 1;
    if ((err = AudioUnitSetProperty(h->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &yes, sizeof(yes)))) goto fail;
    if ((err = AudioUnitSetProperty(h->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &yes, sizeof(yes)))) goto fail;
    if ((err = AudioUnitSetProperty(h->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device)))) goto fail;
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate; format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = 4; format.mFramesPerPacket = 1; format.mBytesPerFrame = 4;
    format.mBitsPerChannel = 32; format.mChannelsPerFrame = inputs;
    if ((err = AudioUnitSetProperty(h->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format)))) goto fail;
    format.mChannelsPerFrame = outputs;
    if ((err = AudioUnitSetProperty(h->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)))) goto fail;
    h->maxFrames = 8192;
    if ((err = AudioUnitSetProperty(h->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &h->maxFrames, sizeof(h->maxFrames)))) goto fail;
    // Preallocate AND touch every page before the realtime thread starts.
    h->input = calloc(1, sizeof(AudioBufferList) + (inputs - 1) * sizeof(AudioBuffer));
    h->inputStorage = calloc((size_t)inputs * h->maxFrames, sizeof(float));
    h->outputLeft = calloc(h->maxFrames, sizeof(float)); h->outputRight = calloc(h->maxFrames, sizeof(float));
    if (!h->input || !h->inputStorage || !h->outputLeft || !h->outputRight) { err = memFullErr; goto fail; }
    h->input->mNumberBuffers = inputs;
    for (uint32_t i = 0; i < inputs; i++) {
        h->input->mBuffers[i] = (AudioBuffer){1, h->maxFrames * 4, h->inputStorage + i * h->maxFrames};
    }
    UInt32 no = 0;
    if ((err = AudioUnitSetProperty(h->unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &no, sizeof(no)))) goto fail;
    AURenderCallbackStruct callback = {render, h};
    if ((err = AudioUnitSetProperty(h->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)))) goto fail;
    if ((err = AudioUnitInitialize(h->unit))) goto fail;
    if (error) *error = 0;
    return h;
fail:
    if (error) *error = err;
    tl_hardware_destroy(h);
    return NULL;
}
OSStatus tl_hardware_start(TLHardware *h) { return h ? AudioOutputUnitStart(h->unit) : kAudio_ParamError; }
void tl_hardware_destroy(TLHardware *h) {
    if (!h) return;
    if (h->unit) {
        AudioOutputUnitStop(h->unit); AudioUnitUninitialize(h->unit); AudioComponentInstanceDispose(h->unit);
    }
    free(h->input); free(h->inputStorage); free(h->outputLeft); free(h->outputRight); free(h);
}
OSStatus tl_hardware_error(TLHardware *h) { return h ? atomic_load_explicit(&h->error, memory_order_relaxed) : 0; }
uint64_t tl_hardware_callbacks(TLHardware *h) { return h ? atomic_load_explicit(&h->callbacks, memory_order_relaxed) : 0; }
