// A conservative automatic fade-to-next over Spotify's one final PCM output. It never claims to
// mix two tracks: Spotify exposes the currently playing stream only at this point in its pipeline.
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <string.h>
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"
#import "AutoFade.h"

typedef NS_ENUM(int, SGAutoFadePhase) {
    SGAutoFadeIdle,
    SGAutoFadeOut,
    SGAutoFadeWaitingForNext,
    SGAutoFadeIn,
};

@class SGAutoFadeObserver;
static atomic_int sg_phase;
static atomic_uint_fast64_t sg_startedTicks;
static double sg_secondsPerTick;
static NSUInteger sg_generation;
static NSString *sg_trackKey;
static atomic_bool sg_outputSupported;
static atomic_uint sg_channels;
static OSStatus (*sg_startOutput)(AudioUnit unit);
static SGAutoFadeObserver *sg_observer;
static void armCurrentState(void);

static double fadeDuration(void) {
    return MAX(1, MIN(5, SGInt(SGKeyAutoFadeDuration, 2)));
}

static void beginPhase(SGAutoFadePhase phase) {
    atomic_store_explicit(&sg_startedTicks, mach_absolute_time(), memory_order_release);
    atomic_store_explicit(&sg_phase, phase, memory_order_release);
}

static BOOL outputSupportsFade(void) {
    return atomic_load_explicit(&sg_outputSupported, memory_order_acquire);
}

void SGSetAutoFadeEnabled(BOOL on) {
    if (on) {
        armCurrentState();
        return;
    }
    sg_generation++;
    beginPhase(SGAutoFadeIdle);
}

static double phaseGain(void) {
    SGAutoFadePhase phase = atomic_load_explicit(&sg_phase, memory_order_acquire);
    if (phase == SGAutoFadeIdle) return 1;
    if (phase == SGAutoFadeWaitingForNext) return 0;
    uint64_t started = atomic_load_explicit(&sg_startedTicks, memory_order_acquire);
    double progress = MIN(1, (mach_absolute_time() - started) * sg_secondsPerTick / fadeDuration());
    return phase == SGAutoFadeOut ? 1 - progress : progress;
}

// The RemoteIO output is normally float, non-interleaved; unsupported layouts pass through rather
// than risking corrupt audio. This only runs on the final output buffer Spotify gives the speaker.
static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    (void)refCon;
    (void)timestamp;
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !frames) return noErr;
    SGAutoFadePhase phase = atomic_load_explicit(&sg_phase, memory_order_acquire);
    if (phase == SGAutoFadeIdle || !outputSupportsFade() || data->mNumberBuffers != atomic_load(&sg_channels)) return noErr;
    if (phase == SGAutoFadeWaitingForNext) {
        for (UInt32 channel = 0; channel < data->mNumberBuffers; channel++) {
            AudioBuffer buffer = data->mBuffers[channel];
            if (buffer.mData) memset(buffer.mData, 0, buffer.mDataByteSize);
        }
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    if (*flags & kAudioUnitRenderAction_OutputIsSilence) return noErr;
    double gain = phaseGain();
    for (UInt32 channel = 0; channel < data->mNumberBuffers; channel++) {
        AudioBuffer buffer = data->mBuffers[channel];
        if (!buffer.mData || buffer.mDataByteSize < frames * sizeof(float)) return noErr;
        float *samples = buffer.mData;
        for (UInt32 frame = 0; frame < frames; frame++) samples[frame] *= gain;
    }
    if (gain == 0) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    else *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}

static BOOL isRemoteIO(AudioUnit unit) {
    AudioComponentDescription description = {0};
    return unit && AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) == noErr &&
           description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO;
}

static void readFormat(AudioUnit unit) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    BOOL supported = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size) == noErr &&
                     format.mFormatID == kAudioFormatLinearPCM && (format.mFormatFlags & kAudioFormatFlagIsFloat) &&
                     (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) && format.mBitsPerChannel == 32 &&
                     format.mChannelsPerFrame >= 1;
    atomic_store(&sg_channels, format.mChannelsPerFrame);
    atomic_store(&sg_outputSupported, supported);
}

static void listenTo(AudioUnit unit) {
    readFormat(unit);
    AudioUnitRemoveRenderNotify(unit, rendered, NULL);
    OSStatus status = AudioUnitAddRenderNotify(unit, rendered, NULL);
    if (status != noErr) SGLog(@"auto fade: could not add output listener (%d)", (int)status);
}

static OSStatus startOutput(AudioUnit unit) {
    if (isRemoteIO(unit)) listenTo(unit);
    return sg_startOutput(unit);
}

@interface SGAutoFadeObserver : NSObject <SGPlayerStateObserver>
@end

@implementation SGAutoFadeObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {
    sg_generation++;
    NSString *key = SGURIString(state.track.URI);
    if (!key.length) return;
    BOOL changedTrack = sg_trackKey.length && ![sg_trackKey isEqualToString:key];
    sg_trackKey = key;
    SGAutoFadePhase phase = atomic_load(&sg_phase);
    if (changedTrack && (phase == SGAutoFadeWaitingForNext || phase == SGAutoFadeOut)) {
        beginPhase(SGAutoFadeIn);
    }
    if (!SGFlag(SGKeyAutoFade, NO) || !state.isPlaying || state.isPaused || !state.future.count || state.duration <= 0 || !outputSupportsFade()) {
        if (!state.isPlaying || state.isPaused) beginPhase(SGAutoFadeIdle);
        return;
    }
    double remaining = state.duration - state.position;
    double duration = fadeDuration();
    if (remaining <= duration + 0.25) return;
    NSUInteger generation = sg_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((remaining - duration) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sg_generation || !SGFlag(SGKeyAutoFade, NO) || !outputSupportsFade()) return;
        SPTPlayerState *current = SGPlayerState();
        if (!current.isPlaying || current.isPaused || ![SGURIString(current.track.URI) isEqualToString:key]) return;
        beginPhase(SGAutoFadeOut);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != sg_generation || atomic_load(&sg_phase) != SGAutoFadeOut) return;
            beginPhase(SGAutoFadeWaitingForNext);
            if (!SGSkipToNextTrack()) beginPhase(SGAutoFadeIn);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (generation == sg_generation && atomic_load(&sg_phase) == SGAutoFadeWaitingForNext) beginPhase(SGAutoFadeIn);
            });
        });
    });
}
@end

static void armCurrentState(void) {
    SPTPlayerState *state = SGPlayerState();
    if (state && sg_observer) [sg_observer playerStateDidChange:state];
}

%ctor {
    %init;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sg_secondsPerTick = (double)timebase.numer / timebase.denom / NSEC_PER_SEC;
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_observer = [SGAutoFadeObserver new];
        SGAddPlayerStateObserver(sg_observer);
        armCurrentState();
    });
    if (!SGRebindImport("AudioOutputUnitStart", startOutput, (void **)&sg_startOutput) || !sg_startOutput) {
        SGLog(@"auto fade: Spotify does not import AudioOutputUnitStart; feature is inactive");
    }
}
