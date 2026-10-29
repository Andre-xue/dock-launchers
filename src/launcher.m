#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <sys/xattr.h>

static NSString *gGroup = @"";
static NSString *gListKey = @"";
static NSString *gListFile = @"";

// 皮肤：0 纯白 1 纯黑 2 质感玻璃 3 自定义图片
static NSInteger gTheme = 0;
static CGFloat gGlassAlpha = 0.82;
static CGFloat gImgScale = 1.0;
static CGFloat gImgDX = 0.0, gImgDY = 0.0;
static NSString *gImgPath = nil;
static NSString *const kSkinPrefix = @"skin.";
static CGFloat gCornerRatio = 0.0;   // 0 = 矩形，0.5 = 圆形
static BOOL gIconMode = NO;          // YES = 图标网格模式
static NSMutableDictionary *gAppIconSettings = nil;  // target -> {size, corner, image}

@class Controller;
@class BackdropView;
@class PillButton;
@class LightButton;
@class TitlePillView;
@class ShortcutRowView;
static NSString *DisplayForSignature(NSString *sig);
static NSString *SignatureForEvent(NSEvent *e);

@interface AppIconView : NSView
@property (strong) NSImage *image;
@property CGFloat cornerRatio;
@property BOOL selected;
@property (strong) NSColor *selColor;
@property BOOL hugHighlight;
@end

@implementation AppIconView
- (BOOL)isFlipped { return NO; }
- (void)setImage:(NSImage *)image { _image = image; [self setNeedsDisplay:YES]; }
- (void)setCornerRatio:(CGFloat)cornerRatio { _cornerRatio = cornerRatio; [self setNeedsDisplay:YES]; }
- (void)setSelected:(BOOL)selected { _selected = selected; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
  NSRect iconRect = NSInsetRect(self.bounds, 0.6, 0.6);
  CGFloat r = self.cornerRatio * MIN(iconRect.size.width, iconRect.size.height);
  if (self.hugHighlight && self.selected) {
    NSColor *c = self.selColor ?: [NSColor colorWithCalibratedRed:0.86 green:0.93 blue:0.99 alpha:1.0];
    [c setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:r + 0.6 yRadius:r + 0.6] fill];
  }
  if (!self.image) return;
  NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:iconRect xRadius:r yRadius:r];
  [clip addClip];
  CGFloat zoom = 1.0 + self.cornerRatio * 0.35;
  CGFloat inset = -(zoom - 1.0) * MIN(iconRect.size.width, iconRect.size.height) / 2.0;
  NSRect drawRect = NSInsetRect(iconRect, inset, inset);
  [self.image drawInRect:drawRect fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver fraction:1.0];
}
@end

@interface CropView : NSView
@property (strong) NSImage *sourceImage;
@property NSRect imgRect;
@property NSRect cropRect;
@property NSPoint dragStart;
@property NSRect cropStart;
@property NSInteger dragMode;
@end

@implementation CropView
- (BOOL)isFlipped { return YES; }
- (void)setSourceImage:(NSImage *)sourceImage {
  _sourceImage = sourceImage;
  [self layoutImageRect];
  [self setNeedsDisplay:YES];
}
- (void)layoutImageRect {
  if (!self.sourceImage) return;
  NSSize sz = self.sourceImage.size;
  if (sz.width <= 0 || sz.height <= 0) return;
  NSRect b = NSInsetRect(self.bounds, 12, 12);
  CGFloat scale = MIN(b.size.width / sz.width, b.size.height / sz.height);
  CGFloat w = sz.width * scale, h = sz.height * scale;
  self.imgRect = NSMakeRect(b.origin.x + (b.size.width - w)/2.0, b.origin.y + (b.size.height - h)/2.0, w, h);
  CGFloat side = MIN(self.imgRect.size.width, self.imgRect.size.height) * 0.8;
  self.cropRect = NSMakeRect(self.imgRect.origin.x + (self.imgRect.size.width - side)/2.0,
                             self.imgRect.origin.y + (self.imgRect.size.height - side)/2.0, side, side);
}
- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
  NSRectFill(self.bounds);
  if (!self.sourceImage) return;
  [self.sourceImage drawInRect:self.imgRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
  [[NSColor colorWithCalibratedWhite:0 alpha:0.55] setFill];
  NSRectFill(NSMakeRect(self.imgRect.origin.x, self.imgRect.origin.y, self.imgRect.size.width, self.cropRect.origin.y - self.imgRect.origin.y));
  CGFloat bottom = NSMaxY(self.cropRect);
  NSRectFill(NSMakeRect(self.imgRect.origin.x, bottom, self.imgRect.size.width, NSMaxY(self.imgRect) - bottom));
  NSRectFill(NSMakeRect(self.imgRect.origin.x, self.cropRect.origin.y, self.cropRect.origin.x - self.imgRect.origin.x, self.cropRect.size.height));
  CGFloat right = NSMaxX(self.cropRect);
  NSRectFill(NSMakeRect(right, self.cropRect.origin.y, NSMaxX(self.imgRect) - right, self.cropRect.size.height));
  [[NSColor whiteColor] setStroke];
  NSBezierPath *p = [NSBezierPath bezierPathWithRect:self.cropRect];
  p.lineWidth = 2;
  [p stroke];
  NSRect handle = NSMakeRect(NSMaxX(self.cropRect)-12, NSMaxY(self.cropRect)-12, 16, 16);
  [[NSColor whiteColor] setFill];
  NSRectFill(handle);
}
- (void)mouseDown:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  NSRect handle = NSMakeRect(NSMaxX(self.cropRect)-16, NSMaxY(self.cropRect)-16, 24, 24);
  self.dragMode = NSPointInRect(pt, handle) ? 2 : (NSPointInRect(pt, self.cropRect) ? 1 : 0);
  self.dragStart = pt;
  self.cropStart = self.cropRect;
}
- (void)mouseDragged:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat dx = pt.x - self.dragStart.x, dy = pt.y - self.dragStart.y;
  if (self.dragMode == 2) {
    CGFloat side = MAX(48.0, self.cropStart.size.width + MAX(dx, dy));
    side = MIN(side, MIN(self.imgRect.size.width, self.imgRect.size.height));
    self.cropRect = NSMakeRect(self.cropStart.origin.x, self.cropStart.origin.y, side, side);
    [self clampCrop];
  } else if (self.dragMode == 1) {
    NSRect r = self.cropStart;
    r.origin.x += dx; r.origin.y += dy;
    self.cropRect = r;
    [self clampCrop];
  }
  [self setNeedsDisplay:YES];
}
- (void)clampCrop {
  NSRect r = self.cropRect;
  r.size.width = MIN(r.size.width, self.imgRect.size.width);
  r.size.height = r.size.width;
  r.origin.x = MAX(self.imgRect.origin.x, MIN(r.origin.x, NSMaxX(self.imgRect) - r.size.width));
  r.origin.y = MAX(self.imgRect.origin.y, MIN(r.origin.y, NSMaxY(self.imgRect) - r.size.height));
  self.cropRect = r;
}
@end

@interface RowView : NSView
@property (assign) NSInteger idx;
@property (strong) AppIconView *iconView;
@property (strong) NSTextField *label;
@property (assign) BOOL selected;
@property (weak) Controller *ctrl;
@property (strong) NSColor *selColor;
@property BOOL iconMode;
@property NSRect iconRect;
@property CGFloat iconCorner;
@end

@interface ContentView : NSView
@property (weak) Controller *ctrl;
@end

@interface FlippedView : NSView
@end

@interface CircleButton : NSButton
@property (strong) NSColor *circleColor;
@property (copy) NSString *glyph;
@end

@implementation CircleButton
- (void)drawRect:(NSRect)dirtyRect {
  CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
  NSRect r = NSMakeRect((self.bounds.size.width-d)/2.0, (self.bounds.size.height-d)/2.0, d, d);
  NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:r];
  [(self.circleColor ?: [NSColor systemGreenColor]) setFill];
  [p fill];
  // glyph
  [[NSColor whiteColor] setStroke];
  NSBezierPath *g = [NSBezierPath bezierPath];
  g.lineWidth = 2.2;
  g.lineCapStyle = NSLineCapStyleRound;
  CGFloat c = d * 0.5, arm = d * 0.22;
  if ([self.glyph isEqualToString:@"+"]) {
    [g moveToPoint:NSMakePoint(c-arm, c)]; [g lineToPoint:NSMakePoint(c+arm, c)];
    [g moveToPoint:NSMakePoint(c, c-arm)]; [g lineToPoint:NSMakePoint(c, c+arm)];
  } else if ([self.glyph isEqualToString:@"search"]) {
    CGFloat r = d * 0.26;
    NSBezierPath *mag = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c - r - d*0.04, c - r + d*0.04, r*2, r*2)];
    mag.lineWidth = MAX(1.2, d * 0.10);
    [[NSColor whiteColor] setStroke];
    [mag stroke];
    NSBezierPath *h = [NSBezierPath bezierPath];
    h.lineWidth = MAX(1.2, d * 0.10);
    h.lineCapStyle = NSLineCapStyleRound;
    [h moveToPoint:NSMakePoint(c + r*0.55, c - r*0.55 + d*0.04)];
    [h lineToPoint:NSMakePoint(c + r*1.25, c - r*1.25 + d*0.04)];
    [h stroke];
    return;
  } else {
    [g moveToPoint:NSMakePoint(c-arm, c)]; [g lineToPoint:NSMakePoint(c+arm, c)];
  }
  [g stroke];
}
- (BOOL)isFlipped { return NO; }
@end

@interface Controller : NSObject <NSWindowDelegate, NSTextFieldDelegate>
@property (strong) NSWindow *window;
@property (strong) NSView *listContainer;
@property (strong) NSScrollView *scroll;
@property (strong) NSMutableArray<RowView *> *rows;
@property (strong) NSMutableArray<NSDictionary *> *items;
@property (assign) NSInteger sel;
@property (strong) NSTextField *titleLabel;
@property (strong) BackdropView *backdrop;
@property (strong) NSVisualEffectView *vibrancy;
@property (strong) NSButton *skinBtn;
@property (strong) NSButton *addBtn;
@property (strong) NSButton *removeBtn;
@property (strong) PillButton *cancelBtn;
@property (strong) PillButton *openBtn;
@property (strong) PillButton *cLightRed;
@property (strong) PillButton *cLightYellow;
@property (strong) PillButton *cLightGreen;
@property (strong) TitlePillView *windowTitleLabel;
@property (strong) NSTextField *hintLabel;
@property (strong) NSTextField *searchField;
@property (strong) NSButton *pinBtn;
@property BOOL pinned;
@property (strong) CircleButton *searchBtn;
@property (copy) NSString *searchQuery;
@property BOOL searchActive;
@property (strong) NSTimer *searchAutoHideTimer;
@property (strong) NSMutableDictionary *customShortcuts;
@property (strong) NSWindow *shortcutPanel;
@property (strong) NSArray<ShortcutRowView *> *shortcutRows;
@property NSInteger shortcutSel;
@property NSInteger hoverRow;
@property (copy) NSString *appIconEditTarget;
@property (strong) NSPanel *appIconPanel;
@property (strong) NSSlider *appIconSizeSlider;
@property (strong) NSSlider *appIconCornerSlider;
@property (strong) NSPopUpButton *appIconPicker;
@property (strong) NSPopUpButton *appIconModePicker;
@property (strong) NSButton *appIconSizeCover;
@property (strong) NSButton *appIconCornerCover;
@property (strong) AppIconView *appIconPreview;
@property (strong) NSPanel *cropPanel;
@property (strong) CropView *cropView;
@property (strong) NSImage *croppedResult;
@property (strong) NSTextField *appIconSizeLabel;
@property (strong) NSTextField *appIconCornerLabel;
@property (copy) NSString *recordingAction;
@property (strong) id keyMonitor;
@property (strong) id recordingMonitor;
@property (strong) id activityMonitor;
@property (strong) NSTimer *idleExitTimer;
@property NSInteger userColumns;
@property (copy) NSString *customIconPath;
@property NSInteger forceColumns;
@property CGFloat lastContentWidth;
@property (strong) LightButton *lightRed;
@property (strong) LightButton *lightYellow;
@property (strong) LightButton *lightGreen;
@property (strong) NSPanel *zoomPanel;
@property (strong) NSTimer *zoomHideTimer;
@property (strong) NSTimer *hoverOpenTimer;
@property (strong) NSPanel *glassPanel;
@property (strong) NSPanel *shapePanel;
@property (strong) NSSlider *shapeSlider;
@property (strong) NSTextField *shapeValueLabel;
@property (strong) NSSlider *glassSlider;
@property (strong) NSTextField *glassValueLabel;
@end

@interface Controller (Actions)
- (void)openSelected:(id)sender;
- (void)closeCancel:(id)sender;
- (void)addApps:(id)sender;
- (void)removeSelected:(id)sender;
- (void)loadIconsFrom:(NSInteger)start;
- (void)selectRow:(NSInteger)idx;
- (void)applyTheme;
- (void)showSkinMenu:(id)sender;
- (void)skinWhite:(id)sender;
- (void)skinBlack:(id)sender;
- (void)skinGlass:(id)sender;
- (void)showGlassPanel:(id)sender;
- (void)glassSliderChanged:(id)sender;
- (void)closeGlassPanel:(id)sender;
- (void)showShapePanel:(id)sender;
- (void)shapeSliderChanged:(id)sender;
- (void)resetShapeRectangle:(id)sender;
- (void)toggleIdleExit:(id)sender;
- (void)resetIdleTimer;
- (void)idleExitFired:(NSTimer *)t;
- (void)refreshListAndCaches:(id)sender;
- (void)createGroupTapped:(id)sender;
- (void)renameSelectedItem:(id)sender;
- (BOOL)updateLabel:(NSString *)newLabel forTarget:(NSString *)target;
- (BOOL)createGroupNamed:(NSString *)name;
- (void)deleteCurrentGroup:(id)sender;
- (void)addDockEntryForPath:(NSString *)path label:(NSString *)label;
- (void)removeDockEntryForPath:(NSString *)path;
- (void)togglePin:(id)sender;
- (void)updatePinAppearance;
- (void)closeShapePanel:(id)sender;
- (void)setupTrafficLights;
- (void)greenLightTapped:(id)sender;
- (void)redLightTapped:(id)sender;
- (void)yellowLightTapped:(id)sender;
- (void)showZoomPanel;
- (void)hideZoomPanel;
- (void)zoomPanelThree:(id)sender;
- (void)zoomPanelFour:(id)sender;
- (void)hideZoomPanelAfterDelay:(NSTimeInterval)delay;
- (void)hideZoomPanelTimerFired:(NSTimer *)t;
- (void)customPick:(id)sender;
- (void)skinReset:(id)sender;
- (void)layoutSingle:(id)sender;
- (void)layoutThree:(id)sender;
- (void)layoutFour:(id)sender;
- (void)applyLayoutColumns:(NSInteger)cols;
- (void)promptIconChange;
- (void)pickIconImage:(id)sender;
- (void)resetCustomIcon:(id)sender;
- (void)applyCustomIconAtPath:(NSString *)path;
- (NSImage *)composeIconWithImage:(NSImage *)img;
- (NSString *)emojiForGroup;
- (void)toggleSearch;
- (void)closeSearch;
- (void)applySearchQuery;
- (void)searchTapped:(id)sender;
- (void)renameGroupFromTitle;
- (void)cLightRedTapped:(id)sender;
- (void)cLightYellowTapped:(id)sender;
- (void)cLightGreenTapped:(id)sender;
- (void)updateGroupDisplayName:(NSString *)name;
- (void)performFullRename:(NSString *)typed;
- (void)batchStripGroupSuffix:(id)sender;
- (void)repairDockMenuTapped:(id)sender;
- (void)repairDockEntries;
- (BOOL)dockHasEntryForPath:(NSString *)path;
- (void)updateDockLabelForPath:(NSString *)path label:(NSString *)label;
- (NSString *)currentBundlePathByID;
- (BOOL)renameBundleAtPath:(NSString *)oldPath toBase:(NSString *)newBase display:(NSString *)display;
- (void)writeInfoNamesInBundle:(NSString *)bundlePath base:(NSString *)base display:(NSString *)display;
- (void)updateDockPathFrom:(NSString *)oldPath to:(NSString *)newPath;
- (void)loadCustomShortcuts;
- (void)saveCustomShortcuts;
- (void)showShortcutSettings:(id)sender;
- (void)refreshShortcutRows;
- (void)shortcutPanelKeyDown:(NSEvent *)event;
- (void)startRecordingForAction:(NSString *)actionId;
- (void)resetShortcutForAction:(NSString *)actionId;
- (NSString *)shortcutSuffixForAction:(NSString *)actionId;
- (NSUserDefaults *)sharedShortcutDefaults;
- (void)closeShortcutPanel:(id)sender;
- (void)beginRecordingShortcut:(id)sender;
- (void)finishRecordingWithEvent:(NSEvent *)event;
- (BOOL)handleCustomShortcut:(NSEvent *)event;
- (void)performShortcutAction:(NSString *)action;
- (void)scheduleSearchAutoHide;
- (void)searchAutoHideFired:(NSTimer *)t;
- (void)moveSel:(NSInteger)delta;
- (void)moveSelRow:(NSInteger)dir;
- (NSInteger)effectiveColumns;
- (NSInteger)displayColumns;
- (void)setDisplayListMode:(id)sender;
- (void)setDisplayIconMode:(id)sender;
- (void)showAppIconPanel:(id)sender;
- (void)appIconSizeChanged:(id)sender;
- (void)appIconCornerChanged:(id)sender;
- (void)pickAppIconImage:(id)sender;
- (void)resetAppIcon:(id)sender;
- (void)closeAppIconPanel:(id)sender;
- (void)appIconPickerChanged:(id)sender;
- (void)renameCurrentApp:(id)sender;
- (void)appIconModePickerChanged:(id)sender;
- (void)updateAppIconPanelState;
- (void)showIconModeRequired:(id)sender;
- (NSImage *)runCropForImage:(NSImage *)image;
- (void)cropConfirm:(id)sender;
- (void)cropCancel:(id)sender;
- (void)updateAppIconPreview;
- (void)updateSelectedIconAppearance;
@end

static NSColor *ThemeBG(NSInteger t) {
  switch (t) {
    case 1: return [NSColor colorWithCalibratedWhite:0.11 alpha:1.0];
    case 2: return [NSColor clearColor];
    case 3: return [NSColor clearColor];
    default: return [NSColor whiteColor];
  }
}
static NSColor *ThemeText(NSInteger t) {
  switch (t) {
    case 1: case 2: case 3: return [NSColor whiteColor];
    default: return [NSColor colorWithCalibratedWhite:0.11 alpha:1.0];
  }
}
static NSColor *ThemeHint(NSInteger t) {
  switch (t) {
    case 1: case 2: case 3: return [NSColor colorWithCalibratedWhite:1.0 alpha:0.65];
    default: return [NSColor secondaryLabelColor];
  }
}
static NSColor *ThemeSel(NSInteger t) {
  switch (t) {
    case 1: case 2: case 3: return [NSColor colorWithCalibratedWhite:1.0 alpha:0.22];
    default: return [NSColor colorWithCalibratedRed:0.90 green:0.94 blue:1.0 alpha:1.0];
  }
}

@implementation RowView
- (void)drawRect:(NSRect)dirtyRect {
  if (!self.selected || self.iconMode) return;
  [(self.selColor ?: ThemeSel(gTheme)) setFill];
  NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:10 yRadius:10];
  [p fill];
}
- (void)mouseDown:(NSEvent *)event {
  [self.ctrl selectRow:self.idx];
  if (event.clickCount >= 2) [self.ctrl openSelected:nil];
}
@end

@interface PillButton : NSButton
@property (strong) NSColor *fillColor;
@property (strong) NSColor *strokeColor;
@property (strong) NSColor *textColor;
@property (strong) NSFont *textFont;
@property BOOL diagonalText;
@end

@implementation PillButton
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
  CGFloat h = self.bounds.size.height;
  NSRect r = NSInsetRect(self.bounds, 1, 1);
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:h/2.0 yRadius:h/2.0];
  NSColor *fill = self.fillColor ?: [NSColor controlAccentColor];
  if (self.isHighlighted) fill = [fill colorWithAlphaComponent:0.75];
  [fill setFill];
  [path fill];
  if (self.strokeColor) {
    [self.strokeColor setStroke];
    path.lineWidth = 1.5;
    [path stroke];
  }
  NSDictionary *attrs = @{
    NSForegroundColorAttributeName: self.textColor ?: [NSColor whiteColor],
    NSFontAttributeName: self.textFont ?: [NSFont systemFontOfSize:16 weight:NSFontWeightMedium]
  };
  if (self.diagonalText && self.title.length >= 2) {
    NSString *a = [self.title substringToIndex:1];
    NSString *b = [self.title substringFromIndex:1];
    NSSize as = [a sizeWithAttributes:attrs];
    NSSize bs = [b sizeWithAttributes:attrs];
    CGFloat cx = NSMidX(self.bounds), cy = NSMidY(self.bounds);
    CGFloat off = 3.5;
    [a drawAtPoint:NSMakePoint(cx - off - as.width/2.0, cy + off - as.height/2.0) withAttributes:attrs];
    [b drawAtPoint:NSMakePoint(cx + off - bs.width/2.0, cy - off - bs.height/2.0) withAttributes:attrs];
  } else {
    NSSize ts = [self.title sizeWithAttributes:attrs];
    NSPoint pt = NSMakePoint(NSMidX(self.bounds) - ts.width/2.0, NSMidY(self.bounds) - ts.height/2.0);
    [self.title drawAtPoint:pt withAttributes:attrs];
  }
}
@end

@interface TitlePillView : NSView
@property (copy) NSString *title;
@property (strong) NSFont *titleFont;
@property (copy) void (^onDoubleClick)(void);
@end

