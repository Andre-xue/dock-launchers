#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import <mach/mach.h>
#import <sys/xattr.h>

static NSString *gGroup = @"";
static NSString *gListKey = @"";
static void CollectDockDragURLs(id obj, NSMutableArray *out) {
  if (!obj) return;
  if ([obj isKindOfClass:[NSString class]]) {
    NSString *s = obj;
    if ([s hasPrefix:@"file://"]) {
      NSURL *u = [NSURL URLWithString:s];
      if (u.isFileURL) [out addObject:u];
    }
    return;
  }
  if ([obj isKindOfClass:[NSArray class]]) {
    for (id x in obj) CollectDockDragURLs(x, out);
    return;
  }
  if ([obj isKindOfClass:[NSDictionary class]]) {
    NSDictionary *d = obj;
    NSString *bid = d[@"bundle-identifier"] ?: d[@"bundleID"] ?: d[@"CFBundleIdentifier"];
    if ([bid isKindOfClass:[NSString class]] && bid.length) {
      NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bid];
      if (u) [out addObject:u];
    }
    for (id x in d.allValues) CollectDockDragURLs(x, out);
  }
}

static BOOL DragIsFromDock(NSPasteboard *pb) {
  return [[pb types] containsObject:@"com.apple.dock.tile"];
}

static NSArray<NSURL *> *ExtractDraggedURLs(NSPasteboard *pb) {
  NSMutableArray *out = [NSMutableArray array];
  NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]] options:nil];
  if (urls.count) [out addObjectsFromArray:urls];
  NSArray *paths = [pb propertyListForType:NSFilenamesPboardType];
  if ([paths isKindOfClass:[NSArray class]]) for (NSString *p in paths) if ([p isKindOfClass:[NSString class]]) [out addObject:[NSURL fileURLWithPath:p]];
  NSRegularExpression *appRx = [NSRegularExpression regularExpressionWithPattern:@"(/[^\\\"\\n\\r\\t ]+?\\.app)" options:0 error:NULL];
  NSRegularExpression *bidRx = [NSRegularExpression regularExpressionWithPattern:@"(com\\.[A-Za-z0-9_.-]+)" options:0 error:NULL];
  for (NSString *type in pb.types) {
    id plist = [pb propertyListForType:type];
    if (plist) CollectDockDragURLs(plist, out);
    NSMutableArray *raws = [NSMutableArray array];
    NSString *str = [pb stringForType:type];
    if (str.length) [raws addObject:str];
    NSData *data = [pb dataForType:type];
    if (data.length) {
      NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (!raw) raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
      if (raw.length) [raws addObject:raw];
    }
    for (NSString *raw in raws) {
      for (NSTextCheckingResult *m in [appRx matchesInString:raw options:0 range:NSMakeRange(0, raw.length)]) {
        NSString *path = [raw substringWithRange:m.range];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [out addObject:[NSURL fileURLWithPath:path]];
      }
      for (NSTextCheckingResult *m in [bidRx matchesInString:raw options:0 range:NSMakeRange(0, raw.length)]) {
        NSString *bid = [raw substringWithRange:m.range];
        NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bid];
        if (u.path) [out addObject:u];
      }
    }
  }
  NSMutableArray *unique = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (NSURL *u in out) {
    if (!u.path.length || [seen containsObject:u.path]) continue;
    [seen addObject:u.path]; [unique addObject:u];
  }
  return unique;
}

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
static NSMutableDictionary *gOriginalNames = nil;      // target -> 首次添加时的名称

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

@interface RowView : NSView <NSDraggingSource>
@property (assign) NSInteger idx;
@property (copy) NSString *targetPath;
@property NSPoint dragStart;
@property (strong) AppIconView *iconView;
@property (strong) NSTextField *label;
@property (assign) BOOL selected;
@property (weak) Controller *ctrl;
@property (strong) NSColor *selColor;
@property BOOL iconMode;
@property NSRect iconRect;
@property CGFloat iconCorner;
@end

@interface GroupDropWindow : NSWindow
@property (weak) id dropCtrl;
@end
@implementation GroupDropWindow
- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)bufferingType defer:(BOOL)flag {
  if ((self = [super initWithContentRect:contentRect styleMask:style backing:bufferingType defer:flag])) {
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSFilenamesPboardType, NSPasteboardTypeString, @"com.apple.dock.tile"]];
  }
  return self;
}
- (NSArray<NSURL *> *)droppedURLs:(id<NSDraggingInfo>)sender {
  return ExtractDraggedURLs(sender.draggingPasteboard);
}
- (void)rightMouseDown:(NSEvent *)event {
  NSMenu *m = [[NSMenu alloc] init];
  NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"从 Dock 导入应用…" action:@selector(contextDockImport:) keyEquivalent:@""];
  it.target = self;
  it.representedObject = self.dropCtrl;
  [m addItem:it];
  [NSMenu popUpContextMenu:m withEvent:event forView:self];
}
- (void)contextDockImport:(NSMenuItem *)item {
  id ctrl = item.representedObject;
  if (ctrl) [ctrl performSelector:@selector(importAppsFromDock:) withObject:nil];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSArray *urls = [self droppedURLs:sender];
  if (urls.count && self.dropCtrl) {
    [self.dropCtrl performSelector:@selector(addDroppedApps:) withObject:urls];
    return YES;
  }
  return NO;
}
@end

@interface ContentView : NSView
@property (weak) Controller *ctrl;
@end

@interface FlippedView : NSView
@property (weak) id dropCtrl;
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
  } else if ([self.glyph isEqualToString:@"import"]) {
    // 托盘 + 向下箭头
    CGFloat half = d * 0.20;
    NSBezierPath *tray = [NSBezierPath bezierPath];
    tray.lineWidth = 2.0; tray.lineCapStyle = NSLineCapStyleRound;
    [tray moveToPoint:NSMakePoint(c - half, c - d*0.16)];
    [tray lineToPoint:NSMakePoint(c - half, c - d*0.24)];
    [tray lineToPoint:NSMakePoint(c + half, c - d*0.24)];
    [tray lineToPoint:NSMakePoint(c + half, c - d*0.16)];
    [[NSColor whiteColor] setStroke]; [tray stroke];
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 2.2; arrow.lineCapStyle = NSLineCapStyleRound;
    [arrow moveToPoint:NSMakePoint(c, c + d*0.20)];
    [arrow lineToPoint:NSMakePoint(c, c - d*0.02)];
    [arrow moveToPoint:NSMakePoint(c - d*0.12, c + d*0.06)];
    [arrow lineToPoint:NSMakePoint(c, c - d*0.02)];
    [arrow moveToPoint:NSMakePoint(c + d*0.12, c + d*0.06)];
    [arrow lineToPoint:NSMakePoint(c, c - d*0.02)];
    [arrow stroke];
    return;
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

@interface Controller : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate>
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
@property (strong) CircleButton *dockImportBtn;
@property (strong) NSWindow *dockImportWindow;
@property (strong) NSArray<NSURL *> *dockImportApps;
@property (strong) NSMutableArray *dockImportChecks;
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
@property (strong) NSTimer *syncTimer;
@property (strong) NSPanel *settingsPanel;
@property (strong) NSView *settingsContent;
@property (strong) NSScrollView *settingsScroll;
@property (strong) NSArray *settingsTree;
@property (strong) NSMutableArray *settingsVisible;
@property (strong) NSMutableSet *settingsExpanded;
@property NSInteger settingsTabIndex;
@property (strong) NSView *settingsTopBar;
@property (strong) NSMutableArray *settingsTabButtons;
@property (copy) NSString *settingsFocusPath;
@property (strong) NSPanel *uninstallPanel;
@property (strong) NSMutableArray *uninstallChecks;
@property (strong) NSArray *uninstallData;
@property (strong) NSArray *uninstallFiltered;
@property (strong) NSMutableSet *uninstallSelected;
@property (strong) NSTableView *uninstallTable;
@property (strong) NSTextField *uninstallHeader;
@property (strong) NSTextField *uninstallFooter;
@property (strong) NSButton *uninstallGoBtn;
@property (strong) NSSearchField *uninstallSearchField;
@property (strong) NSSegmentedControl *uninstallSegmented;
@property (strong) NSPanel *idlePanel;
@property (strong) NSButton *idleCheck;
@property (strong) NSDatePicker *idleDatePicker;
@property (strong) NSDatePicker *idleTimePicker;
@property (strong) NSTextField *countdownLabel;
@property (strong) NSTimer *countdownTimer;
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
- (void)addDroppedApps:(NSArray<NSURL *> *)urls;
- (void)rowDragEnded:(NSString *)path screenPoint:(NSPoint)pt;
- (void)addRowToDockAtIndex:(NSNumber *)idx;
- (void)restoreDockEntriesForPaths:(NSArray<NSURL *> *)urls;
- (void)promptAddAppFromDock;
- (void)importAppsFromDock:(id)sender;
- (void)removeRowAtIndex:(NSNumber *)idx;
- (void)removeSelected:(id)sender;
- (void)loadIconsFrom:(NSInteger)start;
- (void)selectRow:(NSInteger)idx;
- (void)applyTheme;
- (void)showSkinMenu:(id)sender;
- (void)rebuildSettingsRows;
- (void)rebuildSettingsTabs;
- (void)settingsTabClicked:(id)sender;
- (BOOL)handleSettingsKeyDown:(NSEvent *)event;
- (void)appUninstallTabRequested;
- (NSImage *)currentGroupDockIcon;
- (void)showUninstallAppsPanel;
- (void)confirmUninstallApps:(id)sender;
- (void)uninstallSelectAll:(id)sender;
- (void)uninstallSelectNone:(id)sender;
- (void)closeUninstallPanel:(id)sender;
- (void)updateSettingsFocusUI;
- (void)settingsRowClicked:(id)sender;
- (void)closeSettingsPanel:(id)sender;
- (void)setShapeRect:(id)sender;
- (void)setShapeCircle:(id)sender;
- (void)resetAllAppIcons:(id)sender;
- (void)resetAllDefaults:(id)sender;
- (void)resetListMode:(id)sender;
- (void)resetSingleLayout:(id)sender;
- (void)backupGroupsNow:(id)sender;
- (BOOL)writeLocalBackup;
- (void)uninstallAll:(id)sender;
- (void)skinWhite:(id)sender;
- (void)skinBlack:(id)sender;
- (void)skinGlass:(id)sender;
- (void)showGlassPanel:(id)sender;
- (void)glassSliderChanged:(id)sender;
- (void)closeGlassPanel:(id)sender;
- (void)showShapePanel:(id)sender;
- (void)shapeSliderChanged:(id)sender;
- (void)resetShapeRectangle:(id)sender;
- (void)showIdlePanel:(id)sender;
- (void)toggleIdleExit:(id)sender;
- (void)saveIdlePanel:(id)sender;
- (void)closeIdlePanel:(id)sender;
- (void)resetIdleTimer;
- (void)idleExitFired:(NSTimer *)t;
- (void)updateCountdown;
- (void)hideCountdown;
- (void)refreshListAndCaches:(id)sender;
- (void)createGroupTapped:(id)sender;
- (void)renameSelectedItem:(id)sender;
- (BOOL)updateLabel:(NSString *)newLabel forTarget:(NSString *)target;
- (BOOL)createGroupNamed:(NSString *)name;
- (void)deleteCurrentGroup:(id)sender;
- (BOOL)authorizeAdminDeletion;
- (BOOL)trashGroupFilesWithAdmin;
- (void)destroyGroupData;
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
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSFilenamesPboardType, NSPasteboardTypeString, @"com.apple.dock.tile"]];
  }
  return self;
}
- (NSArray<NSURL *> *)dragDropURLs:(id<NSDraggingInfo>)sender {
  return ExtractDraggedURLs(sender.draggingPasteboard);
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSArray *urls = [self dragDropURLs:sender];
  if (self.ctrl && DragIsFromDock(sender.draggingPasteboard) && !urls.count) {
    [self.ctrl performSelector:@selector(promptAddAppFromDock)];
    return YES;
  }
  if (urls.count && self.ctrl) {
    [self.ctrl performSelector:@selector(addDroppedApps:) withObject:urls];
    if (DragIsFromDock(sender.draggingPasteboard)) [self.ctrl performSelector:@selector(restoreDockEntriesForPaths:) withObject:urls];
    return YES;
  }
  return NO;
}
- (NSView *)hitTest:(NSPoint)point {
  return NSPointInRect(point, self.bounds) ? self : [super hitTest:point];
}
- (void)drawRect:(NSRect)dirtyRect {
  if (!self.selected || self.iconMode) return;
  [(self.selColor ?: ThemeSel(gTheme)) setFill];
  NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:10 yRadius:10];
  [p fill];
}
- (void)rightMouseDown:(NSEvent *)event {
  [self.ctrl selectRow:self.idx];
  NSMenu *m = [[NSMenu alloc] init];
  NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:@"添加到 Dock" action:@selector(contextAddToDock:) keyEquivalent:@""];
  add.target = self; add.tag = self.idx; [m addItem:add];
  NSMenuItem *rm = [[NSMenuItem alloc] initWithTitle:@"从分组移除" action:@selector(contextRemoveFromGroup:) keyEquivalent:@""];
  rm.target = self; rm.tag = self.idx; [m addItem:rm];
  [m addItem:[NSMenuItem separatorItem]];
  NSMenuItem *di = [[NSMenuItem alloc] initWithTitle:@"从 Dock 导入应用…" action:@selector(contextDockImport:) keyEquivalent:@""];
  di.target = self; [m addItem:di];
  [NSMenu popUpContextMenu:m withEvent:event forView:self];
}
- (void)contextAddToDock:(NSMenuItem *)item {
  [self.ctrl performSelector:@selector(addRowToDockAtIndex:) withObject:@(item.tag)];
}
- (void)contextDockImport:(NSMenuItem *)item {
  [self.ctrl performSelector:@selector(importAppsFromDock:) withObject:nil];
}
- (void)contextRemoveFromGroup:(NSMenuItem *)item {
  [self.ctrl performSelector:@selector(removeRowAtIndex:) withObject:@(item.tag)];
}
- (void)mouseDown:(NSEvent *)event {
  self.dragStart = event.locationInWindow;
  [self.ctrl selectRow:self.idx];
  if (event.clickCount >= 2) [self.ctrl openSelected:nil];
}
- (void)mouseDragged:(NSEvent *)event {
  if (!self.targetPath.length) return;
  NSPoint p = event.locationInWindow;
  if (hypot(p.x - self.dragStart.x, p.y - self.dragStart.y) < 5) return;
  NSURL *url = [NSURL fileURLWithPath:self.targetPath];
  NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
  NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:self.targetPath];
  [item setDraggingFrame:NSMakeRect(0, 0, 48, 48) contents:icon];
  [self beginDraggingSessionWithItems:@[item] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)session endedAtScreenPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
  if (operation == NSDragOperationNone) return;
  [self.ctrl rowDragEnded:self.targetPath screenPoint:screenPoint];
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
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSFilenamesPboardType, NSPasteboardTypeString, @"com.apple.dock.tile"]];
  return self;
}
- (NSArray<NSURL *> *)droppedURLs:(id<NSDraggingInfo>)sender {
  return ExtractDraggedURLs(sender.draggingPasteboard);
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSArray *urls = [self droppedURLs:sender];
  id ctrl = self.dropCtrl;
  if (ctrl && DragIsFromDock(sender.draggingPasteboard) && !urls.count) {
    [ctrl performSelector:@selector(promptAddAppFromDock)];
    return YES;
  }
  if (urls.count && ctrl) {
    [ctrl performSelector:@selector(addDroppedApps:) withObject:urls];
    if (DragIsFromDock(sender.draggingPasteboard)) [ctrl performSelector:@selector(restoreDockEntriesForPaths:) withObject:urls];
    return YES;
  }
  return NO;
}
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
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return NSDragOperationCopy;
}
- (NSArray<NSURL *> *)droppedURLs:(id<NSDraggingInfo>)sender {
  NSPasteboard *pb = sender.draggingPasteboard;
  NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]] options:nil];
  if (urls.count) return urls;
  NSArray *paths = [pb propertyListForType:NSFilenamesPboardType];
  if ([paths isKindOfClass:[NSArray class]] && paths.count) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in paths) if ([p isKindOfClass:[NSString class]]) [out addObject:[NSURL fileURLWithPath:p]];
    return out;
  }
  NSString *s = [pb stringForType:NSPasteboardTypeFileURL];
  if (s.length) { NSURL *u = [NSURL URLWithString:s]; if (u) return @[u]; }
  return @[];
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSArray<NSURL *> *urls = [self droppedURLs:sender];
  if (urls.count && self.ctrl) {
    [self.ctrl addDroppedApps:urls];
    if (DragIsFromDock(sender.draggingPasteboard)) [self.ctrl restoreDockEntriesForPaths:urls];
    return YES;
  }
  return NO;
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
    if (!gOriginalNames[target]) { gOriginalNames[target] = label; [self saveTheme]; }
    [arr addObject:@{@"label": label, @"target": target}];
  }
  return arr;
}

