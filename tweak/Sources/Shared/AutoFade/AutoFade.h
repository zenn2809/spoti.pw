// Automatic fade-to-next: a single-stream transition for Spotify's final output.
// This is deliberately not called AutoMix: it cannot overlap two decoded Spotify streams.
#import <UIKit/UIKit.h>

#define SGKeyAutoFade @"spotifyglass.autofade.enabled"
#define SGKeyAutoFadeDuration @"spotifyglass.autofade.duration"

@class SGModSection;
NSArray<SGModSection *> *SGAutoFadeSections(void);
// Applies the switch immediately and cancels any pending transition when turned off.
void SGSetAutoFadeEnabled(BOOL on);