@implementation TitlePillView
- (BOOL)isFlipped { return NO; }
- (void)mouseDown:(NSEvent *)event {
  if (event.clickCount >= 2 && self.onDoubleClick) self.onDoubleClick();
}
- (void)drawRect:(NSRect)dirtyRect {
  CGFloat r = NSHeight(self.bounds) / 2.0;
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:r yRadius:r];
  [[NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0] setFill];
  [path fill];
  if (self.title.length == 0) return;
  NSFont *f = self.titleFont ?: [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
  NSDictionary *attrs = @{NSFontAttributeName: f, NSForegroundColorAttributeName: [NSColor whiteColor]};
  NSSize ts = [self.title sizeWithAttributes:attrs];
  NSPoint pt = NSMakePoint((NSWidth(self.bounds) - ts.width) / 2.0,
                           (NSHeight(self.bounds) - ts.height) / 2.0);
  [self.title drawAtPoint:pt withAttributes:attrs];
}
@end

@interface LightButton : NSButton
@property (strong) NSColor *dotColor;
@property (copy) void (^onHover)(BOOL inside);
@property (copy) void (^onRecord)(void);
@end

@implementation LightButton
- (BOOL)isFlipped { return NO; }
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *t in [self.trackingAreas copy]) [self removeTrackingArea:t];
  NSTrackingArea *a = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                   options:(NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect)
                                                     owner:self userInfo:nil];
  [self addTrackingArea:a];
}
- (void)mouseEntered:(NSEvent *)event { if (self.onHover) self.onHover(YES); }
- (void)mouseExited:(NSEvent *)event { if (self.onHover) self.onHover(NO); }
- (void)drawRect:(NSRect)dirtyRect {
  CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
  NSRect r = NSMakeRect((self.bounds.size.width-d)/2.0, (self.bounds.size.height-d)/2.0, d, d);
  NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:r];
  [(self.dotColor ?: [NSColor systemRedColor]) setFill];
  [p fill];
}
@end

@interface ShortcutRowView : NSView
@property (copy) NSString *actionId;
@property (copy) NSString *nameText;
@property (copy) NSString *sigText;
@property (copy) NSString *statusText;
@property BOOL selected;
@property BOOL hovered;
@property (copy) void (^onActivate)(void);
@property (copy) void (^onReset)(void);
@property (copy) void (^onHover)(BOOL inside);
@property (copy) void (^onRecord)(void);
@end

@implementation ShortcutRowView
- (BOOL)isFlipped { return NO; }
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *t in [self.trackingAreas copy]) [self removeTrackingArea:t];
  NSTrackingArea *a = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                   options:(NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect)
                                                     owner:self userInfo:nil];
  [self addTrackingArea:a];
}
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; if (self.onHover) self.onHover(YES); [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e { self.hovered = NO; if (self.onHover) self.onHover(NO); [self setNeedsDisplay:YES]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)mouseDown:(NSEvent *)e {
  BOOL dbl = (e.clickCount >= 2);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (dbl) { if (self.onRecord) self.onRecord(); }
    else { if (self.onActivate) self.onActivate(); }
  });
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  if (p.x > NSWidth(self.bounds) - 52) { if (self.onReset) self.onReset(); return; }
}
- (void)drawRect:(NSRect)dirtyRect {
  NSRect r = NSInsetRect(self.bounds, 2, 4);
  NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8];
  NSColor *fill = self.selected
      ? [NSColor colorWithCalibratedRed:1.0 green:0.68 blue:0.75 alpha:1.0]
      : [NSColor colorWithCalibratedWhite:0.93 alpha:1.0];
  [fill setFill]; [bg fill];

  NSFont *nf = [NSFont systemFontOfSize:13];
  NSDictionary *nattrs = @{NSFontAttributeName: nf, NSForegroundColorAttributeName: [NSColor blackColor]};
  [self.nameText drawAtPoint:NSMakePoint(14, NSMidY(self.bounds) - 9) withAttributes:nattrs];

  NSString *shown = self.statusText.length ? self.statusText
                 : (self.sigText.length ? DisplayForSignature(self.sigText) : @"未设置");
  NSFont *sf = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  NSDictionary *sattrs = @{NSFontAttributeName: sf,
                           NSForegroundColorAttributeName: ((self.sigText.length || self.statusText.length) ? [NSColor blackColor] : [NSColor grayColor])};
  NSSize ts = [shown sizeWithAttributes:sattrs];
  [shown drawAtPoint:NSMakePoint(NSWidth(self.bounds) - 66 - ts.width, NSMidY(self.bounds) - ts.height/2.0) withAttributes:sattrs];

  // 重置图标（圆形箭头）
  CGFloat cx = NSWidth(self.bounds) - 30, cy = NSMidY(self.bounds);
  NSBezierPath *arc = [NSBezierPath bezierPath];
  [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:8
                                  startAngle:40 endAngle:320 clockwise:NO];
  arc.lineWidth = 1.8;
  [[NSColor colorWithCalibratedWhite:0.35 alpha:1.0] setStroke];
  [arc stroke];
  NSBezierPath *arrow = [NSBezierPath bezierPath];
  [arrow moveToPoint:NSMakePoint(cx + 3, cy + 9)];
  [arrow lineToPoint:NSMakePoint(cx + 11, cy + 5)];
  [arrow lineToPoint:NSMakePoint(cx + 2, cy + 1)];
  [arrow closePath];
  [[NSColor colorWithCalibratedWhite:0.35 alpha:1.0] setFill];
  [arrow fill];
}
@end

@interface ShortcutPanelView : NSView
@property (weak) Controller *ctrl;
@end

@implementation ShortcutPanelView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { if (self.ctrl) [self.ctrl shortcutPanelKeyDown:event]; }
@end

@interface BackdropView : NSView
@property (strong) NSImage *image;
@property CGFloat scale, dx, dy;
@property BOOL editable;
@property (copy) void (^onChange)(void);
@end

@implementation BackdropView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
  if (!self.image) return;
  NSSize bs = self.bounds.size, is = self.image.size;
  if (is.width <= 0 || is.height <= 0) return;
  CGFloat base = MAX(bs.width/is.width, bs.height/is.height);
  CGFloat k = base * (self.scale > 0 ? self.scale : 1.0);
  NSSize ds = NSMakeSize(is.width*k, is.height*k);
  CGFloat ox = MAX(0.0, (ds.width - bs.width)/2.0) * self.dx;
  CGFloat oy = MAX(0.0, (ds.height - bs.height)/2.0) * self.dy;
  NSRect dr = NSMakeRect((bs.width-ds.width)/2.0 + ox, (bs.height-ds.height)/2.0 + oy, ds.width, ds.height);
  [self.image drawInRect:dr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
  [[NSColor colorWithCalibratedWhite:0 alpha:0.28] setFill];
  NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}
- (void)mouseDragged:(NSEvent *)e {
  if (!self.editable || !self.image) return;
  NSSize bs = self.bounds.size, is = self.image.size;
  CGFloat base = MAX(bs.width/is.width, bs.height/is.height);
  CGFloat k = base * (self.scale > 0 ? self.scale : 1.0);
  CGFloat overX = MAX(1.0, is.width*k - bs.width);
  CGFloat overY = MAX(1.0, is.height*k - bs.height);
  self.dx = MAX(-1.0, MIN(1.0, self.dx - e.deltaX*2.0/overX));
  self.dy = MAX(-1.0, MIN(1.0, self.dy + e.deltaY*2.0/overY));
  [self setNeedsDisplay:YES];
  if (self.onChange) self.onChange();
}
@end

@interface CropController : NSObject
@property (strong) NSWindow *win;
@property (strong) BackdropView *view;
@property (strong) NSSlider *slider;
@property (strong) NSImage *image;
@property (copy) void (^completion)(BOOL ok);
- (void)runModalForWindow:(NSWindow *)parent;
@end

@implementation CropController
- (void)runModalForWindow:(NSWindow *)parent {
  self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,680,520)
                                         styleMask:(NSWindowStyleMaskTitled)
                                           backing:NSBackingStoreBuffered defer:NO];
  self.win.title = @"自定义皮肤 · 拖动调整位置";
  NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0,0,680,520)];
  cv.wantsLayer = YES;
  cv.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.12 alpha:1.0].CGColor;
  self.win.contentView = cv;

  self.view = [[BackdropView alloc] initWithFrame:NSMakeRect(20,140,640,360)];
  self.view.image = self.image;
  self.view.scale = gImgScale;
  self.view.dx = gImgDX;
  self.view.dy = gImgDY;
  self.view.editable = YES;
  __weak CropController *weakSelf = self;
  self.view.onChange = ^{
    if (weakSelf.slider) [weakSelf.slider setDoubleValue:weakSelf.view.scale];
  };
  [cv addSubview:self.view];

  self.slider = [NSSlider sliderWithValue:gImgScale minValue:1.0 maxValue:4.0 target:self action:@selector(scaleChanged:)];
  self.slider.frame = NSMakeRect(120, 96, 320, 24);
  [cv addSubview:self.slider];
  NSTextField *lab = [NSTextField labelWithString:@"缩放"];
  lab.textColor = [NSColor whiteColor];
  lab.font = [NSFont systemFontOfSize:13];
  lab.frame = NSMakeRect(70, 96, 40, 20);
  [cv addSubview:lab];
  NSTextField *tip = [NSTextField labelWithString:@"拖动图片选择显示区域"];
  tip.textColor = [NSColor colorWithCalibratedWhite:1 alpha:0.6];
  tip.font = [NSFont systemFontOfSize:12];
  tip.frame = NSMakeRect(20, 44, 300, 18);
  [cv addSubview:tip];

  PillButton *apply = [[PillButton alloc] initWithFrame:NSMakeRect(680-20-56, 18, 56, 56)];
  apply.title = @"应用";
  apply.diagonalText = NO;
  apply.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0];
  apply.strokeColor = [NSColor colorWithCalibratedRed:0.78 green:0.22 blue:0.20 alpha:1.0];
  apply.textColor = [NSColor whiteColor];
  apply.textFont = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
  apply.bordered = NO;
  apply.focusRingType = NSFocusRingTypeNone;
  apply.target = self;
  apply.action = @selector(applyTap:);
  [cv addSubview:apply];

  PillButton *cancel = [[PillButton alloc] initWithFrame:NSMakeRect(20, 18, 56, 56)];
  cancel.title = @"取消";
  cancel.diagonalText = NO;
  cancel.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.80 blue:0.10 alpha:1.0];
  cancel.strokeColor = [NSColor colorWithCalibratedRed:0.80 green:0.62 blue:0.05 alpha:1.0];
  cancel.textColor = [NSColor blackColor];
  cancel.textFont = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
  cancel.bordered = NO;
  cancel.focusRingType = NSFocusRingTypeNone;
  cancel.target = self;
  cancel.action = @selector(cancelTap:);
  [cv addSubview:cancel];

  (void)parent;
  [NSApp runModalForWindow:self.win];
}

- (void)scaleChanged:(NSSlider *)s { self.view.scale = s.doubleValue; [self.view setNeedsDisplay:YES]; }
- (void)applyTap:(id)sender {
  gImgScale = self.view.scale; gImgDX = self.view.dx; gImgDY = self.view.dy;
  [NSApp stopModal];
  [self.win orderOut:nil];
  if (self.completion) self.completion(YES);
}
- (void)cancelTap:(id)sender {
  [NSApp stopModal];
  [self.win orderOut:nil];
  if (self.completion) self.completion(NO);
}
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation ContentView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
  NSString *chars = event.charactersIgnoringModifiers;
  unichar c = 0;
  if (chars.length) c = [chars characterAtIndex:0];
  if (event.keyCode == 118) { [self.ctrl toggleSearch]; }              // F4
  else if ((event.modifierFlags & NSEventModifierFlagCommand) && c == ' ') { [self.ctrl toggleSearch]; } // ⌘Space
  else if (c == NSUpArrowFunctionKey) { [self.ctrl moveSelRow:-1]; }
  else if (c == NSDownArrowFunctionKey) { [self.ctrl moveSelRow:1]; }
  else if (c == NSLeftArrowFunctionKey) { [self.ctrl moveSel:-1]; }
  else if (c == NSRightArrowFunctionKey) { [self.ctrl moveSel:1]; }
  else if (c == NSCarriageReturnCharacter || c == NSEnterCharacter || c == 10) { [self.ctrl openSelected:nil]; }
  else if (c == 127 || c == 8) { [self.ctrl removeSelected:nil]; }
  else if (c == 27) { [self.ctrl closeCancel:nil]; }
  else { [super keyDown:event]; }
}
@end

// ================= 可自定义快捷键 =================
static NSArray<NSDictionary *> *ShortcutActions(void) {
  return @[
    @{@"id": @"add",    @"name": @"添加应用",   @"sel": @"addApps:"},
    @{@"id": @"remove", @"name": @"移除应用",   @"sel": @"removeSelected:"},
    @{@"id": @"skin",   @"name": @"皮肤/布局",  @"sel": @"showSkinMenu:"},
    @{@"id": @"search", @"name": @"搜索本组",   @"sel": @"toggleSearch"},
    @{@"id": @"open",   @"name": @"打开选中",   @"sel": @"openSelected:"},
    @{@"id": @"cancel", @"name": @"取消/关闭",  @"sel": @"closeCancel:"},
  ];
}

static NSString *KeyNameForCode(unsigned short code) {
  switch (code) {
    case 122: return @"f1"; case 120: return @"f2"; case 99: return @"f3"; case 118: return @"f4";
    case 96: return @"f5"; case 97: return @"f6"; case 98: return @"f7"; case 100: return @"f8";
    case 101: return @"f9"; case 109: return @"f10"; case 103: return @"f11"; case 111: return @"f12";
    default: return nil;
  }
}

static NSString *SignatureForEvent(NSEvent *e) {
  NSMutableString *sig = [NSMutableString string];
  NSEventModifierFlags f = e.modifierFlags;
  if (f & NSEventModifierFlagCommand) [sig appendString:@"cmd+"];
  if (f & NSEventModifierFlagControl) [sig appendString:@"ctrl+"];
  if (f & NSEventModifierFlagOption)  [sig appendString:@"opt+"];
  if (f & NSEventModifierFlagShift)   [sig appendString:@"shift+"];
  NSString *fn = KeyNameForCode(e.keyCode);
  NSString *key = fn;
  if (!key) {
    key = [e.charactersIgnoringModifiers lowercaseString];
    if (key.length == 0) key = [NSString stringWithFormat:@"key%u", e.keyCode];
  }
  [sig appendString:key];
  return sig;
}

static NSString *DisplayForSignature(NSString *sig) {
  if (sig.length == 0) return @"（未设置）";
  NSMutableString *out = [NSMutableString string];
  NSArray *parts = [sig componentsSeparatedByString:@"+"];
  for (NSString *p in parts) {
    if ([p isEqualToString:@"cmd"]) [out appendString:@"⌘"];
    else if ([p isEqualToString:@"ctrl"]) [out appendString:@"⌃"];
    else if ([p isEqualToString:@"opt"]) [out appendString:@"⌥"];
    else if ([p isEqualToString:@"shift"]) [out appendString:@"⇧"];
    else if (p.length == 1) [out appendString:[p uppercaseString]];
    else [out appendString:[p uppercaseString]];
  }
  return out;
}

static BOOL SignatureIsAllowed(NSString *sig) {
  if (sig.length == 0) return NO;
  return [sig componentsSeparatedByString:@"+"].lastObject.length > 0;
}

static BOOL SignatureHasModifier(NSString *sig) {
  if ([sig hasPrefix:@"f"] && sig.length <= 3) return YES;
  return ([sig containsString:@"cmd+"] || [sig containsString:@"ctrl+"] ||
          [sig containsString:@"opt+"] || [sig containsString:@"shift+"]);
}

// ================= 快捷键 / 操作说明（唯一数据源） =================
// 以后新增快捷键或按钮功能时，只需在这里加一行，底部提示会自动更新。
static NSArray<NSDictionary *> *ShortcutTable(void) {
  return @[
    @{@"keys": @"←→↑↓", @"desc": @"选择"},
    @{@"keys": @"Enter",  @"desc": @"打开"},
    @{@"keys": @"⌫",      @"desc": @"移除"},
    @{@"keys": @"Esc",    @"desc": @"取消"},
    @{@"keys": @"双击",   @"desc": @"打开"},
    @{@"keys": @"＋",     @"desc": @"添加"},
    @{@"keys": @"−",      @"desc": @"移除"},
    @{@"keys": @"🎨",     @"desc": @"皮肤/布局"},
  ];
}

static NSString *ShortcutHintText(void) {
  NSArray *table = ShortcutTable();
  NSMutableArray *parts = [NSMutableArray array];
  for (NSDictionary *it in table) {
    [parts addObject:[NSString stringWithFormat:@"%@ %@", it[@"keys"], it[@"desc"]]];
  }
  // 两行显示，避免 480 宽窗口下溢出
  NSUInteger half = (parts.count + 1) / 2;
  NSString *line1 = [[parts subarrayWithRange:NSMakeRange(0, half)] componentsJoinedByString:@" · "];
  NSString *line2 = half < parts.count
      ? [[parts subarrayWithRange:NSMakeRange(half, parts.count - half)] componentsJoinedByString:@" · "]
      : @"";
  return line2.length ? [NSString stringWithFormat:@"%@\n%@", line1, line2] : line1;
}