- (void)buildWindow {
  NSRect frame = NSMakeRect(0, 0, 480, 600);
  GroupDropWindow *dropWindow = [[GroupDropWindow alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  dropWindow.dropCtrl = self;
  self.window = dropWindow;
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
  [cv registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSFilenamesPboardType, NSPasteboardTypeString, @"com.apple.dock.tile"]];
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

  CircleButton *add = [[CircleButton alloc] initWithFrame:NSMakeRect(385, H-12-btnSize, btnSize, btnSize)];
  add.circleColor = [NSColor colorWithCalibratedRed:0.16 green:0.78 blue:0.25 alpha:1.0];
  add.glyph = @"+";
  add.bordered = NO;
  add.title = @"";
  add.focusRingType = NSFocusRingTypeNone;
  add.target = self;
  add.action = @selector(addApps:);
  add.toolTip = @"添加应用到当前分组";
  [cv addSubview:add];
  self.addBtn = add;

  CircleButton *remove = [[CircleButton alloc] initWithFrame:NSMakeRect(65, H-12-btnSize, btnSize, btnSize)];
  remove.circleColor = [NSColor colorWithCalibratedRed:1.0 green:0.37 blue:0.34 alpha:1.0];
  remove.glyph = @"-";
  remove.bordered = NO;
  remove.title = @"";
  remove.focusRingType = NSFocusRingTypeNone;
  remove.target = self;
  remove.action = @selector(removeSelected:);
  remove.toolTip = @"从当前分组移除所选应用";
  [cv addSubview:remove];
  self.removeBtn = remove;

  // 中间：皮肤按钮（黄色圆形 + 🎨）
  self.skinBtn = [NSButton buttonWithTitle:@"🎨" target:self action:@selector(showSkinMenu:)];
  self.skinBtn.frame = NSMakeRect(225, H-12-btnSize, btnSize, btnSize);
  self.skinBtn.font = [NSFont systemFontOfSize:16];
  self.skinBtn.bordered = NO;
  self.skinBtn.focusRingType = NSFocusRingTypeNone;
  self.skinBtn.toolTip = @"更换分组图标 / 皮肤";
  self.skinBtn.wantsLayer = YES;
  self.skinBtn.layer.backgroundColor = [NSColor colorWithCalibratedRed:1.0 green:0.80 blue:0.10 alpha:1.0].CGColor;
  self.skinBtn.layer.cornerRadius = 15;
  [cv addSubview:self.skinBtn];

  self.searchBtn = [[CircleButton alloc] initWithFrame:NSMakeRect(305, H-12-btnSize, 30, 30)];
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

  self.dockImportBtn = [[CircleButton alloc] initWithFrame:NSMakeRect(145, H - 12 - btnSize, btnSize, btnSize)];
  self.dockImportBtn.circleColor = [NSColor colorWithCalibratedRed:0.55 green:0.35 blue:0.95 alpha:1.0];
  self.dockImportBtn.glyph = @"import";
  self.dockImportBtn.bordered = NO;
  self.dockImportBtn.title = @"";
  self.dockImportBtn.focusRingType = NSFocusRingTypeNone;
  self.dockImportBtn.target = self;
  self.dockImportBtn.action = @selector(importAppsFromDock:);
  self.dockImportBtn.toolTip = @"从系统 Dock 导入应用";
  [cv addSubview:self.dockImportBtn];

  self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 76, W-32, H-54-76)];
  self.scroll.hasVerticalScroller = YES;
  self.scroll.drawsBackground = YES;
  self.scroll.backgroundColor = [NSColor whiteColor];
  self.scroll.autohidesScrollers = YES;
  self.scroll.wantsLayer = YES;
  self.scroll.layer.cornerRadius = 12;
  [cv addSubview:self.scroll];

  self.listContainer = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,W-32,10)];
  ((FlippedView *)self.listContainer).dropCtrl = self;
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
    if ([ss handleSettingsKeyDown:e]) return nil;
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

  self.countdownLabel = [NSTextField labelWithString:@""];
  self.countdownLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium];
  self.countdownLabel.textColor = [NSColor labelColor];
  self.countdownLabel.alignment = NSTextAlignmentCenter;
  self.countdownLabel.hidden = YES;
  self.countdownLabel.wantsLayer = YES;
  self.countdownLabel.layer.cornerRadius = 6;
  self.countdownLabel.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.93 alpha:0.95].CGColor;
  [cv addSubview:self.countdownLabel];

  self.rows = [NSMutableArray array];
  [self reload];
  [self applyTheme];
  [self layoutContent];
  [self updatePinAppearance];
  [self resetIdleTimer];
  [self.window makeFirstResponder:cv];
  [self.syncTimer invalidate];
  self.syncTimer = [NSTimer scheduledTimerWithTimeInterval:15.0 target:self selector:@selector(syncTick:) userInfo:nil repeats:YES];
}

