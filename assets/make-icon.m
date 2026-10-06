// Draws Sonora's 1024 px app icon: a deep violet squircle with three mixer
// faders at different levels over a soft glow.
#import <AppKit/AppKit.h>
int main(int argc, char **argv) { @autoreleasepool {
    const CGFloat S = 1024;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [[NSColor clearColor] set]; NSRectFill(NSMakeRect(0, 0, S, S));

    // macOS icon grid: 824 px body centred in 1024, corner radius ~185
    NSRect body = NSMakeRect(100, 100, 824, 824);
    NSBezierPath *squircle = [NSBezierPath bezierPathWithRoundedRect:body xRadius:185 yRadius:185];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
    shadow.shadowOffset = NSMakeSize(0, -12); shadow.shadowBlurRadius = 28;
    [NSGraphicsContext saveGraphicsState]; [shadow set];
    [[NSColor blackColor] set]; [squircle fill];
    [NSGraphicsContext restoreGraphicsState];

    [NSGraphicsContext saveGraphicsState];
    [squircle addClip];
    NSGradient *bg = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:0.42 green:0.25 blue:0.95 alpha:1],
        [NSColor colorWithSRGBRed:0.20 green:0.10 blue:0.55 alpha:1],
        [NSColor colorWithSRGBRed:0.07 green:0.04 blue:0.22 alpha:1]]];
    [bg drawInRect:body angle:-70];
    // warm glow behind the faders
    NSGradient *glow = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:1.0 green:0.45 blue:0.75 alpha:0.55], [NSColor colorWithSRGBRed:1.0 green:0.45 blue:0.75 alpha:0]]];
    [glow drawFromCenter:NSMakePoint(512, 470) radius:0 toCenter:NSMakePoint(512, 470) radius:430 options:0];
    // three faders
    CGFloat xs[3] = {362, 512, 662}, levels[3] = {0.72, 0.38, 0.86};
    for (int i = 0; i < 3; i++) {
        NSRect track = NSMakeRect(xs[i] - 14, 250, 28, 524);
        [[NSColor colorWithWhite:1 alpha:0.18] set];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:14 yRadius:14] fill];
        CGFloat ky = 250 + levels[i] * 524;
        NSRect fill = NSMakeRect(xs[i] - 14, 250, 28, ky - 250);
        NSGradient *lit = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.55 green:0.85 blue:1 alpha:1]
                                                        endingColor:[NSColor colorWithSRGBRed:1 green:0.55 blue:0.85 alpha:1]];
        [lit drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:fill xRadius:14 yRadius:14] angle:90];
        NSShadow *ks = [NSShadow new]; ks.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
        ks.shadowOffset = NSMakeSize(0, -6); ks.shadowBlurRadius = 14;
        [NSGraphicsContext saveGraphicsState]; [ks set];
        [[NSColor whiteColor] set];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(xs[i] - 62, ky - 30, 124, 60) xRadius:30 yRadius:30] fill];
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithSRGBRed:0.30 green:0.18 blue:0.70 alpha:0.9] set];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(xs[i] - 34, ky - 4, 68, 8) xRadius:4 yRadius:4] fill];
    }
    // top sheen
    NSGradient *sheen = [[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:1 alpha:0.16], [NSColor colorWithWhite:1 alpha:0]]];
    [sheen drawInRect:NSMakeRect(100, 600, 824, 324) angle:-90];
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
}}