static NSString *ResolveAppPath(NSString *target) {
  if ([target hasPrefix:@"/"]) {
    return [[NSFileManager defaultManager] fileExistsAtPath:target] ? target : nil;
  }
  NSArray *dirs = @[@"/Applications", @"/System/Applications", @"/System/Applications/Utilities",
                    [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
  for (NSString *d in dirs) {
    NSString *p = [[d stringByAppendingPathComponent:target] stringByAppendingPathExtension:@"app"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
  }
  return nil;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (weak) NSWindow *mainWindow;
@property (weak) Controller *controller;
@property NSTimeInterval lastReopen;
@end

@implementation AppDelegate
- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
  NSMenu *m = [[NSMenu alloc] init];
  NSMenuItem *it = [m addItemWithTitle:@"更换图标（人物图片）…" action:@selector(dockChangeIcon:) keyEquivalent:@""];
  it.target = self;
  it = [m addItemWithTitle:@"恢复默认图标" action:@selector(dockResetIcon:) keyEquivalent:@""];
  it.target = self;
  [m addItem:[NSMenuItem separatorItem]];
  it = [m addItemWithTitle:@"显示分组窗口" action:@selector(dockOpen:) keyEquivalent:@""];
  it.target = self;
  return m;
}

- (void)dockChangeIcon:(id)sender { [self.controller promptIconChange]; }
- (void)dockResetIcon:(id)sender { [self.controller resetCustomIcon:nil]; }
- (void)dockOpen:(id)sender {
  if (self.mainWindow) { if (self.mainWindow.isMiniaturized) [self.mainWindow deminiaturize:nil]; [self.mainWindow makeKeyAndOrderFront:nil]; }
  [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  if (getenv("DOCKLAUNCHER_BENCH")) fprintf(stderr, "REOPEN visible=%d\n", flag);
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (self.controller && now - self.lastReopen < 0.9 && self.lastReopen > 0) {
    self.lastReopen = 0;
    [self.controller promptIconChange];
    return YES;
  }
  self.lastReopen = now;
  if (self.mainWindow) {
    if (self.mainWindow.isMiniaturized) [self.mainWindow deminiaturize:nil];
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
  }
  return YES;
}
@end

@implementation Controller

- (NSArray<NSDictionary *> *)loadItems {
  NSMutableArray *arr = [NSMutableArray array];
  NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
  if (!content) return arr;
  for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (line.length == 0 || [line hasPrefix:@"#"]) continue;
    NSString *label = line, *target = line;
    NSRange r = [line rangeOfString:@"|"];
    if (r.location != NSNotFound) {
      label = [[line substringToIndex:r.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      target = [[line substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    if (target.length == 0) continue;
    if (label.length == 0) label = target;
    [arr addObject:@{@"label": label, @"target": target}];
  }
  return arr;
}

- (void)buildWindow {
  NSRect frame = NSMakeRect(0, 0, 480, 600);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.title = gGroup;
  self.window.releasedWhenClosed = NO;
  self.window.delegate = self;
  self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
  self.window.contentMinSize = NSMakeSize(420, 480);
  self.window.titlebarAppearsTransparent = YES;
  self.window.titleVisibility = NSWindowTitleHidden;
  self.window.movableByWindowBackground = YES;

  ContentView *cv = [[ContentView alloc] initWithFrame:frame];
  cv.ctrl = self;
  cv.wantsLayer = YES;
  cv.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.96 green:0.965 blue:0.972 alpha:1.0].CGColor;
  self.window.contentView = cv;

  CGFloat W = 480, H = 600;

  self.windowTitleLabel = [[TitlePillView alloc] initWithFrame:NSZeroRect];
  self.windowTitleLabel.title = gGroup;
  self.windowTitleLabel.titleFont = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
  __weak Controller *weakTitleSelf = self;
  self.windowTitleLabel.onDoubleClick = ^{ [weakTitleSelf renameGroupFromTitle]; };
  self.windowTitleLabel.toolTip = @"双击重命名分组";
  [cv addSubview:self.windowTitleLabel];


  CGFloat btnSize = 30.0;

  CircleButton *add = [[CircleButton alloc] initWithFrame:NSMakeRect(16, H-12-btnSize, btnSize, btnSize)];
  add.circleColor = [NSColor colorWithCalibratedRed:0.16 green:0.78 blue:0.25 alpha:1.0];
  add.glyph = @"+";
  add.bordered = NO;
  add.title = @"";
  add.focusRingType = NSFocusRingTypeNone;
  add.target = self;
  add.action = @selector(addApps:);
  [cv addSubview:add];
  self.addBtn = add;

  CircleButton *remove = [[CircleButton alloc] initWithFrame:NSMakeRect(W-16-btnSize, H-12-btnSize, btnSize, btnSize)];
  remove.circleColor = [NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0];
  remove.glyph = @"-";
  remove.bordered = NO;
  remove.title = @"";
  remove.focusRingType = NSFocusRingTypeNone;
  remove.target = self;
  remove.action = @selector(removeSelected:);
  [cv addSubview:remove];
  self.removeBtn = remove;

  // 中间：皮肤按钮（黄色圆形 + 🎨）
  self.skinBtn = [NSButton buttonWithTitle:@"🎨" target:self action:@selector(showSkinMenu:)];
  self.skinBtn.frame = NSMakeRect((W-btnSize)/2.0, H-12-btnSize, btnSize, btnSize);
  self.skinBtn.font = [NSFont systemFontOfSize:16];
  self.skinBtn.bordered = NO;
  self.skinBtn.focusRingType = NSFocusRingTypeNone;
  self.skinBtn.wantsLayer = YES;
  self.skinBtn.layer.backgroundColor = [NSColor colorWithCalibratedRed:1.0 green:0.80 blue:0.10 alpha:1.0].CGColor;
  self.skinBtn.layer.cornerRadius = 15;
  [cv addSubview:self.skinBtn];

  self.searchBtn = [[CircleButton alloc] initWithFrame:NSMakeRect(W-16-30-38, H-88, 30, 30)];
  self.searchBtn.circleColor = [NSColor colorWithCalibratedRed:0.04 green:0.52 blue:1.0 alpha:1.0];
  self.searchBtn.glyph = @"search";
  self.searchBtn.bordered = NO;
  self.searchBtn.title = @"";
  self.searchBtn.focusRingType = NSFocusRingTypeNone;
  self.searchBtn.target = self;
  self.searchBtn.action = @selector(searchTapped:);
  self.searchBtn.toolTip = @"搜索本组应用（F4 或 ⌘Space）";
  [cv addSubview:self.searchBtn];

  self.pinBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(togglePin:)];
  self.pinBtn.frame = NSMakeRect(W-44, H-34, 28, 28);
  self.pinBtn.bordered = NO;
  self.pinBtn.focusRingType = NSFocusRingTypeNone;
  self.pinBtn.toolTip = @"钉住：禁止自动退出与关闭窗口（再点取消）";
  [cv addSubview:self.pinBtn];
  self.pinned = [[NSUserDefaults standardUserDefaults] boolForKey:@"pinned"];

  self.cLightRed = [[PillButton alloc] initWithFrame:NSMakeRect(0,0,14,14)];
  self.cLightRed.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0];
  self.cLightRed.target = self; self.cLightRed.action = @selector(cLightRedTapped:);
  self.cLightRed.bordered = NO; self.cLightRed.title = @""; self.cLightRed.focusRingType = NSFocusRingTypeNone;
  self.cLightYellow = [[PillButton alloc] initWithFrame:NSMakeRect(0,0,14,14)];
  self.cLightYellow.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.74 blue:0.18 alpha:1.0];
  self.cLightYellow.target = self; self.cLightYellow.action = @selector(cLightYellowTapped:);
  self.cLightYellow.bordered = NO; self.cLightYellow.title = @""; self.cLightYellow.focusRingType = NSFocusRingTypeNone;
  self.cLightGreen = [[PillButton alloc] initWithFrame:NSMakeRect(0,0,14,14)];
  self.cLightGreen.fillColor = [NSColor colorWithCalibratedRed:0.16 green:0.78 blue:0.25 alpha:1.0];
  self.cLightGreen.target = self; self.cLightGreen.action = @selector(cLightGreenTapped:);
  self.cLightGreen.bordered = NO; self.cLightGreen.title = @""; self.cLightGreen.focusRingType = NSFocusRingTypeNone;
  for (PillButton *b in @[self.cLightRed, self.cLightYellow, self.cLightGreen]) { b.hidden = YES; [cv addSubview:b]; }
  self.cLightRed.toolTip = @"关闭"; self.cLightYellow.toolTip = @"最小化"; self.cLightGreen.toolTip = @"放大";

  self.searchField = [[NSTextField alloc] initWithFrame:NSMakeRect(W/2.0-170, H-50, 340, 30)];
  self.searchField.placeholderString = @"搜索本组应用…";
  self.searchField.font = [NSFont systemFontOfSize:14];
  self.searchField.bezelStyle = NSTextFieldRoundedBezel;
  self.searchField.delegate = self;
  self.searchField.hidden = YES;
  [cv addSubview:self.searchField];

  [[self.window standardWindowButton:NSWindowCloseButton] setToolTip:@"关闭"];
  [[self.window standardWindowButton:NSWindowMiniaturizeButton] setToolTip:@"最小化"];
  [[self.window standardWindowButton:NSWindowZoomButton] setToolTip:@"放大（Option+点击 = 四列）"];

  [cv addSubview:add positioned:NSWindowAbove relativeTo:nil];
  [cv addSubview:remove positioned:NSWindowAbove relativeTo:nil];

  self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 76, W-32, H-54-76)];
  self.scroll.hasVerticalScroller = YES;
  self.scroll.drawsBackground = YES;
  self.scroll.backgroundColor = [NSColor whiteColor];
  self.scroll.autohidesScrollers = YES;
  self.scroll.wantsLayer = YES;
  self.scroll.layer.cornerRadius = 12;
  [cv addSubview:self.scroll];

  self.listContainer = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,W-32,10)];
  self.scroll.documentView = self.listContainer;

  PillButton *cancel = [[PillButton alloc] initWithFrame:NSMakeRect(16, 10, 56, 56)];
  cancel.title = @"取消";
  cancel.diagonalText = NO;
  cancel.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.80 blue:0.10 alpha:1.0];
  cancel.strokeColor = [NSColor colorWithCalibratedRed:0.80 green:0.62 blue:0.05 alpha:1.0];
  cancel.textColor = [NSColor blackColor];
  cancel.textFont = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
  cancel.bordered = NO;
  cancel.focusRingType = NSFocusRingTypeNone;
  cancel.target = self;
  cancel.action = @selector(closeCancel:);
  [cv addSubview:cancel];
  self.cancelBtn = cancel;

  PillButton *open = [[PillButton alloc] initWithFrame:NSMakeRect(W-16-56, 10, 56, 56)];
  open.title = @"打开";
  open.diagonalText = NO;
  open.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0];
  open.strokeColor = [NSColor colorWithCalibratedRed:0.78 green:0.22 blue:0.20 alpha:1.0];
  open.textColor = [NSColor whiteColor];
  open.textFont = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
  open.bordered = NO;
  open.focusRingType = NSFocusRingTypeNone;
  open.keyEquivalent = @"\r";
  open.target = self;
  open.action = @selector(openSelected:);
  [cv addSubview:open];
  self.openBtn = open;
  [self setupTooltips];

  __weak Controller *weakSelf = self;
  self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
    Controller *ss = weakSelf; if (!ss) return e;
    [ss resetIdleTimer];
    if ([NSApp modalWindow]) return e;
    if (ss.appIconPanel && ss.appIconPanel.isVisible) return e;
    if ([ss handleCustomShortcut:e]) return nil;
    return e;
  }];

  self.activityMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskAny handler:^NSEvent *(NSEvent *e) {
    Controller *ss = weakSelf; if (ss) [ss resetIdleTimer];
    return e;
  }];
  [self resetIdleTimer];

  self.hintLabel = [NSTextField labelWithString:@"←→↑↓ 选择 · Enter 打开 · ⌫ 移除 · Esc 取消"];
  self.hintLabel.font = [NSFont systemFontOfSize:11];
  self.hintLabel.textColor = ThemeHint(gTheme);
  self.hintLabel.alignment = NSTextAlignmentCenter;
  self.hintLabel.frame = NSMakeRect(96, 10, W-192, 34);
  [cv addSubview:self.hintLabel];

  self.rows = [NSMutableArray array];
  [self reload];
  [self applyTheme];
  [self layoutContent];
  [self updatePinAppearance];
  [self.window makeFirstResponder:cv];
}

- (void)reload {
  NSArray *allItems = [self loadItems];
  if (self.searchQuery.length > 0) {
    NSPredicate *p = [NSPredicate predicateWithFormat:@"label CONTAINS[cd] %@ OR target CONTAINS[cd] %@", self.searchQuery, self.searchQuery];
    allItems = [allItems filteredArrayUsingPredicate:p];
  }
  self.items = [allItems mutableCopy];
  for (NSView *v in [self.listContainer.subviews copy]) [v removeFromSuperview];
  [self.rows removeAllObjects];

  BOOL icons = gIconMode;
  NSInteger cols = [self displayColumns];
  CGFloat W = self.scroll ? MAX(200, self.scroll.contentSize.width) : (480 - 32);
  CGFloat cellW = floor(W / cols);
  CGFloat rowH = icons ? MAX(72.0, MIN(cellW, 96.0)) : 56.0;
  NSInteger rowCount = (self.items.count + cols - 1) / (cols > 0 ? cols : 1);
  self.listContainer.frame = NSMakeRect(0, 0, W, MAX(rowCount * rowH, 10));

  BOOL narrow = (cellW < 250);
  NSFont *f = [NSFont systemFontOfSize:(narrow ? 16 : 18)];
  NSInteger i = 0;
  for (NSDictionary *it in self.items) {
    NSInteger col = i % cols, gridRow = i / cols;
    NSRect cell = icons ? NSMakeRect(col * cellW + 4, gridRow * rowH + 4, cellW - 8, rowH - 8)
                        : NSMakeRect(col * cellW + 3, gridRow * rowH, cellW - 6, rowH);
    RowView *row = [[RowView alloc] initWithFrame:cell];
    row.idx = i;
    row.ctrl = self;
    row.selected = (i == self.sel);
    row.selColor = ThemeSel(gTheme);

    NSString *target = it[@"target"];
    NSString *path = ResolveAppPath(target);
    NSImage *icon = nil;
    if (path) icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
    NSDictionary *cfg = (icons && target) ? gAppIconSettings[target] : nil;
    CGFloat customSz = cfg[@"size"] ? [cfg[@"size"] doubleValue] : 0;
    CGFloat customCorner = cfg[@"corner"] ? [cfg[@"corner"] doubleValue] : 0;
    if (icons) {
      CGFloat sz = customSz > 0 ? customSz : MIN(cell.size.width * 0.62, MIN(cell.size.height * 0.72, 64.0));
      sz = MAX(24.0, sz);
      NSRect iconFrame = NSMakeRect((cell.size.width - sz)/2.0 - 0.6, (cell.size.height - sz)/2.0 - 0.6, sz + 1.2, sz + 1.2);
      AppIconView *iv = [[AppIconView alloc] initWithFrame:iconFrame];
      iv.cornerRatio = customCorner;
      iv.hugHighlight = YES;
      iv.selected = row.selected;
      iv.selColor = row.selColor;
      row.iconMode = YES;
      row.iconRect = iconFrame;
      row.iconCorner = customCorner;
      [row addSubview:iv];
      row.iconView = iv;
      row.label = nil;
      row.toolTip = it[@"label"];
      [self.listContainer addSubview:row];
      [self.rows addObject:row];
      i++;
      continue;
    }
    CGFloat iconSize = narrow ? 34 : 40;
    CGFloat iconX = narrow ? 12 : 20;
    if (customSz > 0) iconSize = MAX(24.0, MIN(customSz, rowH - 10));
    CGFloat textX = iconX + iconSize + (narrow ? 8 : 14);
    NSTextField *lab = [NSTextField labelWithString:it[@"label"]];
    lab.font = f;
    lab.textColor = ThemeText(gTheme);
    lab.lineBreakMode = NSLineBreakByTruncatingTail;
    lab.frame = NSMakeRect(textX, (rowH-24)/2.0, MAX(40, cell.size.width - textX - 8), 24);
    AppIconView *iv = [[AppIconView alloc] initWithFrame:NSMakeRect(iconX, (rowH-iconSize)/2, iconSize, iconSize)];
    iv.cornerRatio = customCorner;
    [row addSubview:iv];
    [row addSubview:lab];
    row.iconView = iv;
    row.label = lab;
    [self.listContainer addSubview:row];
    [self.rows addObject:row];
    i++;
  }
  [self.listContainer setNeedsDisplay:YES];
  self.scroll.documentView = self.listContainer;
  [self loadIconsFrom:0];
}

- (void)loadIconsFrom:(NSInteger)start {
  NSInteger total = (NSInteger)self.items.count;
  if (start >= total) return;
  NSInteger end = MIN(start + 3, total);
  for (NSInteger i = start; i < end; i++) {
    NSDictionary *it = self.items[i];
    NSString *target = it[@"target"];
    NSDictionary *cfg = gIconMode ? gAppIconSettings[target] : nil;
    NSImage *img = nil;
    if (cfg[@"image"]) img = [[NSImage alloc] initWithContentsOfFile:cfg[@"image"]];
    if (!img) {
      NSString *path = ResolveAppPath(target);
      if (!path) continue;
      img = [[NSWorkspace sharedWorkspace] iconForFile:path];
    }
    self.rows[i].iconView.image = img;
  }
  if (end < total) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self loadIconsFrom:end];
    });
  }
}

- (void)selectRow:(NSInteger)idx {
  if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
  self.sel = idx;
  for (RowView *r in self.rows) {
    r.selected = (r.idx == idx);
    r.iconView.selected = (r.idx == idx);
    r.iconView.selColor = r.selColor;
    [r.iconView setNeedsDisplay:YES];
  }
  for (RowView *r in self.rows) [r setNeedsDisplay:YES];
  NSRect r = self.rows[idx].frame;
  [self.listContainer scrollRectToVisible:r];
}

- (void)moveSel:(NSInteger)delta {
  NSInteger idx = self.sel + delta;
  if (idx < 0) idx = 0;
  if (idx >= (NSInteger)self.rows.count) idx = self.rows.count - 1;
  if (self.rows.count) [self selectRow:idx];
}

- (void)moveSelRow:(NSInteger)dir {
  NSInteger cols = MAX(1, [self displayColumns]);
  NSInteger idx = self.sel + dir * cols;
  if (idx < 0 || idx >= (NSInteger)self.rows.count) { [self moveSel:dir]; return; }
  [self selectRow:idx];
}

- (NSInteger)displayColumns {
  NSInteger base = [self effectiveColumns];
  if (!gIconMode) return base;
  return (base <= 1) ? 2 : base * 2;
}

- (void)setDisplayListMode:(id)sender { gIconMode = NO; [self saveTheme]; [self reload]; }
- (void)setDisplayIconMode:(id)sender { gIconMode = YES; [self saveTheme]; [self reload]; }