- (NSInteger)pruneStaleListEntries {
  if (!gListFile.length) return 0;
  NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
  if (!content) return 0;
  NSMutableArray *keep = [NSMutableArray array];
  NSInteger removed = 0;
  for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!line.length) continue;
    if ([line hasPrefix:@"#"]) { [keep addObject:raw]; continue; }
    NSString *target = line;
    NSRange r = [line rangeOfString:@"|"];
    if (r.location != NSNotFound) target = [[line substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (ResolveAppPath(target).length == 0) { removed++; continue; }
    [keep addObject:raw];
  }
  if (removed) [[keep componentsJoinedByString:@"\n"] writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  return removed;
}

- (void)syncTick:(NSTimer *)t {
  if ([self pruneStaleListEntries] > 0) [self reload];
}

- (void)promptAddAppFromDock {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
  p.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
  p.message = @"无法从 Dock 读取应用信息，请选择要添加到当前分组的 App";
  if ([p runModal] != NSModalResponseOK) return;
  NSURL *u = p.URL;
  if (![u.pathExtension.lowercaseString isEqualToString:@"app"]) return;
  [self addDroppedApps:@[u]];
  [self restoreDockEntriesForPaths:@[u]];
}

- (void)restoreDockEntriesForPaths:(NSArray<NSURL *> *)urls {
  for (NSURL *u in urls) {
    if (![u.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
    NSString *path = u.path.stringByStandardizingPath;
    if (![self dockContainsApp:path]) [self addAppToDock:path];
  }
}

- (NSArray<NSURL *> *)dockAppURLs {
  NSMutableArray *out = [NSMutableArray array];
  CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
  NSArray *apps = raw ? CFBridgingRelease(raw) : @[];
  NSMutableSet *seen = [NSMutableSet set];
  for (id item in apps) {
    if (![item isKindOfClass:[NSDictionary class]]) continue;
    NSString *u = item[@"tile-data"][@"file-data"][@"_CFURLString"];
    if (!u.length) continue;
    NSURL *url = [NSURL URLWithString:u];
    if (!url.isFileURL || ![url.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
    if ([seen containsObject:url.path]) continue;
    [seen addObject:url.path]; [out addObject:url];
  }
  return out;
}

- (void)importAppsFromDock:(id)sender {
  self.dockImportApps = [self dockAppURLs];
  if (!self.dockImportApps.count) { NSAlert *a=[[NSAlert alloc] init]; a.messageText=@"Dock 中没有应用"; [a addButtonWithTitle:@"好"]; [a runModal]; return; }
  if (!self.dockImportWindow) {
    self.dockImportWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,540,460) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    self.dockImportWindow.title = @"从 Dock 导入应用";
    self.dockImportWindow.releasedWhenClosed = NO;
    self.dockImportWindow.level = NSFloatingWindowLevel;
    [self.dockImportWindow center];
  }
  NSView *cv = self.dockImportWindow.contentView;
  for (NSView *x in [cv.subviews copy]) [x removeFromSuperview];
  NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 420, 400, 24)];
  title.stringValue = @"从 Dock 导入应用";
  title.bezeled = NO; title.editable = NO; title.drawsBackground = NO;
  title.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
  [cv addSubview:title];
  NSTextField *hint = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 398, 480, 18)];
  hint.stringValue = @"勾选要加入当前分组的应用；已加入本组或其他分组的会被跳过";
  hint.bezeled = NO; hint.editable = NO; hint.drawsBackground = NO;
  hint.font = [NSFont systemFontOfSize:10];
  hint.textColor = [NSColor secondaryLabelColor];
  [cv addSubview:hint];
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 70, 508, 320)];
  sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
  sv.drawsBackground = YES; sv.backgroundColor = [NSColor whiteColor];
  NSView *doc = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,490,MAX(320,self.dockImportApps.count*32))];
  self.dockImportChecks = [NSMutableArray array];
  NSString *body = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL] ?: @"";
  for (NSInteger i = 0; i < (NSInteger)self.dockImportApps.count; i++) {
    NSURL *u = self.dockImportApps[i];
    NSString *name = [[NSFileManager defaultManager] displayNameAtPath:u.path];
    NSButton *cb = [NSButton checkboxWithTitle:name target:nil action:nil];
    cb.frame = NSMakeRect(8, i*32+4, 460, 24);
    BOOL exists = NO;
    for (NSString *line in [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSRange r = [line rangeOfString:@"|"];
      NSString *target = r.location == NSNotFound ? line : [line substringFromIndex:r.location+1];
      if ([[target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:u.path]) { exists = YES; break; }
    }
    if (exists) { cb.state = NSControlStateValueOn; cb.enabled = NO; cb.title = [name stringByAppendingString:@"（已在分组）"]; }
    [doc addSubview:cb]; [self.dockImportChecks addObject:cb];
  }
  sv.documentView = doc; [cv addSubview:sv];
  NSButton *all = [NSButton buttonWithTitle:@"全选" target:self action:@selector(dockImportSelectAll:)];
  all.frame = NSMakeRect(16, 24, 70, 30); [cv addSubview:all];
  NSButton *none = [NSButton buttonWithTitle:@"全不选" target:self action:@selector(dockImportSelectNone:)];
  none.frame = NSMakeRect(92, 24, 80, 30); [cv addSubview:none];
  NSButton *add = [NSButton buttonWithTitle:@"添加所选" target:self action:@selector(confirmDockImport:)];
  add.frame = NSMakeRect(398, 24, 100, 32); add.keyEquivalent = @"\r"; [cv addSubview:add];
  [NSApp activateIgnoringOtherApps:YES];
  [self.dockImportWindow makeKeyAndOrderFront:nil];
  [self.dockImportWindow orderFrontRegardless];
}

- (void)dockImportSelectAll:(id)sender { for (NSButton *b in self.dockImportChecks) if (b.enabled) b.state = NSControlStateValueOn; }
- (void)dockImportSelectNone:(id)sender { for (NSButton *b in self.dockImportChecks) if (b.enabled) b.state = NSControlStateValueOff; }

- (void)confirmDockImport:(id)sender {
  NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL] ?: @"";
  NSMutableArray *lines = [[content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy];
  NSInteger added = 0;
  for (NSInteger i = 0; i < (NSInteger)self.dockImportApps.count; i++) {
    NSButton *cb = self.dockImportChecks[i];
    if (!cb.enabled || cb.state != NSControlStateValueOn) continue;
    NSURL *u = self.dockImportApps[i];
    NSString *name = [[NSFileManager defaultManager] displayNameAtPath:u.path];
    [lines addObject:[NSString stringWithFormat:@"%@|%@", name, u.path]];
    added++;
  }
  while (lines.count && [[lines lastObject] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) [lines removeLastObject];
  if (added) {
    [[lines componentsJoinedByString:@"\n"] writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"DockLaunchersGroupsChanged" object:nil];
    [self reload];
  }
  [self.dockImportWindow orderOut:nil];
}

- (void)addDroppedApps:(NSArray<NSURL *> *)urls {
  if (!urls.count || !gListFile.length) return;
  NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL] ?: @"";
  NSMutableArray *lines = [[content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *listsDir = [gListFile stringByDeletingLastPathComponent];
  NSInteger added = 0;
  for (NSURL *u in urls) {
    if (![u.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
    NSString *path = u.path.stringByStandardizingPath;
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    NSString *display = bundle.localizedInfoDictionary[@"CFBundleDisplayName"] ?: bundle.infoDictionary[@"CFBundleDisplayName"] ?: bundle.localizedInfoDictionary[@"CFBundleName"] ?: bundle.infoDictionary[@"CFBundleName"] ?: path.lastPathComponent.stringByDeletingPathExtension;
    BOOL exists = NO;
    for (NSString *line in lines) {
      NSRange r = [line rangeOfString:@"|"];
      NSString *target = [(r.location == NSNotFound ? line : [line substringFromIndex:r.location+1]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([target isEqualToString:path] || [ResolveAppPath(target) isEqualToString:path]) { exists = YES; break; }
    }
    if (exists) {
      NSAlert *a = [[NSAlert alloc] init];
      a.messageText = @"该应用已在此分组中";
      a.informativeText = display;
      [a addButtonWithTitle:@"好"];
      [a runModal];
      continue;
    }
    NSString *otherGroup = nil;
    for (NSString *f in [[fm contentsOfDirectoryAtPath:listsDir error:NULL] ?: @[] sortedArrayUsingSelector:@selector(compare:)]) {
      if (![f.pathExtension isEqualToString:@"txt"] || [[listsDir stringByAppendingPathComponent:f] isEqualToString:gListFile]) continue;
      NSString *body = [NSString stringWithContentsOfFile:[listsDir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:NULL] ?: @"";
      for (NSString *line in [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSRange r = [line rangeOfString:@"|"];
        NSString *target = [(r.location == NSNotFound ? line : [line substringFromIndex:r.location+1]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([target isEqualToString:path] || [ResolveAppPath(target) isEqualToString:path]) { otherGroup = f.stringByDeletingPathExtension; break; }
      }
      if (otherGroup) break;
    }
    if (otherGroup) {
      NSAlert *a = [[NSAlert alloc] init];
      a.messageText = @"该应用已加入其他分组";
      a.informativeText = [NSString stringWithFormat:@"%@ 已在「%@」中，不能重复添加。", display, otherGroup];
      [a addButtonWithTitle:@"好"];
      [a runModal];
      continue;
    }
    [lines addObject:[NSString stringWithFormat:@"%@|%@", display, path]];
    added++;
  }
  while (lines.count && [[lines lastObject] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) [lines removeLastObject];
  if (added > 0) {
    [[lines componentsJoinedByString:@"\n"] writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"DockLaunchersGroupsChanged" object:nil];
    [self reload];
  }
}

- (BOOL)pointIsOverDock:(NSPoint)pt {
  NSScreen *screen = nil;
  for (NSScreen *s in [NSScreen screens]) if (NSMouseInRect(pt, s.frame, NO)) { screen = s; break; }
  if (!screen) screen = [NSScreen mainScreen];
  NSRect vis = screen.visibleFrame, full = screen.frame;
  BOOL inDockArea = (pt.y < NSMinY(vis) - 1) || (pt.x < NSMinX(vis) - 1) || (pt.x > NSMaxX(vis) + 1);
  // Dock 自动隐藏时 visibleFrame 等于全屏，补充屏幕边缘判断
  BOOL nearEdge = (pt.y < NSMinY(full) + 150) || (pt.x < NSMinX(full) + 100) || (pt.x > NSMaxX(full) - 100);
  return inDockArea || nearEdge;
}

- (BOOL)dockContainsApp:(NSString *)path {
  CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
  NSArray *apps = raw ? CFBridgingRelease(raw) : @[];
  for (id item in apps) {
    if (![item isKindOfClass:[NSDictionary class]]) continue;
    NSString *u = item[@"tile-data"][@"file-data"][@"_CFURLString"];
    if (!u.length) continue;
    NSURL *url = [NSURL URLWithString:u];
    if (url.isFileURL && [url.path.stringByStandardizingPath isEqualToString:path]) return YES;
  }
  return NO;
}

- (void)addAppToDock:(NSString *)path {
  NSString *label = path.lastPathComponent.stringByDeletingPathExtension;
  NSString *bid = [[NSBundle bundleWithPath:path] bundleIdentifier] ?: @"";
  NSDictionary *entry = @{@"tile-type": @"file-tile",
                          @"tile-data": @{@"file-data": @{@"_CFURLString": [NSURL fileURLWithPath:path].absoluteString, @"_CFURLStringType": @15},
                                          @"file-label": label,
                                          @"bundle-identifier": bid}};
  CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
  NSMutableArray *apps = raw ? [CFBridgingRelease(raw) mutableCopy] : [NSMutableArray array];
  [apps addObject:entry];
  CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)apps, CFSTR("com.apple.dock"));
  CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  NSTask *kill = [[NSTask alloc] init];
  kill.launchPath = @"/usr/bin/killall";
  kill.arguments = @[@"Dock"];
  @try { [kill launch]; } @catch (NSException *e) {}
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
  });
}

- (void)removeAppFromList:(NSString *)path {
  NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL] ?: @"";
  NSMutableArray *keep = [NSMutableArray array];
  for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    NSRange r = [line rangeOfString:@"|"];
    NSString *target = r.location == NSNotFound ? line : [line substringFromIndex:r.location+1];
    if ([[target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:path]) continue;
    [keep addObject:line];
  }
  [[keep componentsJoinedByString:@"\n"] writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"DockLaunchersGroupsChanged" object:nil];
}

- (void)addRowToDockAtIndex:(NSNumber *)idxNum {
  NSInteger idx = idxNum.integerValue;
  if (idx < 0 || idx >= (NSInteger)self.items.count) return;
  NSString *path = ResolveAppPath(self.items[idx][@"target"]);
  if (!path.length) { NSAlert *a=[[NSAlert alloc] init]; a.messageText=@"找不到应用"; [a addButtonWithTitle:@"好"]; [a runModal]; return; }
  if ([self dockContainsApp:path]) { NSAlert *a=[[NSAlert alloc] init]; a.messageText=@"Dock 中已有该应用"; a.informativeText=@"同一个应用不能重复添加。"; [a addButtonWithTitle:@"好"]; [a runModal]; return; }
  [self addAppToDock:path];
  [self removeAppFromList:path];
  [self reload];
}

- (void)removeRowAtIndex:(NSNumber *)idxNum {
  NSInteger idx = idxNum.integerValue;
  if (idx < 0 || idx >= (NSInteger)self.items.count) return;
  NSString *path = ResolveAppPath(self.items[idx][@"target"]);
  if (path.length) [self removeAppFromList:path];
  [self reload];
}

- (void)rowDragEnded:(NSString *)path screenPoint:(NSPoint)pt {
  if (!path.length) return;
  if (![self dockContainsApp:path]) [self addAppToDock:path];
  [self removeAppFromList:path];
  [self reload];
}

- (void)reload {
  [self pruneStaleListEntries];
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
    row.targetPath = path ?: @"";
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
  if (self.countdownLabel) self.countdownLabel.frame = NSMakeRect(ox + rw - 14 - 28 - 8 - 150, oy + rh - 34 + 4, 150, 20);

  // 第二行四个控件各占 1/4
  CGFloat btnSize = 30.0;
  CGFloat cw = rw / 4.0;
  self.removeBtn.frame = NSMakeRect(ox + cw*0.5 - btnSize/2.0, oy + rh - 88, btnSize, btnSize);
  if (self.dockImportBtn) self.dockImportBtn.frame = NSMakeRect(ox + cw*1.5 - btnSize/2.0, oy + rh - 88, btnSize, btnSize);
  self.skinBtn.frame   = NSMakeRect(ox + cw*2.5 - btnSize/2.0, oy + rh - 88, btnSize, btnSize);
  if (self.searchBtn) self.searchBtn.frame = NSMakeRect(ox + cw*3.5 - 15.0, oy + rh - 88, 30, 30);
  self.addBtn.frame    = NSMakeRect(ox + cw*4.5 - btnSize/2.0, oy + rh - 88, btnSize, btnSize);

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
    if (!gOriginalNames[[u path]]) gOriginalNames[[u path]] = display;
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
    // 记录"首次添加完成时"的最终名字（包含添加后改名弹窗里的自定义名）
    for (NSDictionary *item in added) {
      NSString *t = item[@"target"];
      for (NSDictionary *cur in self.items) {
        if ([cur[@"target"] isEqualToString:t]) { gOriginalNames[t] = cur[@"label"]; break; }
      }
    }
    [self saveTheme];
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
  gOriginalNames = [[[d dictionaryForKey:@"originalAppNames"] mutableCopy] mutableCopy] ?: [NSMutableDictionary dictionary];
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
  [d setObject:gOriginalNames forKey:@"originalAppNames"];
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
  if (!self.settingsExpanded) self.settingsExpanded = [NSMutableSet set];
  self.settingsTree = @[
    @{@"title":@"窗口背景", @"children":@[
      @{@"title":@"纯白风格（默认）", @"sel":@"skinWhite:"},
      @{@"title":@"纯黑风格", @"sel":@"skinBlack:"},
      @{@"title":@"质感玻璃", @"children":@[@{@"title":@"玻璃透明度…", @"sel":@"showGlassPanel:"}]},
      @{@"title":@"自定义背景", @"children":@[@{@"title":@"选择背景图片…", @"sel":@"customPick:"}]},
      @{@"title":@"一键恢复（纯白）", @"sel":@"skinReset:"}]},
    @{@"title":@"窗口形变", @"children":@[
      @{@"title":@"矩形（默认）", @"sel":@"setShapeRect:"},
      @{@"title":@"圆形（最圆）", @"sel":@"setShapeCircle:"},
      @{@"title":@"手动形变", @"children":@[@{@"title":@"窗口形状调节…", @"sel":@"showShapePanel:"}]},
      @{@"title":@"一键恢复（矩形）", @"sel":@"resetShapeRectangle:"}]},
    @{@"title":@"应用排列", @"children":@[
      @{@"title":@"列表显示（默认）", @"sel":@"setDisplayListMode:"},
      @{@"title":@"图标显示", @"sel":@"setDisplayIconMode:"},
      @{@"title":@"一键恢复（列表）", @"sel":@"resetListMode:"}]},
    @{@"title":@"应用布局", @"children":@[
      @{@"title":@"单列布局（默认）", @"sel":@"layoutSingle:"},
      @{@"title":@"三列布局", @"sel":@"layoutThree:"},
      @{@"title":@"四列布局", @"sel":@"layoutFour:"},
      @{@"title":@"一键恢复（单列）", @"sel":@"resetSingleLayout:"}]},
    @{@"title":@"图标风格", @"children":@[
      @{@"title":@"图标自定义", @"children":@[@{@"title":@"图标大小 / 形状 / 重命名…", @"sel":@"showAppIconPanel:"}]},
      @{@"title":@"一键恢复默认", @"sel":@"resetAllAppIcons:"}]},
    @{@"title":@"Dock 栏", @"children":@[
      @{@"title":@"Dock 风格", @"children":@[
        @{@"title":@"更换 Dock 图标…", @"sel":@"pickIconImage:"},
        @{@"title":@"恢复分组默认图标", @"sel":@"resetCustomIcon:"}]},
      @{@"title":@"一键恢复 Dock 栏", @"sel":@"repairDockMenuTapped:"}]},
    @{@"title":@"设置", @"children":@[
      @{@"title":@"快捷键映射", @"sel":@"showShortcutSettings:"},
      @{@"title":@"效率", @"children":@[
        @{@"title":@"自动退出程序时间（空闲 3 分钟）", @"sel":@"toggleIdleExit:"},
        @{@"title":@"刷新列表并释放内存缓存", @"sel":@"refreshListAndCaches:"}]},
      @{@"title":@"一键恢复所有页面状态（回到初始）", @"sel":@"resetAllDefaults:"}]}
  ];

  if (!self.settingsPanel) {
    self.settingsTabIndex = -1;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,520,640)
                                            styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
                                              backing:NSBackingStoreBuffered defer:NO];
    p.title = @"设置";
    p.level = NSFloatingWindowLevel;
    self.settingsPanel = p;
    self.settingsTopBar = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 640-50, 520, 46)];
    [p.contentView addSubview:self.settingsTopBar];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,520,640-54)];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;
    sv.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    self.settingsScroll = sv;
    [p.contentView addSubview:sv];
  }
  if (self.settingsFocusPath == nil) self.settingsFocusPath = @"";
  [self rebuildSettingsTabs];
  [self rebuildSettingsRows];
  [self.settingsPanel center];
  [NSApp activateIgnoringOtherApps:YES];
  [self.settingsPanel makeKeyAndOrderFront:nil];
}

- (void)rebuildSettingsTabs {
  for (NSView *v in [self.settingsTopBar.subviews copy]) [v removeFromSuperview];
  if (!self.settingsTabButtons) self.settingsTabButtons = [NSMutableArray array];
  [self.settingsTabButtons removeAllObjects];
  CGFloat W = self.settingsTopBar.bounds.size.width;
  CGFloat gap = 4;
  CGFloat bw = (W - gap * (self.settingsTree.count + 1)) / MAX((NSInteger)self.settingsTree.count, 1);
  NSInteger i = 0;
  for (NSDictionary *n in self.settingsTree) {
    NSButton *b = [NSButton buttonWithTitle:(n[@"title"] ?: @"") target:self action:@selector(settingsTabClicked:)];
    b.tag = i;
    b.frame = NSMakeRect(gap + i * (bw + gap), 6, bw, 34);
    b.bordered = NO;
    b.focusRingType = NSFocusRingTypeNone;
    b.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightBold];
    b.contentTintColor = [NSColor labelColor];
    b.wantsLayer = YES;
    b.layer.cornerRadius = 8;
    BOOL sel = (self.settingsTabIndex == i);
    b.layer.backgroundColor = (sel ? [NSColor colorWithCalibratedRed:0.04 green:0.52 blue:1.0 alpha:0.15].CGColor
                                   : [NSColor colorWithCalibratedWhite:0.95 alpha:1.0].CGColor);
    [self.settingsTopBar addSubview:b];
    [self.settingsTabButtons addObject:b];
    i++;
  }
}

