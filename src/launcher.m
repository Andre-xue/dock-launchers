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

@class Controller;
@class BackdropView;
@class PillButton;
@class LightButton;
@class TitlePillView;

@interface RowView : NSView
@property (assign) NSInteger idx;
@property (strong) NSImageView *iconView;
@property (strong) NSTextField *label;
@property (assign) BOOL selected;
@property (weak) Controller *ctrl;
@property (strong) NSColor *selColor;
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
@property (strong) TitlePillView *windowTitleLabel;
@property (strong) NSTextField *hintLabel;
@property (strong) NSTextField *searchField;
@property (strong) CircleButton *searchBtn;
@property (copy) NSString *searchQuery;
@property BOOL searchActive;
@property NSInteger userColumns;
@property (copy) NSString *customIconPath;
@property NSInteger forceColumns;
@property (strong) LightButton *lightRed;
@property (strong) LightButton *lightYellow;
@property (strong) LightButton *lightGreen;
@property (strong) NSPanel *zoomPanel;
@property (strong) NSTimer *zoomHideTimer;
@property (strong) NSTimer *hoverOpenTimer;
@property (strong) NSPanel *glassPanel;
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
- (void)moveSel:(NSInteger)delta;
- (void)moveSelRow:(NSInteger)dir;
- (NSInteger)effectiveColumns;
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
  if (self.selected) {
    [(self.selColor ?: ThemeSel(gTheme)) setFill];
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:10 yRadius:10];
    [p fill];
  }
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
@end

@implementation TitlePillView
- (BOOL)isFlipped { return NO; }
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
  it = [m addItemWithTitle:@"打开启动器" action:@selector(dockOpen:) keyEquivalent:@""];
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

  self.searchBtn = [[CircleButton alloc] initWithFrame:NSMakeRect(W-16-30, H-35, 30, 30)];
  self.searchBtn.circleColor = [NSColor colorWithCalibratedRed:0.04 green:0.52 blue:1.0 alpha:1.0];
  self.searchBtn.glyph = @"search";
  self.searchBtn.bordered = NO;
  self.searchBtn.title = @"";
  self.searchBtn.focusRingType = NSFocusRingTypeNone;
  self.searchBtn.target = self;
  self.searchBtn.action = @selector(searchTapped:);
  self.searchBtn.toolTip = @"搜索本组应用（F4 或 ⌘Space）";
  [cv addSubview:self.searchBtn];

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

  self.hintLabel = [NSTextField labelWithString:@"←→↑↓ 选择 · Enter 打开 · ⌫ 移除 · Esc 取消"];
  self.hintLabel.font = [NSFont systemFontOfSize:11];
  self.hintLabel.textColor = ThemeHint(gTheme);
  self.hintLabel.alignment = NSTextAlignmentCenter;
  self.hintLabel.frame = NSMakeRect(96, 26, W-192, 18);
  [cv addSubview:self.hintLabel];

  self.rows = [NSMutableArray array];
  [self reload];
  [self applyTheme];
  [self layoutContent];
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

  NSInteger cols = [self effectiveColumns];
  CGFloat W = self.scroll ? MAX(200, self.scroll.contentSize.width) : (480 - 32);
  CGFloat rowH = 56.0;
  CGFloat cellW = floor(W / cols);
  NSInteger rowCount = (self.items.count + cols - 1) / (cols > 0 ? cols : 1);
  self.listContainer.frame = NSMakeRect(0, 0, W, MAX(rowCount * rowH, 10));

  BOOL narrow = (cellW < 250);
  NSFont *f = [NSFont systemFontOfSize:(narrow ? 16 : 18)];
  NSInteger i = 0;
  for (NSDictionary *it in self.items) {
    NSInteger col = i % cols, gridRow = i / cols;
    NSRect cell = NSMakeRect(col * cellW + 3, gridRow * rowH, cellW - 6, rowH);
    RowView *row = [[RowView alloc] initWithFrame:cell];
    row.idx = i;
    row.ctrl = self;
    row.selected = (i == self.sel);
    row.selColor = ThemeSel(gTheme);

    NSString *target = it[@"target"];
    NSString *path = ResolveAppPath(target);
    NSImage *icon = nil;
    if (path) icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
    CGFloat iconSize = narrow ? 34 : 40;
    CGFloat iconX = narrow ? 12 : 20;
    CGFloat textX = narrow ? 54 : 78;
    NSTextField *lab = [NSTextField labelWithString:it[@"label"]];
    lab.font = f;
    lab.textColor = ThemeText(gTheme);
    lab.lineBreakMode = NSLineBreakByTruncatingTail;
    lab.frame = NSMakeRect(textX, (rowH-24)/2.0, MAX(40, cell.size.width - textX - 8), 24);
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(iconX, (rowH-iconSize)/2, iconSize, iconSize)];
    iv.image = nil;
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
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
    NSString *path = ResolveAppPath(it[@"target"]);
    if (!path) continue;
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
    self.rows[i].iconView.image = icon;
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
  for (RowView *r in self.rows) r.selected = (r.idx == idx);
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
  NSInteger cols = MAX(1, [self effectiveColumns]);
  NSInteger idx = self.sel + dir * cols;
  if (idx < 0 || idx >= (NSInteger)self.rows.count) { [self moveSel:dir]; return; }
  [self selectRow:idx];
}

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
  if (w < 560 && self.userColumns != 1) { self.userColumns = 1; }
  [self layoutContent];
  [self reload];
}

