#import <AppKit/AppKit.h>

/// Private AppKit API (macOS 10.14+) that shows a Touch Bar from any app, even a background one.
/// Not allowed in the Mac App Store; fine for Developer ID builds. Callers must check `respondsToSelector:`.
@interface NSTouchBar (ShiftioPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                         placement:(long long)placement
          systemTrayItemIdentifier:(nullable NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end