- (void)settingsTabClicked:(id)sender {
  NSInteger idx = [sender tag];
  if (idx < 0 || idx >= (NSInteger)self.settingsTree.count) return;
  NSString *t = self.settingsTree[idx][@"title"] ?: @"";
  if ([t isEqualToString:@"应用卸载"]) {
    self.settingsTabIndex = -1;
    self.settingsFocusPath = @"";
    [self rebuildSettingsTabs];
    [self rebuildSettingsRows];
    [self appUninstallTabRequested];
    return;
  }
  self.settingsTabIndex = (self.settingsTabIndex == idx) ? -1 : idx;
  self.settingsFocusPath = @"";
  [self rebuildSettingsTabs];
  [self rebuildSettingsRows];
}

- (void)rebuildSettingsRows {
  if (!self.settingsVisible) self.settingsVisible = [NSMutableArray array];
  [self.settingsVisible removeAllObjects];
  if (!self.settingsExpanded) self.settingsExpanded = [NSMutableSet set];
  __block NSMutableArray *flat = [NSMutableArray array];
  __block void (^walk)(NSArray *, NSInteger, NSString *);
  walk = ^(NSArray *nodes, NSInteger level, NSString *prefix) {
    for (NSDictionary *n in nodes) {
      NSString *title = n[@"title"] ?: @"";
      NSString *path = prefix.length ? [prefix stringByAppendingFormat:@"/%@", title] : title;
      BOOL hasKids = [(NSArray *)n[@"children"] count] > 0;
      BOOL expanded = hasKids && [self.settingsExpanded containsObject:path];
      [flat addObject:@{@"title":title, @"level":@(level), @"path":path, @"sel":(n[@"sel"] ?: @""), @"kids":@(hasKids), @"open":@(expanded)}];
      if (expanded) walk(n[@"children"], level+1, path);
    }
  };
  if (self.settingsTabIndex >= 0 && self.settingsTabIndex < (NSInteger)self.settingsTree.count) {
    NSDictionary *tab = self.settingsTree[self.settingsTabIndex];
    walk(tab[@"children"], 1, tab[@"title"] ?: @"");
  }
  [self.settingsVisible addObjectsFromArray:flat];
  CGFloat totalH = 20;
  for (NSDictionary *n in flat) totalH += ([n[@"level"] integerValue] == 0 ? 40 : 34);
  NSInteger idx = 0;
  CGFloat y = 10;
  NSView *content = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,420,totalH)];
  if (flat.count == 0) {
    NSTextField *hint = [NSTextField labelWithString:@"请选择上方一级菜单"];
    hint.font = [NSFont systemFontOfSize:12];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.frame = NSMakeRect(20, 20, 300, 20);
    NSView *empty = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,420,60)];
    [empty addSubview:hint];
    [self.settingsScroll setDocumentView:empty];
    self.settingsContent = empty;
    return;
  }
  for (NSDictionary *n in flat) {
    NSInteger level = [n[@"level"] integerValue];
    BOOL kids = [n[@"kids"] boolValue], open = [n[@"open"] boolValue];
    CGFloat h = (level == 0 ? 40 : 34);
    NSString *mark = kids ? (open ? @"▾ " : @"▸ ") : @"   ";
    NSString *title = [NSString stringWithFormat:@"%@%@", mark, n[@"title"]];
    NSFont *font = (level == 0) ? [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                                : [NSFont systemFontOfSize:(level == 1 ? 13 : 12)];
    NSButton *b = [NSButton buttonWithTitle:title target:self action:@selector(settingsRowClicked:)];
    b.frame = NSMakeRect(10 + level * 22, y, 400 - level * 22, h - 4);
    y += h;
    b.tag = idx;
    b.bordered = NO;
    b.focusRingType = NSFocusRingTypeNone;
    b.alignment = NSTextAlignmentLeft;
    b.font = font;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 7;
    BOOL focused = (self.settingsFocusPath.length > 0 && [self.settingsFocusPath isEqualToString:n[@"path"]]);
    if (level == 1) {
      b.font = [NSFont systemFontOfSize:13];
      if (focused) b.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.85 green:0.92 blue:1.0 alpha:1.0].CGColor;
    } else if (level >= 2) {
      b.font = [NSFont systemFontOfSize:12.5];
      if (focused) {
        b.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.97 alpha:1.0].CGColor;
        b.layer.shadowColor = [NSColor blackColor].CGColor;
        b.layer.shadowOpacity = 0.28;
        b.layer.shadowRadius = 4;
        b.layer.shadowOffset = CGSizeMake(0, -1.5);
        b.layer.masksToBounds = NO;
      }
    }
    [content addSubview:b];
    idx++;
  }
  content.frame = NSMakeRect(0, 0, 420, MAX(y + 10, totalH));
  [self.settingsScroll setDocumentView:content];
  [content scrollPoint:NSMakePoint(0, 0)];
  self.settingsContent = content;
}

- (NSImage *)currentGroupDockIcon {
  NSImage *img = [[NSWorkspace sharedWorkspace] iconForFile:[[NSBundle mainBundle] bundlePath]];
  if (!img) img = [NSApp applicationIconImage];
  return img ?: [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
}

- (void)appUninstallTabRequested {
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self currentGroupDockIcon];
  a.messageText = @"此项操作为卸载应用本体，请谨慎选择是否卸载";
  a.informativeText = @"卸载会把这些应用从本机移除（移到废纸篓），并从当前分组列表删除，操作不可恢复。";
  [a addButtonWithTitle:@"是"];
  [a addButtonWithTitle:@"否"];
  if ([a runModal] == NSAlertFirstButtonReturn) {
    [self showUninstallAppsPanel];
  } else {
    self.settingsTabIndex = -1;
    self.settingsFocusPath = @"";
    [self rebuildSettingsTabs];
    [self rebuildSettingsRows];
  }
}

- (NSString *)formatBytes:(unsigned long long)bytes {
  if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
  double v = bytes;
  NSArray *units = @[@"KB", @"MB", @"GB", @"TB"];
  NSInteger i = -1;
  do { v /= 1024.0; i++; } while (v >= 1024.0 && i < (NSInteger)units.count - 1);
  return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
}

- (unsigned long long)folderSizeAtPath:(NSString *)path {
  unsigned long long total = 0;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator *en = [fm enumeratorAtPath:path];
  for (NSString *rel in en) {
    NSDictionary *attr = [fm attributesOfItemAtPath:[path stringByAppendingPathComponent:rel] error:NULL];
    if (!attr) continue;
    total += [attr fileSize];
  }
  return total;
}


- (NSArray<NSString *> *)relatedDataPathsForApp:(NSDictionary *)d {
  NSString *bid = d[@"bid"] ?: @"";
  NSString *appPath = d[@"path"] ?: @"";
  NSString *appName = [[appPath lastPathComponent] stringByDeletingPathExtension];
  NSString *home = NSHomeDirectory();
  NSMutableArray *cands = [NSMutableArray array];
  void (^addIfExists)(NSString *) = ^(NSString *p) {
    if (p.length && [[NSFileManager defaultManager] fileExistsAtPath:p] && ![cands containsObject:p]) [cands addObject:p];
  };
  if (bid.length) {
    addIfExists([home stringByAppendingPathComponent:[@"Library/Application Support" stringByAppendingPathComponent:bid]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/Caches" stringByAppendingPathComponent:bid]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/Preferences" stringByAppendingPathComponent:[bid stringByAppendingPathExtension:@"plist"]]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/Saved Application State" stringByAppendingPathComponent:[bid stringByAppendingPathExtension:@"savedState"]]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/Containers" stringByAppendingPathComponent:bid]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/HTTPStorages" stringByAppendingPathComponent:bid]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/WebKit" stringByAppendingPathComponent:bid]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/Application Scripts" stringByAppendingPathComponent:bid]]);
    NSString *byHost = [home stringByAppendingPathComponent:@"Library/Preferences/ByHost"];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:byHost error:NULL]) {
      if ([f hasPrefix:bid] && [f hasSuffix:@".plist"]) addIfExists([byHost stringByAppendingPathComponent:f]);
    }
  }
  if (appName.length) {
    addIfExists([home stringByAppendingPathComponent:[@"Library/Application Support" stringByAppendingPathComponent:appName]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/Caches" stringByAppendingPathComponent:appName]]);
    addIfExists([home stringByAppendingPathComponent:[@"Library/Logs" stringByAppendingPathComponent:appName]]);
  }
  return cands;
}

- (void)loadUninstallData {
  NSMutableArray *arr = [NSMutableArray array];
  NSArray *running = [[NSWorkspace sharedWorkspace] runningApplications];
  for (NSDictionary *it in self.items) {
    NSString *p = ResolveAppPath(it[@"target"]);
    if (!p.length) continue;
    NSString *real = [p stringByResolvingSymlinksInPath];
    if ([real hasPrefix:@"/System/"] || [p hasPrefix:@"/System/"]) continue;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *bid = info[@"CFBundleIdentifier"] ?: @"";
    NSString *ver = info[@"CFBundleShortVersionString"] ?: info[@"CFBundleVersion"] ?: @"";
    BOOL isRunning = NO;
    for (NSRunningApplication *ra in running) {
      if (ra.bundleURL && [[ra.bundleURL path] isEqualToString:p]) { isRunning = YES; break; }
    }
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL] ?: @{};
    NSDate *installed = attr[NSFileCreationDate] ?: attr[NSFileModificationDate];
    NSURL *u = [NSURL fileURLWithPath:p];
    id accObj = nil;
    [u getResourceValue:&accObj forKey:NSURLContentAccessDateKey error:NULL];
    NSDate *lastUsed = [accObj isKindOfClass:[NSDate class]] ? accObj : nil;
    [arr addObject:@{@"label": it[@"label"] ?: p.lastPathComponent.stringByDeletingPathExtension,
                     @"path": p, @"bid": bid, @"version": ver,
                     @"size": @([self folderSizeAtPath:p]),
                     @"installed": installed ?: [NSDate date],
                     @"lastUsed": lastUsed ?: [NSNull null],
                     @"running": @(isRunning),
                     @"target": it[@"target"]}];
  }
  self.uninstallData = arr;
}