- (NSInteger)effectiveColumns {
  NSInteger cols = self.userColumns;
  if (cols < 1) cols = 1;
  NSInteger n = (NSInteger)self.items.count;
  if (cols == 3 && n < 4) cols = 1;
  if (cols == 4 && n < 6) cols = 1;
  return cols;
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window defaultFrame:(NSRect)defaultFrame {
  BOOL alt = (([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0);
  NSInteger n = (NSInteger)self.items.count;
  NSInteger wanted = self.forceColumns > 0 ? self.forceColumns : (alt ? 4 : 3);
  self.forceColumns = 0;
  self.userColumns = wanted;
  if (self.userColumns == 4 && n < 6) self.userColumns = (n >= 4 ? 3 : 1);
  if (self.userColumns == 3 && n < 4) self.userColumns = 1;
  dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; });
  NSScreen *screen = window.screen ?: [NSScreen mainScreen];
  NSRect vf = screen.visibleFrame;
  CGFloat w = MIN(vf.size.width * 0.78, 980.0);
  CGFloat h = MIN(vf.size.height * 0.86, 900.0);
  return NSMakeRect(vf.origin.x + (vf.size.width - w)/2.0,
                    vf.origin.y + (vf.size.height - h)/2.0, w, h);
}

- (void)windowDidResize:(NSNotification *)notification {
  CGFloat w = self.window.contentView.bounds.size.width;
  // 只在大窗缩回小窗时恢复单列；变形导致的布局变化不重置列数
  if (w < 560 && self.lastContentWidth >= 600 && self.userColumns != 1) {
    self.userColumns = 1;
  }
  self.lastContentWidth = w;
  [self layoutContent];
  [self reload];
}

- (void)layoutContent {
  NSView *cv = self.window.contentView;
  if (!cv) return;
  CGFloat W = cv.bounds.size.width, H = cv.bounds.size.height;
  CGFloat radius = gCornerRatio * MIN(W, H);
  CGFloat inset = radius * (1.0 - 1.0 / sqrt(2.0)); // 保证内容落在圆角内
  CGFloat rw = W - 2*inset, rh = H - 2*inset;
  if (gCornerRatio > 0.01) {
    CGFloat side = MIN(rw, rh);
    rw = side; rh = side;
  }
  CGFloat ox = (W - rw)/2.0, oy = (H - rh)/2.0;

  cv.wantsLayer = YES;
  cv.layer.cornerRadius = radius;
  cv.layer.masksToBounds = (radius > 0.5);

  // 标题胶囊（随可用宽度收窄）
  NSFont *tf = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
  NSDictionary *tattrs = @{NSFontAttributeName: tf};
  CGFloat tw = [self.windowTitleLabel.title sizeWithAttributes:tattrs].width + 44;
  tw = MIN(tw, MAX(80, rw - 24));
  CGFloat th = 32;
  self.windowTitleLabel.titleFont = tf;
  self.windowTitleLabel.frame = NSMakeRect(ox + (rw - tw)/2.0, oy + rh - 48, tw, th);

  if (self.pinBtn) self.pinBtn.frame = NSMakeRect(ox + rw - 14 - 28, oy + rh - 34, 28, 28);

  // 第二行四个控件各占 1/4
  CGFloat btnSize = 30.0;
  CGFloat cw = rw / 4.0;
  self.removeBtn.frame = NSMakeRect(ox + cw*0.5 - btnSize/2.0, oy + rh - 88, btnSize, btnSize);
  self.skinBtn.frame   = NSMakeRect(ox + cw*1.5 - btnSize/2.0, oy + rh - 88, btnSize, btnSize);
  if (self.searchBtn) self.searchBtn.frame = NSMakeRect(ox + cw*2.5 - 15.0, oy + rh - 88, 30, 30);
  self.addBtn.frame    = NSMakeRect(ox + cw*3.5 - btnSize/2.0, oy + rh - 88, btnSize, btnSize);

  BOOL morph = (gCornerRatio > 0.05);
  // 保持 Resizable：这样系统绿灯的 Move & Resize 悬停菜单在变形状态下也能用
  NSWindowStyleMask wantMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                               NSWindowStyleMaskFullSizeContentView;
  if (self.window.styleMask != wantMask) self.window.styleMask = wantMask;
  for (NSWindowButton b = NSWindowCloseButton; b <= NSWindowZoomButton; b++) {
    NSButton *btn = [self.window standardWindowButton:b];
    if (btn) btn.hidden = morph;
  }
  self.cLightRed.hidden = !morph;
  self.cLightYellow.hidden = !morph;
  self.cLightGreen.hidden = !morph;
  if (morph) {
    CGFloat ly2 = oy + rh - 24;
    self.cLightRed.frame = NSMakeRect(ox + 18, ly2, 14, 14);
    self.cLightYellow.frame = NSMakeRect(ox + 40, ly2, 14, 14);
    self.cLightGreen.frame = NSMakeRect(ox + 62, ly2, 14, 14);
  }

  CGFloat ly = oy + rh - 26;
  if (self.lightRed) self.lightRed.frame = NSMakeRect(ox + 20, ly, 12, 12);
  if (self.lightYellow) self.lightYellow.frame = NSMakeRect(ox + 40, ly, 12, 12);
  if (self.lightGreen) self.lightGreen.frame = NSMakeRect(ox + 60, ly, 12, 12);

  if (self.backdrop) self.backdrop.frame = NSMakeRect(0,0,W,H);
  if (self.vibrancy) self.vibrancy.frame = NSMakeRect(0,0,W,H);
  if (morph) {
    self.scroll.frame = NSMakeRect(ox + 16, oy + 104, rw - 32, MAX(40, rh - 110 - 104));
    self.hintLabel.font = [NSFont systemFontOfSize:9.0];
    self.hintLabel.frame = NSMakeRect(ox + 12, oy + 72, MAX(40, rw - 24), 20);
    self.hintLabel.maximumNumberOfLines = 1;
  } else {
    self.hintLabel.font = [NSFont systemFontOfSize:10.5];
    self.scroll.frame = NSMakeRect(ox + 16, oy + 76, rw - 32, MAX(40, rh - 100 - 76));
    self.hintLabel.frame = NSMakeRect(ox + 96, oy + 10, MAX(40, rw - 192), 34);
    self.hintLabel.maximumNumberOfLines = 2;
  }
  [self.scroll layoutSubtreeIfNeeded];
  self.cancelBtn.frame = NSMakeRect(ox + 16, oy + 10, 56, 56);
  self.openBtn.frame = NSMakeRect(ox + rw - 16 - 56, oy + 10, 56, 56);
  [self.listContainer setFrameSize:NSMakeSize(rw - 32, self.listContainer.frame.size.height)];
}

- (void)sendBackgroundToBack {
  NSView *cv = self.window.contentView;
  if (!cv) return;
  if (self.vibrancy) [cv addSubview:self.vibrancy positioned:NSWindowBelow relativeTo:nil];
  if (self.backdrop) [cv addSubview:self.backdrop positioned:NSWindowBelow relativeTo:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
  return !self.pinned;
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
  if (self.pinned) [self.window deminiaturize:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
  [NSApp terminate:nil];
}

- (void)openSelected:(id)sender {
  if (self.items.count == 0) return;
  NSString *target = self.items[self.sel][@"target"];
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/usr/bin/open";
  if ([target hasPrefix:@"/"]) task.arguments = @[target];
  else task.arguments = @[@"-a", target];
  NSTimeInterval ts = [NSDate timeIntervalSinceReferenceDate];
  @try { [task launch]; } @catch (NSException *e) {}
  if (getenv("DOCKLAUNCHER_BENCH") || getenv("DOCKLAUNCHER_TEST")) fprintf(stderr, "OPEN_CALL_MS=%.2f\n", ([NSDate timeIntervalSinceReferenceDate]-ts)*1000.0);
  [NSApp terminate:nil];
  exit(0);
}

- (void)closeCancel:(id)sender {
  if (self.pinned) { NSBeep(); return; }
  fflush(stdout);
  [NSApp terminate:nil];
  exit(1);
}

- (void)removeSelected:(id)sender {
  if (self.items.count == 0) return;
  NSDictionary *it = self.items[self.sel];
  if (!getenv("DOCKLAUNCHER_TEST_REMOVE")) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"从「%@」移除「%@」？", gGroup, it[@"label"]];
    alert.informativeText = @"只会从分组列表移除，不会删除或修改应用本身。";
    [alert addButtonWithTitle:@"移除"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
  }

  NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
  NSMutableArray *keep = [NSMutableArray array];
  if (content) {
    for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (line.length == 0) continue;
      if ([line hasPrefix:@"#"]) { [keep addObject:line]; continue; }
      NSString *t = line;
      NSRange r = [line rangeOfString:@"|"];
      if (r.location != NSNotFound) t = [[line substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (t.length == 0) continue;
      if ([t isEqualToString:it[@"target"]]) continue;
      [keep addObject:line];
    }
  }
  NSString *newContent = [[keep componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
  [newContent writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  [self reload];
  NSInteger n = (NSInteger)self.items.count;
  if (n > 0) [self selectRow:MIN(self.sel, n-1)];
  else self.sel = 0;
}

- (void)addApps:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowsMultipleSelection = YES;
  panel.canChooseDirectories = NO;
  panel.canChooseFiles = YES;
  panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
  panel.message = [NSString stringWithFormat:@"选择要加入「%@」的应用", gGroup];
  if ([panel runModal] != NSModalResponseOK) return;
  NSMutableString *add = [NSMutableString string];
  NSMutableArray *added = [NSMutableArray array];
  for (NSURL *u in panel.URLs) {
    NSString *display = [[NSFileManager defaultManager] displayNameAtPath:[u path]];
    if (display.length == 0) display = [[u lastPathComponent] stringByDeletingPathExtension];
    if ([display hasSuffix:@".app"]) display = [display substringToIndex:display.length - 4];
    [add appendFormat:@"\n%@|%@", display, [u path]];
    [added addObject:@{@"label": display, @"target": [u path]}];
  }
  if (add.length) {
    NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
    if (!content) content = @"";
    NSString *new = [content stringByAppendingString:add];
    [new writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  [self reload];

  if (added.count > 0) {
    NSAlert *ask = [[NSAlert alloc] init];
    ask.messageText = [NSString stringWithFormat:@"已添加 %ld 个应用", (long)added.count];
    ask.informativeText = @"要现在自定义它们的显示名称吗？";
    [ask addButtonWithTitle:@"自定义名称…"];
    [ask addButtonWithTitle:@"保持默认"];
    if ([ask runModal] == NSAlertFirstButtonReturn) {
      for (NSDictionary *item in added) {
        NSAlert *r = [[NSAlert alloc] init];
        r.messageText = @"自定义显示名称";
        r.informativeText = @"只改列表里的名字，不影响应用本身。";
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
        tf.stringValue = item[@"label"];
        r.accessoryView = tf;
        [r addButtonWithTitle:@"保存"];
        [r addButtonWithTitle:@"跳过"];
        if ([r runModal] == NSAlertFirstButtonReturn) {
          NSString *nm = [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
          if (nm.length > 0) [self updateLabel:nm forTarget:item[@"target"]];
        }
      }
      [self reload];
    }
  }
  if (self.rows.count) [self selectRow:0];
}

- (void)setupTooltips {
  if (!self.addBtn) return;
  self.addBtn.toolTip = [@"添加应用到本组" stringByAppendingString:[self shortcutSuffixForAction:@"add"]];
  self.removeBtn.toolTip = [@"移除选中应用（只从列表移除）" stringByAppendingString:[self shortcutSuffixForAction:@"remove"]];
  self.skinBtn.toolTip = [@"皮肤 / 布局 / 更换图标" stringByAppendingString:[self shortcutSuffixForAction:@"skin"]];
  self.cancelBtn.toolTip = [@"取消（Esc）" stringByAppendingString:[self shortcutSuffixForAction:@"cancel"]];
  self.openBtn.toolTip = [@"打开选中应用（Enter）" stringByAppendingString:[self shortcutSuffixForAction:@"open"]];
  self.searchField.toolTip = @"输入关键字搜索本组应用，Esc 退出搜索";
  self.searchBtn.toolTip = [@"搜索本组应用（F4 或 ⌘Space）" stringByAppendingString:[self shortcutSuffixForAction:@"search"]];
  [[self.window standardWindowButton:NSWindowCloseButton] setToolTip:@"关闭"];
  [[self.window standardWindowButton:NSWindowMiniaturizeButton] setToolTip:@"最小化"];
  [[self.window standardWindowButton:NSWindowZoomButton] setToolTip:@"放大（Option+点击 = 四列）"];
}

- (void)searchTapped:(id)sender { [self toggleSearch]; }

- (void)toggleSearch {
  if (self.searchActive) { [self closeSearch]; return; }
  self.searchActive = YES;
  self.searchField.hidden = NO;
  self.windowTitleLabel.hidden = YES;
  [self.window makeFirstResponder:self.searchField];
  [self applySearchQuery];
  [self scheduleSearchAutoHide];
}

- (void)scheduleSearchAutoHide {
  [self.searchAutoHideTimer invalidate];
  self.searchAutoHideTimer = [NSTimer timerWithTimeInterval:3.0 target:self selector:@selector(searchAutoHideFired:) userInfo:nil repeats:NO];
  [[NSRunLoop mainRunLoop] addTimer:self.searchAutoHideTimer forMode:NSRunLoopCommonModes];
}

- (void)searchAutoHideFired:(NSTimer *)t {
  self.searchAutoHideTimer = nil;
  if (!self.searchActive) return;
  if (self.searchField.stringValue.length == 0) [self closeSearch];
}

- (void)closeSearch {
  [self.searchAutoHideTimer invalidate];
  self.searchAutoHideTimer = nil;
  self.searchActive = NO;
  self.searchQuery = nil;
  self.searchField.stringValue = @"";
  self.searchField.hidden = YES;
  self.windowTitleLabel.hidden = NO;
  self.sel = 0;
  [self reload];
  [self.window makeFirstResponder:self.window.contentView];
}

- (void)applySearchQuery {
  self.searchQuery = [self.searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  self.sel = 0;
  [self reload];
}

- (void)controlTextDidChange:(NSNotification *)obj {
  if (obj.object == self.searchField) {
    [self.searchAutoHideTimer invalidate];
    self.searchAutoHideTimer = nil;
    [self applySearchQuery];
  }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
  if (control != self.searchField) return NO;
  if (selector == @selector(cancelOperation:)) { [self closeSearch]; return YES; }
  if (selector == @selector(insertNewline:)) { if (self.rows.count) [self openSelected:nil]; return YES; }
  if (selector == @selector(moveDown:)) { [self moveSelRow:1]; return YES; }
  if (selector == @selector(moveUp:)) { [self moveSelRow:-1]; return YES; }
  return NO;
}

- (void)setupTrafficLights {
  NSView *cv = self.window.contentView;
  CGFloat H = cv.bounds.size.height;
  CGFloat y = H - 26;
  self.lightRed = [[LightButton alloc] initWithFrame:NSMakeRect(20, y, 12, 12)];
  self.lightYellow = [[LightButton alloc] initWithFrame:NSMakeRect(40, y, 12, 12)];
  self.lightGreen = [[LightButton alloc] initWithFrame:NSMakeRect(60, y, 12, 12)];
  self.lightRed.dotColor = [NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0];
  self.lightYellow.dotColor = [NSColor colorWithCalibratedRed:1.0 green:0.74 blue:0.18 alpha:1.0];
  self.lightGreen.dotColor = [NSColor colorWithCalibratedRed:0.16 green:0.78 blue:0.25 alpha:1.0];
  for (LightButton *l in @[self.lightRed, self.lightYellow, self.lightGreen]) {
    l.bordered = NO; l.title = @""; l.focusRingType = NSFocusRingTypeNone;
    [cv addSubview:l];
  }
  self.lightRed.target = self; self.lightRed.action = @selector(redLightTapped:);
  self.lightYellow.target = self; self.lightYellow.action = @selector(yellowLightTapped:);
  self.lightGreen.target = self; self.lightGreen.action = @selector(greenLightTapped:);
  __weak Controller *weakSelf = self;
  self.lightGreen.onHover = ^(BOOL inside) {
    Controller *ss = weakSelf; if (!ss) return;
    if (inside) {
      [ss.hoverOpenTimer invalidate];
      ss.hoverOpenTimer = [NSTimer timerWithTimeInterval:0.18 target:ss selector:@selector(showZoomPanel) userInfo:nil repeats:NO];
      [[NSRunLoop mainRunLoop] addTimer:ss.hoverOpenTimer forMode:NSRunLoopCommonModes];
    } else {
      [ss.hoverOpenTimer invalidate]; ss.hoverOpenTimer = nil;
      [ss hideZoomPanelAfterDelay:0.45];
    }
  };
}

- (void)redLightTapped:(id)sender { [NSApp terminate:nil]; }
- (void)yellowLightTapped:(id)sender { if (self.pinned) { NSBeep(); return; } [self.window miniaturize:nil]; }

- (void)greenLightTapped:(id)sender {
  BOOL alt = (([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0);
  self.forceColumns = alt ? 4 : 3;
  [self.window zoom:nil];
}

- (void)showZoomPanel {
  [self hideZoomPanel];
  if (!self.zoomPanel) {
    self.zoomPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,196,62)
                                                styleMask:(NSWindowStyleMaskBorderless)
                                                  backing:NSBackingStoreBuffered defer:NO];
    self.zoomPanel.level = NSFloatingWindowLevel;
    self.zoomPanel.opaque = NO;
    self.zoomPanel.backgroundColor = [NSColor clearColor];
    self.zoomPanel.hasShadow = YES;
    NSView *pv = self.zoomPanel.contentView;
    pv.wantsLayer = YES;
    pv.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.15 alpha:0.96].CGColor;
    pv.layer.cornerRadius = 10;
    PillButton *three = [[PillButton alloc] initWithFrame:NSMakeRect(10, 12, 84, 38)];
    three.title = @"三列"; three.fillColor = [NSColor colorWithCalibratedWhite:0.32 alpha:1.0];
    three.strokeColor = [NSColor colorWithCalibratedWhite:0.45 alpha:1.0];
    three.textColor = [NSColor whiteColor]; three.textFont = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
    three.bordered = NO; three.focusRingType = NSFocusRingTypeNone;
    three.target = self; three.action = @selector(zoomPanelThree:);
    [pv addSubview:three];
    PillButton *four = [[PillButton alloc] initWithFrame:NSMakeRect(102, 12, 84, 38)];
    four.title = @"四列"; four.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0];
    four.strokeColor = [NSColor colorWithCalibratedRed:0.78 green:0.22 blue:0.20 alpha:1.0];
    four.textColor = [NSColor whiteColor]; four.textFont = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    four.bordered = NO; four.focusRingType = NSFocusRingTypeNone;
    four.target = self; four.action = @selector(zoomPanelFour:);
    [pv addSubview:four];
    NSTextField *tip = [NSTextField labelWithString:@"选择列数（2.5 秒无操作自动关闭）"];
    tip.font = [NSFont systemFontOfSize:10];
    tip.textColor = [NSColor colorWithCalibratedWhite:1 alpha:0.55];
    tip.frame = NSMakeRect(10, 44, 180, 14);
    [pv addSubview:tip];
  }
  NSRect gf = [self.lightGreen convertRect:self.lightGreen.bounds toView:nil];
  NSPoint screenPt = [self.window convertPointToScreen:NSMakePoint(NSMinX(gf), NSMinY(gf))];
  [self.zoomPanel setFrameOrigin:NSMakePoint(screenPt.x, screenPt.y - 70)];
  [self.zoomPanel makeKeyAndOrderFront:nil];
  [self.zoomHideTimer invalidate];
  self.zoomHideTimer = [NSTimer timerWithTimeInterval:2.5 target:self selector:@selector(hideZoomPanelTimerFired:) userInfo:nil repeats:NO];
  [[NSRunLoop mainRunLoop] addTimer:self.zoomHideTimer forMode:NSRunLoopCommonModes];
}

- (void)hideZoomPanelTimerFired:(NSTimer *)t { [self hideZoomPanel]; }
- (void)hideZoomPanelAfterDelay:(NSTimeInterval)delay {
  [self.zoomHideTimer invalidate];
  self.zoomHideTimer = [NSTimer timerWithTimeInterval:delay target:self selector:@selector(hideZoomPanelTimerFired:) userInfo:nil repeats:NO];
  [[NSRunLoop mainRunLoop] addTimer:self.zoomHideTimer forMode:NSRunLoopCommonModes];
}
- (void)hideZoomPanel {
  [self.zoomHideTimer invalidate]; self.zoomHideTimer = nil;
  [self.zoomPanel orderOut:nil];
}
- (void)zoomPanelThree:(id)sender {
  self.forceColumns = 3; [self hideZoomPanel];
  if (self.window.contentView.bounds.size.width < 600) [self.window zoom:nil]; else { self.userColumns = 3; [self reload]; }
}
- (void)zoomPanelFour:(id)sender {
  self.forceColumns = 4; [self hideZoomPanel];
  if (self.window.contentView.bounds.size.width < 600) [self.window zoom:nil]; else { self.userColumns = 4; [self reload]; }
}

#pragma mark - 皮肤

- (void)loadTheme {
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  gTheme = [d integerForKey:@"skinTheme"];
  if (gTheme < 0 || gTheme > 3) gTheme = 0;
  if ([d objectForKey:@"skinGlassAlpha"]) gGlassAlpha = [d doubleForKey:@"skinGlassAlpha"];
  if ([d objectForKey:@"skinImgScale"]) gImgScale = [d doubleForKey:@"skinImgScale"];
  if ([d objectForKey:@"skinImgDX"]) gImgDX = [d doubleForKey:@"skinImgDX"];
  if ([d objectForKey:@"skinImgDY"]) gImgDY = [d doubleForKey:@"skinImgDY"];
  gImgPath = [d stringForKey:@"skinImgPath"];
  if ([d objectForKey:@"cornerRatio"]) gCornerRatio = [d doubleForKey:@"cornerRatio"];
  gIconMode = [d boolForKey:@"iconMode"];
  gAppIconSettings = [[[d dictionaryForKey:@"appIconSettings"] mutableCopy] mutableCopy] ?: [NSMutableDictionary dictionary];
  [self loadCustomShortcuts];
  if (gTheme == 3 && gImgPath.length == 0) gTheme = 0;
  if (gGlassAlpha < 0.3) gGlassAlpha = 0.82;
  if (gImgScale < 1.0) gImgScale = 1.0;
}

- (void)saveTheme {
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setInteger:gTheme forKey:@"skinTheme"];
  [d setDouble:gGlassAlpha forKey:@"skinGlassAlpha"];
  [d setDouble:gImgScale forKey:@"skinImgScale"];
  [d setDouble:gImgDX forKey:@"skinImgDX"];
  [d setDouble:gImgDY forKey:@"skinImgDY"];
  [d setDouble:gCornerRatio forKey:@"cornerRatio"];
  [d setBool:gIconMode forKey:@"iconMode"];
  [d setObject:gAppIconSettings forKey:@"appIconSettings"];
  [d setObject:(gImgPath ?: @"") forKey:@"skinImgPath"];
  [d synchronize];
}

- (void)applyTheme {
  NSWindow *w = self.window;
  if (!w) return;
  NSView *cv = w.contentView;
  BOOL transparent = (gTheme == 2 || gTheme == 3);
  w.opaque = !transparent;
  w.backgroundColor = transparent ? [NSColor clearColor] : ThemeBG(gTheme);
  if (cv.layer) cv.layer.backgroundColor = transparent ? [NSColor clearColor].CGColor : ThemeBG(gTheme).CGColor;
  w.alphaValue = (gTheme == 2) ? gGlassAlpha : 1.0;

  if (gTheme == 2 && !self.vibrancy) {
    self.vibrancy = [[NSVisualEffectView alloc] initWithFrame:cv.bounds];
    self.vibrancy.material = NSVisualEffectMaterialUnderWindowBackground;
    self.vibrancy.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.vibrancy.state = NSVisualEffectStateActive;
    [cv addSubview:self.vibrancy positioned:NSWindowBelow relativeTo:nil];
  }
  if (gTheme == 3 && !self.backdrop) {
    self.backdrop = [[BackdropView alloc] initWithFrame:cv.bounds];
    [cv addSubview:self.backdrop positioned:NSWindowBelow relativeTo:nil];
  }
  self.vibrancy.hidden = (gTheme != 2);
  self.backdrop.hidden = (gTheme != 3);
  [self sendBackgroundToBack];
  if (gTheme == 3 && gImgPath.length > 0) {
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:gImgPath];
    if (img) {
      self.backdrop.image = img;
      self.backdrop.scale = gImgScale;
      self.backdrop.dx = gImgDX;
      self.backdrop.dy = gImgDY;
    }
  }

  // 窗口变形：圆角/圆形
  CGFloat radius = gCornerRatio * MIN(cv.bounds.size.width, cv.bounds.size.height);
  cv.wantsLayer = YES;
  cv.layer.cornerRadius = radius;
  cv.layer.masksToBounds = (radius > 0.5);
  if (radius > 0.5) {
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    w.hasShadow = NO;
  } else {
    w.hasShadow = YES;
  }

  BOOL solid = (gTheme == 0 || gTheme == 1);
  self.scroll.drawsBackground = solid;
  self.scroll.backgroundColor = solid ? ThemeBG(gTheme) : [NSColor clearColor];
  self.listContainer.wantsLayer = YES;
  if (self.listContainer.layer) self.listContainer.layer.backgroundColor = [NSColor clearColor].CGColor;

  self.hintLabel.textColor = ThemeHint(gTheme);
  for (RowView *r in self.rows) {
    r.selColor = ThemeSel(gTheme);
    r.label.textColor = ThemeText(gTheme);
    [r setNeedsDisplay:YES];
  }
  [self scrollToSel];
  [w.contentView setNeedsDisplay:YES];
  [self saveTheme];
}

- (void)scrollToSel {
  if (self.rows.count == 0) return;
  NSInteger idx = MIN(MAX(0, self.sel), (NSInteger)self.rows.count - 1);
  [self.listContainer scrollRectToVisible:self.rows[idx].frame];
}

- (void)showSkinMenu:(id)sender {
  NSMenu *m = [[NSMenu alloc] init];
  NSMenuItem *it;
  it = [m addItemWithTitle:@"纯白背景" action:@selector(skinWhite:) keyEquivalent:@""]; it.target = self; it.state = (gTheme == 0);
  it = [m addItemWithTitle:@"纯黑背景" action:@selector(skinBlack:) keyEquivalent:@""]; it.target = self; it.state = (gTheme == 1);
  it = [m addItemWithTitle:@"质感玻璃" action:@selector(skinGlass:) keyEquivalent:@""]; it.target = self; it.state = (gTheme == 2);
  [m addItem:[NSMenuItem separatorItem]];
  it = [m addItemWithTitle:@"玻璃透明度…" action:@selector(showGlassPanel:) keyEquivalent:@""]; it.target = self; it.enabled = (gTheme == 2);
  it = [m addItemWithTitle:@"窗口变形（矩形→圆形）…" action:@selector(showShapePanel:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"恢复默认矩形" action:@selector(resetShapeRectangle:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"刷新列表并释放缓存" action:@selector(refreshListAndCaches:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"空闲 3 分钟自动退出" action:@selector(toggleIdleExit:) keyEquivalent:@""];
  it.target = self;
  it.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"idleExitEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
  it = [m addItemWithTitle:@"选择自定义图片…" action:@selector(customPick:) keyEquivalent:@""]; it.target = self; it.state = (gTheme == 3);
  [m addItem:[NSMenuItem separatorItem]];
  NSMenuItem *modeHdr = [m addItemWithTitle:@"排列方式" action:nil keyEquivalent:@""];
  modeHdr.enabled = NO;
  it = [m addItemWithTitle:@"列表显示" action:@selector(setDisplayListMode:) keyEquivalent:@""]; it.target = self; it.state = (gIconMode ? NSControlStateValueOff : NSControlStateValueOn);
  it = [m addItemWithTitle:@"图标显示" action:@selector(setDisplayIconMode:) keyEquivalent:@""]; it.target = self; it.state = (gIconMode ? NSControlStateValueOn : NSControlStateValueOff);
  [m addItem:[NSMenuItem separatorItem]];
  NSMenuItem *hdr = [m addItemWithTitle:@"布局" action:nil keyEquivalent:@""];
  hdr.enabled = NO;
  NSInteger curCols = [self effectiveColumns];
  it = [m addItemWithTitle:@"单列（默认）" action:@selector(layoutSingle:) keyEquivalent:@""]; it.target = self; it.state = (curCols == 1);
  it = [m addItemWithTitle:@"三列" action:@selector(layoutThree:) keyEquivalent:@""]; it.target = self; it.state = (curCols == 3);
  it = [m addItemWithTitle:@"四列" action:@selector(layoutFour:) keyEquivalent:@""]; it.target = self; it.state = (curCols == 4);
  [m addItem:[NSMenuItem separatorItem]];
  it = [m addItemWithTitle:@"自定义选中应用图标…" action:@selector(showAppIconPanel:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"新建分组…" action:@selector(createGroupTapped:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"删除当前分组…" action:@selector(deleteCurrentGroup:) keyEquivalent:@""]; it.target = self;
  [m addItem:[NSMenuItem separatorItem]];
  it = [m addItemWithTitle:@"修复程序坞图标…" action:@selector(repairDockMenuTapped:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"快捷键设置…" action:@selector(showShortcutSettings:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"恢复分组默认图标" action:@selector(resetCustomIcon:) keyEquivalent:@""]; it.target = self;
  [m addItem:[NSMenuItem separatorItem]];
  it = [m addItemWithTitle:@"恢复默认（纯白）" action:@selector(skinReset:) keyEquivalent:@""]; it.target = self;
  [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(16, 0) inView:self.skinBtn];
}

- (void)skinWhite:(id)sender { gTheme = 0; [self applyTheme]; }
- (void)skinBlack:(id)sender { gTheme = 1; [self applyTheme]; }
- (void)skinGlass:(id)sender {
  if (gTheme != 2) gGlassAlpha = 0.82;
  gTheme = 2; [self applyTheme];
}
- (void)skinReset:(id)sender { gTheme = 0; [self applyTheme]; }

- (void)applyLayoutColumns:(NSInteger)cols {
  if (cols <= 1) {
    self.userColumns = 1;
    if (self.window.contentView.bounds.size.width >= 600) [self.window zoom:nil];
    [self reload];
    return;
  }
  if (self.window.contentView.bounds.size.width < 600) {
    self.forceColumns = cols;
    [self.window zoom:nil];
  } else {
    self.userColumns = cols;
    [self reload];
  }
}

- (void)layoutSingle:(id)sender { [self applyLayoutColumns:1]; }
- (void)layoutThree:(id)sender { [self applyLayoutColumns:3]; }
- (void)layoutFour:(id)sender { [self applyLayoutColumns:4]; }

- (void)cLightRedTapped:(id)sender { [NSApp terminate:nil]; }
- (void)cLightYellowTapped:(id)sender { if (self.pinned) { NSBeep(); return; } [self.window miniaturize:nil]; }
- (void)cLightGreenTapped:(id)sender {
  NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
  NSRect vf = screen.visibleFrame;
  CGFloat w = MIN(vf.size.width * 0.78, 980.0);
  CGFloat h = MIN(vf.size.height * 0.86, 900.0);
  NSRect std = NSMakeRect(vf.origin.x + (vf.size.width - w)/2.0,
                          vf.origin.y + (vf.size.height - h)/2.0, w, h);
  if (self.window.frame.size.width < 600) [self.window setFrame:std display:YES animate:YES];
  else {
    NSRect normal = NSMakeRect(self.window.frame.origin.x, self.window.frame.origin.y, 480, 600);
    normal.origin.x = std.origin.x + (std.size.width - 480)/2.0;
    normal.origin.y = std.origin.y + (std.size.height - 600)/2.0;
    [self.window setFrame:normal display:YES animate:YES];
  }
}

#pragma mark - 重命名分组

- (void)renameGroupFromTitle {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"重命名分组";
  a.informativeText = @"会同时重命名 App 包、列表文件和程序坞图标名，分组内容保留。";
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
  tf.stringValue = gGroup ?: @"";
  a.accessoryView = tf;
  [a addButtonWithTitle:@"确定"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *name = [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (name.length == 0) return;
  [self performFullRename:name];
}

- (void)writeInfoNamesInBundle:(NSString *)bundlePath base:(NSString *)base display:(NSString *)display {
  @try {
    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSData *data = [NSData dataWithContentsOfFile:plistPath];
    if (!data) return;
    NSMutableDictionary *info = [[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL] mutableCopy];
    if (!info) return;
    info[@"CFBundleName"] = base;
    info[@"CFBundleDisplayName"] = display;
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (out) [out writeToFile:plistPath atomically:YES];
  } @catch (NSException *e) {}
}

- (void)updateDockPathFrom:(NSString *)oldPath to:(NSString *)newPath {
  @try {
    NSString *oldBase = [[oldPath lastPathComponent] stringByDeletingPathExtension];
    NSString *newBase = [[newPath lastPathComponent] stringByDeletingPathExtension];
    NSString *oldEnc = [[NSString stringWithFormat:@"%@.app", oldBase] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *newEnc = [[NSString stringWithFormat:@"%@.app", newBase] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!raw) return;
    NSArray *apps = CFBridgingRelease(raw);
    NSMutableArray *updated = [NSMutableArray array];
    BOOL changed = NO;
    for (id item in apps) {
      if ([item isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [item mutableCopy];
        NSMutableDictionary *tileData = [m[@"tile-data"] mutableCopy];
        if (tileData) {
          NSMutableDictionary *fileData = [tileData[@"file-data"] mutableCopy];
          if (fileData[@"_CFURLString"]) {
            NSString *u = fileData[@"_CFURLString"];
            if ([u containsString:oldEnc]) {
              fileData[@"_CFURLString"] = [u stringByReplacingOccurrencesOfString:oldEnc withString:newEnc];
              tileData[@"file-data"] = fileData;
              m[@"tile-data"] = tileData;
              changed = YES;
            }
          }
        }
        [updated addObject:m];
      } else {
        [updated addObject:item];
      }
    }
    if (changed) {
      CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)updated, CFSTR("com.apple.dock"));
      CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
    }
  } @catch (NSException *e) {}
}

- (NSString *)currentBundlePathByID {
  NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
  NSString *parent = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
  NSString *bundlePath = [NSBundle mainBundle].bundlePath;
  // bundlePath 在改名后可能过期，扫描父目录按 bundle id 找
  NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parent error:NULL];
  for (NSString *name in items) {
    if (![name hasSuffix:@".app"]) continue;
    NSString *p = [parent stringByAppendingPathComponent:name];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]];
    if (info && [info[@"CFBundleIdentifier"] isEqualToString:bid]) return p;
  }
  return bundlePath;
}

- (void)updateDockLabelForPath:(NSString *)path label:(NSString *)label {
  @try {
    NSString *norm = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
    NSString *enc = [norm stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!raw) return;
    NSArray *apps = CFBridgingRelease(raw);
    NSMutableArray *out = [NSMutableArray array];
    for (id item in apps) {
      NSMutableDictionary *m = [item mutableCopy];
      @try {
        NSString *u = m[@"tile-data"][@"file-data"][@"_CFURLString"];
        if (u && ([u containsString:enc] || [u containsString:[path lastPathComponent]])) {
          NSMutableDictionary *td = [m[@"tile-data"] mutableCopy];
          td[@"file-label"] = label;
          m[@"tile-data"] = td;
        }
      } @catch (NSException *e) {}
      [out addObject:m];
    }
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)out, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  } @catch (NSException *e) {}
}

- (BOOL)dockHasEntryForPath:(NSString *)path {
  @try {
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!raw) return NO;
    NSArray *apps = CFBridgingRelease(raw);
    NSString *enc = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    for (id item in apps) {
      NSString *u = item[@"tile-data"][@"file-data"][@"_CFURLString"];
      if (u && [u containsString:enc]) return YES;
    }
  } @catch (NSException *e) {}
  return NO;
}

- (void)repairDockEntries {
  @try {
    NSString *parent = [[self currentBundlePathByID] stringByDeletingLastPathComponent];
    NSMutableArray *wanted = [NSMutableArray array];
    NSArray *order = @[@"工作", @"聊天", @"外网", @"影音", @"Ai", @"Docker", @"工具"];
    for (NSString *n in order) {
      NSString *p = [parent stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"app"]];
      if ([[NSFileManager defaultManager] fileExistsAtPath:p]) [wanted addObject:p];
    }
    if (wanted.count == 0) {
      NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parent error:NULL];
      for (NSString *n in items) if ([n hasSuffix:@".app"]) [wanted addObject:[parent stringByAppendingPathComponent:n]];
    }

    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    NSMutableArray *apps = raw ? [CFBridgingRelease(raw) mutableCopy] : [NSMutableArray array];
    BOOL changed = NO;

    // 1) 先清掉指向不存在路径的 DockLaunchers 条目
    for (NSInteger i = (NSInteger)apps.count - 1; i >= 0; i--) {
      NSDictionary *item = apps[i];
      NSString *u = nil;
      @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
      if (!u || !([u containsString:@"/DockLaunchers/"] || [u containsString:@"DockLaunchers%2F"])) continue;
      NSString *decoded = [[u stringByRemovingPercentEncoding] stringByReplacingOccurrencesOfString:@"file://" withString:@""];
      decoded = [decoded stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
      if (![[NSFileManager defaultManager] fileExistsAtPath:decoded]) { [apps removeObjectAtIndex:i]; changed = YES; }
    }

    // 2) 已有条目只更新标签/补齐字段；缺失的才追加
    for (NSString *p in wanted) {
      NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]];
      NSString *label = info[@"CFBundleDisplayName"] ?: [[p lastPathComponent] stringByDeletingPathExtension];
      NSString *base = [p lastPathComponent];
      NSInteger found = -1;
      for (NSInteger i = 0; i < (NSInteger)apps.count; i++) {
        NSString *u = nil;
        @try { u = apps[i][@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
        if (u && [[[u stringByRemovingPercentEncoding] lastPathComponent] stringByDeletingPathExtension].length &&
            [[[[u stringByRemovingPercentEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] lastPathComponent] isEqualToString:base]) {
          found = i; break;
        }
      }
      if (found >= 0) {
        NSMutableDictionary *m = [apps[found] mutableCopy];
        NSMutableDictionary *td = [m[@"tile-data"] mutableCopy];
        if (![td[@"file-label"] isEqualToString:label] || !td[@"file-type"]) {
          td[@"file-label"] = label;
          td[@"file-type"] = @41;
          m[@"tile-data"] = td;
          apps[found] = m;
          changed = YES;
        }
      } else {
        NSString *url = [NSString stringWithFormat:@"file://%@/", [p stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]];
        NSString *bid = info[@"CFBundleIdentifier"] ?: label;
        [apps addObject:@{@"tile-data": @{@"file-data": @{@"_CFURLString": url, @"_CFURLStringType": @15},
                                          @"file-label": label, @"file-type": @41,
                                          @"bundle-identifier": bid, @"dock-extra": @NO},
                          @"tile-type": @"file-tile"}];
        changed = YES;
      }
    }

    if (!changed) return;

    // 备份当前 Dock 配置
    @try {
      NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DockLaunchers"];
      [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
      NSData *bak = [NSPropertyListSerialization dataWithPropertyList:apps format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
      [bak writeToFile:[dir stringByAppendingPathComponent:@"dock-persistent-apps-backup.plist"] atomically:YES];
    } @catch (NSException *e) {}

    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)apps, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));

    // 强杀 Dock，避免它退出时回写旧状态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSTask *task = [[NSTask alloc] init];
      task.launchPath = @"/usr/bin/killall";
      task.arguments = @[@"-KILL", @"Dock"];
      @try { [task launch]; } @catch (NSException *e) {}
    });
  } @catch (NSException *e) {}
}

- (void)performFullRename:(NSString *)typed {
  NSString *display = typed;
  while ([display hasSuffix:@"组"] && display.length > 1) display = [display substringToIndex:display.length - 1];
  display = [display stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (display.length == 0) return;

  // 只改显示名，不动 App 包和列表文件名 —— 避免 Dock 路径变化导致图标变文件夹
  NSString *curPath = [self currentBundlePathByID];
  [self writeInfoNamesInBundle:curPath base:display display:display];

  gGroup = display;
  self.windowTitleLabel.title = display;
  self.window.title = display;
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setObject:display forKey:@"displayNameOverride"];
  [d synchronize];
  [self updateDockLabelForPath:curPath label:display];
  [self layoutContent];

  if (getenv("DOCKLAUNCHER_TEST_RENAME") || getenv("DOCKLAUNCHER_TEST_RENAME2")) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    NSTask *reg = [[NSTask alloc] init];
    reg.launchPath = @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
    reg.arguments = @[@"-f", curPath];
    @try { [reg launch]; [reg waitUntilExit]; } @catch (NSException *e) {}
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/killall";
    task.arguments = @[@"-KILL", @"Dock"];
    @try { [task launch]; } @catch (NSException *e) {}
  });
}


- (void)repairDockMenuTapped:(id)sender {
  // 顺带清除可能残留的自定义分组图标（旧版本「更换图标」写入的图片）
  [self resetCustomIcon:nil];
  [self repairDockEntries];
  [self reload];
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"程序坞已修复";
  a.informativeText = @"已补齐缺失/无效条目、同步标签，并清除残留的自定义分组图标，Dock 会自动重启刷新。";
  [a runModal];
}

#pragma mark - 批量改名

- (BOOL)renameBundleAtPath:(NSString *)oldPath toBase:(NSString *)newBase display:(NSString *)display {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *parent = [oldPath stringByDeletingLastPathComponent];
  NSString *oldBase = [[oldPath lastPathComponent] stringByDeletingPathExtension];
  if ([newBase isEqualToString:oldBase]) return NO;
  NSString *newPath = [parent stringByAppendingPathComponent:[newBase stringByAppendingPathExtension:@"app"]];
  if ([fm fileExistsAtPath:newPath]) return NO;

  NSString *listsDir = [parent stringByAppendingPathComponent:@"lists"];
  NSString *oldList = [listsDir stringByAppendingPathComponent:[oldBase stringByAppendingPathExtension:@"txt"]];
  NSString *newList = [listsDir stringByAppendingPathComponent:[newBase stringByAppendingPathExtension:@"txt"]];
  BOOL hadList = [fm fileExistsAtPath:oldList];
  if (hadList) {
    NSError *err = nil;
    [fm moveItemAtPath:oldList toPath:newList error:&err];
    if (err) return NO;
  }
  [self writeInfoNamesInBundle:oldPath base:newBase display:display];
  NSError *moveErr = nil;
  [fm moveItemAtPath:oldPath toPath:newPath error:&moveErr];
  if (moveErr) {
    if (hadList) [fm moveItemAtPath:newList toPath:oldList error:nil];
    return NO;
  }
  [self updateDockPathFrom:oldPath to:newPath];
  return YES;
}

- (void)batchStripGroupSuffix:(id)sender {
  NSAlert *confirm = [[NSAlert alloc] init];
  confirm.messageText = @"批量去掉分组名里的「组」？";
  confirm.informativeText = @"会把所有以「组」结尾的分组 App 包和列表文件一起改名（如 影音组.app → 影音.app），并更新程序坞图标。";
  [confirm addButtonWithTitle:@"开始"];
  [confirm addButtonWithTitle:@"取消"];
  if (!getenv("DOCKLAUNCHER_TEST_BATCH")) {
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;
  }

  NSString *parent = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
  NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parent error:NULL];
  NSMutableArray *targets = [NSMutableArray array];
  for (NSString *name in contents) {
    if (![name hasSuffix:@".app"]) continue;
    NSString *base = [name stringByDeletingPathExtension];
    if ([base hasSuffix:@"组"] && base.length > 1) [targets addObject:base];
  }

  NSInteger renamed = 0;
  NSString *selfOldPath = [[NSBundle mainBundle] bundlePath];
  for (NSString *base in targets) {
    NSString *display = [base substringToIndex:base.length - 1];
    NSString *path = [parent stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"app"]];
    BOOL isSelf = [path isEqualToString:selfOldPath];
    if ([self renameBundleAtPath:path toBase:display display:display]) {
      renamed++;
      if (isSelf) {
        gListKey = display;
        gListFile = [[parent stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[display stringByAppendingPathExtension:@"txt"]];
        gGroup = display;
        self.windowTitleLabel.title = display;
        self.window.title = display;
      }
    }
  }

  if (renamed > 0) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:gGroup forKey:@"displayNameOverride"];
    [d synchronize];
    [self layoutContent];
    if (!getenv("DOCKLAUNCHER_TEST_BATCH")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/killall";
        task.arguments = @[@"-KILL", @"Dock"];
        @try { [task launch]; } @catch (NSException *e) {}
      });
    }
  }

  if (getenv("DOCKLAUNCHER_TEST_BATCH")) { fprintf(stderr, "renamed=%ld\n", (long)renamed); return; }
  NSAlert *done = [[NSAlert alloc] init];
  done.messageText = [NSString stringWithFormat:@"已重命名 %ld 个分组", (long)renamed];
  done.informativeText = renamed ? @"程序坞会在稍后自动刷新，标签将不再带「组」。" : @"没有需要改名的分组。";
  [done runModal];
}