- (void)layoutContent {
  NSView *cv = self.window.contentView;
  if (!cv) return;
  CGFloat W = cv.bounds.size.width, H = cv.bounds.size.height;
  CGFloat btnSize = 30.0;
  NSFont *tf = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
  NSDictionary *tattrs = @{NSFontAttributeName: tf};
  CGFloat tw = [self.windowTitleLabel.title sizeWithAttributes:tattrs].width + 44;
  CGFloat th = 32;
  self.windowTitleLabel.titleFont = tf;
  self.windowTitleLabel.frame = NSMakeRect((W-tw)/2.0, H-48, tw, th);
  self.removeBtn.frame = NSMakeRect(16, H-88, btnSize, btnSize);
  self.addBtn.frame = NSMakeRect(W-16-btnSize, H-88, btnSize, btnSize);
  self.skinBtn.frame = NSMakeRect((W-btnSize)/2.0, H-88, btnSize, btnSize);
  CGFloat ly = H - 26;
  if (self.lightRed) self.lightRed.frame = NSMakeRect(20, ly, 12, 12);
  if (self.lightYellow) self.lightYellow.frame = NSMakeRect(40, ly, 12, 12);
  if (self.lightGreen) self.lightGreen.frame = NSMakeRect(60, ly, 12, 12);
  if (self.searchBtn) self.searchBtn.frame = NSMakeRect(W-16-30, H-35, 30, 30);
  if (self.backdrop) self.backdrop.frame = NSMakeRect(0,0,W,H);
  if (self.vibrancy) self.vibrancy.frame = NSMakeRect(0,0,W,H);
  self.scroll.frame = NSMakeRect(16, 76, W-32, MAX(40, H-100-76));
  [self.scroll layoutSubtreeIfNeeded];
  self.cancelBtn.frame = NSMakeRect(16, 10, 56, 56);
  self.openBtn.frame = NSMakeRect(W-16-56, 10, 56, 56);
  self.hintLabel.frame = NSMakeRect(96, 26, W-192, 18);
  [self.listContainer setFrameSize:NSMakeSize(W-32, self.listContainer.frame.size.height)];
}

- (void)sendBackgroundToBack {
  NSView *cv = self.window.contentView;
  if (!cv) return;
  if (self.vibrancy) [cv addSubview:self.vibrancy positioned:NSWindowBelow relativeTo:nil];
  if (self.backdrop) [cv addSubview:self.backdrop positioned:NSWindowBelow relativeTo:nil];
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
  for (NSURL *u in panel.URLs) {
    NSString *name = [[u lastPathComponent] stringByDeletingPathExtension];
    [add appendFormat:@"\n%@|%@", name, [u path]];
  }
  if (add.length) {
    NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
    if (!content) content = @"";
    NSString *new = [content stringByAppendingString:add];
    [new writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  [self reload];
  if (self.rows.count) [self selectRow:0];
}

- (void)setupTooltips {
  self.addBtn.toolTip = @"添加应用到本组";
  self.removeBtn.toolTip = @"移除选中应用（只从列表移除）";
  self.skinBtn.toolTip = @"皮肤 / 布局 / 更换图标";
  self.cancelBtn.toolTip = @"取消（Esc）";
  self.openBtn.toolTip = @"打开选中应用（Enter）";
  self.searchField.toolTip = @"输入关键字搜索本组应用，Esc 退出搜索";
}

- (void)searchTapped:(id)sender { [self toggleSearch]; }

- (void)toggleSearch {
  if (self.searchActive) { [self closeSearch]; return; }
  self.searchActive = YES;
  self.searchField.hidden = NO;
  self.windowTitleLabel.hidden = YES;
  [self.window makeFirstResponder:self.searchField];
  [self applySearchQuery];
}

- (void)closeSearch {
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
  if (obj.object == self.searchField) [self applySearchQuery];
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
- (void)yellowLightTapped:(id)sender { [self.window miniaturize:nil]; }

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
  it = [m addItemWithTitle:@"选择自定义图片…" action:@selector(customPick:) keyEquivalent:@""]; it.target = self; it.state = (gTheme == 3);
  [m addItem:[NSMenuItem separatorItem]];
  NSMenuItem *hdr = [m addItemWithTitle:@"布局" action:nil keyEquivalent:@""];
  hdr.enabled = NO;
  NSInteger curCols = [self effectiveColumns];
  it = [m addItemWithTitle:@"单列（默认）" action:@selector(layoutSingle:) keyEquivalent:@""]; it.target = self; it.state = (curCols == 1);
  it = [m addItemWithTitle:@"三列" action:@selector(layoutThree:) keyEquivalent:@""]; it.target = self; it.state = (curCols == 3);
  it = [m addItemWithTitle:@"四列" action:@selector(layoutFour:) keyEquivalent:@""]; it.target = self; it.state = (curCols == 4);
  [m addItem:[NSMenuItem separatorItem]];
  it = [m addItemWithTitle:@"更换图标（人物图片）…" action:@selector(pickIconImage:) keyEquivalent:@""]; it.target = self;
  it = [m addItemWithTitle:@"恢复默认图标" action:@selector(resetCustomIcon:) keyEquivalent:@""]; it.target = self;
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
  [NSApp setApplicationIconImage:nil];
  [[NSWorkspace sharedWorkspace] setIcon:nil forFile:[[NSBundle mainBundle] bundlePath] options:0];
  self.customIconPath = nil;
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d removeObjectForKey:@"customIconPath"];
  [d removeObjectForKey:@"customIconApplied"];
  [d synchronize];
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