- (void)applyUninstallFilter {
  NSString *q = [self.uninstallSearchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSInteger filter = self.uninstallSegmented.selectedSegment;
  NSMutableArray *filtered = [NSMutableArray array];
  for (NSDictionary *d in self.uninstallData) {
    if (filter == 1 && ![d[@"running"] boolValue]) { /* 可卸载 = 未运行 */ }
    else if (filter == 2 && ![d[@"running"] boolValue]) continue;
    if (filter == 1 && [d[@"running"] boolValue]) continue;
    if (filter == 3) continue; // 系统应用已全部排除
    if (q.length > 0) {
      NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", d[@"label"], d[@"bid"], d[@"path"]];
      if ([hay rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
    }
    [filtered addObject:d];
  }
  self.uninstallFiltered = filtered;
  [self.uninstallTable reloadData];
  [self updateUninstallSummary];
}

- (void)updateUninstallSummary {
  unsigned long long total = 0, selectedSize = 0;
  for (NSDictionary *d in self.uninstallData) total += [d[@"size"] unsignedLongLongValue];
  for (NSDictionary *d in self.uninstallData) {
    if ([self.uninstallSelected containsObject:d[@"path"]]) selectedSize += [d[@"size"] unsignedLongLongValue];
  }
  self.uninstallHeader.stringValue = [NSString stringWithFormat:@"发现 %ld 个应用   估算总大小 %@", (long)self.uninstallData.count, [self formatBytes:total]];
  self.uninstallFooter.stringValue = [NSString stringWithFormat:@"已选择应用 %ld    预计移除数据 %@    将同时清理应用本体与用户数据", (long)self.uninstallSelected.count, [self formatBytes:selectedSize]];
  self.uninstallGoBtn.enabled = (self.uninstallSelected.count > 0);
}

- (void)uninstallSelectionChanged:(id)sender {
  NSInteger row = [sender tag];
  if (row < 0 || row >= (NSInteger)self.uninstallFiltered.count) return;
  NSDictionary *d = self.uninstallFiltered[row];
  if ([self.uninstallSelected containsObject:d[@"path"]]) {
    [self.uninstallSelected removeObject:d[@"path"]];
    [sender setState:NSControlStateValueOff];
  } else {
    [self.uninstallSelected addObject:d[@"path"]];
    [sender setState:NSControlStateValueOn];
  }
  [self updateUninstallSummary];
}

- (void)uninstallFilterChanged:(id)sender { [self applyUninstallFilter]; }
- (void)uninstallSearchChanged:(id)sender { [self applyUninstallFilter]; }

- (void)uninstallSelectAll:(id)sender {
  for (NSDictionary *d in self.uninstallFiltered) [self.uninstallSelected addObject:d[@"path"]];
  [self.uninstallTable reloadData];
  [self updateUninstallSummary];
}

- (void)uninstallSelectNone:(id)sender {
  [self.uninstallSelected removeAllObjects];
  [self.uninstallTable reloadData];
  [self updateUninstallSummary];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  return (NSInteger)self.uninstallFiltered.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)self.uninstallFiltered.count) return nil;
  NSDictionary *d = self.uninstallFiltered[row];
  NSString *ident = tableColumn.identifier;
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,tableColumn.width,56)];
  if ([ident isEqualToString:@"app"]) {
    NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(uninstallSelectionChanged:)];
    cb.frame = NSMakeRect(4, 18, 18, 18);
    cb.tag = row;
    cb.state = [self.uninstallSelected containsObject:d[@"path"]] ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:cb];
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:d[@"path"]];
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(28, 12, 32, 32)];
    iv.image = icon;
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    [v addSubview:iv];
    NSTextField *name = [NSTextField labelWithString:d[@"label"]];
    name.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    name.frame = NSMakeRect(70, 26, 330, 18);
    [v addSubview:name];
    NSString *sub = d[@"bid"];
    if ([d[@"version"] length]) sub = [NSString stringWithFormat:@"%@ · 版本 %@", sub, d[@"version"]];
    NSTextField *bidLab = [NSTextField labelWithString:sub];
    bidLab.font = [NSFont systemFontOfSize:10.5];
    bidLab.textColor = [NSColor secondaryLabelColor];
    bidLab.frame = NSMakeRect(70, 8, 360, 16);
    [v addSubview:bidLab];
  } else if ([ident isEqualToString:@"status"]) {
    NSTextField *lab = [NSTextField labelWithString:[d[@"running"] boolValue] ? @"正在运行" : @"可卸载"];
    lab.font = [NSFont systemFontOfSize:12];
    lab.textColor = [d[@"running"] boolValue] ? [NSColor systemOrangeColor] : [NSColor secondaryLabelColor];
    lab.frame = NSMakeRect(4, 18, tableColumn.width - 8, 20);
    [v addSubview:lab];
  } else if ([ident isEqualToString:@"size"]) {
    NSTextField *lab = [NSTextField labelWithString:[self formatBytes:[d[@"size"] unsignedLongLongValue]]];
    lab.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    lab.alignment = NSTextAlignmentRight;
    lab.frame = NSMakeRect(4, 18, tableColumn.width - 12, 20);
    [v addSubview:lab];
  } else if ([ident isEqualToString:@"used"]) {
    id lu = d[@"lastUsed"];
    NSDate *dt = [lu isKindOfClass:[NSDate class]] ? lu : nil;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy/MM/dd";
    NSTextField *lab = [NSTextField labelWithString:dt ? [df stringFromDate:dt] : @"暂无记录"];
    lab.font = [NSFont systemFontOfSize:11.5];
    lab.textColor = [NSColor secondaryLabelColor];
    lab.frame = NSMakeRect(4, 18, tableColumn.width - 8, 20);
    [v addSubview:lab];
  } else if ([ident isEqualToString:@"installed"]) {
    NSDate *dt = d[@"installed"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy/MM/dd";
    NSTextField *lab = [NSTextField labelWithString:dt ? [df stringFromDate:dt] : @"未知"];
    lab.font = [NSFont systemFontOfSize:11.5];
    lab.textColor = [NSColor secondaryLabelColor];
    lab.frame = NSMakeRect(4, 18, tableColumn.width - 8, 20);
    [v addSubview:lab];
  }
  return v;
}

- (void)showUninstallAppsPanel {
  [self loadUninstallData];
  if (self.uninstallData.count == 0) {
    NSAlert *e = [[NSAlert alloc] init];
    e.messageText = @"没有可卸载的应用";
    e.informativeText = @"当前分组里没有可卸载的用户应用（系统自带应用不支持卸载）。";
    [e runModal];
    return;
  }
  if (!self.uninstallSelected) self.uninstallSelected = [NSMutableSet set];
  [self.uninstallSelected removeAllObjects];

  [self.uninstallPanel orderOut:nil];
  NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,900,620)
                                          styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered defer:NO];
  p.title = @"应用卸载";
  p.level = NSFloatingWindowLevel;
  self.uninstallPanel = p;
  NSView *cv = p.contentView;

  self.uninstallHeader = [NSTextField labelWithString:@""];
  self.uninstallHeader.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
  self.uninstallHeader.frame = NSMakeRect(20, 566, 600, 24);
  [cv addSubview:self.uninstallHeader];

  self.uninstallSegmented = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(20, 528, 300, 28)];
  [self.uninstallSegmented setSegmentCount:4];
  [self.uninstallSegmented setLabel:@"全部" forSegment:0];
  [self.uninstallSegmented setLabel:@"可卸载" forSegment:1];
  [self.uninstallSegmented setLabel:@"正在运行" forSegment:2];
  [self.uninstallSegmented setLabel:@"不可卸载" forSegment:3];
  self.uninstallSegmented.selectedSegment = 0;
  self.uninstallSegmented.target = self;
  self.uninstallSegmented.action = @selector(uninstallFilterChanged:);
  [cv addSubview:self.uninstallSegmented];

  self.uninstallSearchField = [NSSearchField alloc];
  self.uninstallSearchField = [self.uninstallSearchField initWithFrame:NSMakeRect(600, 528, 280, 28)];
  self.uninstallSearchField.placeholderString = @"搜索应用、Bundle ID 或路径";
  self.uninstallSearchField.target = self;
  self.uninstallSearchField.action = @selector(uninstallSearchChanged:);
  [self.uninstallSearchField setContinuous:YES];
  [cv addSubview:self.uninstallSearchField];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 86, 868, 430)];
  sv.hasVerticalScroller = YES;
  sv.drawsBackground = NO;
  sv.borderType = NSNoBorder;
  self.uninstallTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0,0,868,430)];
  self.uninstallTable.dataSource = self;
  self.uninstallTable.delegate = self;
  self.uninstallTable.rowHeight = 56;
  self.uninstallTable.usesAlternatingRowBackgroundColors = YES;
  self.uninstallTable.headerView = [[NSTableHeaderView alloc] init];
  NSArray *cols = @[
    @[@"app", @"应用名称", @(430)],
    @[@"status", @"状态", @(76)],
    @[@"size", @"估算大小", @(96)],
    @[@"used", @"上次使用", @(110)],
    @[@"installed", @"安装日期", @(120)]
  ];
  for (NSArray *c in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1];
    col.width = [c[2] doubleValue];
    [self.uninstallTable addTableColumn:col];
  }
  sv.documentView = self.uninstallTable;
  [cv addSubview:sv];

  self.uninstallFooter = [NSTextField labelWithString:@"将同时清理应用本体与用户数据（配置/缓存/容器）"];
  self.uninstallFooter.font = [NSFont systemFontOfSize:12];
  self.uninstallFooter.textColor = [NSColor secondaryLabelColor];
  self.uninstallFooter.frame = NSMakeRect(20, 30, 380, 20);
  [cv addSubview:self.uninstallFooter];

  NSButton *all = [NSButton buttonWithTitle:@"全选" target:self action:@selector(uninstallSelectAll:)];
  all.frame = NSMakeRect(430, 24, 64, 30); all.bezelStyle = NSBezelStyleRounded; [cv addSubview:all];
  NSButton *none = [NSButton buttonWithTitle:@"全不选" target:self action:@selector(uninstallSelectNone:)];
  none.frame = NSMakeRect(498, 24, 72, 30); none.bezelStyle = NSBezelStyleRounded; [cv addSubview:none];
  NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(closeUninstallPanel:)];
  cancel.frame = NSMakeRect(700, 24, 76, 30); cancel.bezelStyle = NSBezelStyleRounded; [cv addSubview:cancel];
  self.uninstallGoBtn = [NSButton buttonWithTitle:@"卸载所选应用" target:self action:@selector(confirmUninstallApps:)];
  self.uninstallGoBtn.frame = NSMakeRect(780, 24, 110, 30); self.uninstallGoBtn.bezelStyle = NSBezelStyleRounded; [cv addSubview:self.uninstallGoBtn];

  [p center];
  [NSApp activateIgnoringOtherApps:YES];
  [p makeKeyAndOrderFront:nil];
  [self applyUninstallFilter];
}

- (void)closeUninstallPanel:(id)sender {
  [self.uninstallPanel orderOut:nil];
}