#pragma mark - 新建 / 删除分组

- (void)addDockEntryForPath:(NSString *)path label:(NSString *)label {
  @try {
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    NSMutableArray *apps = raw ? [CFBridgingRelease(raw) mutableCopy] : [NSMutableArray array];
    NSString *enc = [[path stringByAppendingString:@"/"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *url = [NSString stringWithFormat:@"file://%@", enc];
    for (id item in apps) {
      NSString *u = nil; @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
      if (u && [u containsString:enc]) return;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"] ?: label;
    [apps addObject:@{@"tile-data": @{@"file-data": @{@"_CFURLString": url, @"_CFURLStringType": @15},
                                      @"file-label": label, @"file-type": @41,
                                      @"bundle-identifier": bid, @"dock-extra": @NO},
                      @"tile-type": @"file-tile"}];
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)apps, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  } @catch (NSException *e) {}
}

- (void)removeDockEntryForPath:(NSString *)path {
  @try {
    NSString *enc = [[path stringByAppendingString:@"/"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!raw) return;
    NSArray *apps = CFBridgingRelease(raw);
    NSMutableArray *kept = [NSMutableArray array];
    for (id item in apps) {
      NSString *u = nil; @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
      if (u && [u containsString:enc]) continue;
      [kept addObject:item];
    }
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)kept, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  } @catch (NSException *e) {}
}

- (BOOL)createGroupNamed:(NSString *)name {
  while ([name hasSuffix:@"组"] && name.length > 1) name = [name substringToIndex:name.length-1];
  if (name.length == 0) return NO;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *parent = [[self currentBundlePathByID] stringByDeletingLastPathComponent];
  NSString *newPath = [parent stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
  if ([fm fileExistsAtPath:newPath]) return NO;
  NSError *err = nil;
  if (![fm copyItemAtPath:[self currentBundlePathByID] toPath:newPath error:&err]) return NO;

  NSString *plistPath = [newPath stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSData *data = [NSData dataWithContentsOfFile:plistPath];
  NSMutableDictionary *info = data ? [[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL] mutableCopy] : nil;
  if (!info) { [fm removeItemAtPath:newPath error:NULL]; return NO; }
  info[@"CFBundleName"] = name;
  info[@"CFBundleDisplayName"] = name;
  info[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.docklaunchers.g%lu", (unsigned long)([[NSDate date] timeIntervalSince1970] * 1000)];
  NSData *out = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
  if (!out || ![out writeToFile:plistPath atomically:YES]) { [fm removeItemAtPath:newPath error:NULL]; return NO; }

  NSString *listsDir = [parent stringByAppendingPathComponent:@"lists"];
  [fm createDirectoryAtPath:listsDir withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *listFile = [listsDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]];
  if (![fm fileExistsAtPath:listFile]) [@"" writeToFile:listFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];

  NSTask *sign = [[NSTask alloc] init];
  sign.launchPath = @"/usr/bin/codesign";
  sign.arguments = @[@"--force", @"--deep", @"--sign", @"-", newPath];
  @try { [sign launch]; [sign waitUntilExit]; } @catch (NSException *e) {}

  // 校验产物
  NSString *exe = [newPath stringByAppendingPathComponent:@"Contents/MacOS/ui"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:exe]) { [fm removeItemAtPath:newPath error:NULL]; return NO; }
  if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) { return NO; }
  return YES;
}

- (BOOL)updateLabel:(NSString *)newLabel forTarget:(NSString *)target {
  if (newLabel.length == 0 || target.length == 0) return NO;
  if ([newLabel containsString:@"|"]) newLabel = [newLabel stringByReplacingOccurrencesOfString:@"|" withString:@" "];
  NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
  if (!content) return NO;
  NSMutableArray *lines = [[content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
    NSString *line = lines[i];
    NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trim.length == 0 || [trim hasPrefix:@"#"]) continue;
    NSString *t = trim;
    NSRange r = [trim rangeOfString:@"|"];
    if (r.location != NSNotFound) t = [[trim substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([t isEqualToString:target]) {
      lines[i] = [NSString stringWithFormat:@"%@|%@", newLabel, target];
      NSString *out = [lines componentsJoinedByString:@"\n"];
      [out writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
      return YES;
    }
  }
  return NO;
}

- (void)renameSelectedItem:(id)sender {
  if (self.sel < 0 || self.sel >= (NSInteger)self.items.count) return;
  NSDictionary *it = self.items[self.sel];
  NSString *target = it[@"target"];
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"重命名选中项";
  a.informativeText = @"只修改列表中显示的名字，不会改动应用本身。";
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
  tf.stringValue = it[@"label"] ?: @"";
  a.accessoryView = tf;
  [a addButtonWithTitle:@"确定"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *newLabel = [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (![self updateLabel:newLabel forTarget:target]) return;
  NSInteger keep = self.sel;
  [self reload];
  if (self.rows.count) [self selectRow:MIN(keep, (NSInteger)self.rows.count - 1)];
}

- (void)createGroupTapped:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"新建分组";
  a.informativeText = @"输入分组名（例如 设计 或 设计组）。会复制当前分组作为模板，创建后可在窗口里用 ＋ 添加应用。";
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
  a.accessoryView = tf;
  [a addButtonWithTitle:@"创建"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *name = [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  while ([name hasSuffix:@"组"] && name.length > 1) name = [name substringToIndex:name.length-1];
  if (name.length == 0) return;

  if (![self createGroupNamed:name]) {
    NSAlert *e = [[NSAlert alloc] init];
    e.messageText = @"创建失败";
    e.informativeText = @"同名分组已存在，或复制/写入失败。请换一个名字再试。";
    [e runModal];
    return;
  }

  NSString *parent = [[self currentBundlePathByID] stringByDeletingLastPathComponent];
  NSString *newPath = [parent stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
  // 先让 LaunchServices 认识新 App，再写入 Dock，避免出现问号
  NSTask *reg = [[NSTask alloc] init];
  reg.launchPath = @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
  reg.arguments = @[@"-f", newPath];
  @try { [reg launch]; [reg waitUntilExit]; } @catch (NSException *e) {}
  [self addDockEntryForPath:newPath label:name];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/killall";
    task.arguments = @[@"-KILL", @"Dock"];
    @try { [task launch]; } @catch (NSException *e) {}
  });

  NSAlert *ok = [[NSAlert alloc] init];
  ok.messageText = @"已创建";
  ok.informativeText = [NSString stringWithFormat:@"%@.app 已创建并加入程序坞。\n如果图标显示异常，可点 🎨 →「修复程序坞图标…」。", name];
  [ok runModal];
}

- (void)deleteCurrentGroup:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = [NSString stringWithFormat:@"删除分组「%@」？", gGroup];
  a.informativeText = [NSString stringWithFormat:@"分组里的 %ld 个应用不会被卸载，只会删除分组本身（App 与列表移到废纸篓）并从程序坞移除。", (long)self.items.count];
  [a addButtonWithTitle:@"继续"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;

  NSAlert *confirm2 = [[NSAlert alloc] init];
  confirm2.messageText = [NSString stringWithFormat:@"再次确认：删除分组「%@」？", gGroup];
  confirm2.informativeText = @"此操作会把该分组的 App 包和列表文件移到废纸篓，Dock 图标会被移除；分组里的应用本体不受影响。";
  [confirm2 addButtonWithTitle:@"确认删除"];
  [confirm2 addButtonWithTitle:@"取消"];
  if ([confirm2 runModal] != NSAlertFirstButtonReturn) return;

  NSString *curPath = [self currentBundlePathByID];
  NSString *parent = [curPath stringByDeletingLastPathComponent];
  NSString *base = [[curPath lastPathComponent] stringByDeletingPathExtension];
  [self removeDockEntryForPath:curPath];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm trashItemAtURL:[NSURL fileURLWithPath:curPath] resultingItemURL:nil error:NULL];
  NSString *listFile = [[parent stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"txt"]];
  if ([fm fileExistsAtPath:listFile]) [fm trashItemAtURL:[NSURL fileURLWithPath:listFile] resultingItemURL:nil error:NULL];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/killall";
    task.arguments = @[@"-KILL", @"Dock"];
    @try { [task launch]; } @catch (NSException *e) {}
  });
  [NSApp terminate:nil];
}

#pragma mark - 应用图标自定义

- (void)appIconPickerChanged:(id)sender {
  NSInteger idx = self.appIconPicker.indexOfSelectedItem;
  if (idx < 0 || idx >= (NSInteger)self.items.count) return;
  self.sel = idx;
  [self selectRow:idx];
  self.appIconEditTarget = self.items[idx][@"target"];
  NSDictionary *cfg = gAppIconSettings[self.appIconEditTarget] ?: @{};
  CGFloat sz = cfg[@"size"] ? [cfg[@"size"] doubleValue] : 40;
  CGFloat cr = cfg[@"corner"] ? [cfg[@"corner"] doubleValue] : 0;
  [self.appIconSizeSlider setDoubleValue:sz];
  self.appIconSizeLabel.stringValue = [NSString stringWithFormat:@"%.0f", sz];
  [self.appIconCornerSlider setDoubleValue:cr*100];
  self.appIconCornerLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", cr*100];
  [self updateAppIconPreview];
}

- (void)updateAppIconPreview {
  if (!self.appIconPreview || !self.appIconEditTarget) return;
  NSDictionary *cfg = gAppIconSettings[self.appIconEditTarget] ?: @{};
  CGFloat sz = cfg[@"size"] ? [cfg[@"size"] doubleValue] : 40;
  sz = MAX(24.0, MIN(sz, 96.0));
  CGFloat cr = cfg[@"corner"] ? [cfg[@"corner"] doubleValue] : 0;
  NSImage *img = nil;
  if (cfg[@"image"]) img = [[NSImage alloc] initWithContentsOfFile:cfg[@"image"]];
  if (!img) {
    NSString *path = ResolveAppPath(self.appIconEditTarget);
    if (path) img = [[NSWorkspace sharedWorkspace] iconForFile:path];
  }
  NSView *host = self.appIconPreview.superview;
  if (host) {
    CGFloat hw = host.bounds.size.width, hh = host.bounds.size.height;
    self.appIconPreview.frame = NSMakeRect((hw - sz)/2.0, (hh - sz)/2.0, sz, sz);
  }
  self.appIconPreview.cornerRatio = cr;
  self.appIconPreview.selected = NO;
  self.appIconPreview.hugHighlight = NO;
  self.appIconPreview.image = img;
  [self.appIconPreview setNeedsDisplay:YES];
}

- (void)showAppIconPanel:(id)sender {
  if (self.items.count == 0) { NSBeep(); return; }
  if (self.sel < 0 || self.sel >= (NSInteger)self.items.count) self.sel = 0;
  self.appIconEditTarget = self.items[self.sel][@"target"];
  NSDictionary *cfg = gAppIconSettings[self.appIconEditTarget] ?: @{};
  CGFloat curSize = cfg[@"size"] ? [cfg[@"size"] doubleValue] : 40;
  CGFloat curCorner = cfg[@"corner"] ? [cfg[@"corner"] doubleValue] : 0;

  [self.appIconPanel orderOut:nil];
  NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,420,470)
                                          styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
                                            backing:NSBackingStoreBuffered defer:NO];
  p.title = @"自定义图标";
  p.level = NSFloatingWindowLevel;
  self.appIconPanel = p;
  NSView *cv = p.contentView;

  NSTextField *labM = [NSTextField labelWithString:@"应用排列"];
  labM.font = [NSFont systemFontOfSize:13];
  labM.frame = NSMakeRect(20, 420, 60, 20);
  [cv addSubview:labM];
  self.appIconModePicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(90, 416, 310, 26) pullsDown:NO];
  [self.appIconModePicker addItemWithTitle:@"列表显示"];
  [self.appIconModePicker addItemWithTitle:@"图标显示"];
  [self.appIconModePicker selectItemAtIndex:(gIconMode ? 1 : 0)];
  self.appIconModePicker.target = self;
  self.appIconModePicker.action = @selector(appIconModePickerChanged:);
  [cv addSubview:self.appIconModePicker];

  NSTextField *lab0 = [NSTextField labelWithString:@"应用"];
  lab0.font = [NSFont systemFontOfSize:13];
  lab0.frame = NSMakeRect(20, 380, 60, 20);
  [cv addSubview:lab0];
  self.appIconPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(90, 376, 310, 26) pullsDown:NO];
  for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
    [self.appIconPicker addItemWithTitle:(self.items[i][@"label"] ?: @"")];
  }
  [self.appIconPicker selectItemAtIndex:self.sel];
  self.appIconPicker.target = self;
  self.appIconPicker.action = @selector(appIconPickerChanged:);
  [cv addSubview:self.appIconPicker];

  NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(150, 255, 120, 100)];
  host.wantsLayer = YES;
  host.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0].CGColor;
  host.layer.cornerRadius = 12;
  [cv addSubview:host];
  self.appIconPreview = [[AppIconView alloc] initWithFrame:NSMakeRect(10,10,100,100)];
  self.appIconPreview.hugHighlight = NO;
  [host addSubview:self.appIconPreview];

  NSTextField *lab1 = [NSTextField labelWithString:@"图标大小"];
  lab1.font = [NSFont systemFontOfSize:13];
  lab1.frame = NSMakeRect(20, 215, 90, 20);
  [cv addSubview:lab1];
  self.appIconSizeLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f", curSize]];
  self.appIconSizeLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
  self.appIconSizeLabel.alignment = NSTextAlignmentRight;
  self.appIconSizeLabel.frame = NSMakeRect(320, 215, 80, 20);
  [cv addSubview:self.appIconSizeLabel];
  self.appIconSizeSlider = [NSSlider sliderWithValue:curSize minValue:24 maxValue:96 target:self action:@selector(appIconSizeChanged:)];
  self.appIconSizeSlider.frame = NSMakeRect(20, 185, 380, 24);
  self.appIconSizeSlider.continuous = YES;
  [cv addSubview:self.appIconSizeSlider];

  NSTextField *lab2 = [NSTextField labelWithString:@"形状（矩形→圆形）"];
  lab2.font = [NSFont systemFontOfSize:13];
  lab2.frame = NSMakeRect(20, 150, 200, 20);
  [cv addSubview:lab2];
  self.appIconCornerLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f%%", curCorner*100]];
  self.appIconCornerLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
  self.appIconCornerLabel.alignment = NSTextAlignmentRight;
  self.appIconCornerLabel.frame = NSMakeRect(320, 150, 80, 20);
  [cv addSubview:self.appIconCornerLabel];
  self.appIconCornerSlider = [NSSlider sliderWithValue:curCorner*100 minValue:0 maxValue:50 target:self action:@selector(appIconCornerChanged:)];
  self.appIconCornerSlider.frame = NSMakeRect(20, 120, 380, 24);
  self.appIconCornerSlider.continuous = YES;
  [cv addSubview:self.appIconCornerSlider];

  // 列表模式下的遮挡层：点击提示先切换为图标显示
  self.appIconSizeCover = [NSButton buttonWithTitle:@"" target:self action:@selector(showIconModeRequired:)];
  self.appIconSizeCover.frame = self.appIconSizeSlider.frame;
  self.appIconSizeCover.bordered = NO;
  self.appIconSizeCover.focusRingType = NSFocusRingTypeNone;
  [cv addSubview:self.appIconSizeCover];
  self.appIconCornerCover = [NSButton buttonWithTitle:@"" target:self action:@selector(showIconModeRequired:)];
  self.appIconCornerCover.frame = self.appIconCornerSlider.frame;
  self.appIconCornerCover.bordered = NO;
  self.appIconCornerCover.focusRingType = NSFocusRingTypeNone;
  [cv addSubview:self.appIconCornerCover];

  NSButton *pick = [NSButton buttonWithTitle:@"更换应用图标" target:self action:@selector(pickAppIconImage:)];
  pick.frame = NSMakeRect(20, 45, 120, 32);
  pick.bezelStyle = NSBezelStyleRounded;
  [cv addSubview:pick];
  NSButton *rename = [NSButton buttonWithTitle:@"重命名…" target:self action:@selector(renameCurrentApp:)];
  rename.frame = NSMakeRect(150, 45, 78, 32);
  rename.bezelStyle = NSBezelStyleRounded;
  [cv addSubview:rename];
  NSButton *reset = [NSButton buttonWithTitle:@"重置" target:self action:@selector(resetAppIcon:)];
  reset.frame = NSMakeRect(238, 45, 64, 32);
  reset.bezelStyle = NSBezelStyleRounded;
  [cv addSubview:reset];
  NSButton *done = [NSButton buttonWithTitle:@"保存设置" target:self action:@selector(closeAppIconPanel:)];
  done.frame = NSMakeRect(310, 45, 90, 32);
  done.bezelStyle = NSBezelStyleRounded;
  [cv addSubview:done];

  [p center];
  [p makeKeyAndOrderFront:nil];
  [self updateAppIconPanelState];
  [self updateAppIconPreview];
}

