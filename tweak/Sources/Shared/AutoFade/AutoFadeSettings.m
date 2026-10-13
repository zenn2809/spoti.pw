#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import <math.h>
#import "AutoFade.h"

static const NSInteger kMinimumSeconds = 1, kMaximumSeconds = 5;

NSArray<SGModSection *> *SGAutoFadeSections(void) {
    SGModRow *enabled = SGOptionRow(@"Automatic fade-to-next", @"Fades the current Spotify output down, skips, then fades the new track up", SGKeyAutoFade);
    enabled.info = @"This is a single-stream transition, not AutoMix: Spotify does not expose a second decoded track for this mod to overlap. A brief silent gap can occur while Spotify loads the next track.";
    enabled.changed = ^(BOOL on) { SGSetAutoFadeEnabled(on); };
    SGModRow *duration = SGSliderRow(@"Fade duration", nil, kMinimumSeconds, kMaximumSeconds, 1,
        ^double { return MAX(kMinimumSeconds, MIN(kMaximumSeconds, SGInt(SGKeyAutoFadeDuration, 2))); },
        ^(double value) { SGSetInt(SGKeyAutoFadeDuration, lround(value)); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f seconds", value]; });
    duration.visible = ^BOOL { return SGFlag(SGKeyAutoFade, NO); };
    return @[SGSection(@"Playback", @[SGWithSymbol(enabled, @"arrow.triangle.2.circlepath"), duration])];
}