- (void)confirmUninstallApps:(id)sender {
  NSMutableArray *selected = [NSMutableArray array];
  for (NSDictionary *d in self.uninstallData) {
    if ([self.uninstallSelected containsObject:d[@"path"]]) [selected addObject:d];
  }
  if (selected.count == 0) {
    NSAlert *e = [[NSAlert alloc] init];
    e.messageText = @"未选择应用";
    e.informativeText = @"请先勾选要卸载的应用。";
    [e runModal];
    return;
  }
  if (getenv("DOCKLAUNCHER_TEST_UNINSTALL_APPS") == NULL) {
    NSAlert *c = [[NSAlert alloc] init];
    c.icon = [self currentGroupDockIcon];
    c.messageText = [NSString stringWithFormat:@"确认卸载 %ld 个应用？", (long)selected.count];
    c.informativeText = @"此操作将卸载应用本体并从分组删除，不可恢复。5 秒后可点击「是」继续；选择「否」将取消。";
    [c addButtonWithTitle:@"是（5）"];
    [c addButtonWithTitle:@"否"];
    NSButton *yesBtn = c.buttons[0];
    yesBtn.enabled = NO;
    for (int sec = 5; sec >= 1; sec--) {
      int remain = sec - 1;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((5 - sec + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (remain > 0) yesBtn.title = [NSString stringWithFormat:@"是（%d）", remain];
        else { yesBtn.title = @"是"; yesBtn.enabled = YES; }
      });
    }
    if ([c runModal] != NSAlertFirstButtonReturn) return;
  }

  NSMutableArray *removals = [NSMutableArray array];
  NSInteger dataCount = 0;
  for (NSDictionary *sel in selected) {
    NSString *appPath = sel[@"path"];
    if (![removals containsObject:appPath]) [removals addObject:appPath];
    for (NSString *dp in [self relatedDataPathsForApp:sel]) {
      if (![removals containsObject:dp]) { [removals addObject:dp]; dataCount++; }
    }
  }

  BOOL testMode = (getenv("DOCKLAUNCHER_TEST_UNINSTALL_APPS") != NULL);
  BOOL ok = NO;
  if (testMode) {
    NSString *staging = [NSString stringWithFormat:@"/tmp/DockLaunchers-apps-uninstall-%d", getpid()];
    [[NSFileManager defaultManager] createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:NULL];
    NSInteger idx = 0;
    for (NSString *path in removals) {
      NSString *dst = [staging stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld-%@", (long)idx++, [path lastPathComponent]]];
      [[NSFileManager defaultManager] moveItemAtPath:path toPath:dst error:NULL];
    }
    ok = YES;
    fprintf(stderr, "UNINSTALL_APPS staging=%s apps=%ld data=%ld\n", [staging UTF8String], (long)selected.count, (long)dataCount);
  } else {
    NSMutableString *body = [NSMutableString stringWithString:@"#!/bin/sh\n"];
    NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
    NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    [body appendFormat:@"mkdir -p \"%@\"\n", trash];
    NSInteger idx = 0;
    for (NSString *path in removals) {
      [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/%@-%ld-%@\"\n", path, path, trash, stamp, (long)idx++, [path lastPathComponent]];
    }
    NSString *sp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"docklaunchers-uninstall-apps.sh"];
    [body writeToFile:sp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:sp error:NULL];
    NSString *osa = [NSString stringWithFormat:@"do shell script \"/bin/sh %@\" with administrator privileges", sp];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/osascript";
    t.arguments = @[@"-e", osa];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    ok = (t.terminationStatus == 0);
  }

  if (ok) {
    NSMutableSet *targets = [NSMutableSet set];
    for (NSDictionary *sel in selected) [targets addObject:sel[@"target"]];
    NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (line.length == 0) continue;
      if ([line hasPrefix:@"#"]) { [keep addObject:raw]; continue; }
      NSString *target = line;
      NSRange r = [line rangeOfString:@"|"];
      if (r.location != NSNotFound) target = [[line substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (![targets containsObject:target]) [keep addObject:raw];
    }
    [[keep componentsJoinedByString:@"\n"] writeToFile:gListFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self reload];
    [self.uninstallPanel orderOut:nil];
    // 验证是否全部清除
    NSMutableArray *leftovers = [NSMutableArray array];
    for (NSString *path in removals) {
      if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [leftovers addObject:path];
    }
    if (!testMode) {
      NSAlert *d = [[NSAlert alloc] init];
      d.icon = [self currentGroupDockIcon];
      d.messageText = leftovers.count == 0 ? @"卸载并清理完成" : @"卸载完成，但有残留";
      if (leftovers.count == 0) {
        d.informativeText = [NSString stringWithFormat:@"已卸载 %ld 个应用，并清理 %ld 项应用数据（配置/缓存/容器等）；已验证全部清除。", (long)selected.count, (long)dataCount];
      } else {
        d.informativeText = [NSString stringWithFormat:@"已卸载 %ld 个应用、清理 %ld 项数据；检测到 %ld 项残留：\n%@", (long)selected.count, (long)dataCount, (long)leftovers.count, [leftovers componentsJoinedByString:@"\n"]];
      }
      [d runModal];
    } else {
      fprintf(stderr, "UNINSTALL_VERIFY leftovers=%ld\n", (long)leftovers.count);
    }
  } else {
    NSAlert *d = [[NSAlert alloc] init];
    d.messageText = @"已取消";
    d.informativeText = @"未通过管理员验证，未卸载任何应用。";
    [d runModal];
  }
}

- (void)settingsRowClicked:(id)sender {
  NSInteger idx = [sender tag];
  if (idx < 0 || idx >= (NSInteger)self.settingsVisible.count) return;
  NSDictionary *n = self.settingsVisible[idx];
  self.settingsFocusPath = n[@"path"] ?: @"";
  if ([n[@"kids"] boolValue]) {
    NSString *path = n[@"path"];
    if ([self.settingsExpanded containsObject:path]) [self.settingsExpanded removeObject:path];
    else [self.settingsExpanded addObject:path];
    [self rebuildSettingsRows];
    return;
  }
  NSString *selName = n[@"sel"];
  self.settingsFocusPath = n[@"path"] ?: @"";
  [self updateSettingsFocusUI];
  if (selName.length) {
    SEL sel = NSSelectorFromString(selName);
    if ([self respondsToSelector:sel]) [self performSelector:sel withObject:nil];
  }
}

- (void)updateSettingsFocusUI {
  [self rebuildSettingsRows];
}

- (BOOL)handleSettingsKeyDown:(NSEvent *)event {
  if (!self.settingsPanel.isVisible || !self.settingsPanel.isKeyWindow) return NO;
  NSString *chars = event.charactersIgnoringModifiers;
  if (chars.length == 0) return NO;
  unichar c = [chars characterAtIndex:0];
  BOOL left = (c == NSLeftArrowFunctionKey), right = (c == NSRightArrowFunctionKey);
  BOOL up = (c == NSUpArrowFunctionKey), down = (c == NSDownArrowFunctionKey);
  if (!left && !right && !up && !down) {
    if (c == 27) [self closeSettingsPanel:nil];
    return YES; // 设置页内只响应方向键与鼠标，其它按键吞掉
  }
  BOOL tabFocus = (self.settingsFocusPath.length == 0);
  if (tabFocus) {
    if (left || right) {
      NSInteger idx = self.settingsTabIndex;
      if (idx < 0) idx = (right ? 0 : self.settingsTree.count - 1);
      else idx += (right ? 1 : -1);
      if (idx < 0) idx = self.settingsTree.count - 1;
      if (idx >= (NSInteger)self.settingsTree.count) idx = 0;
      self.settingsTabIndex = idx;
      self.settingsFocusPath = @"";
      [self rebuildSettingsTabs];
      [self rebuildSettingsRows];
      if ([self.settingsTree[idx][@"title"] isEqualToString:@"应用卸载"]) [self appUninstallTabRequested];
      return YES;
    }
    if (down && self.settingsVisible.count > 0) {
      self.settingsFocusPath = self.settingsVisible.firstObject[@"path"];
      [self rebuildSettingsRows];
      return YES;
    }
    return YES;
  }
  NSInteger cur = -1;
  for (NSInteger i = 0; i < (NSInteger)self.settingsVisible.count; i++) {
    if ([self.settingsVisible[i][@"path"] isEqualToString:self.settingsFocusPath]) { cur = i; break; }
  }
  if (cur < 0) { self.settingsFocusPath = @""; [self rebuildSettingsRows]; return YES; }
  NSDictionary *node = self.settingsVisible[cur];
  NSInteger level = [node[@"level"] integerValue];
  NSString *path = node[@"path"];
  if (up || down) {
    NSString *parentPrefix = @"";
    NSRange dot = [path rangeOfString:@"/" options:NSBackwardsSearch];
    if (dot.location != NSNotFound) parentPrefix = [path substringToIndex:dot.location];
    NSMutableArray *siblings = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.settingsVisible.count; i++) {
      NSDictionary *m = self.settingsVisible[i];
      if ([m[@"level"] integerValue] != level) continue;
      NSString *mp = m[@"path"];
      if (level == 1) { [siblings addObject:@(i)]; continue; }
      NSRange d = [mp rangeOfString:@"/" options:NSBackwardsSearch];
      NSString *parent = (d.location != NSNotFound) ? [mp substringToIndex:d.location] : @"";
      if ([parent isEqualToString:parentPrefix]) [siblings addObject:@(i)];
    }
    NSInteger pos = [siblings indexOfObject:@(cur)];
    if (pos == NSNotFound) pos = 0;
    NSInteger nxtPos = pos + (down ? 1 : -1);
    if (nxtPos >= 0 && nxtPos < (NSInteger)siblings.count) {
      NSInteger nxt = [siblings[nxtPos] integerValue];
      self.settingsFocusPath = self.settingsVisible[nxt][@"path"];
      [self rebuildSettingsRows];
    }
    return YES;
  }
  if (right && [node[@"kids"] boolValue]) {
    if (![self.settingsExpanded containsObject:path]) [self.settingsExpanded addObject:path];
    [self rebuildSettingsRows];
    NSString *prefix = [path stringByAppendingString:@"/"];
    for (NSDictionary *m in self.settingsVisible) {
      if ([m[@"path"] hasPrefix:prefix] && [m[@"level"] integerValue] == level + 1) {
        self.settingsFocusPath = m[@"path"];
        [self rebuildSettingsRows];
        break;
      }
    }
    return YES;
  }
  if (left) {
    if ([self.settingsExpanded containsObject:path]) {
      [self.settingsExpanded removeObject:path];
      [self rebuildSettingsRows];
    } else {
      NSRange d = [path rangeOfString:@"/" options:NSBackwardsSearch];
      if (d.location != NSNotFound) {
        NSString *parent = [path substringToIndex:d.location];
        BOOL isTab = NO;
        for (NSDictionary *tab in self.settingsTree) if ([tab[@"title"] isEqualToString:parent]) isTab = YES;
        self.settingsFocusPath = isTab ? @"" : parent;
        [self rebuildSettingsRows];
      }
    }
  }
  return YES;
}

- (void)closeSettingsPanel:(id)sender {
  [self.settingsPanel orderOut:nil];
}

- (void)setShapeRect:(id)sender {
  gCornerRatio = 0;
  [self applyTheme]; [self layoutContent]; [self reload]; [self saveTheme];
}

- (void)setShapeCircle:(id)sender {
  gCornerRatio = 0.5;
  [self applyTheme]; [self layoutContent]; [self reload]; [self saveTheme];
}

- (void)resetAllAppIcons:(id)sender {
  [gAppIconSettings removeAllObjects];
  [self saveTheme];
  [self reload];
}

- (void)resetListMode:(id)sender {
  gIconMode = NO;
  [self saveTheme];
  [self reload];
  [self layoutContent];
}

- (BOOL)writeLocalBackup {
  NSString *parent = [[self currentBundlePathByID] stringByDeletingLastPathComponent];
  NSString *base = [@"~/Library/Application Support/DockLaunchers/backup/DockLaunchers" stringByExpandingTildeInPath];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSInteger appCount = 0;
  for (NSString *f in [fm contentsOfDirectoryAtPath:parent error:NULL]) if ([f hasSuffix:@".app"]) appCount++;
  if (appCount == 0) return NO;   // 没有 App 时不覆盖已有备份
  [fm removeItemAtPath:base error:NULL];
  [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
  for (NSString *f in [fm contentsOfDirectoryAtPath:parent error:NULL]) {
    if ([f hasSuffix:@".app"]) [fm copyItemAtPath:[parent stringByAppendingPathComponent:f] toPath:[base stringByAppendingPathComponent:f] error:NULL];
  }
  NSString *lists = [parent stringByAppendingPathComponent:@"lists"];
  if ([fm fileExistsAtPath:lists]) [fm copyItemAtPath:lists toPath:[base stringByAppendingPathComponent:@"lists"] error:NULL];

  // 同时备份各分组偏好（自定义图标/名字/主题等）
  NSString *prefsDir = [base stringByAppendingPathComponent:@"prefs"];
  [fm createDirectoryAtPath:prefsDir withIntermediateDirectories:YES attributes:nil error:NULL];
  NSArray *domains = @[@"com.docklaunchers.gongzuo", @"com.docklaunchers.liaotian", @"com.docklaunchers.waiwang",
                       @"com.docklaunchers.yingyin", @"com.docklaunchers.ai", @"com.docklaunchers.docker",
                       @"com.docklaunchers.gongju", @"com.docklaunchers.shared"];
  for (NSString *dom in domains) {
    NSString *out = [prefsDir stringByAppendingPathComponent:[dom stringByAppendingPathExtension:@"plist"]];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/defaults";
    t.arguments = @[@"export", dom, out];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
  }
  return YES;
}

- (void)backupGroupsNow:(id)sender {
  if (![self writeLocalBackup]) {
    NSAlert *e = [[NSAlert alloc] init];
    e.messageText = @"备份失败";
    e.informativeText = @"当前目录下没有找到分组 App，已保留原有备份未覆盖。";
    [e runModal];
    return;
  }
  NSString *base = [@"~/Library/Application Support/DockLaunchers/backup/DockLaunchers" stringByExpandingTildeInPath];
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"已备份到本机";
  a.informativeText = [NSString stringWithFormat:@"备份位置：%@\n\n桌面「恢复Dock分组.command」与「恢复Dock分组.app」可离线恢复全部内容。", base];
  [a runModal];
}

- (void)uninstallAll:(id)sender {
  NSAlert *c = [[NSAlert alloc] init];
  c.messageText = @"一键卸载全部 Dock 分组？";
  c.informativeText = @"将把 7 个分组 App、列表、本机偏好与缓存移到废纸篓，并移除全部 Dock 图标。\n本机备份与恢复工具会保留，可随时一键恢复。";
  [c addButtonWithTitle:@"卸载"];
  [c addButtonWithTitle:@"取消"];
  if ([c runModal] != NSAlertFirstButtonReturn) return;

  // 先刷新备份，保证可恢复；备份失败则取消卸载
  if (![self writeLocalBackup]) {
    NSAlert *e = [[NSAlert alloc] init];
    e.messageText = @"无法卸载";
    e.informativeText = @"未能完成本机备份，为避免数据丢失，已取消卸载。";
    [e runModal];
    return;
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *parent = [[self currentBundlePathByID] stringByDeletingLastPathComponent];
  NSArray *order = @[@"工作", @"聊天", @"外网", @"影音", @"Ai", @"Docker", @"工具"];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSString *n in order) {
    NSString *p = [parent stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"app"]];
    if ([fm fileExistsAtPath:p]) { [paths addObject:p]; [self removeDockEntryForPath:p]; }
  }
  for (NSString *f in [fm contentsOfDirectoryAtPath:parent error:NULL]) {
    if ([f hasSuffix:@".app"]) {
      NSString *p = [parent stringByAppendingPathComponent:f];
      if (![paths containsObject:p]) { [paths addObject:p]; [self removeDockEntryForPath:p]; }
    }
  }
  NSString *prefsDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
  NSMutableArray *prefFiles = [NSMutableArray array];
  for (NSString *f in [fm contentsOfDirectoryAtPath:prefsDir error:NULL]) {
    if ([f hasPrefix:@"com.docklaunchers."] && [f hasSuffix:@".plist"]) [prefFiles addObject:[prefsDir stringByAppendingPathComponent:f]];
  }
  NSString *appIcons = [@"~/Library/Application Support/DockLaunchers/appicons" stringByExpandingTildeInPath];

  if (getenv("DOCKLAUNCHER_TEST_UNINSTALL")) {
    // 测试模式：移动到 /tmp 而不是废纸篓，便于自动验证
    NSString *staging = [NSString stringWithFormat:@"/tmp/DockLaunchers-uninstall-%d", getpid()];
    [fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([fm fileExistsAtPath:parent]) [fm moveItemAtPath:parent toPath:[staging stringByAppendingPathComponent:@"DockLaunchers"] error:NULL];
    for (NSString *pf in prefFiles) [fm moveItemAtPath:pf toPath:[staging stringByAppendingPathComponent:[pf lastPathComponent]] error:NULL];
    if ([fm fileExistsAtPath:appIcons]) [fm moveItemAtPath:appIcons toPath:[staging stringByAppendingPathComponent:@"appicons"] error:NULL];
    fprintf(stderr, "UNINSTALL staging=%s\n", [staging UTF8String]);
    exit(0);
  }

  // 真实卸载：管理员脚本移动到废纸篓（保留 backup 与恢复工具）
  NSMutableString *body = [NSMutableString stringWithString:@"#!/bin/sh\n"];
  NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
  NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
  [body appendFormat:@"mkdir -p \"%@\"\n", trash];
  [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/DockLaunchers-uninstall-%@\"\n", parent, parent, trash, stamp];
  for (NSString *pf in prefFiles) [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/\"\n", pf, pf, trash];
  if ([fm fileExistsAtPath:appIcons]) [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/appicons-%@\"\n", appIcons, appIcons, trash, stamp];
  [body appendString:@"/usr/bin/killall -KILL Dock 2>/dev/null\n"];
  NSString *sp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"docklaunchers-uninstall.sh"];
  [body writeToFile:sp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  [fm setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:sp error:NULL];
  NSString *osa = [NSString stringWithFormat:@"do shell script \"/bin/sh %@\" with administrator privileges", sp];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/osascript";
  t.arguments = @[@"-e", osa];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}

  NSAlert *d = [[NSAlert alloc] init];
  d.messageText = @"已卸载到废纸篓";
  d.informativeText = @"分组 App、列表、偏好与缓存已移入废纸篓；本机备份和恢复工具已保留。\n双击「恢复Dock分组.app」即可恢复。";
  [d runModal];
  exit(0);
}

