// Draws the background of Sonora's disk image window: an arrow from the app
// to the Applications folder, and a short note for the first launch.
// Usage: make-dmg-background out.png (rendered at 2x: 1320x880 for a 660x440 window).
#import <AppKit/AppKit.h>
int main(int argc, char **argv) { @autoreleasepool {
    const CGFloat W = 660, H = 440, scale = 2;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W * scale pixelsHigh:H * scale
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = NSMakeSize(W, H);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

    NSGradient *bg = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:0.13 green:0.08 blue:0.30 alpha:1],
        [NSColor colorWithSRGBRed:0.05 green:0.03 blue:0.12 alpha:1]]];
    [bg drawInRect:NSMakeRect(0, 0, W, H) angle:-90];
    NSGradient *glow = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:0.55 green:0.30 blue:1.0 alpha:0.35], [NSColor colorWithSRGBRed:0.55 green:0.30 blue:1.0 alpha:0]]];
    [glow drawFromCenter:NSMakePoint(W / 2, H - 200) radius:0 toCenter:NSMakePoint(W / 2, H - 200) radius:320 options:0];

    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    void (^text)(NSString *, CGFloat, CGFloat, NSFontWeight, CGFloat) = ^(NSString *s, CGFloat y, CGFloat size, NSFontWeight w, CGFloat alpha) {
        [s drawInRect:NSMakeRect(20, y, W - 40, size + 8) withAttributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:size weight:w],
            NSForegroundColorAttributeName : [NSColor colorWithWhite:1 alpha:alpha],
            NSParagraphStyleAttributeName : center}];
    };
    text(@"Drag Sonora to Applications", H - 72, 22, NSFontWeightBold, 0.95);
    text(@"Per-app volume control for your Mac", H - 100, 13, NSFontWeightRegular, 0.6);

    // arrow between the two icons (icons sit at x 170 and 490, y 220 from the top)
    CGFloat ay = H - 220;
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(262, ay)];
    [arrow lineToPoint:NSMakePoint(390, ay)];
    arrow.lineWidth = 5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    [[NSColor colorWithWhite:1 alpha:0.55] set];
    [arrow stroke];
    NSBezierPath *head = [NSBezierPath bezierPath];
    [head moveToPoint:NSMakePoint(374, ay + 14)];
    [head lineToPoint:NSMakePoint(396, ay)];
    [head lineToPoint:NSMakePoint(374, ay - 14)];
    head.lineWidth = 5;
    head.lineCapStyle = NSLineCapStyleRound;
    head.lineJoinStyle = NSLineJoinStyleRound;
    [head stroke];

    text(@"First time you open it: if macOS says it can't verify the developer,", 62, 11.5, NSFontWeightRegular, 0.55);
    text(@"open System Settings → Privacy & Security and click “Open Anyway”.", 44, 11.5, NSFontWeightRegular, 0.55);

    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
}}
