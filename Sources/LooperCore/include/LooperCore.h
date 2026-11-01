#ifndef LOOPER_CORE_H
#define LOOPER_CORE_H
#include "LooperDSP.h"
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <AudioToolbox/AudioToolbox.h>
// One AUHAL duplex device, which can be a private drift-compensated aggregate.
// Channel indices are zero-based physical/aggregate channels.
TLHardware *tl_hardware_create(TLCore *core, AudioDeviceID device, double rate,
                              uint32_t inputChannels, uint32_t outputChannels,
                              uint32_t inputLeft, uint32_t inputRight,
                              uint32_t outputLeft, uint32_t outputRight,
                              OSStatus *error);
typedef OSStatus (*TLGraphRender)(void *context, const AudioBufferList *input, float *left, float *right,
                                  UInt32 frames, const AudioTimeStamp *time);
void tl_hardware_set_graph(TLHardware *hardware, TLGraphRender render, void *context);
OSStatus tl_hardware_start(TLHardware *hardware);
void tl_hardware_destroy(TLHardware *hardware);
OSStatus tl_hardware_error(TLHardware *hardware);
uint64_t tl_hardware_callbacks(TLHardware *hardware);
uint32_t tl_hardware_callback_frames(TLHardware *hardware);
#endif
#endif