- (void)resetSingleLayout:(id)sender {
  // 一键恢复单列：同时恢复列表模式，确保一定是单列列表
  gIconMode = NO;
  BOOL big = (self.window.contentView.bounds.size.width >= 560);
  if (big || self.window.isZoomed) {
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSRect normal = NSMakeRect(vf.origin.x + (vf.size.width - 480)/2.0,
                               vf.origin.y + (vf.size.height - 600)/2.0, 480, 600);
    [self.window setFrame:normal display:YES animate:NO];
  }
  self.forceColumns = 0;
  self.userColumns = 1;
  [self saveTheme];
  [self reload];
  [self layoutContent];
}

- (void)resetAllDefaults:(id)sender {
  // 恢复为该分组"刚打开时"的初始状态
  gTheme = 0;
  gGlassAlpha = 0.82;
  gImgScale = 1.0;
  gImgDX = 0.0;
  gImgDY = 0.0;
  gImgPath = nil;
  gCornerRatio = 0;
  gIconMode = NO;
  self.userColumns = 1;
  self.forceColumns = 0;
  [gAppIconSettings removeAllObjects];
  [gOriginalNames removeAllObjects];
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d removeObjectForKey:@"idleExitEnabled"];
  [d removeObjectForKey:@"skinImgPath"];
  [d synchronize];
  [self.idleExitTimer invalidate];
  self.idleExitTimer = nil;
  [self hideCountdown];
  self.pinned = NO;
  [d setBool:NO forKey:@"pinned"];
  [self updatePinAppearance];
  [self saveTheme];
  [self resetCustomIcon:nil];
  [self applyTheme];
  [self reload];
  // 窗口尺寸恢复默认 480x600 居中
  NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
  NSRect vf = screen.visibleFrame;
  NSRect normal = NSMakeRect(vf.origin.x + (vf.size.width - 480)/2.0,
                             vf.origin.y + (vf.size.height - 600)/2.0, 480, 600);
  [self.window setFrame:normal display:YES];
  [self layoutContent];
  [self resetIdleTimer];
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
    // 恢复单列：清掉强制列数，窗口若已放大则收回默认尺寸
    BOOL big = (self.window.contentView.bounds.size.width >= 560);
    if (big || self.window.isZoomed) {
      NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
      NSRect vf = screen.visibleFrame;
      NSRect normal = NSMakeRect(vf.origin.x + (vf.size.width - 480)/2.0,
                                 vf.origin.y + (vf.size.height - 600)/2.0, 480, 600);
      [self.window setFrame:normal display:YES animate:NO];
    }
    self.userColumns = 1;
    self.forceColumns = 0;
    [self reload];
    [self layoutContent];
    return;
  }
  self.userColumns = cols;
  if (self.window.contentView.bounds.size.width < 560) {
    self.forceColumns = cols;
    [self.window zoom:nil];
  } else {
    self.forceColumns = 0;
    [self reload];
  }
  [self layoutContent];
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

- (BOOL)authorizeAdminDeletion {
  AuthorizationRef ref = NULL;
  OSStatus st = AuthorizationCreate(NULL, NULL, kAuthorizationFlagDefaults, &ref);
  if (st != errAuthorizationSuccess) return NO;
  AuthorizationItem item = { "system.privilege.admin", 0, NULL, 0 };
  AuthorizationRights rights = { 1, &item };
  AuthorizationFlags flags = kAuthorizationFlagDefaults | kAuthorizationFlagInteractionAllowed |
                             kAuthorizationFlagPreAuthorize | kAuthorizationFlagExtendRights;
  st = AuthorizationCopyRights(ref, &rights, NULL, flags, NULL);
  AuthorizationFree(ref, kAuthorizationFlagDefaults);
  return st == errAuthorizationSuccess;
}

- (BOOL)trashGroupFilesWithAdmin {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *curPath = [self currentBundlePathByID];
  NSString *parent = [curPath stringByDeletingLastPathComponent];
  NSString *base = [[curPath lastPathComponent] stringByDeletingPathExtension];
  NSString *listFile = [[parent stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"txt"]];
  NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
  NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
  NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"docklauncher-admin-delete.sh"];
  NSMutableString *body = [NSMutableString stringWithString:@"#!/bin/sh\nmkdir -p \"$TRASH\"\n"];
  [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/%@-%@\" 2>/dev/null\n", curPath, curPath, trash, stamp, [curPath lastPathComponent]];
  if ([fm fileExistsAtPath:listFile]) [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/%@-%@\" 2>/dev/null\n", listFile, listFile, trash, stamp, [listFile lastPathComponent]];
  [body appendString:@"/usr/bin/killall -KILL Dock 2>/dev/null\ntrue\n"];
  NSString *final = [body stringByReplacingOccurrencesOfString:@"\"$TRASH\"" withString:[NSString stringWithFormat:@"\"%@\"", trash]];
  if (![final writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return NO;
  [fm setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:scriptPath error:NULL];
  NSString *osa = [NSString stringWithFormat:@"do shell script \"/bin/sh %@\" with administrator privileges", scriptPath];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/osascript";
  t.arguments = @[@"-e", osa];
  @try {
    [t launch];
    [t waitUntilExit];
  } @catch (NSException *e) { return NO; }
  return (t.terminationStatus == 0);
}

- (void)destroyGroupData {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *curPath = [self currentBundlePathByID];
  NSString *parent = [curPath stringByDeletingLastPathComponent];
  NSString *base = [[curPath lastPathComponent] stringByDeletingPathExtension];
  [self removeDockEntryForPath:curPath];
  for (NSDictionary *cfg in [gAppIconSettings allValues]) {
    NSString *img = cfg[@"image"];
    if (img.length && [fm fileExistsAtPath:img]) [fm removeItemAtPath:img error:NULL];
  }
  [gAppIconSettings removeAllObjects];
  [gOriginalNames removeAllObjects];
  NSString *listFile = [[parent stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"txt"]];
  NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
  if (bid.length) [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bid];
  [[NSUserDefaults standardUserDefaults] synchronize];
  (void)curPath; (void)listFile;
}

- (void)deleteCurrentGroup:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = [NSString stringWithFormat:@"删除分组「%@」？", gGroup];
  a.informativeText = [NSString stringWithFormat:@"此操作将删除该页面的所有数据（不可逆）：\n• 分组 App 与列表（含 %ld 个应用条目）\n• 自定义图标、大小、形状、改名记录\n• Dock 图标与本机设置\n\n不会卸载应用本体。", (long)self.items.count];
  [a addButtonWithTitle:@"删除"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;

  NSAlert *warn = [[NSAlert alloc] init];
  warn.messageText = @"此操作将删除该页面的所有数据不可逆，是否操作？";
  warn.informativeText = @"5 秒后可点击「是」继续；选择「否」将退回设置界面。";
  [warn addButtonWithTitle:@"是（5）"];
  [warn addButtonWithTitle:@"否"];
  NSButton *yesBtn = warn.buttons[0];
  yesBtn.enabled = NO;
  for (int sec = 5; sec >= 1; sec--) {
    int remain = sec - 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((5 - sec + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (remain > 0) yesBtn.title = [NSString stringWithFormat:@"是（%d）", remain];
      else { yesBtn.title = @"是"; yesBtn.enabled = YES; }
    });
  }
  if ([warn runModal] != NSAlertFirstButtonReturn) return;

  NSAlert *warn2 = [[NSAlert alloc] init];
  warn2.messageText = @"再次确认：删除当前分组？";
  warn2.informativeText = @"确认后需要输入管理员密码，所有数据会被移到废纸篓且无法恢复。";
  [warn2 addButtonWithTitle:@"是"];
  [warn2 addButtonWithTitle:@"否"];
  if ([warn2 runModal] != NSAlertFirstButtonReturn) return;

  if (![self trashGroupFilesWithAdmin]) {
    NSAlert *e = [[NSAlert alloc] init];
    e.messageText = @"已取消";
    e.informativeText = @"未通过管理员验证，数据未做任何改动。";
    [e runModal];
    return;
  }

  [self destroyGroupData];
  NSAlert *done = [[NSAlert alloc] init];
  done.messageText = @"该数据已被全部清除在废纸篓内";
  done.informativeText = @"分组 App、列表与本地设置已删除；如需找回，可从废纸篓恢复。";
  [done runModal];
  exit(0);
}

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
  // 恢复"首次添加时"记录的名称（而不是系统当前默认名）
  NSString *path = ResolveAppPath(self.appIconEditTarget);
  NSString *orig = gOriginalNames[self.appIconEditTarget];
  if (orig.length == 0 && path) {
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
  if (self.pinned) { [self.idleExitTimer invalidate]; self.idleExitTimer = nil; [self hideCountdown]; }
  else [self resetIdleTimer];
  if (self.pinned) NSBeep();
}

#pragma mark - 内存/缓存

- (void)showIdlePanel:(id)sender {
  if (!self.idlePanel) {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,400,220)
                                            styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
                                              backing:NSBackingStoreBuffered defer:NO];
    p.title = @"定时自动关闭";
    p.level = NSFloatingWindowLevel;
    self.idlePanel = p;
    NSView *cv = p.contentView;

    self.idleCheck = [NSButton checkboxWithTitle:@"启用定时自动关闭" target:nil action:nil];
    self.idleCheck.frame = NSMakeRect(20, 168, 250, 24);
    [cv addSubview:self.idleCheck];

    NSTextField *lab2 = [NSTextField labelWithString:@"时间"];
    lab2.frame = NSMakeRect(20, 122, 40, 20);
    lab2.font = [NSFont systemFontOfSize:13];
    [cv addSubview:lab2];
    self.idleTimePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(70, 116, 140, 30)];
    self.idleTimePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    self.idleTimePicker.datePickerElements = NSDatePickerElementFlagHourMinute;
    [cv addSubview:self.idleTimePicker];

    NSTextField *hh = [NSTextField labelWithString:@"时"];
    hh.font = [NSFont systemFontOfSize:10];
    hh.textColor = [NSColor secondaryLabelColor];
    hh.frame = NSMakeRect(96, 97, 20, 16);
    [cv addSubview:hh];
    NSTextField *mm = [NSTextField labelWithString:@"分"];
    mm.font = [NSFont systemFontOfSize:10];
    mm.textColor = [NSColor secondaryLabelColor];
    mm.frame = NSMakeRect(146, 97, 20, 16);
    [cv addSubview:mm];

    NSTextField *tip = [NSTextField labelWithString:@"格式为 时:分；到该时间自动退出，若今天已过则顺延到明天。默认关闭"];
    tip.frame = NSMakeRect(20, 68, 360, 20);
    tip.font = [NSFont systemFontOfSize:11];
    tip.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:tip];

    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(closeIdlePanel:)];
    cancel.frame = NSMakeRect(190, 25, 90, 32);
    cancel.bezelStyle = NSBezelStyleRounded;
    [cv addSubview:cancel];
    NSButton *save = [NSButton buttonWithTitle:@"保存" target:self action:@selector(saveIdlePanel:)];
    save.frame = NSMakeRect(290, 25, 90, 32);
    save.bezelStyle = NSBezelStyleRounded;
    [cv addSubview:save];
    [p center];
  }
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  double ts = [d doubleForKey:@"autoCloseDate"];
  NSDate *when;
  if (ts > [[NSDate date] timeIntervalSince1970]) when = [NSDate dateWithTimeIntervalSince1970:ts];
  else {
    NSDateComponents *c = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:[NSDate date]];
    c.hour = 0; c.minute = 0; c.second = 0;
    when = [[NSCalendar currentCalendar] dateFromComponents:c] ?: [NSDate date];
  }
  self.idleCheck.state = (ts > [[NSDate date] timeIntervalSince1970]) ? NSControlStateValueOn : NSControlStateValueOff;
  self.idleTimePicker.dateValue = when;
  [self.idlePanel makeKeyAndOrderFront:nil];
}