- (void)updateAppIconPanelState {
  BOOL icons = gIconMode;
  self.appIconSizeSlider.enabled = icons;
  self.appIconCornerSlider.enabled = icons;
  self.appIconSizeSlider.alphaValue = icons ? 1.0 : 0.45;
  self.appIconCornerSlider.alphaValue = icons ? 1.0 : 0.45;
  self.appIconSizeLabel.alphaValue = icons ? 1.0 : 0.45;
  self.appIconCornerLabel.alphaValue = icons ? 1.0 : 0.45;
  self.appIconSizeCover.hidden = icons;
  self.appIconCornerCover.hidden = icons;
  [self.appIconModePicker selectItemAtIndex:(icons ? 1 : 0)];
}

- (void)appIconModePickerChanged:(id)sender {
  gIconMode = (self.appIconModePicker.indexOfSelectedItem == 1);
  [self saveTheme];
  [self reload];
  if (self.rows.count) [self selectRow:MIN(self.sel, (NSInteger)self.rows.count - 1)];
  [self updateAppIconPanelState];
  [self updateAppIconPreview];
}

- (void)showIconModeRequired:(id)sender {
  NSAlert *e = [[NSAlert alloc] init];
  e.messageText = @"请将应用排列更换为图标显示，方可设置";
  e.informativeText = @"可在此页面上方「应用排列」中切换到「图标显示」。";
  [e runModal];
}

- (void)updateSelectedIconAppearance {
  if (!self.appIconEditTarget) return;
  NSInteger idx = -1;
  for (RowView *r in self.rows) {
    if (r.idx >= 0 && r.idx < (NSInteger)self.items.count && [self.items[r.idx][@"target"] isEqualToString:self.appIconEditTarget]) { idx = r.idx; break; }
  }
  if (idx < 0) { [self reload]; return; }
  RowView *row = self.rows[idx];
  NSDictionary *cfg = gAppIconSettings[self.appIconEditTarget] ?: @{};
  CGFloat customSz = cfg[@"size"] ? [cfg[@"size"] doubleValue] : 0;
  CGFloat corner = cfg[@"corner"] ? [cfg[@"corner"] doubleValue] : 0;
  NSImage *img = nil;
  if (cfg[@"image"]) img = [[NSImage alloc] initWithContentsOfFile:cfg[@"image"]];
  if (!img) {
    NSString *path = ResolveAppPath(self.items[idx][@"target"]);
    if (path) img = [[NSWorkspace sharedWorkspace] iconForFile:path];
  }
  AppIconView *iv = row.iconView;
  CGFloat cellW = row.bounds.size.width, cellH = row.bounds.size.height;
  BOOL grid = gIconMode;
  if (grid) {
    CGFloat sz = customSz > 0 ? customSz : MIN(cellW * 0.62, MIN(cellH * 0.72, 64.0));
    sz = MAX(24.0, MIN(sz, MIN(cellW, cellH) - 4));
    iv.frame = NSMakeRect((cellW - sz)/2.0 - 0.6, (cellH - sz)/2.0 - 0.6, sz + 1.2, sz + 1.2);
    row.iconRect = iv.frame;
    row.iconCorner = corner;
  } else {
    BOOL narrow = (cellW < 250);
    CGFloat base = narrow ? 34 : 40;
    CGFloat sz = customSz > 0 ? MAX(24.0, MIN(customSz, cellH - 10)) : base;
    CGFloat iconX = narrow ? 12 : 20;
    iv.frame = NSMakeRect(iconX, (cellH - sz)/2.0, sz, sz);
    if (row.label) {
      CGFloat textX = iconX + sz + (narrow ? 8 : 14);
      row.label.frame = NSMakeRect(textX, (cellH - 24)/2.0, MAX(40, cellW - textX - 8), 24);
    }
  }
  iv.cornerRatio = corner;
  iv.image = img;
  iv.selected = YES;
  iv.selColor = row.selColor;
  [row setNeedsDisplay:YES];
  [iv setNeedsDisplay:YES];
}

- (void)appIconSizeChanged:(id)sender {
  if (!self.appIconEditTarget) return;
  NSMutableDictionary *cfg = [gAppIconSettings[self.appIconEditTarget] mutableCopy] ?: [NSMutableDictionary dictionary];
  cfg[@"size"] = @(self.appIconSizeSlider.doubleValue);
  gAppIconSettings[self.appIconEditTarget] = cfg;
  self.appIconSizeLabel.stringValue = [NSString stringWithFormat:@"%.0f", self.appIconSizeSlider.doubleValue];
  [self saveTheme];
  [self updateSelectedIconAppearance];
  [self updateAppIconPreview];
}

- (void)appIconCornerChanged:(id)sender {
  if (!self.appIconEditTarget) return;
  NSMutableDictionary *cfg = [gAppIconSettings[self.appIconEditTarget] mutableCopy] ?: [NSMutableDictionary dictionary];
  cfg[@"corner"] = @(self.appIconCornerSlider.doubleValue / 100.0);
  gAppIconSettings[self.appIconEditTarget] = cfg;
  self.appIconCornerLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", self.appIconCornerSlider.doubleValue];
  [self saveTheme];
  [self updateSelectedIconAppearance];
  [self updateAppIconPreview];
}

- (NSImage *)runCropForImage:(NSImage *)image {
  NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,640,700)
                                          styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
                                            backing:NSBackingStoreBuffered defer:NO];
  p.title = @"裁剪应用图标";
  p.level = NSFloatingWindowLevel;
  self.cropPanel = p;
  NSView *cv = p.contentView;
  CropView *crop = [[CropView alloc] initWithFrame:NSMakeRect(20, 90, 600, 560)];
  crop.sourceImage = image;
  self.cropView = crop;
  [cv addSubview:crop];
  NSTextField *tip = [NSTextField labelWithString:@"拖动方框选择裁剪区域，拖右下角调整大小（保持正方形）"];
  tip.font = [NSFont systemFontOfSize:12];
  tip.textColor = [NSColor secondaryLabelColor];
  tip.frame = NSMakeRect(20, 58, 600, 20);
  [cv addSubview:tip];
  NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cropCancel:)];
  cancel.frame = NSMakeRect(400, 16, 90, 32);
  cancel.bezelStyle = NSBezelStyleRounded;
  [cv addSubview:cancel];
  NSButton *ok = [NSButton buttonWithTitle:@"确定裁剪" target:self action:@selector(cropConfirm:)];
  ok.frame = NSMakeRect(500, 16, 120, 32);
  ok.bezelStyle = NSBezelStyleRounded;
  [cv addSubview:ok];
  [p center];
  [NSApp runModalForWindow:p];
  [p orderOut:nil];
  self.cropView = nil;
  self.cropPanel = nil;
  NSImage *result = self.croppedResult;
  self.croppedResult = nil;
  return result;
}

- (void)cropConfirm:(id)sender {
  CropView *crop = self.cropView;
  if (!crop || !crop.sourceImage) { [NSApp stopModalWithCode:0]; return; }
  CGImageRef cg = [crop.sourceImage CGImageForProposedRect:NULL context:nil hints:nil];
  if (!cg) { [NSApp stopModalWithCode:0]; return; }
  CGFloat pw = (CGFloat)CGImageGetWidth(cg), ph = (CGFloat)CGImageGetHeight(cg);
  NSRect ir = crop.imgRect, cr = crop.cropRect;
  CGFloat sx = pw / ir.size.width, sy = ph / ir.size.height;
  CGRect rect = CGRectMake((cr.origin.x - ir.origin.x) * sx, (cr.origin.y - ir.origin.y) * sy,
                           cr.size.width * sx, cr.size.height * sy);
  rect = CGRectIntegral(rect);
  rect.origin.x = MAX(0, MIN(rect.origin.x, pw - rect.size.width));
  rect.origin.y = MAX(0, MIN(rect.origin.y, ph - rect.size.height));
  CGImageRef cropped = CGImageCreateWithImageInRect(cg, rect);
  if (cropped) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cropped];
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(rect.size.width, rect.size.height)];
    [img addRepresentation:rep];
    self.croppedResult = img;
    CGImageRelease(cropped);
  }
  [NSApp stopModalWithCode:1];
}

- (void)cropCancel:(id)sender {
  [NSApp stopModalWithCode:0];
}

- (void)pickAppIconImage:(id)sender {
  if (!self.appIconEditTarget) return;
  NSOpenPanel *pn = [NSOpenPanel openPanel];
  pn.allowsMultipleSelection = NO;
  pn.canChooseDirectories = NO;
  pn.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"tiff", @"gif", @"webp"];
  if ([pn runModal] != NSModalResponseOK) return;
  NSImage *src = [[NSImage alloc] initWithContentsOfURL:pn.URL];
  if (!src) return;
  NSImage *cropped = [self runCropForImage:src];
  if (!cropped) return;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"DockLaunchers/appicons"];
  [fm createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *path = [support stringByAppendingPathComponent:[NSString stringWithFormat:@"icon-%lu.png", (unsigned long)([[NSDate date] timeIntervalSince1970]*1000)]];
  CGImageRef cg = [cropped CGImageForProposedRect:NULL context:nil hints:nil];
  NSBitmapImageRep *rep = cg ? [[NSBitmapImageRep alloc] initWithCGImage:cg] : nil;
  NSData *png = rep ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
  if (!png || ![png writeToFile:path atomically:YES]) return;

  NSMutableDictionary *cfg = [gAppIconSettings[self.appIconEditTarget] mutableCopy] ?: [NSMutableDictionary dictionary];
  cfg[@"image"] = path;
  gAppIconSettings[self.appIconEditTarget] = cfg;
  [self saveTheme];
  [self updateSelectedIconAppearance];
  [self updateAppIconPreview];
}

- (void)resetAppIcon:(id)sender {
  if (!self.appIconEditTarget) return;
  // 恢复首次添加时的默认名称
  NSString *path = ResolveAppPath(self.appIconEditTarget);
  NSString *orig = nil;
  if (path) {
    orig = [[NSFileManager defaultManager] displayNameAtPath:path];
    if ([orig hasSuffix:@".app"]) orig = [orig substringToIndex:orig.length - 4];
  }
  if (orig.length > 0) {
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
      if ([self.items[i][@"target"] isEqualToString:self.appIconEditTarget]) {
        if (![self.items[i][@"label"] isEqualToString:orig]) {
          [self updateLabel:orig forTarget:self.appIconEditTarget];
          if (self.appIconPicker && i == self.appIconPicker.indexOfSelectedItem) {
            NSMenuItem *mi = [self.appIconPicker menu].itemArray[i];
            if (mi) mi.title = orig;
          }
        }
        break;
      }
    }
  }
  // 清除自定义图标/大小/形状
  [gAppIconSettings removeObjectForKey:self.appIconEditTarget];
  [self saveTheme];
  [self.appIconSizeSlider setDoubleValue:40];
  [self.appIconCornerSlider setDoubleValue:0];
  self.appIconSizeLabel.stringValue = @"40";
  self.appIconCornerLabel.stringValue = @"0%";
  NSInteger keep = self.sel;
  [self reload];
  if (self.rows.count) [self selectRow:MIN(keep, (NSInteger)self.rows.count - 1)];
  [self updateSelectedIconAppearance];
  [self updateAppIconPreview];
}

- (void)renameCurrentApp:(id)sender {
  if (!self.appIconEditTarget) return;
  NSString *curName = @"";
  NSInteger idx = -1;
  for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
    if ([self.items[i][@"target"] isEqualToString:self.appIconEditTarget]) { curName = self.items[i][@"label"] ?: @""; idx = i; break; }
  }
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
  a.messageText = @"重命名应用";
  a.informativeText = @"只修改列表中的显示名，不改变应用本身；列表显示和图标显示都会同步。";
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
  tf.stringValue = curName;
  a.accessoryView = tf;
  [a addButtonWithTitle:@"确定"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *newLabel = [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (newLabel.length == 0) return;
  if (![self updateLabel:newLabel forTarget:self.appIconEditTarget]) return;

  // 同步面板下拉标题
  if (idx >= 0) {
    NSMenuItem *mi = [self.appIconPicker menu].itemArray[idx];
    if (mi) mi.title = newLabel;
    [self.appIconPicker selectItemAtIndex:idx];
  }
  // 同步主列表
  NSInteger keep = self.sel;
  [self reload];
  if (self.rows.count) [self selectRow:MIN(keep, (NSInteger)self.rows.count - 1)];
  [self updateAppIconPreview];
}

- (void)closeAppIconPanel:(id)sender {
  // 保存后刷新主页面，确保同步
  NSInteger keep = self.sel;
  [self reload];
  if (self.rows.count) [self selectRow:MIN(keep, (NSInteger)self.rows.count - 1)];
  [self.appIconPanel orderOut:nil];
  self.appIconEditTarget = nil;
  self.appIconPicker = nil;
  self.appIconPreview = nil;
}

#pragma mark - 钉住

#pragma mark - 钉住

- (void)updatePinAppearance {
  NSImage *img = [NSImage imageWithSystemSymbolName:@"pin.fill" accessibilityDescription:@"钉住"];
  if (img) {
    [img setTemplate:YES];
    self.pinBtn.image = img;
    self.pinBtn.imagePosition = NSImageOnly;
    self.pinBtn.contentTintColor = self.pinned ? [NSColor systemRedColor] : [NSColor secondaryLabelColor];
    self.pinBtn.title = @"";
  } else {
    self.pinBtn.title = @"📌";
    self.pinBtn.font = [NSFont systemFontOfSize:18];
    self.pinBtn.alphaValue = self.pinned ? 1.0 : 0.45;
  }
  self.pinBtn.toolTip = self.pinned ? @"已钉住：窗口置顶，最小化/关闭已禁用" : @"钉住：置顶并禁用最小化/关闭（再点取消）";
  if (self.window) {
    if (self.pinned) {
      self.window.level = NSStatusWindowLevel;
      self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
      self.window.hidesOnDeactivate = NO;
    } else {
      self.window.level = NSNormalWindowLevel;
      self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
    }
    NSButton *mini = [self.window standardWindowButton:NSWindowMiniaturizeButton];
    if (mini) mini.enabled = !self.pinned;
    NSButton *cl = [self.window standardWindowButton:NSWindowCloseButton];
    if (cl) cl.enabled = !self.pinned;
  }
}

- (void)togglePin:(id)sender {
  self.pinned = !self.pinned;
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setBool:self.pinned forKey:@"pinned"];
  [d synchronize];
  [self updatePinAppearance];
  if (self.pinned) { [self.idleExitTimer invalidate]; self.idleExitTimer = nil; }
  else [self resetIdleTimer];
  if (self.pinned) NSBeep();
}

#pragma mark - 内存/缓存

- (void)toggleIdleExit:(id)sender {
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  BOOL on = ![d boolForKey:@"idleExitEnabled"];
  [d setBool:on forKey:@"idleExitEnabled"];
  [d synchronize];
  if (on) [self resetIdleTimer]; else { [self.idleExitTimer invalidate]; self.idleExitTimer = nil; }
}

- (void)resetIdleTimer {
  [self.idleExitTimer invalidate];
  self.idleExitTimer = nil;
  if (self.pinned) return;
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  if (![d boolForKey:@"idleExitEnabled"]) return;
  self.idleExitTimer = [NSTimer timerWithTimeInterval:180.0 target:self selector:@selector(idleExitFired:) userInfo:nil repeats:NO];
  [[NSRunLoop mainRunLoop] addTimer:self.idleExitTimer forMode:NSRunLoopCommonModes];
}

- (void)idleExitFired:(NSTimer *)t {
  self.idleExitTimer = nil;
  if (self.pinned) return;
  [NSApp terminate:nil];
}

- (void)refreshListAndCaches:(id)sender {
  [self reload];
  [[NSURLCache sharedURLCache] removeAllCachedResponses];
}

#pragma mark - 快捷键映射

// 所有分组共用同一份快捷键（存放在共享偏好域里）
static NSString *const kSharedShortcutSuite = @"com.docklaunchers.shared";

- (NSUserDefaults *)sharedShortcutDefaults {
  return [[NSUserDefaults alloc] initWithSuiteName:kSharedShortcutSuite];
}

- (void)loadCustomShortcuts {
  NSUserDefaults *shared = [self sharedShortcutDefaults];
  NSDictionary *d = [shared dictionaryForKey:@"customShortcuts"];
  if (!d) {
    // 迁移旧的“按分组保存”的快捷键
    d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"customShortcuts"];
    if (d) { [shared setObject:d forKey:@"customShortcuts"]; [shared synchronize]; }
  }
  self.customShortcuts = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveCustomShortcuts {
  NSUserDefaults *shared = [self sharedShortcutDefaults];
  [shared setObject:self.customShortcuts forKey:@"customShortcuts"];
  [shared synchronize];
  [self setupTooltips];
}

- (NSString *)shortcutSuffixForAction:(NSString *)actionId {
  NSString *sig = self.customShortcuts[actionId];
  if (sig.length == 0) return @"";
  return [NSString stringWithFormat:@"（%@）", DisplayForSignature(sig)];
}

- (void)showShortcutSettings:(id)sender {
  if (!self.shortcutPanel) {
    CGFloat rowH = 46.0;
    CGFloat n = (CGFloat)[ShortcutActions() count];
    CGFloat h = 150.0 + rowH * n;
    ShortcutPanelView *pv = [[ShortcutPanelView alloc] initWithFrame:NSMakeRect(0, 0, 500, h)];
    pv.ctrl = self;
    self.shortcutPanel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,500,h)
                                                     styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
                                                       backing:NSBackingStoreBuffered defer:NO];
    self.shortcutPanel.title = @"快捷键设置（仅本应用生效）";
    self.shortcutPanel.level = NSFloatingWindowLevel;
    self.shortcutPanel.contentView = pv;

    NSTextField *tip = [NSTextField labelWithString:@"点击行选中 · ↑↓ 换行 · Enter/空格/双击 录制 · Esc 取消 · 右侧 ↺ 重置。⌘Space 被系统占用，建议用 ⌘F。"];
    tip.font = [NSFont systemFontOfSize:11];
    tip.textColor = [NSColor secondaryLabelColor];
    tip.frame = NSMakeRect(20, h - 34, 460, 16);
    [pv addSubview:tip];

    NSMutableArray *rows = [NSMutableArray array];
    __weak Controller *weakSelf = self;
    CGFloat y = h - 72;
    NSInteger rowIdx = 0;
    for (NSDictionary *a in ShortcutActions()) {
      ShortcutRowView *r = [[ShortcutRowView alloc] initWithFrame:NSMakeRect(20, y, 460, rowH)];
      r.actionId = a[@"id"];
      r.nameText = a[@"name"];
      NSInteger myIdx = rowIdx;
      r.onHover = ^(BOOL inside) {
        Controller *ss = weakSelf; if (!ss) return;
        ss.hoverRow = inside ? myIdx : -1;
        [ss refreshShortcutRows];
      };
      NSString *aid = a[@"id"];
      r.onActivate = ^{
        Controller *ss = weakSelf; if (!ss) return;
        ss.shortcutSel = [ss.shortcutRows indexOfObject:r];
        ss.hoverRow = -1;
        [ss refreshShortcutRows];
        [ss.shortcutPanel makeFirstResponder:ss.shortcutPanel.contentView];
      };
      r.onRecord = ^{
        Controller *ss = weakSelf; if (!ss) return;
        [ss startRecordingForAction:aid];
      };
      r.onReset = ^{
        Controller *ss = weakSelf; if (!ss) return;
        [ss resetShortcutForAction:aid];
      };
      [pv addSubview:r];
      [rows addObject:r];
      rowIdx++;
      y -= rowH;
    }
    self.shortcutRows = rows;

    NSButton *done = [NSButton buttonWithTitle:@"关闭" target:self action:@selector(closeShortcutPanel:)];
    done.bezelStyle = NSBezelStyleRounded;
    done.frame = NSMakeRect(380, 16, 100, 32);
    done.focusRingType = NSFocusRingTypeNone;
    [pv addSubview:done];
  }

  [self refreshShortcutRows];
  if (self.shortcutPanel.sheetParent) {
    [self.shortcutPanel makeKeyAndOrderFront:nil];
    return;
  }
  self.shortcutSel = -1;   // 进入时不预选，等 ↑↓/点击再高亮
  self.hoverRow = -1;
  [self refreshShortcutRows];
  [NSApp activateIgnoringOtherApps:YES];
  [self.window beginSheet:self.shortcutPanel completionHandler:nil];
  [self.shortcutPanel makeFirstResponder:self.shortcutPanel.contentView];
}

- (void)refreshShortcutRows {
  NSInteger hl = (self.hoverRow >= 0) ? self.hoverRow : self.shortcutSel;
  NSInteger idx = 0;
  for (ShortcutRowView *r in self.shortcutRows) {
    r.sigText = self.customShortcuts[r.actionId];
    r.statusText = [r.actionId isEqualToString:(self.recordingAction ?: @"")] ? @"请按下按键…" : nil;
    r.selected = (idx == hl);
    [r setNeedsDisplay:YES];
    idx++;
  }
}

- (void)shortcutPanelKeyDown:(NSEvent *)event {
  NSUInteger code = event.keyCode;
  NSInteger n = (NSInteger)self.shortcutRows.count;
  if (code == 126) { // ↑
    self.hoverRow = -1;
    if (n > 0) { self.shortcutSel = (self.shortcutSel <= 0) ? n - 1 : self.shortcutSel - 1; [self refreshShortcutRows]; }
  } else if (code == 125) { // ↓
    self.hoverRow = -1;
    if (n > 0) { self.shortcutSel = (self.shortcutSel < 0 || self.shortcutSel >= n - 1) ? 0 : self.shortcutSel + 1; [self refreshShortcutRows]; }
  } else if (code == 36 || code == 49) { // Enter / Space
    if (self.shortcutSel >= 0 && self.shortcutSel < n) [self startRecordingForAction:self.shortcutRows[self.shortcutSel].actionId];
  } else if (code == 53) { // Esc
    [self closeShortcutPanel:nil];
  }
}

- (void)startRecordingForAction:(NSString *)actionId {
  self.recordingAction = actionId;
  self.hoverRow = -1;
  for (ShortcutRowView *r in self.shortcutRows) {
    r.selected = NO; r.hovered = NO;
    r.statusText = [r.actionId isEqualToString:actionId] ? @"请按下按键…" : nil;
    [r setNeedsDisplay:YES];
  }
  if (self.recordingMonitor) { [NSEvent removeMonitor:self.recordingMonitor]; self.recordingMonitor = nil; }
  __weak Controller *weakSelf = self;
  self.recordingMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
    Controller *ss = weakSelf; if (!ss) return e;
    [ss finishRecordingWithEvent:e];
    return nil;
  }];
}

- (void)resetShortcutForAction:(NSString *)actionId {
  [self.customShortcuts removeObjectForKey:actionId];
  [self saveCustomShortcuts];
  [self refreshShortcutRows];
}

- (void)closeShortcutPanel:(id)sender {
  if (self.shortcutPanel.sheetParent) {
    [self.shortcutPanel.sheetParent endSheet:self.shortcutPanel];
  } else {
    [self.shortcutPanel orderOut:nil];
  }
}

- (void)finishRecordingWithEvent:(NSEvent *)event {
  if (self.recordingMonitor) { [NSEvent removeMonitor:self.recordingMonitor]; self.recordingMonitor = nil; }
  NSString *action = self.recordingAction;
  self.recordingAction = nil;
  [self refreshShortcutRows];
  [self.shortcutPanel makeFirstResponder:self.shortcutPanel.contentView];
  if (!action) return;
  if (event.keyCode == 53) return; // Esc 取消
  if (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 ||
      event.keyCode == 126 || event.keyCode == 48) {   // ←→↓↑ / Tab 不能作快捷键
    NSBeep();
    [self refreshShortcutRows];
    return;
  }
  NSString *sig = SignatureForEvent(event);
  if (!SignatureIsAllowed(sig)) { NSBeep(); return; }

  // 系统保留组合键提示
  NSArray *reserved = @[@"cmd+space", @"cmd+tab", @"cmd+`", @"cmd+q", @"cmd+w", @"cmd+h", @"cmd+m", @"ctrl+up", @"ctrl+down", @"ctrl+left", @"ctrl+right"];
  if ([reserved containsObject:sig]) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"这是 macOS 系统快捷键";
    a.informativeText = [NSString stringWithFormat:@"%@ 可能被系统占用导致不生效，建议换一个组合键。", DisplayForSignature(sig)];
    [a runModal];
    return;
  }

  // 与本应用其他动作冲突检查
  for (NSDictionary *a in ShortcutActions()) {
    if ([a[@"id"] isEqualToString:action]) continue;
    NSString *other = self.customShortcuts[a[@"id"]];
    if (other.length && [other isEqualToString:sig]) {
      NSAlert *al = [[NSAlert alloc] init];
      al.messageText = @"快捷键已被占用";
      al.informativeText = [NSString stringWithFormat:@"%@ 已经绑定给「%@」，请换一个组合键。", DisplayForSignature(sig), a[@"name"]];
      [al runModal];
      return;
    }
  }

  self.customShortcuts[action] = sig;
  [self saveCustomShortcuts];
  [self refreshShortcutRows];
  [self.shortcutPanel makeFirstResponder:self.shortcutPanel.contentView];
}

- (BOOL)handleCustomShortcut:(NSEvent *)event {
  if (self.recordingAction) return NO;
  // 快捷键设置面板打开时，不触发应用内快捷键（避免设单键时误触发操作）
  if (self.shortcutPanel.sheetParent != nil) return NO;
  NSString *sig = SignatureForEvent(event);
  BOOL hasMod = SignatureHasModifier(sig);
  BOOL editing = [self.window.firstResponder isKindOfClass:[NSTextView class]];
  for (NSDictionary *a in ShortcutActions()) {
    NSString *stored = self.customShortcuts[a[@"id"]];
    if (stored.length && [stored isEqualToString:sig]) {
      if (!hasMod && editing) return NO; // 正在输入文字时，单键快捷键不触发
      [self performShortcutAction:a[@"id"]];
      return YES;
    }
  }
  return NO;
}

- (void)performShortcutAction:(NSString *)action {
  if ([action isEqualToString:@"add"]) [self addApps:nil];
  else if ([action isEqualToString:@"remove"]) [self removeSelected:nil];
  else if ([action isEqualToString:@"skin"]) [self showSkinMenu:nil];
  else if ([action isEqualToString:@"search"]) [self toggleSearch];
  else if ([action isEqualToString:@"open"]) [self openSelected:nil];
  else if ([action isEqualToString:@"cancel"]) [self closeCancel:nil];
}

#pragma mark - 自定义图标

- (NSString *)emojiForGroup {
  NSString *g = gGroup ?: @"";
  if ([g containsString:@"工作"]) return @"💼";
  if ([g containsString:@"聊天"]) return @"💬";
  if ([g containsString:@"外网"]) return @"🌐";
  if ([g containsString:@"影音"]) return @"🎬";
  if ([g containsString:@"Ai"] || [g containsString:@"AI"]) return @"🧠";
  if ([g containsString:@"Docker"]) return @"🐳";
  if ([g containsString:@"工具"]) return @"🔧";
  return @"✨";
}

- (NSImage *)composeIconWithImage:(NSImage *)img {
  NSSize sz = NSMakeSize(1024, 1024);
  NSImage *out = [[NSImage alloc] initWithSize:sz];
  [out lockFocus];

  // macOS 应用图标的圆角方形（约 22.4% 圆角）
  CGFloat radius = 1024.0 * 0.2237;
  NSRect full = NSMakeRect(0, 0, 1024, 1024);
  NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:full xRadius:radius yRadius:radius];
  [clip addClip];

  // 背景：与默认图标一致的浅色渐变
  NSGradient *grad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.99 green:0.99 blue:1.0 alpha:1.0]
                                                  endingColor:[NSColor colorWithCalibratedRed:0.93 green:0.94 blue:0.96 alpha:1.0]];
  [grad drawInRect:full angle:-90.0];

  // 人物图等比缩放，留出内边距，不裁切
  NSSize is = img.size;
  if (is.width > 0 && is.height > 0) {
    CGFloat pad = 8.0;
    CGFloat avail = 1024.0 - pad * 2.0;
    CGFloat k = MIN(avail/is.width, avail/is.height);
    NSSize ds = NSMakeSize(is.width*k, is.height*k);
    [img drawInRect:NSMakeRect((1024-ds.width)/2.0, (1024-ds.height)/2.0, ds.width, ds.height)
           fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
  }

  // 右上角 emoji 角标保持原位
  NSString *emoji = [self emojiForGroup];
  NSFont *ef = [NSFont fontWithName:@"Apple Color Emoji" size:190];
  if (!ef) ef = [NSFont systemFontOfSize:190];
  NSShadow *sh = [[NSShadow alloc] init];
  sh.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.42];
  sh.shadowBlurRadius = 18.0;
  sh.shadowOffset = NSMakeSize(0, -8);
  NSDictionary *attrs = @{NSFontAttributeName: ef, NSShadowAttributeName: sh};
  NSSize es = [emoji sizeWithAttributes:attrs];
  [emoji drawAtPoint:NSMakePoint(1024 - es.width - 26, 1024 - es.height - 20) withAttributes:attrs];

  [out unlockFocus];
  return out;
}

- (void)applyCustomIconAtPath:(NSString *)path {
  if (path.length == 0) return;
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
  if (!img) return;
  NSImage *icon = [self composeIconWithImage:img];
  // 运行中的 App：立刻替换 Dock / 程序切换器里的图标
  [NSApp setApplicationIconImage:icon];
  // 同时写入 App 包，退出后 Dock / Finder 也保持新图标
  [[NSWorkspace sharedWorkspace] setIcon:icon forFile:[[NSBundle mainBundle] bundlePath] options:0];
  self.customIconPath = path;
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setObject:path forKey:@"customIconPath"];
  [d setObject:path forKey:@"customIconApplied"];
  [d synchronize];
}

- (void)pickIconImage:(id)sender {
  NSOpenPanel *pn = [NSOpenPanel openPanel];
  pn.allowsMultipleSelection = NO;
  pn.canChooseDirectories = NO;
  pn.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"tiff", @"gif", @"webp"];
  pn.message = @"选择人物图片作为图标（保持等比缩放进图标，不裁切；右上角 emoji 保持不变）";
  if ([pn runModal] != NSModalResponseOK) return;
  [self applyCustomIconAtPath:pn.URL.path];
}

- (void)resetCustomIcon:(id)sender {
  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
  [NSApp setApplicationIconImage:nil];
  [[NSWorkspace sharedWorkspace] setIcon:nil forFile:bundlePath options:0];
  self.customIconPath = nil;
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d removeObjectForKey:@"customIconPath"];
  [d removeObjectForKey:@"customIconApplied"];
  [d synchronize];
  NSTask *md = [[NSTask alloc] init];
  md.launchPath = @"/usr/bin/mdimport";
  md.arguments = @[bundlePath];
  @try { [md launch]; } @catch (NSException *e) {}
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/killall";
    t.arguments = @[@"-KILL", @"Dock"];
    @try { [t launch]; } @catch (NSException *e) {}
  });
}

- (void)promptIconChange {
  if (self.window) { [self.window makeKeyAndOrderFront:nil]; }
  [self pickIconImage:nil];
}

- (void)showGlassPanel:(id)sender {
  if (gTheme != 2) { gTheme = 2; [self applyTheme]; }
  if (!self.glassPanel) {
    self.glassPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,360,140)
                                                  styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView)
                                                    backing:NSBackingStoreBuffered defer:NO];
    self.glassPanel.title = @"玻璃透明度（实时预览）";
    self.glassPanel.level = NSFloatingWindowLevel;
    self.glassPanel.releasedWhenClosed = NO;
    NSView *cv = self.glassPanel.contentView;

    NSTextField *lab = [NSTextField labelWithString:@"透明度"];
    lab.font = [NSFont systemFontOfSize:13];
    lab.frame = NSMakeRect(20, 92, 60, 20);
    [cv addSubview:lab];

    self.glassValueLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f%%", gGlassAlpha*100]];
    self.glassValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.glassValueLabel.alignment = NSTextAlignmentRight;
    self.glassValueLabel.frame = NSMakeRect(270, 92, 70, 20);
    [cv addSubview:self.glassValueLabel];

    self.glassSlider = [NSSlider sliderWithValue:gGlassAlpha minValue:0.30 maxValue:1.0 target:self action:@selector(glassSliderChanged:)];
    self.glassSlider.frame = NSMakeRect(20, 60, 320, 24);
    self.glassSlider.continuous = YES;
    [cv addSubview:self.glassSlider];

    NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(closeGlassPanel:)];
    done.frame = NSMakeRect(240, 16, 100, 32);
    done.bezelStyle = NSBezelStyleRounded;
    done.keyEquivalent = @"\r";
    [cv addSubview:done];

    [self.glassPanel center];
  }
  [self.glassSlider setDoubleValue:gGlassAlpha];
  self.glassValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", gGlassAlpha*100];
  [self.glassPanel makeKeyAndOrderFront:nil];
}