- (void)saveIdlePanel:(id)sender {
  if (self.idleCheck.state != NSControlStateValueOn) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"autoCloseDate"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.idleExitTimer invalidate]; self.idleExitTimer = nil;
    [self hideCountdown];
    [self.idlePanel orderOut:nil];
    return;
  }
  NSDateComponents *tc = [[NSCalendar currentCalendar] components:(NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:self.idleTimePicker.dateValue];
  NSDateComponents *dc = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:[NSDate date]];
  dc.hour = tc.hour; dc.minute = tc.minute; dc.second = 0;
  NSDate *when = [[NSCalendar currentCalendar] dateFromComponents:dc];
  BOOL rolled = NO;
  if (!when || [when timeIntervalSinceNow] < 1) {
    when = [when dateByAddingTimeInterval:86400];
    rolled = YES;
  }
  [[NSUserDefaults standardUserDefaults] setDouble:[when timeIntervalSince1970] forKey:@"autoCloseDate"];
  [[NSUserDefaults standardUserDefaults] synchronize];
  [self resetIdleTimer];
  [self.idlePanel orderOut:nil];
  if (rolled) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm";
    NSAlert *n = [[NSAlert alloc] init];
    n.icon = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    n.messageText = [NSString stringWithFormat:@"已设置为明天 %@ 自动关闭", [df stringFromDate:when]];
    n.informativeText = @"今天该时间已过，因此顺延到明天的同一时间。";
    [n runModal];
  }
}

- (void)closeIdlePanel:(id)sender {
  [self.idlePanel orderOut:nil];
}

- (void)hideCountdown {
  self.countdownLabel.hidden = YES;
  self.countdownLabel.stringValue = @"";
  [self.countdownTimer invalidate];
  self.countdownTimer = nil;
}

- (void)updateCountdown {
  if (!self.idleExitTimer) { [self hideCountdown]; return; }
  NSTimeInterval left = [self.idleExitTimer.fireDate timeIntervalSinceNow];
  if (left <= 0) { [self idleExitFired:nil]; return; }
  double ts = [self.idleExitTimer.fireDate timeIntervalSince1970];
  NSInteger total = (NSInteger)left;
  NSInteger h = total / 3600, m = (total % 3600) / 60, sec = total % 60;
  NSString *remain;
  if (h >= 24) remain = [NSString stringWithFormat:@"剩%ld天%02ld:%02ld", (long)(h/24), (long)(h%24), (long)m];
  else if (h >= 1) remain = [NSString stringWithFormat:@"剩%02ld:%02ld", (long)h, (long)m];
  else remain = [NSString stringWithFormat:@"剩%02ld:%02ld", (long)m, (long)sec];
  NSDateFormatter *df = [[NSDateFormatter alloc] init];
  df.dateFormat = @"HH:mm";
  NSString *target = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
  self.countdownLabel.stringValue = [NSString stringWithFormat:@"%@ 关 · %@", target, remain];
  self.countdownLabel.hidden = NO;
}

- (void)resetIdleTimer {
  [self.idleExitTimer invalidate];
  self.idleExitTimer = nil;
  if (self.pinned) { [self hideCountdown]; return; }
  if (![[NSUserDefaults standardUserDefaults] boolForKey:@"idleExitEnabled"]) { [self hideCountdown]; return; }
  self.idleExitTimer = [NSTimer timerWithTimeInterval:180.0 target:self selector:@selector(idleExitFired:) userInfo:nil repeats:NO];
  [[NSRunLoop mainRunLoop] addTimer:self.idleExitTimer forMode:NSRunLoopCommonModes];
  if (!self.countdownTimer) {
    self.countdownTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(updateCountdown) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.countdownTimer forMode:NSRunLoopCommonModes];
  }
  [self updateCountdown];
}

- (void)idleExitFired:(NSTimer *)t {
  self.idleExitTimer = nil;
  [self hideCountdown];
  if (self.pinned) return;
  [NSApp terminate:nil];
}

- (void)toggleIdleExit:(id)sender {
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  BOOL on = ![d boolForKey:@"idleExitEnabled"];
  [d setBool:on forKey:@"idleExitEnabled"];
  [d synchronize];
  if (on) [self resetIdleTimer];
  else { [self.idleExitTimer invalidate]; self.idleExitTimer = nil; [self hideCountdown]; }
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

    if (getenv("DOCKLAUNCHER_TEST_UNINSTALL")) {
      [NSApplication sharedApplication];
      Controller *uc = [[Controller alloc] init];
      [uc uninstallAll:nil];
      return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "--restore-dock") == 0) {
      [NSApplication sharedApplication];
      Controller *c = [[Controller alloc] init];
      [c repairDockEntries];
      NSTask *t = [[NSTask alloc] init];
      t.launchPath = @"/usr/bin/killall";
      t.arguments = @[@"-KILL", @"Dock"];
      @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
      fprintf(stderr, "DOCK_RESTORED\n");
      return 0;
    }

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
    if (getenv("DOCKLAUNCHER_TEST_COUNTDOWN_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSUserDefaults standardUserDefaults] setDouble:([[NSDate date] timeIntervalSince1970] + 3725) forKey:@"autoCloseDate"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [c resetIdleTimer];
        fprintf(stderr, "CD hidden=%d frame=%.0f,%.0f,%.0fx%.0f text='%s'\n", c.countdownLabel.hidden, c.countdownLabel.frame.origin.x, c.countdownLabel.frame.origin.y, c.countdownLabel.frame.size.width, c.countdownLabel.frame.size.height, [c.countdownLabel.stringValue UTF8String]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_RESET_SINGLE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES; c.userColumns = 4;
        [c reload];
        fprintf(stderr, "RS before icon=%d cols=%ld\n", gIconMode, (long)[c effectiveColumns]);
        [c resetSingleLayout:nil];
        fprintf(stderr, "RS after icon=%d cols=%ld width=%.0f user=%ld force=%ld\n", gIconMode, (long)[c effectiveColumns], c.window.contentView.bounds.size.width, (long)c.userColumns, (long)c.forceColumns);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_LAYOUT_SINGLE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSRect f = c.window.frame; f.size.width = 900; f.size.height = 700;
        [c.window setFrame:f display:YES];
        c.userColumns = 4; c.forceColumns = 3;
        [c reload];
        fprintf(stderr, "LAYOUT before cols=%ld width=%.0f\n", (long)[c effectiveColumns], c.window.contentView.bounds.size.width);
        [c layoutSingle:nil];
        [c layoutContent];
        fprintf(stderr, "LAYOUT after cols=%ld width=%.0f force=%ld\n", (long)[c effectiveColumns], c.window.contentView.bounds.size.width, (long)c.forceColumns);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SETTINGS_SUB")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showSkinMenu:nil];
        NSButton *fake = [[NSButton alloc] init];
        fake.tag = 0; [c settingsTabClicked:fake];
        fake.tag = 2; [c settingsRowClicked:fake];
        fake.tag = 3; [c settingsRowClicked:fake];
        fprintf(stderr, "SUB focus=%s visible=%ld panelVisible=%d\n", [c.settingsFocusPath UTF8String], (long)c.settingsVisible.count, c.settingsPanel.isVisible);
        fake.tag = 0; [c settingsRowClicked:fake];
        fprintf(stderr, "SUB leaf panelVisible=%d\n", c.settingsPanel.isVisible);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SETTINGS_KEYS")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showSkinMenu:nil];
        NSString *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
        NSString *down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
        NSEvent *(^ev)(NSString *) = ^NSEvent *(NSString *ch) {
          return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                 timestamp:0 windowNumber:c.settingsPanel.windowNumber context:nil
                                characters:ch charactersIgnoringModifiers:ch isARepeat:NO keyCode:0];
        };
        [c handleSettingsKeyDown:ev(right)];
        fprintf(stderr, "KEYS tab=%ld focus=%s visible=%ld\n", (long)c.settingsTabIndex, [c.settingsFocusPath UTF8String], (long)c.settingsVisible.count);
        [c handleSettingsKeyDown:ev(down)];
        fprintf(stderr, "KEYS2 focus=%s\n", [c.settingsFocusPath UTF8String]);
        [c handleSettingsKeyDown:ev(down)];
        [c handleSettingsKeyDown:ev(down)];
        fprintf(stderr, "KEYS3 focus=%s kids=%s\n", [c.settingsFocusPath UTF8String], "");
        [c handleSettingsKeyDown:ev(right)];
        fprintf(stderr, "KEYS4 visible=%ld\n", (long)c.settingsVisible.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_UNINSTALL_CONFIRM_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showUninstallAppsPanel];
        fprintf(stderr, "UNINSTALL_DEBUG data=%ld filtered=%ld first=%s\n", (long)c.uninstallData.count, (long)c.uninstallFiltered.count, c.uninstallFiltered.count ? [c.uninstallFiltered.firstObject[@"path"] UTF8String] : "-");
        if (c.uninstallFiltered.count) [c.uninstallSelected addObject:c.uninstallFiltered.firstObject[@"path"]];
        [c updateUninstallSummary];
        [c confirmUninstallApps:nil];
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_UNINSTALL_RUN")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showUninstallAppsPanel];
        fprintf(stderr, "UNINSTALL_DEBUG data=%ld filtered=%ld first=%s\n", (long)c.uninstallData.count, (long)c.uninstallFiltered.count, c.uninstallFiltered.count ? [c.uninstallFiltered.firstObject[@"path"] UTF8String] : "-");
        if (c.uninstallFiltered.count) [c.uninstallSelected addObject:c.uninstallFiltered.firstObject[@"path"]];
        [c updateUninstallSummary];
        [c confirmUninstallApps:nil];
        NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
        fprintf(stderr, "UNINSTALL_RUN list='%s'\n", [content UTF8String]);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_UNINSTALL_PANEL_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = NO; [c reload];
        [c showUninstallAppsPanel];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_UNINSTALL_WARN_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showSkinMenu:nil];
        [c appUninstallTabRequested];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_SETTINGS_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showSkinMenu:nil];
        fprintf(stderr, "SETTINGS tree=%ld visible0=%ld\n", (long)c.settingsTree.count, (long)c.settingsVisible.count);
        NSButton *tab = [[NSButton alloc] init];
        tab.tag = 0;
        [c settingsTabClicked:tab];
        fprintf(stderr, "SETTINGS visible=%ld\n", (long)c.settingsVisible.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_IDLE_IDLE")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"idleExitEnabled"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [c resetIdleTimer];
        fprintf(stderr, "IDLEIDLE fireIn=%.0f cdHidden=%d text='%s'\n", c.idleExitTimer ? [c.idleExitTimer.fireDate timeIntervalSinceNow] : -1, c.countdownLabel.hidden, [c.countdownLabel.stringValue UTF8String]);
        [c togglePin:nil];
        fprintf(stderr, "IDLEIDLE pinned timerNil=%d cdHidden=%d\n", c.idleExitTimer == nil, c.countdownLabel.hidden);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_IDLE_SHOW")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [c showIdlePanel:nil];
        fprintf(stderr, "IDLESHOW vis=%d frame=%.0f,%.0f level=%ld\n", c.idlePanel.isVisible, c.idlePanel.frame.origin.x, c.idlePanel.frame.origin.y, (long)c.idlePanel.level);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_IDLE_CALC")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSUserDefaults standardUserDefaults] setDouble:([[NSDate date] timeIntervalSince1970] + 60) forKey:@"autoCloseDate"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [c resetIdleTimer];
        fprintf(stderr, "IDLECALC ts=%.0f fireIn=%.1f valid=%d\n", [[NSUserDefaults standardUserDefaults] doubleForKey:@"autoCloseDate"], c.idleExitTimer ? [c.idleExitTimer.fireDate timeIntervalSinceNow] : -1, c.idleExitTimer != nil);
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"autoCloseDate"];
        [c resetIdleTimer];
        fprintf(stderr, "IDLECALC off=%d\n", c.idleExitTimer != nil);
        exit(0);
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_DESTROY")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        fprintf(stderr, "DESTROY before=%s\n", [[c currentBundlePathByID] UTF8String]);
        gAppIconSettings[@"x"] = @{@"image": @"/nonexistent"};
        [c destroyGroupData];
        fprintf(stderr, "DESTROY after=%d\n", [[NSFileManager defaultManager] fileExistsAtPath:[c currentBundlePathByID]]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
      });
    }
    if (getenv("DOCKLAUNCHER_TEST_RESETNAME")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gIconMode = YES; [c reload];
        c.sel = 0; [c selectRow:0];
        NSString *t = c.items[0][@"target"];
        gOriginalNames[t] = @"首次添加名";
        c.appIconEditTarget = t;
        [c showAppIconPanel:nil];
        [c updateLabel:@"后来改名" forTarget:t];
        [c resetAppIcon:nil];
        NSString *content = [NSString stringWithContentsOfFile:gListFile encoding:NSUTF8StringEncoding error:NULL];
        fprintf(stderr, "RESETNAME content=%s\n", [content UTF8String]);
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