- (void)glassSliderChanged:(id)sender {
  gGlassAlpha = self.glassSlider.doubleValue;
  self.glassValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", gGlassAlpha*100];
  self.window.alphaValue = gGlassAlpha;
  [self saveTheme];
}

- (void)closeGlassPanel:(id)sender {
  [self.glassPanel orderOut:nil];
}

- (void)showShapePanel:(id)sender {
  if (!self.shapePanel) {
    self.shapePanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,380,150)
                                                 styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
                                                   backing:NSBackingStoreBuffered defer:NO];
    self.shapePanel.title = @"窗口变形（实时预览）";
    self.shapePanel.level = NSFloatingWindowLevel;
    NSView *cv = self.shapePanel.contentView;
    CGFloat W3 = 380.0 / 3.0;

    NSTextField *leftLab = [NSTextField labelWithString:@"矩形"];
    leftLab.font = [NSFont systemFontOfSize:12];
    leftLab.textColor = [NSColor secondaryLabelColor];
    leftLab.alignment = NSTextAlignmentCenter;
    leftLab.frame = NSMakeRect(0, 100, W3, 20);
    [cv addSubview:leftLab];

    self.shapeValueLabel = [NSTextField labelWithString:@"0%"];
    self.shapeValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    self.shapeValueLabel.alignment = NSTextAlignmentCenter;
    self.shapeValueLabel.frame = NSMakeRect(W3, 100, W3, 20);
    [cv addSubview:self.shapeValueLabel];

    NSTextField *rightLab = [NSTextField labelWithString:@"圆形"];
    rightLab.font = [NSFont systemFontOfSize:12];
    rightLab.textColor = [NSColor secondaryLabelColor];
    rightLab.alignment = NSTextAlignmentCenter;
    rightLab.frame = NSMakeRect(W3*2, 100, W3, 20);
    [cv addSubview:rightLab];

    self.shapeSlider = [NSSlider sliderWithValue:gCornerRatio*100.0 minValue:0 maxValue:50 target:self action:@selector(shapeSliderChanged:)];
    self.shapeSlider.frame = NSMakeRect(20, 56, 340, 24);
    self.shapeSlider.continuous = YES;
    [cv addSubview:self.shapeSlider];

    NSButton *resetBtn = [NSButton buttonWithTitle:@"恢复矩形" target:self action:@selector(resetShapeRectangle:)];
    resetBtn.frame = NSMakeRect(20, 14, 110, 32);
    resetBtn.bezelStyle = NSBezelStyleRounded;
    [cv addSubview:resetBtn];
    NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(closeShapePanel:)];
    done.frame = NSMakeRect(260, 14, 100, 32);
    done.bezelStyle = NSBezelStyleRounded;
    [cv addSubview:done];
    [self.shapePanel center];
  }
  [self.shapeSlider setDoubleValue:gCornerRatio*100.0];
  self.shapeValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", gCornerRatio*100.0];
  [self.shapePanel makeKeyAndOrderFront:nil];
}

- (void)shapeSliderChanged:(id)sender {
  gCornerRatio = self.shapeSlider.doubleValue / 100.0;
  self.shapeValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", gCornerRatio*100.0];
  [self applyTheme];
  [self layoutContent];
  [self reload];
  [self saveTheme];
}

- (void)resetShapeRectangle:(id)sender {
  gCornerRatio = 0;
  if (self.shapeSlider) [self.shapeSlider setDoubleValue:0];
  if (self.shapeValueLabel) self.shapeValueLabel.stringValue = @"0%";
  [self applyTheme];
  [self layoutContent];
  [self reload];
  [self saveTheme];
}

- (void)closeShapePanel:(id)sender {
  [self.shapePanel orderOut:nil];
}

- (void)customPick:(id)sender {
  NSOpenPanel *pn = [NSOpenPanel openPanel];
  pn.allowsMultipleSelection = NO;
  pn.canChooseDirectories = NO;
  pn.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"tiff", @"gif", @"webp"];
  if ([pn runModal] != NSModalResponseOK) return;
  NSString *path = pn.URL.path;
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
  if (!img) return;
  CropController *cc = [[CropController alloc] init];
  cc.image = img;
  __weak Controller *weakSelf = self;
  cc.completion = ^(BOOL ok) {
    if (!ok) return;
    gImgPath = path;
    gTheme = 3;
    [weakSelf applyTheme];
  };
  [cc runModalForWindow:self.window];
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSTimeInterval t_start = [NSDate timeIntervalSinceReferenceDate];
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleKey = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
    if (argc >= 3) {
      gListKey = [NSString stringWithUTF8String:argv[1]];
      gListFile = [NSString stringWithUTF8String:argv[2]];
    } else if (bundleKey.length > 0 && bundlePath.length > 0) {
      gListKey = bundleKey;
      NSString *lists = [[bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"lists"];
      gListFile = [lists stringByAppendingPathComponent:[bundleKey stringByAppendingPathExtension:@"txt"]];
    } else {
      fprintf(stderr, "usage: ui <group> <listfile>\n");
      return 2;
    }
    NSString *display = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (display.length == 0) {
      display = gListKey;
      if ([display hasSuffix:@"组"]) display = [display substringToIndex:display.length-1];
    }
    gGroup = display;
    NSString *nameOverride = [[NSUserDefaults standardUserDefaults] stringForKey:@"displayNameOverride"];
    if (nameOverride.length > 0) gGroup = nameOverride;

    NSTimeInterval tA = [NSDate timeIntervalSinceReferenceDate];
    [NSApplication sharedApplication];
    NSTimeInterval tB = [NSDate timeIntervalSinceReferenceDate];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSTimeInterval tC = [NSDate timeIntervalSinceReferenceDate];
    if (getenv("DOCKLAUNCHER_BENCH")) fprintf(stderr, "INIT app=%.0f policy=%.0f\n", (tB-tA)*1000.0, (tC-tB)*1000.0);
    // 单实例清理放到窗口显示之后异步做，不占用启动关键路径
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      for (NSRunningApplication *ra in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (ra.processIdentifier != getpid() && [ra.localizedName isEqualToString:@"ui"]) {
          [ra terminate];
        }
      }
    });
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [NSApplication sharedApplication].delegate = delegate;

    Controller *c = [[Controller alloc] init];
    [c loadTheme];
    NSString *savedIcon = [[NSUserDefaults standardUserDefaults] stringForKey:@"customIconPath"];
    NSString *appliedIcon = [[NSUserDefaults standardUserDefaults] stringForKey:@"customIconApplied"];
    BOOL bundleHasCustomIcon = (getxattr([bundlePath fileSystemRepresentation], "com.apple.FinderInfo", NULL, 0, 0, 0) > 0);
    if (savedIcon.length > 0 && (![savedIcon isEqualToString:(appliedIcon ?: @"")] || !bundleHasCustomIcon)) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c applyCustomIconAtPath:savedIcon];
      });
    }
    c.sel = 0;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    if (getenv("DOCKLAUNCHER_BENCH")) fprintf(stderr, "PREBUILD_MS=%.0f\n", (t0 - t_start)*1000.0);
    [c buildWindow];
    if (getenv("DOCKLAUNCHER_BENCH")) {
      fprintf(stderr, "BUILD_MS=%.1f\n", ([NSDate timeIntervalSinceReferenceDate] - t0)*1000.0);
    }
    if (getenv("DOCKLAUNCHER_TEST_SETICON")) {
      NSString *ip = [NSString stringWithUTF8String:getenv("DOCKLAUNCHER_TEST_SETICON")];
      [c applyCustomIconAtPath:ip];
      fprintf(stderr, "SETICON_DONE\n");
      exit(0);
    }
    if (getenv("DOCKLAUNCHER_TEST_ICON")) {
      NSString *ip = [NSString stringWithUTF8String:getenv("DOCKLAUNCHER_TEST_ICON")];
      NSImage *src = [[NSImage alloc] initWithContentsOfFile:ip];
      if (src) {
        NSImage *ic = [c composeIconWithImage:src];
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[ic TIFFRepresentation]];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:@"/tmp/icon_test.png" atomically:YES];
      }
      exit(0);
    }
    delegate.mainWindow = c.window;
    delegate.controller = c;
    NSTimeInterval tD = [NSDate timeIntervalSinceReferenceDate];
    [c.window center];
    NSTimeInterval tE = [NSDate timeIntervalSinceReferenceDate];
    c.window.level = NSFloatingWindowLevel;
    NSTimeInterval tF = [NSDate timeIntervalSinceReferenceDate];
    [c.window orderFrontRegardless];
    if (getenv("DOCKLAUNCHER_BENCH")) fprintf(stderr, "STAGE center=%.0f level=%.0f orderfront=%.0f\n",
      (tE-tD)*1000.0, (tF-tE)*1000.0, ([NSDate timeIntervalSinceReferenceDate]-tF)*1000.0);
    if (getenv("DOCKLAUNCHER_BENCH")) {
      fprintf(stderr, "VISIBLE_MS=%.1f (BUILD %.1f)\n",
              ([NSDate timeIntervalSinceReferenceDate] - t_start) * 1000.0,
              ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0);
    }
    [c.window makeKeyWindow];
    if (getenv("DOCKLAUNCHER_BENCH")) fprintf(stderr, "MAKEKEY_DONE\n");
    [NSApp activateIgnoringOtherApps:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      c.window.level = NSNormalWindowLevel;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [NSApp activateIgnoringOtherApps:YES];
      [c.window makeKeyAndOrderFront:nil];
      [c.window makeFirstResponder:c.window.contentView];
    if (getenv("DOCKLAUNCHER_BENCH")) {
      fprintf(stderr, "WINDOW_READY_MS=%.1f (BUILD_MS=%.1f)\n",
              ([NSDate timeIntervalSinceReferenceDate] - t_start) * 1000.0,
              ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
    }
    });
    if (getenv("DOCKLAUNCHER_MEM")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        struct mach_task_basic_info info;
        mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
          fprintf(stderr, "RSS=%.1fMB\n", info.resident_size / 1048576.0);
        }
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SHAPE_COLS")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        c.userColumns = 3;
        [c reload];
        gCornerRatio = 0.5;
        [c applyTheme];
        [c layoutContent];
        [c reload];
        fprintf(stderr, "COLS=%ld ROWW=%.0f\n", (long)[c effectiveColumns], c.rows.count ? [c.rows.firstObject frame].size.width : 0);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_PANEL_LIST_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = NO; [c reload];
        c.sel = 0; [c selectRow:0];
        [c showAppIconPanel:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_RENAME_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES; [c reload];
        c.sel = 0; [c selectRow:0];
        [c showAppIconPanel:nil];
        [c renameCurrentApp:nil];
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_CROP_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *path = [NSString stringWithUTF8String:getenv("DOCKLAUNCHER_TEST_CROP_SHOW")];
        NSImage *src = [[NSImage alloc] initWithContentsOfFile:path];
        NSImage *out = [c runCropForImage:src];
        fprintf(stderr, "CROP result=%d size=%.0fx%.0f\n", out != nil, out.size.width, out.size.height);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_ICONSTRESS")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES; [c reload];
        for (int i = 0; i < 12; i++) {
          c.sel = i % (c.items.count ? c.items.count : 1);
          [c selectRow:c.sel];
          [c showAppIconPanel:nil];
          if (c.appIconPicker.numberOfItems > 1) {
            [c.appIconPicker selectItemAtIndex:(i+1) % c.appIconPicker.numberOfItems];
            [c appIconPickerChanged:nil];
          }
          [c.appIconCornerSlider setDoubleValue:25]; [c appIconCornerChanged:nil];
          [c.appIconSizeSlider setDoubleValue:50]; [c appIconSizeChanged:nil];
          [c closeAppIconPanel:nil];
        }
        fprintf(stderr, "ICONSTRESS ok\n");
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_ICONPICK")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES;
        [c reload];
        c.sel = 0;
        [c selectRow:0];
        [c showAppIconPanel:nil];
        [c.appIconPicker selectItemAtIndex:1];
        [c appIconPickerChanged:nil];
        fprintf(stderr, "PICK sel=%ld target=%s preview=%d corner=%.2f\n", (long)c.sel,
                [c.appIconEditTarget UTF8String], c.appIconPreview.image != nil, c.appIconPreview.cornerRatio);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_ICONPANEL_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES;
        [c reload];
        c.sel = 0;
        [c selectRow:0];
        [c showAppIconPanel:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_PINCANCEL")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c togglePin:nil];
        [c closeCancel:nil];
        fprintf(stderr, "PINCANCEL alive=1 pinned=%d\n", c.pinned);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_PININFO")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSButton *pb = c.pinBtn;
        fprintf(stderr, "PININFO frame=%.0f,%.0f,%.0fx%.0f image=%d title='%s' hidden=%d super=%d pinned=%d\n",
                pb.frame.origin.x, pb.frame.origin.y, pb.frame.size.width, pb.frame.size.height,
                pb.image != nil, [pb.title UTF8String], pb.hidden, pb.superview != nil, c.pinned);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_PIN")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c togglePin:nil];
        NSButton *mini = [c.window standardWindowButton:NSWindowMiniaturizeButton];
        fprintf(stderr, "PIN1 level=%ld mini=%d shouldClose=%d\n", (long)c.window.level, mini.enabled, [c windowShouldClose:c.window]);
        [c togglePin:nil];
        fprintf(stderr, "PIN0 level=%ld mini=%d shouldClose=%d\n", (long)c.window.level, mini.enabled, [c windowShouldClose:c.window]);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_ICONHUG_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES;
        [c reload];
        if (c.items.count) {
          c.sel = 0;
          [c selectRow:0];
          c.appIconEditTarget = c.items[0][@"target"];
          gAppIconSettings[c.appIconEditTarget] = [@{@"size": @64, @"corner": @0.5} mutableCopy];
          [c updateSelectedIconAppearance];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_ICONLIVE_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (c.items.count) {
          c.sel = 0;
          [c selectRow:0];
          c.appIconEditTarget = c.items[0][@"target"];
          gAppIconSettings[c.appIconEditTarget] = [@{@"size": @64, @"corner": @0.5} mutableCopy];
          [c updateSelectedIconAppearance];
          RowView *r = c.rows.firstObject;
          fprintf(stderr, "LIVE corner=%.2f frame=%.0fx%.0f\n", r.iconView.cornerRatio, r.iconView.frame.size.width, r.iconView.frame.size.height);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_APPICON_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *target = c.items.count ? c.items[0][@"target"] : nil;
        if (target) {
          gAppIconSettings[target] = [@{@"size": @64, @"corner": @(atof(getenv("DOCKLAUNCHER_TEST_APPICON_SHOW")))} mutableCopy];
          [c reload];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_APPICON")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *target = c.items.count ? c.items[0][@"target"] : nil;
        if (target) {
          gAppIconSettings[target] = [@{@"size": @64, @"corner": @0.5} mutableCopy];
          [c reload];
          RowView *r = c.rows.firstObject;
          fprintf(stderr, "APPICON frame=%.0fx%.0f corner=%.1f\n",
                  r.iconView.frame.size.width, r.iconView.frame.size.height, r.iconView.layer.cornerRadius);
        }
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_ICONMODE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES;
        [c reload];
        RowView *r0 = c.rows.firstObject;
        fprintf(stderr, "ICONMODE cols=%ld rows=%ld cell=%.0fx%.0f icon=%.0f tooltip=%s\n",
                (long)[c displayColumns], (long)c.rows.count, r0.frame.size.width, r0.frame.size.height,
                r0.iconView.frame.size.width, [r0.toolTip UTF8String]);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SHAPE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gCornerRatio = 0.5;
        [c applyTheme];
        [c layoutContent];
        CGFloat r = c.window.contentView.layer.cornerRadius;
        fprintf(stderr, "SHAPE radius=%.1f opaque=%d scroll=%.0fx%.0f@%.0f,%.0f title=%.0f,%.0f\n",
                r, c.window.isOpaque,
                c.scroll.frame.size.width, c.scroll.frame.size.height,
                c.scroll.frame.origin.x, c.scroll.frame.origin.y,
                c.windowTitleLabel.frame.origin.x, c.windowTitleLabel.frame.origin.y);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_CREATE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *nm = [NSString stringWithUTF8String:getenv("DOCKLAUNCHER_TEST_CREATE")];
        BOOL ok = [c createGroupNamed:nm];
        fprintf(stderr, "CREATE ok=%d path=%s\n", ok, [[[c currentBundlePathByID] stringByDeletingLastPathComponent] UTF8String]);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_BATCH")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c batchStripGroupSuffix:nil];
        fprintf(stderr, "BATCH_DONE\n");
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_RENAME2")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        const char *firstEnv = getenv("DOCKLAUNCHER_TEST_RENAME");
        NSString *firstName = firstEnv ? [NSString stringWithUTF8String:firstEnv] : @"临时名";
        [c performFullRename:firstName];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          [c performFullRename:[NSString stringWithUTF8String:getenv("DOCKLAUNCHER_TEST_RENAME2")]];
          fprintf(stderr, "RENAMED2 group=%s list=%s path=%s\n", [gGroup UTF8String], [gListFile UTF8String], [[c currentBundlePathByID] UTF8String]);
          exit(0);
        });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_RENAME") && !getenv("DOCKLAUNCHER_TEST_RENAME2")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c performFullRename:[NSString stringWithUTF8String:getenv("DOCKLAUNCHER_TEST_RENAME")]];
        fprintf(stderr, "RENAMED group=%s list=%s\n", [gGroup UTF8String], [gListFile UTF8String]);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_RECORD")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showShortcutSettings:nil];
        [c startRecordingForAction:@"add"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          fprintf(stderr, "RECORDED=%s\n", [[c.customShortcuts description] UTF8String]);
          exit(0);
        });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SHORTCUT_DUMP")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        fprintf(stderr, "SHORTCUTS=%s\n", [[c.customShortcuts description] UTF8String]);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SHORTCUT")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        c.customShortcuts[@"search"] = @"cmd+f";
        NSEvent *ev = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagCommand timestamp:0
                                  windowNumber:c.window.windowNumber context:nil
                                   characters:@"f" charactersIgnoringModifiers:@"f"
                                     isARepeat:NO keyCode:3];
        BOOL handled = [c handleCustomShortcut:ev];
        [c saveCustomShortcuts];
        [NSApp sendAction:@selector(showShortcutSettings:) to:c from:nil];
        fprintf(stderr, "HANDLED=%d SEARCH_ACTIVE=%d VISIBLE=%d FRAME=%.0f,%.0f,%.0fx%.0f\n",
                handled, c.searchActive, c.shortcutPanel.isVisible,
                c.shortcutPanel.frame.origin.x, c.shortcutPanel.frame.origin.y,
                c.shortcutPanel.frame.size.width, c.shortcutPanel.frame.size.height);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SEARCH_TIMEOUT")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c toggleSearch];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          fprintf(stderr, "SEARCH_ACTIVE=%d FIELD_HIDDEN=%d\n", c.searchActive, c.searchField.hidden);
          exit(0);
        });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SEARCH")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c toggleSearch];
        c.searchField.stringValue = [NSString stringWithUTF8String:getenv("DOCKLAUNCHER_TEST_SEARCH")];
        [c applySearchQuery];
        fprintf(stderr, "MATCHED=%ld\n", (long)c.rows.count);
        for (RowView *r in c.rows) fprintf(stderr, "  %s\n", [r.label.stringValue UTF8String]);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_PANEL")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showZoomPanel];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          fprintf(stderr, "PANEL_VISIBLE=%d\n", c.zoomPanel.isVisible ? 1 : 0);
          exit(0);
        });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_ZOOM")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        c.forceColumns = atoi(getenv("DOCKLAUNCHER_TEST_ZOOM"));
        [c.window zoom:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          fprintf(stderr, "ZOOMED W=%.0f H=%.0f COLS=%ld\n", c.window.frame.size.width, c.window.frame.size.height, (long)[c effectiveColumns]);
          exit(0);
        });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_GRID")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        c.userColumns = atoi(getenv("DOCKLAUNCHER_TEST_GRID"));
        [c.window setFrame:NSMakeRect(c.window.frame.origin.x, c.window.frame.origin.y, 900, 800) display:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          fprintf(stderr, "COLS=%ld ROWS=%ld SCROLLW=%.0f\n", (long)[c effectiveColumns], (long)c.rows.count, c.scroll.contentSize.width);
          for (RowView *r in c.rows) fprintf(stderr, " row idx=%ld x=%.0f w=%.0f y=%.0f\n", (long)r.idx, r.frame.origin.x, r.frame.size.width, r.frame.origin.y);
          exit(0);
        });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_RESIZE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSRect f = c.window.frame;
        [c.window setFrame:NSMakeRect(f.origin.x, f.origin.y, 900, 800) display:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          RowView *r = c.rows.firstObject;
          fprintf(stderr, "WIN=%.0f ROW=%.0f SCROLL=%.0f\n", c.window.frame.size.width, r.frame.size.width, c.scroll.contentSize.width);
          exit(0);
        });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c openSelected:nil];
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_REMOVE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c removeSelected:nil];
        exit(0);
      });
    }
    [NSApp run];
  }
  return 1;
}
