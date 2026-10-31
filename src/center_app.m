#import <Cocoa/Cocoa.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/stat.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <Quartz/Quartz.h>
#import <objc/runtime.h>
#import <CoreServices/CoreServices.h>
#import <IOKit/IOKitLib.h>
#import <ImageIO/ImageIO.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <Photos/Photos.h>
#import <Vision/Vision.h>
#import <PDFKit/PDFKit.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

static double gPrevCPUBusy = 0, gPrevCPUTotal = 0;
static unsigned long long gPrevNetIn = 0, gPrevNetOut = 0;
static double gLastNetTime = 0;

static NSString *GroupDir(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DockLaunchers"]; }

static NSString *ResolveAppPath(NSString *target) {
  if (!target.length) return nil;
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([target hasPrefix:@"/"]) return [fm fileExistsAtPath:target] ? target : nil;
  if ([target hasPrefix:@"file://"]) {
    NSString *p = [[NSURL URLWithString:target] path];
    return (p && [fm fileExistsAtPath:p]) ? p : nil;
  }
  NSArray *dirs = @[@"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"], @"/System/Applications", @"/Applications/Utilities"];
  // 带完整文件名（如 WeChat.app）
  for (NSString *d in dirs) {
    NSString *p = [d stringByAppendingPathComponent:target];
    if ([fm fileExistsAtPath:p]) return p;
    if (![target hasSuffix:@".app"]) {
      p = [d stringByAppendingPathComponent:[target stringByAppendingPathExtension:@"app"]];
      if ([fm fileExistsAtPath:p]) return p;
    }
  }
  // 纯名称，遍历目录匹配
  for (NSString *d in dirs) {
    NSArray *items = [fm contentsOfDirectoryAtPath:d error:NULL];
    for (NSString *f in items) {
      if (![f hasSuffix:@".app"]) continue;
      if ([[f stringByDeletingPathExtension] isEqualToString:target]) return [d stringByAppendingPathComponent:f];
    }
  }
  return nil;
}


static NSString *LocalizedAppName(NSString *path, NSDictionary *info) {
  NSArray *langs = @[@"zh-Hans", @"zh_CN", @"zh-Hant", @"Base", @"en"];
  NSString *res = path;
  for (NSString *lang in langs) {
    NSString *f = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"Contents/Resources/%@.lproj/InfoPlist.strings", lang]];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:f];
    if (![d isKindOfClass:[NSDictionary class]]) continue;
    NSString *v = d[@"CFBundleDisplayName"];
    if (![v isKindOfClass:[NSString class]] || !v.length) v = d[@"CFBundleName"];
    if ([v isKindOfClass:[NSString class]] && v.length) { res = v; break; }
  }
  if ([res isEqualToString:path]) {
    NSString *v = info[@"CFBundleDisplayName"];
    if (![v isKindOfClass:[NSString class]] || !v.length) v = info[@"CFBundleName"];
    if ([v isKindOfClass:[NSString class]] && v.length) res = v;
  }
  if ([res isEqualToString:path]) res = [[path lastPathComponent] stringByDeletingPathExtension];
  return res;
}


static NSString *DockEntryPath(NSString *u) {
  if (![u isKindOfClass:[NSString class]]) return @"";
  NSString *p = u;
  if ([p hasPrefix:@"file://"]) p = [[p substringFromIndex:7] stringByRemovingPercentEncoding] ?: p;
  while ([p hasSuffix:@"/"] && p.length > 1) p = [p substringToIndex:p.length-1];
  return [p stringByStandardizingPath];
}
static BOOL IsOurDockEntry(NSDictionary *item) {
  NSString *bid = nil; NSString *label = nil;
  @try { bid = item[@"tile-data"][@"bundle-identifier"]; label = item[@"tile-data"][@"file-label"]; } @catch (NSException *e) {}
  return [bid hasPrefix:@"com.docklaunchers."] || [label hasPrefix:@"DockLaunchers"];
}

static BOOL DLThemeIsDark(void) {
  NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
  if (t == 2) return YES;
  if (t == 1) return NO;
  return [[[NSApp effectiveAppearance].name lowercaseString] containsString:@"dark"];
}
static NSColor *DLButtonBackground(void) {
  return DLThemeIsDark() ? [NSColor colorWithCalibratedWhite:0.24 alpha:1.0] : [NSColor colorWithCalibratedWhite:0.975 alpha:1.0];
}

static NSImage *ToolIconImage(NSString *symbol, NSColor *color) {
  return [NSImage imageWithSize:NSMakeSize(68, 68) flipped:NO drawingHandler:^BOOL(NSRect r) {
    NSRect box = NSMakeRect(5, 5, 58, 58);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:box xRadius:15 yRadius:15];
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    NSShadow *outer = [[NSShadow alloc] init];
    outer.shadowBlurRadius = 6; outer.shadowOffset = NSMakeSize(0, -2);
    outer.shadowColor = [[NSColor blackColor] colorWithAlphaComponent:0.18];
    [outer set];
    [[color colorWithAlphaComponent:0.9] setFill]; [p fill];
    [ctx restoreGraphicsState];
    [ctx saveGraphicsState];
    [p addClip];
    NSColor *top = [color blendedColorWithFraction:0.52 ofColor:[NSColor whiteColor]];
    NSGradient *g = [[NSGradient alloc] initWithColors:@[top, color, [color blendedColorWithFraction:0.16 ofColor:[NSColor blackColor]]]];
    [g drawInRect:box angle:-90];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.24] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1, 32, 70, 46)] fill];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(9, 7, 50, 20) xRadius:10 yRadius:10] fill];
    [ctx restoreGraphicsState];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.58] setStroke];
    p.lineWidth = 1;
    [p stroke];
    NSImage *sym = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    sym = [sym imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:28 weight:NSFontWeightSemibold]];
    sym.template = YES;
    NSShadow *sh = [[NSShadow alloc] init]; sh.shadowBlurRadius = 2; sh.shadowOffset = NSMakeSize(0, -1);
    sh.shadowColor = [[NSColor blackColor] colorWithAlphaComponent:0.22];
    [sh set];
    [[NSColor whiteColor] set];
    [sym drawInRect:NSMakeRect(20, 20, 28, 28)];
    return YES;
  }];
}


static NSColor *DLRowBackground(void) {
  return DLThemeIsDark() ? [NSColor colorWithCalibratedWhite:0.16 alpha:1.0] : [NSColor colorWithCalibratedWhite:0.985 alpha:1.0];
}

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface Sparkline : NSView
@property (strong) NSMutableArray<NSNumber *> *values;
@property (strong) NSColor *lineColor;
@end
@implementation Sparkline
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _values = [NSMutableArray array]; _lineColor = [NSColor systemBlueColor]; }
  return self;
}
- (void)addValue:(double)v {
  [self.values addObject:@(v)];
  while (self.values.count > 90) [self.values removeObjectAtIndex:0];
  [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
  NSInteger themeVal = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
  BOOL darkBg = (themeVal == 2) || (themeVal == 0 && [[[NSApp effectiveAppearance].name lowercaseString] containsString:@"dark"]);
  [[NSColor colorWithCalibratedWhite:(darkBg ? 0.20 : 0.985) alpha:1.0] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill];
  if (self.values.count < 2) return;
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  CGFloat step = w / 89.0;
  NSBezierPath *path = [NSBezierPath bezierPath];
  NSBezierPath *area = [NSBezierPath bezierPath];
  [area moveToPoint:NSMakePoint(0, 0)];
  for (NSInteger i = 0; i < (NSInteger)self.values.count; i++) {
    double v = [self.values[i] doubleValue];
    CGFloat y = MAX(3, MIN(h - 3, h * (v / 100.0)));
    NSPoint pt = NSMakePoint(i * step + 1, y);
    if (i == 0) [path moveToPoint:pt]; else [path lineToPoint:pt];
    [area lineToPoint:pt];
  }
  [area lineToPoint:NSMakePoint((self.values.count - 1) * step + 1, 0)];
  [area closePath];
  [[self.lineColor colorWithAlphaComponent:0.12] setFill];
  [area fill];
  [self.lineColor setStroke];
  path.lineWidth = 1.8;
  [path stroke];
}
@end

static NSString *LetterSortKey(NSString *name) {
  if (!name.length) return @"#";
  unichar c = [name characterAtIndex:0];
  if (c >= 'A' && c <= 'Z') return [NSString stringWithFormat:@"%C", c];
  if (c >= 'a' && c <= 'z') return [[NSString stringWithFormat:@"%C", c] uppercaseString];
  NSMutableString *m = [name mutableCopy];
  CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformToLatin, false);
  CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformStripDiacritics, false);
  for (NSUInteger i = 0; i < m.length; i++) {
    unichar ch = [m characterAtIndex:i];
    if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) return [[NSString stringWithFormat:@"%C", ch] uppercaseString];
  }
  return @"#";
}

@class LetterIndexView;
@class MetricColumnView;
@class DiskSegmentBar;
@class DiskJustifiedLayout;
@class QuickBarView;
@class ColorHoverButton;
@class DiskTypeControl;
@class ScopeColorControl;
static NSFont *DLDisplayFont(CGFloat size, BOOL bold) {
  CGFloat bump = size <= 14 ? 2.0 : (size <= 20 ? 1.5 : 1.0);
  return [NSFont systemFontOfSize:size + bump weight:bold ? NSFontWeightBold : NSFontWeightSemibold];
}

@interface Controller : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSComboBoxDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate>
- (void)handleActivityPaths:(NSArray<NSString *> *)paths;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSWindow *window;
@property (strong) NSTextField *centerTitleLabel;
@property (strong) NSView *sideView;
@property (strong) ColorHoverButton *sidebarToggle;
@property BOOL sidebarCollapsed;
@property (strong) NSView *content;
@property (strong) NSButton *sideLive, *sideGroups, *sideAI, *sideDisk, *sideUninstall, *sideSettings;
@property NSInteger section;
@property (strong) NSView *liveView, *groupsView, *uninstallView, *settingsView;
@property (strong) NSMutableSet *builtSections;
@property (strong) NSWindow *compressWindow;
@property (strong) NSButton *compressPinButton, *translationPinButton;
@property (strong) NSView *quickToolsPage;
@property (strong) NSMutableArray *compressPaths;
@property (strong) NSTextField *compressStatus, *compressListLabel;
@property (strong) NSWindow *translationWindow;
@property (strong) NSTextView *translationSourceView, *translationResultView;
@property (strong) NSPopUpButton *translationProviderPopup, *translationTargetPopup;
@property (strong) NSComboBox *translationModelField;
@property (strong) NSTextField *translationStatus;
- (void)translateSelectedText;
- (void)beginScreenshotTranslation;
- (void)translateCurrentText;
@property (strong) NSTimer *translationAutoTimer;
@property BOOL translationBusy;
@property EventHotKeyRef translationHotKey, selectionHotKey, translateHotKey;
@property UInt32 shotKeyCode, shotModifiers, selectionKeyCode, selectionModifiers, translateKeyCode, translateModifiers;
@property (strong) NSString *shotShortcutDisplay, *selectionShortcutDisplay, *translateShortcutDisplay;
@property (strong) NSMutableArray *shortcutButtons;
@property (strong) NSWindow *shortcutSettingsWindow;
@property (strong) id shortcutRecordingMonitor;
@property NSInteger shortcutRecordingAction;
@property (strong) NSTextField *shortcutStatusLabel;
@property (strong) NSWindow *translateConfirmWindow;
@property BOOL translateConfirmYes;
@property EventHandlerRef translationHotKeyHandler;
@property (strong) NSProgressIndicator *compressSpinner;
@property NSInteger groupsPage;
@property (strong) NSString *groupsFilter, *groupsHighlightedName, *groupsSelectedName;
@property (strong) NSArray *groupsFiltered;
@property (strong) id groupsKeyMonitor;
@property (strong) NSSearchField *groupsSearch;
@property (strong) ColorHoverButton *groupsPrevButton, *groupsNextButton;
@property (strong) NSTextField *groupsPageLabel;
@property (strong) NSScrollView *contentScroll;
@property CGFloat uiZoom;
@property (strong) NSTextField *uptimeLabel;
@property (strong) NSArray *metricColumns;
@property (strong) NSArray *internalColumns;
@property (strong) MetricColumnView *externalColumn;
@property (strong) NSPopUpButton *externalPopup;
@property (strong) NSMutableArray *externalVolumes;
@property NSInteger externalSelectedIndex;
@property (strong) NSView *metricHostView;
@property (strong) NSView *liveAIBoard;
@property NSInteger liveAIPage;
// disk analysis
@property (strong) NSView *diskView;
@property (strong) NSView *aiView;
@property (strong) NSTableView *aiTable;
@property (strong) NSMutableArray *aiEntries;
@property (strong) NSMutableSet *aiSelected;
@property (strong) NSMutableSet *aiRevealedNames;
@property (strong) NSArray *backupAppChoices;
@property (strong) NSDate *lastAIQuotaRefresh;
@property (strong) NSArray *aiVisibleEntries;
@property NSInteger aiPage;
@property (strong) NSString *aiCategory;
@property (strong) ColorHoverButton *aiPrevButton, *aiNextButton;
@property (strong) NSTextField *aiPageLabel;
@property (strong) ColorHoverButton *aiCategoryButton;
@property (strong) NSSearchField *aiSearchField;
@property (strong) NSComboBox *dialogAIName;
@property (strong) NSTextField *dialogAIQuota, *dialogAIEndpoint, *dialogAIApi, *dialogAINote, *dialogAIStatus;
@property BOOL aiQuotaRefreshing;
@property (strong) NSPopUpButton *diskVolumePopup;
@property (strong) NSTextField *diskStatus;
@property (strong) NSTextField *diskSummary;
@property (strong) DiskSegmentBar *diskSegmentBar;
@property (strong) NSTextField *diskCategoryLabel;
@property (strong) NSTextField *diskAppsLabel;
@property (strong) NSButton *diskPersonalCheck;
@property (strong) NSArray *diskVolumes;
@property (strong) NSTableView *diskTable;
@property (strong) NSScrollView *diskScroll;
@property (strong) DiskTypeControl *diskTypeSegment;
@property (strong) NSTextField *diskHintLabel;
@property (strong) NSArray *diskFileData;
@property (strong) NSArray *diskFileFiltered;
@property (strong) NSProgressIndicator *diskSpinner;
@property (strong) NSCollectionView *diskCollection;
@property (strong) NSScrollView *diskCollectionScroll;
@property (strong) NSArray *diskGalleryItems;
@property (strong) NSArray *diskAllGalleryItems;
@property NSInteger diskGalleryPage;
@property (strong) ColorHoverButton *diskPrevPageButton, *diskNextPageButton;
@property (strong) NSTextField *diskPageLabel;
@property (strong) NSCollectionViewFlowLayout *diskFlowLayout;
@property CGFloat diskGalleryItemWidth;
@property (strong) NSView *diskCard;
@property (strong) NSString *diskCurrentPath;
@property (strong) NSMutableArray *diskBackStack, *diskForwardStack;
@property (strong) NSButton *diskBackButton, *diskForwardButton;
@property (strong) NSPathControl *diskPathControl;
@property BOOL diskSourcePicked;
@property (strong) NSDatePicker *diskDatePicker;
@property (strong) NSPopover *diskDatePopover;
@property (strong) NSButton *diskDateButton;
@property (strong) NSDate *diskDateFilter;
@property BOOL diskPreviewMode;
@property NSInteger diskSelectedIndex;
@property (strong) id diskKeyMonitor;
@property (strong) NSString *diskSelectedMount;
@property NSInteger diskGeneration;
@property (strong) NSMutableString *gpuText;
@property double gpuPercent;
@property NSInteger batteryHealthFromProfiler;
@property NSInteger batteryCyclesFromProfiler;
@property (strong) NSString *batteryConditionText;
@property NSTimeInterval lastBatteryProbe;
@property BOOL batteryProbeRunning;
@property (strong) Sparkline *cpuSpark, *memSpark;
@property (strong) NSTimer *timer;
@property (strong) NSTimer *autoSyncTimer;
@property (strong) NSButton *autoSyncCheck;
@property NSInteger sampleSeconds;
@property (strong) NSButton *menuBarCheck;
@property (strong) NSPopUpButton *intervalPopup;
@property (strong) NSPopUpButton *themePopup;
@property (strong) NSButton *loginCheck;
// groups
@property (strong) NSMutableArray<NSDictionary *> *groups;
@property (strong) NSMutableSet<NSString *> *selectedGroups;
@property (strong) NSView *groupsList;
@property (strong) NSMutableArray *dialogIconButtons;
@property NSInteger dialogSelectedBuiltin;
@property (strong) NSString *dialogCustomIcon;
@property NSInteger dialogEditIndex;
@property (strong) NSImage *dialogFirstIconImage;
@property (strong) NSString *dialogPrefillName;
@property (strong) NSTextField *dialogNameField;
@property (strong) NSString *dialogPendingOpen;
@property (strong) NSString *dialogPendingEditName;
@property BOOL dialogIconsMissing;
@property (strong) NSMutableArray *emptyGroupCheckboxes;
@property (strong) NSButton *emptyContinueButton;
@property (strong) NSArray *userFilesForUninstall;
@property (strong) NSMutableSet *userFilesSelected;
@property (strong) NSTableView *userFilesTable;
@property (strong) NSString *userFilesPreviewPath;
@property (strong) NSArray *userFilesApps;
@property (strong) NSArray *rememberedDirEntries;
@property FSEventStreamRef activityStream;
@property (strong) NSMutableArray *activityEntries;
@property (strong) NSButton *activityCheck;
@property (strong) NSButton *protectedDirsCheck;
@property (strong) NSButton *albumModeCheck;
@property (strong) NSButton *mediaModeCheck;
@property (strong) NSTimer *activitySaveTimer;
@property BOOL activityDirty;
@property BOOL dialogHighlightName;
@property (strong) NSScrollView *groupsScroll;
// uninstall
@property (strong) NSMutableArray<NSDictionary *> *uninstallData;
@property (strong) NSMutableArray<NSDictionary *> *uninstallFiltered;
@property (strong) NSMutableSet<NSString *> *uninstallSelected;
@property (strong) NSTableView *uninstallTable;
@property (strong) LetterIndexView *letterIndex;
@property (strong) NSArray<NSString *> *letters;
@property (strong) NSString *letterFilter;
@property (strong) NSTimer *letterFilterTimer;
@property (strong) id letterActivityMonitor;
@property (strong) NSSearchField *uninstallSearch;
@property (strong) NSTextField *uninstallFooter;
@property (strong) ScopeColorControl *uninstallScopeCtl;
@property (strong) NSPopUpButton *uninstallGroupPopup;
@property NSInteger uninstallScope;
@property (strong) NSButton *uninstallGo;
- (void)unloadLoginAgent;
@property (strong) NSPopover *popover;
@property (strong) NSView *quickGroups;
@property (strong) NSTextField *quickCPU, *quickMem, *quickBat;
@property (strong) NSTextField *quickGPU, *quickDisk, *quickNet;
@property (strong) NSTextField *quickCPUSub, *quickGPUSub, *quickMemSub, *quickDiskSub, *quickNetSub, *quickPowerSub;
@property (strong) QuickBarView *quickCPUBar, *quickGPUBar, *quickMemBar, *quickDiskBar;
@property (strong) Sparkline *quickCPUSpark, *quickGPUSpark, *quickNetSpark;
@property (strong) NSView *quickOverview, *quickDetail, *quickGroupPage, *quickAIPage;
@property (strong) NSMutableArray *quickAIRowViews;
@property NSInteger quickAISelectedRow;
@property (strong) NSView *quickGroupContainer;
@property (strong) NSSegmentedControl *quickTabs;
@property (strong) NSTextField *quickDetailTitle, *quickDetailValue, *quickDetailSub, *quickDetailExtra;
@property (strong) Sparkline *quickDetailChart;
@property (strong) QuickBarView *quickDetailBar;
@property NSInteger quickBatteryCycles;
@property double quickBatteryHealth;
@property (strong) NSString *quickBatteryState;
@property (strong) NSTextField *batteryLabel, *thermalLabel, *processLabel;
@end


static void ActivityStreamCallback(ConstFSEventStreamRef streamRef, void *info, size_t numEvents, void *eventPaths, const FSEventStreamEventFlags eventFlags[], const FSEventStreamEventId eventIds[]) {
  char **paths = (char **)eventPaths;
  NSMutableArray *arr = [NSMutableArray array];
  for (size_t i = 0; i < numEvents; i++) if (paths[i]) [arr addObject:[NSString stringWithUTF8String:paths[i]]];
  Controller *c = (__bridge Controller *)info;
  [c handleActivityPaths:arr];
}


@interface LetterIndexView : NSView
@property (strong) NSArray<NSString *> *letters;
@property (strong) NSString *letterFilter;
@property (strong) NSTimer *letterFilterTimer;
@property (strong) id letterActivityMonitor;
@property NSInteger hovered;
@property (weak) id target;
@property SEL action;
@property BOOL persistentHighlight;
@end
@implementation LetterIndexView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _letters = @[]; _hovered = -1; }
  return self;
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect) owner:self userInfo:nil];
  [self addTrackingArea:ta];
}
- (void)setLetters:(NSArray<NSString *> *)letters { _letters = letters; self.hovered = -1; [self setNeedsDisplay:YES]; }
- (NSInteger)indexAtPoint:(NSPoint)p {
  if (!self.letters.count) return -1;
  CGFloat h = self.bounds.size.height / self.letters.count;
  NSInteger i = (NSInteger)(p.y / MAX(h,1));
  return (i >= 0 && i < (NSInteger)self.letters.count) ? i : -1;
}
- (void)mouseMoved:(NSEvent *)e {
  NSInteger i = [self indexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
  if (i != self.hovered) { self.hovered = i; [self setNeedsDisplay:YES]; }
}
- (void)mouseExited:(NSEvent *)e { self.hovered = -1; [self setNeedsDisplay:YES]; }
- (void)mouseDown:(NSEvent *)e {
  NSInteger i = [self indexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
  if (i >= 0 && i < (NSInteger)self.letters.count && self.target) {
    SEL sel = self.action;
    if (sel) [self.target performSelector:sel withObject:self.letters[i]];
  }
}
- (void)drawRect:(NSRect)dirtyRect {
  NSInteger themeVal = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
  BOOL dark = (themeVal == 2) || (themeVal == 0 && [[[NSApp effectiveAppearance].name lowercaseString] containsString:@"dark"]);
  [[NSColor colorWithCalibratedWhite:(dark ? 0.18 : 0.97) alpha:0.92] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8] fill];
  CGFloat h = self.bounds.size.height / MAX(self.letters.count,1);
  for (NSInteger i = 0; i < (NSInteger)self.letters.count; i++) {
    BOOL hot = (i == self.hovered);
    NSFont *f = hot ? [NSFont boldSystemFontOfSize:15] : [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    NSColor *c = hot ? [NSColor controlAccentColor] : (dark ? [NSColor colorWithCalibratedWhite:0.85 alpha:1.0] : [NSColor secondaryLabelColor]);
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps};
    NSString *s = self.letters[i];
    NSSize sz = [s sizeWithAttributes:attrs];
    [s drawAtPoint:NSMakePoint((self.bounds.size.width-sz.width)/2, i*h + (h-sz.height)/2) withAttributes:attrs];
  }
}
@end

static NSDate *InstallDateForPath(NSString *path) {
  struct stat st;
  if (stat(path.fileSystemRepresentation, &st) != 0) return nil;
  time_t t = st.st_birthtime;
  if (t < 946684800) t = st.st_ctime;
  if (t < 946684800) t = st.st_mtime;
  if (t < 946684800) return nil;
  return [NSDate dateWithTimeIntervalSince1970:t];
}


@interface HoverTextButton : NSButton
@property (strong) NSColor *hoverColor;
@property (strong) NSColor *normalColor;
@end
@implementation HoverTextButton
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect) owner:self userInfo:nil];
  [self addTrackingArea:ta];
}
- (void)applyTitleColor:(NSColor *)color {
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentCenter;
  self.attributedTitle = [[NSAttributedString alloc] initWithString:self.title attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: ps}];
}
- (void)mouseEntered:(NSEvent *)e { [self applyTitleColor:self.hoverColor ?: [NSColor systemGreenColor]]; }
- (void)mouseExited:(NSEvent *)e { [self applyTitleColor:self.normalColor ?: [NSColor secondaryLabelColor]]; }
@end


@interface BarChartView : NSView
@property (strong) NSMutableArray<NSNumber *> *values;
@property (strong) NSColor *barColor;
@end
@implementation BarChartView
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _values = [NSMutableArray array]; _barColor = [NSColor systemBlueColor]; }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)addValue:(double)v {
  [self.values addObject:@(MAX(0, MIN(100, v)))];
  while (self.values.count > 28) [self.values removeObjectAtIndex:0];
  [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
  NSInteger themeVal = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
  BOOL darkBg = (themeVal == 2) || (themeVal == 0 && [[[NSApp effectiveAppearance].name lowercaseString] containsString:@"dark"]);
  [[NSColor colorWithCalibratedWhite:(darkBg ? 0.20 : 0.985) alpha:1.0] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8] fill];
  if (!self.values.count) return;
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height - 10;
  NSInteger n = self.values.count;
  CGFloat gap = 2.0;
  CGFloat bw = MAX(2.0, (w - gap * (n + 1)) / MAX(n,1));
  for (NSInteger i = 0; i < n; i++) {
    double v = [self.values[i] doubleValue];
    CGFloat bh = MAX(2.0, h * v / 100.0);
    NSRect r = NSMakeRect(gap + i * (bw + gap), self.bounds.size.height - 4 - bh, bw, bh);
    [[self.barColor colorWithAlphaComponent:0.75] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:MIN(3,bw/2) yRadius:MIN(3,bw/2)] fill];
  }
}
@end

@interface MetricColumnView : NSView
@property (strong) NSString *metricKey;
@property (strong) NSColor *accent;
@property (strong) NSTextField *titleLabel;
@property (strong) NSTextField *valueLabel;
@property (strong) NSTextField *detailLabel;
@property (strong) BarChartView *bar;
@property (weak) id target;
@property SEL action;
@property BOOL persistentHighlight;
@end
@implementation MetricColumnView
- (instancetype)initWithFrame:(NSRect)frame title:(NSString *)title accent:(NSColor *)accent key:(NSString *)key target:(id)target action:(SEL)action {
  if ((self = [super initWithFrame:frame])) {
    _metricKey = key; _accent = accent; _target = target; _action = action;
    self.wantsLayer = YES;
    self.identifier = @"MetricCard";
    NSInteger themeVal = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
    BOOL dark = (themeVal == 2) || (themeVal == 0 && [[[NSApp effectiveAppearance].name lowercaseString] containsString:@"dark"]);
    self.layer.backgroundColor = (dark ? [NSColor colorWithCalibratedWhite:0.13 alpha:1.0] : [NSColor whiteColor]).CGColor;
    self.layer.cornerRadius = 14;
    self.layer.borderWidth = 1;
    self.layer.borderColor = (dark ? [NSColor colorWithCalibratedWhite:1.0 alpha:0.14] : [NSColor colorWithCalibratedWhite:0.93 alpha:1.0]).CGColor;
    CGFloat w = frame.size.width;
    _titleLabel = [NSTextField labelWithString:title];
    _titleLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    _titleLabel.textColor = [NSColor secondaryLabelColor];
    _titleLabel.frame = NSMakeRect(12, frame.size.height - 30, w - 24, 18);
    [self addSubview:_titleLabel];
    _valueLabel = [NSTextField labelWithString:@"--"];
    _valueLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightBold];
    _valueLabel.textColor = accent;
    _valueLabel.frame = NSMakeRect(12, frame.size.height - 64, w - 24, 28);
    [self addSubview:_valueLabel];
    _detailLabel = [NSTextField labelWithString:@""];
    _detailLabel.font = [NSFont systemFontOfSize:9.5];
    _detailLabel.textColor = [NSColor secondaryLabelColor];
    _detailLabel.maximumNumberOfLines = 3;
    _detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _detailLabel.usesSingleLineMode = NO;
    _detailLabel.cell.wraps = YES;
    _detailLabel.frame = NSMakeRect(12, 14, w - 24, 48);
    [self addSubview:_detailLabel];
    _bar = [[BarChartView alloc] initWithFrame:NSMakeRect(10, 70, w - 20, frame.size.height - 150)];
    _bar.barColor = accent;
    [self addSubview:_bar];
  }
  return self;
}
- (void)setTitleText:(NSString *)title { self.titleLabel.stringValue = title; }
- (void)setValueFontSize:(CGFloat)size { self.valueLabel.font = [NSFont systemFontOfSize:size weight:NSFontWeightBold]; }
- (void)setValueText:(NSString *)value detail:(NSString *)detail bar:(double)barVal {
  self.valueLabel.stringValue = value;
  self.detailLabel.stringValue = detail;
  [self.bar addValue:barVal];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect) owner:self userInfo:nil];
  [self addTrackingArea:ta];
}
- (void)refreshBorderForHover:(BOOL)hover {
  self.wantsLayer = YES;
  if (hover || self.persistentHighlight) {
    self.layer.borderWidth = 2;
    self.layer.borderColor = self.accent.CGColor;
  } else {
    self.layer.borderWidth = 1;
    self.layer.borderColor = [NSColor colorWithCalibratedWhite:0.93 alpha:1.0].CGColor;
  }
}
- (void)mouseEntered:(NSEvent *)e {
  [self refreshBorderForHover:YES];
  [[NSCursor pointingHandCursor] set];
}
- (void)mouseExited:(NSEvent *)e {
  [self refreshBorderForHover:NO];
  [[NSCursor arrowCursor] set];
}
- (void)mouseDown:(NSEvent *)e {
  if (self.target && self.action) [self.target performSelector:self.action withObject:self.metricKey];
}
@end


@interface SidebarToggleButton : NSButton
@property BOOL collapsedStyle;
@end
@implementation SidebarToggleButton
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.bordered = NO;
    self.imagePosition = NSImageOnly;
    self.image = [NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:@"侧边栏"];
    self.contentTintColor = [NSColor whiteColor];
    self.toolTip = @"收起 / 展开侧边栏";
    self.wantsLayer = YES;
    self.layer.cornerRadius = 10;
  }
  return self;
}
- (void)drawRect:(NSRect)dirtyRect {
  NSArray *colors = self.collapsedStyle ? @[[NSColor systemGreenColor], [NSColor systemTealColor]] : @[[NSColor systemPinkColor], [NSColor systemOrangeColor]];
  NSGradient *g = [[NSGradient alloc] initWithColors:colors];
  [g drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] angle:-45];
  [super drawRect:dirtyRect];
}
@end


@interface DiskSegmentBar : NSView
@property (strong) NSArray<NSDictionary *> *segments;
@end
@implementation DiskSegmentBar
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) self.segments = @[];
  return self;
}
- (void)drawRect:(NSRect)dirtyRect {
  NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
  [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] setFill]; [bg fill];
  double total = 0;
  for (NSDictionary *d in self.segments) total += [d[@"size"] doubleValue];
  if (total <= 0) return;
  [bg addClip];
  CGFloat x = 0;
  for (NSDictionary *d in self.segments) {
    CGFloat w = self.bounds.size.width * [d[@"size"] doubleValue] / total;
    NSColor *c = d[@"color"] ?: [NSColor systemGrayColor];
    [c setFill];
    NSRectFill(NSMakeRect(x, 0, MAX(1, w - 1), self.bounds.size.height));
    x += w;
  }
}
@end


static NSCache *DiskThumbnailCache(void) {
  static NSCache *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 80; });
  return cache;
}

static NSImage *DiskThumbnailForPath(NSString *path) {
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (!src) return nil;
  NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                         (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                         (id)kCGImageSourceThumbnailMaxPixelSize: @1600};
  CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
  CFRelease(src);
  if (!cg) return nil;
  NSImage *img = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(120, 100)];
  CGImageRelease(cg);
  return img;
}


@interface NoHitTextField : NSTextField
@end
@implementation NoHitTextField
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface DiskGalleryItem : NSCollectionViewItem
@property (strong) NSImageView *thumbView;
@property (strong) NSTextField *nameLabel;
@property (strong) NSDictionary *file;
@property (weak) id owner;
@end
@implementation DiskGalleryItem
- (void)loadView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
  v.wantsLayer = YES;
  v.layer.cornerRadius = 10;
  v.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.96 alpha:1.0].CGColor;
  self.thumbView = [[NSImageView alloc] initWithFrame:NSMakeRect(5, 5, 190, 190)];
  self.thumbView.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.thumbView.imageAlignment = NSImageAlignCenter;
  self.thumbView.wantsLayer = YES;
  self.thumbView.layer.cornerRadius = 7;
  self.thumbView.layer.masksToBounds = YES;
  [v addSubview:self.thumbView];
  self.nameLabel = [[NoHitTextField alloc] initWithFrame:NSMakeRect(12, 12, 176, 34)];
  self.nameLabel.bezeled = NO; self.nameLabel.editable = NO; self.nameLabel.selectable = NO;
  self.nameLabel.drawsBackground = NO;
  self.nameLabel.alignment = NSTextAlignmentCenter;
  self.nameLabel.maximumNumberOfLines = 2;
  self.nameLabel.wantsLayer = YES;
  self.nameLabel.layer.cornerRadius = 6;
  self.nameLabel.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.42].CGColor;
  self.nameLabel.textColor = [NSColor whiteColor];
  self.nameLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
  [v addSubview:self.nameLabel];
  NSClickGestureRecognizer *single = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(cellClicked:)];
  single.numberOfClicksRequired = 1;
  [v addGestureRecognizer:single];
  NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(cellDoubleClicked:)];
  dbl.numberOfClicksRequired = 2;
  [v addGestureRecognizer:dbl];
  self.view = v;
}
- (void)cellClicked:(id)sender {
  if ([self.owner respondsToSelector:@selector(galleryItemClicked:)]) [self.owner performSelector:@selector(galleryItemClicked:) withObject:self];
}
- (void)cellDoubleClicked:(id)sender {
  if ([self.owner respondsToSelector:@selector(galleryItemDoubleClicked:)]) [self.owner performSelector:@selector(galleryItemDoubleClicked:) withObject:self];
}
- (void)setSelected:(BOOL)selected {
  [super setSelected:selected];
  self.view.layer.borderWidth = selected ? 3 : 0;
  self.view.layer.borderColor = [NSColor controlAccentColor].CGColor;
}
- (void)setFile:(NSDictionary *)file {
  CGFloat w = MAX(100, self.view.bounds.size.width), h = MAX(100, self.view.bounds.size.height);
  BOOL browser = [file[@"browser"] boolValue];
  BOOL isDir = [file[@"isDir"] boolValue];
  if (browser) {
    self.thumbView.frame = NSMakeRect(8, 8, MAX(20, w - 16), MAX(20, h - 16));
    if (isDir) {
      self.nameLabel.hidden = NO;
      self.nameLabel.frame = NSMakeRect(12, 12, MAX(20, w - 24), 34);
      NSInteger cnt = [file[@"count"] integerValue];
      self.nameLabel.stringValue = cnt > 0 ? [NSString stringWithFormat:@"%@\n%ld 个项目", file[@"name"] ?: @"", (long)cnt] : (file[@"name"] ?: @"");
    } else {
      self.nameLabel.hidden = YES;
    }
  } else {
    self.thumbView.frame = NSMakeRect(6, 6, MAX(20, w - 12), MAX(20, h - 12));
    self.nameLabel.hidden = YES;
  }
  self.view.toolTip = file[@"name"];
  _file = file;
  NSString *path = file[@"path"];
  NSImage *cached = [DiskThumbnailCache() objectForKey:path];
  if (cached) { self.thumbView.image = cached; return; }
  self.thumbView.image = [[NSWorkspace sharedWorkspace] iconForFile:path ?: @"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"];
  __weak typeof(self) weakSelf = self;
  NSString *assetID = file[@"assetID"];
  if (assetID.length) {
    NSImage *cached = [DiskThumbnailCache() objectForKey:[@"asset:" stringByAppendingString:assetID]];
    if (cached) { self.thumbView.image = cached; return; }
    PHFetchResult *fr = [PHAsset fetchAssetsWithLocalIdentifiers:@[assetID] options:nil];
    PHAsset *asset = fr.firstObject;
    if (asset) {
      PHImageRequestOptions *opt = [[PHImageRequestOptions alloc] init];
      opt.networkAccessAllowed = YES;
      opt.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
      opt.resizeMode = PHImageRequestOptionsResizeModeFast;
      [[PHImageManager defaultManager] requestImageForAsset:asset targetSize:CGSizeMake(800, 800) contentMode:PHImageContentModeAspectFit options:opt resultHandler:^(NSImage *result, NSDictionary *info) {
        if (!result) return;
        [DiskThumbnailCache() setObject:result forKey:[@"asset:" stringByAppendingString:assetID]];
        dispatch_async(dispatch_get_main_queue(), ^{
          if ([weakSelf.file[@"assetID"] isEqualToString:assetID]) weakSelf.thumbView.image = result;
        });
      }];
    }
    return;
  }
  if ([file[@"kind"] isEqualToString:@"图片"]) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSImage *img = DiskThumbnailForPath(path);
      if (!img) return;
      [DiskThumbnailCache() setObject:img forKey:path];
      dispatch_async(dispatch_get_main_queue(), ^{
        if ([weakSelf.file[@"path"] isEqualToString:path]) weakSelf.thumbView.image = img;
      });
    });
  } else if ([file[@"kind"] isEqualToString:@"视频"]) {
    NSURL *url = [NSURL fileURLWithPath:path];
    QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:url size:CGSizeMake(800, 800) scale:2 representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    [[QLThumbnailGenerator sharedGenerator] generateBestRepresentationForRequest:req completionHandler:^(QLThumbnailRepresentation *rep, NSError *error) {
      if (!rep.CGImage) return;
      NSImage *img = [[NSImage alloc] initWithCGImage:rep.CGImage size:NSMakeSize(800, 800)];
      if (!img) return;
      [DiskThumbnailCache() setObject:img forKey:path];
      dispatch_async(dispatch_get_main_queue(), ^{
        if ([weakSelf.file[@"path"] isEqualToString:path]) weakSelf.thumbView.image = img;
      });
    }];
  }
}
@end


@interface DiskJustifiedLayout : NSCollectionViewLayout
@property CGFloat contentWidth;
@property CGFloat targetHeight;
@property CGFloat spacing;
@property (strong) NSArray<NSNumber *> *aspects;
@property (strong) NSMutableArray<NSCollectionViewLayoutAttributes *> *attrs;
@property CGFloat contentHeight;
@end
@implementation DiskJustifiedLayout
- (instancetype)init {
  if ((self = [super init])) { _contentWidth = 640; _targetHeight = 200; _spacing = 10; _aspects = @[]; _attrs = [NSMutableArray array]; }
  return self;
}
- (void)prepareLayout {
  [super prepareLayout];
  [self.attrs removeAllObjects];
  NSInteger count = [self.collectionView numberOfItemsInSection:0];
  if (count <= 0) { self.contentHeight = 0; return; }
  CGFloat x = 0, y = 0, rowAspect = 0;
  NSInteger rowStart = 0, rowCount = 0;
  for (NSInteger i = 0; i < count; i++) {
    double aspect = 1.0;
    if (i < (NSInteger)self.aspects.count) aspect = MAX(0.35, MIN(3.2, self.aspects[i].doubleValue));
    rowAspect += aspect;
    rowCount++;
    CGFloat rowWidth = rowAspect * self.targetHeight + self.spacing * (rowCount - 1);
    if (rowWidth >= self.contentWidth || i == count - 1) {
      CGFloat h = (self.contentWidth - self.spacing * (rowCount - 1)) / MAX(0.1, rowAspect);
      h = MAX(90, MIN(360, h));
      x = 0;
      for (NSInteger j = rowStart; j <= i; j++) {
        double a = (j < (NSInteger)self.aspects.count) ? self.aspects[j].doubleValue : 1.0;
        a = MAX(0.35, MIN(3.2, a));
        CGFloat w = h * a;
        NSIndexPath *ip = [NSIndexPath indexPathForItem:j inSection:0];
        NSCollectionViewLayoutAttributes *attr = [[NSCollectionViewLayoutAttributes alloc] init];
        attr.indexPath = ip;
        attr.frame = NSMakeRect(x, y, w, h);
        [self.attrs addObject:attr];
        x += w + self.spacing;
      }
      y += h + self.spacing;
      rowStart = i + 1; rowCount = 0; rowAspect = 0;
    }
  }
  self.contentHeight = MAX(0, y - self.spacing);
}
- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.item < (NSInteger)self.attrs.count) return self.attrs[indexPath.item];
  return nil;
}
- (NSArray<NSCollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(NSRect)rect {
  NSMutableArray *out = [NSMutableArray array];
  for (NSCollectionViewLayoutAttributes *a in self.attrs) if (NSIntersectsRect(a.frame, rect)) [out addObject:a];
  return out;
}
- (NSSize)collectionViewContentSize { return NSMakeSize(self.contentWidth, self.contentHeight); }
@end


@interface QuickBarView : NSView
@property double value;
@property (strong) NSColor *barColor;
@end
@implementation QuickBarView
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _value = 0; _barColor = [NSColor systemOrangeColor]; }
  return self;
}
- (void)drawRect:(NSRect)dirtyRect {
  NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4];
  [[NSColor quaternaryLabelColor] setFill]; [bg fill];
  CGFloat w = self.bounds.size.width * MAX(0, MIN(100, self.value)) / 100.0;
  if (w <= 0) return;
  NSRect r = NSMakeRect(0, 0, w, self.bounds.size.height);
  NSBezierPath *fg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4 yRadius:4];
  [self.barColor setFill]; [fg fill];
}
- (void)setValue:(double)value { _value = value; [self setNeedsDisplay:YES]; }
@end


@interface DockHoverTipPanel : NSPanel
@end
@implementation DockHoverTipPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static DockHoverTipPanel *gHoverTipPanel = nil;
static NSTextField *gHoverTipTitle = nil;
static NSTextField *gHoverTipDetail = nil;

static void ShowDockHoverTip(NSString *title, NSString *detail) {
  if (!title.length) return;
  if (!gHoverTipPanel) {
    gHoverTipPanel = [[DockHoverTipPanel alloc] initWithContentRect:NSMakeRect(0,0,300,70) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    gHoverTipPanel.level = NSFloatingWindowLevel;
    gHoverTipPanel.opaque = NO;
    gHoverTipPanel.backgroundColor = [NSColor clearColor];
    gHoverTipPanel.hasShadow = YES;
    gHoverTipPanel.ignoresMouseEvents = YES;
    gHoverTipPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *bg = [[NSView alloc] initWithFrame:NSMakeRect(0,0,300,70)];
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 10;
    bg.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.98 alpha:0.97].CGColor;
    bg.layer.borderWidth = 1;
    bg.layer.borderColor = [[NSColor separatorColor] colorWithAlphaComponent:0.5].CGColor;
    [gHoverTipPanel.contentView addSubview:bg];
    gHoverTipTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(12,38,276,20)];
    gHoverTipTitle.editable = NO; gHoverTipTitle.bordered = NO; gHoverTipTitle.drawsBackground = NO;
    gHoverTipTitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    gHoverTipTitle.textColor = [NSColor labelColor];
    [bg addSubview:gHoverTipTitle];
    gHoverTipDetail = [[NSTextField alloc] initWithFrame:NSMakeRect(12,12,276,22)];
    gHoverTipDetail.editable = NO; gHoverTipDetail.bordered = NO; gHoverTipDetail.drawsBackground = NO;
    gHoverTipDetail.font = [NSFont systemFontOfSize:10.5];
    gHoverTipDetail.textColor = [NSColor secondaryLabelColor];
    gHoverTipDetail.maximumNumberOfLines = 2;
    gHoverTipDetail.lineBreakMode = NSLineBreakByWordWrapping;
    [bg addSubview:gHoverTipDetail];
  }
  gHoverTipTitle.stringValue = title;
  gHoverTipDetail.stringValue = detail ?: @"";
  NSPoint mouse = [NSEvent mouseLocation];
  NSScreen *scr = [NSScreen mainScreen];
  NSRect vf = scr.visibleFrame;
  CGFloat w = 300, h = detail.length > 34 ? 70 : 56;
  CGFloat x = mouse.x + 14;
  CGFloat y = mouse.y - h - 8;
  if (x + w > NSMaxX(vf)) x = mouse.x - w - 14;
  if (y < NSMinY(vf)) y = mouse.y + 14;
  [gHoverTipPanel setFrame:NSMakeRect(x, y, w, h) display:YES];
  [gHoverTipPanel orderFrontRegardless];
}

static void HideDockHoverTip(void) {
  [gHoverTipPanel orderOut:nil];
}

@interface ColorHoverButton : NSButton
@property (strong) NSColor *hoverColor;
@property (strong) NSString *hoverTitle, *hoverDetail;
@property BOOL persistentHighlight;
@end
@implementation ColorHoverButton
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect) owner:self userInfo:nil];
  [self addTrackingArea:ta];
}
- (void)applyColor:(NSColor *)color textColor:(NSColor *)text {
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentCenter;
  self.attributedTitle = [[NSAttributedString alloc] initWithString:self.title attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium], NSForegroundColorAttributeName: text, NSParagraphStyleAttributeName: ps}];
  self.wantsLayer = YES;
  self.layer.backgroundColor = color.CGColor;
  self.layer.cornerRadius = 9;
  self.layer.borderWidth = 1;
  self.layer.borderColor = [[NSColor whiteColor] colorWithAlphaComponent:0.5].CGColor;
  self.layer.shadowColor = [NSColor blackColor].CGColor;
  self.layer.shadowOpacity = 0.0;
  self.layer.shadowRadius = 3;
  self.layer.shadowOffset = CGSizeMake(0, -2);
}
- (void)mouseDown:(NSEvent *)e {
  self.layer.shadowOffset = CGSizeMake(0, 0);
  self.layer.shadowOpacity = 0.0;
  [super mouseDown:e];
  self.layer.shadowOffset = CGSizeMake(0, -2);
  self.layer.shadowOpacity = 0.0;
}
- (void)mouseEntered:(NSEvent *)e {
  [self applyColor:self.hoverColor ?: [NSColor systemBlueColor] textColor:[NSColor whiteColor]];
  if (self.hoverTitle.length) ShowDockHoverTip(self.hoverTitle, self.hoverDetail);
}
- (void)mouseExited:(NSEvent *)e {
  HideDockHoverTip();
  if (self.persistentHighlight) [self applyColor:self.hoverColor ?: [NSColor systemBlueColor] textColor:[NSColor whiteColor]];
  else [self applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
}
@end


@interface DiskTypeButton : NSButton
@property (strong) NSColor *segmentColor;
@property BOOL segmentSelected;
@end
@implementation DiskTypeButton
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds options:(NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect) owner:self userInfo:nil];
  [self addTrackingArea:ta];
}
- (void)applyLook:(BOOL)highlight {
  self.wantsLayer = YES;
  self.layer.cornerRadius = 6;
  NSColor *bg = highlight ? (self.segmentColor ?: [NSColor controlAccentColor]) : DLButtonBackground();
  NSColor *fg = highlight ? [NSColor whiteColor] : [NSColor labelColor];
  self.layer.backgroundColor = bg.CGColor;
  NSFontWeight weight = self.segmentSelected ? NSFontWeightSemibold : NSFontWeightMedium;
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init]; ps.alignment = NSTextAlignmentCenter;
  self.attributedTitle = [[NSAttributedString alloc] initWithString:self.title attributes:@{NSFontAttributeName: DLDisplayFont(12.5, YES), NSForegroundColorAttributeName: fg, NSParagraphStyleAttributeName: ps}];
}
- (void)mouseEntered:(NSEvent *)e { [self applyLook:YES]; }
- (void)mouseExited:(NSEvent *)e { [self applyLook:NO]; }
- (void)setSegmentSelected:(BOOL)sel { _segmentSelected = sel; [self applyLook:NO]; }
@end

@interface DiskTypeControl : NSView
@property NSInteger selectedSegment;
@property (weak) id target;
@property SEL action;
@end
@implementation DiskTypeControl {
  DiskTypeButton *_b0, *_b1, *_b2;
}
- (instancetype)initWithFrame:(NSRect)frame target:(id)target action:(SEL)action {
  if ((self = [super initWithFrame:frame])) {
    self.target = target; self.action = action; self.selectedSegment = -1;
    NSArray *titles = @[@"文件", @"图片", @"视频"];
    NSArray *colors = @[[NSColor systemBlueColor], [NSColor systemGreenColor], [NSColor systemYellowColor]];
    CGFloat w = frame.size.width / 3.0;
    NSMutableArray *bs = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
      DiskTypeButton *b = [[DiskTypeButton alloc] initWithFrame:NSMakeRect(i * w, 0, w - 2, frame.size.height)];
      b.title = titles[i]; b.segmentColor = colors[i]; b.bordered = NO; b.tag = i;
      b.target = self; b.action = @selector(clicked:);
      [b applyLook:NO];
      [self addSubview:b];
      [bs addObject:b];
    }
    _b0 = bs[0]; _b1 = bs[1]; _b2 = bs[2];
  }
  return self;
}
- (void)clicked:(DiskTypeButton *)b {
  self.selectedSegment = b.tag;
  if (self.target && self.action) [self.target performSelector:self.action withObject:self];
}
- (void)setSelectedSegment:(NSInteger)seg {
  _selectedSegment = seg;
  _b0.segmentSelected = (seg == 0);
  _b1.segmentSelected = (seg == 1);
  _b2.segmentSelected = (seg == 2);
}
@end


@interface ScopeColorControl : NSView
@property NSInteger selectedSegment;
@property (weak) id target;
@property SEL action;
@end
@implementation ScopeColorControl {
  DiskTypeButton *_b0, *_b1;
}
- (instancetype)initWithFrame:(NSRect)frame title0:(NSString *)t0 color0:(NSColor *)c0 title1:(NSString *)t1 color1:(NSColor *)c1 target:(id)target action:(SEL)action {
  if ((self = [super initWithFrame:frame])) {
    self.target = target; self.action = action; self.selectedSegment = 0;
    CGFloat w = frame.size.width / 2.0;
    _b0 = [[DiskTypeButton alloc] initWithFrame:NSMakeRect(0, 0, w - 2, frame.size.height)];
    _b0.title = t0; _b0.segmentColor = c0; _b0.bordered = NO; _b0.tag = 0;
    _b0.target = self; _b0.action = @selector(clicked:);
    [_b0 applyLook:NO]; [self addSubview:_b0];
    _b1 = [[DiskTypeButton alloc] initWithFrame:NSMakeRect(w, 0, w - 2, frame.size.height)];
    _b1.title = t1; _b1.segmentColor = c1; _b1.bordered = NO; _b1.tag = 1;
    _b1.target = self; _b1.action = @selector(clicked:);
    [_b1 applyLook:NO]; [self addSubview:_b1];
    self.selectedSegment = 0;
  }
  return self;
}
- (void)clicked:(DiskTypeButton *)b {
  self.selectedSegment = b.tag;
  if (self.target && self.action) [self.target performSelector:self.action withObject:self];
}
- (void)setSelectedSegment:(NSInteger)seg {
  _selectedSegment = seg;
  _b0.segmentSelected = (seg == 0);
  _b1.segmentSelected = (seg == 1);
}
@end


@interface AIDropView : NSView
@property (weak) id dropTarget;
@property SEL dropAction;
@end
@implementation AIDropView
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    [self registerForDraggedTypes:@[NSFilenamesPboardType, NSPasteboardTypeFileURL]];
  }
  return self;
}
- (NSArray<NSURL *> *)draggedURLs:(id<NSDraggingInfo>)info {
  NSPasteboard *pb = info.draggingPasteboard;
  NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]] options:nil];
  if (!urls.count) {
    NSArray *paths = [pb propertyListForType:NSFilenamesPboardType];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *p in paths) [arr addObject:[NSURL fileURLWithPath:p]];
    urls = arr;
  }
  NSMutableArray *ok = [NSMutableArray array];
  for (NSURL *u in urls) {
    NSString *ext = u.pathExtension.lowercaseString;
    if ([@[@"json", @"csv", @"txt"] containsObject:ext]) [ok addObject:u];
  }
  return ok;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  if ([self draggedURLs:sender].count) {
    self.layer.borderWidth = 2;
    self.layer.borderColor = [NSColor controlAccentColor].CGColor;
    return NSDragOperationCopy;
  }
  return NSDragOperationNone;
}
- (void)draggingExited:(id<NSDraggingInfo>)sender {
  self.layer.borderWidth = 0;
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return [self draggedURLs:sender].count > 0; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  self.layer.borderWidth = 0;
  NSArray *urls = [self draggedURLs:sender];
  if (urls.count && self.dropTarget && self.dropAction) {
    [self.dropTarget performSelector:self.dropAction withObject:urls];
    return YES;
  }
  return NO;
}
@end


@interface FanTitleView : NSView
@end
@implementation FanTitleView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
  NSString *text = @"DockLaunchers";
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  NSInteger n = (NSInteger)text.length;
  if (n == 0) return;
  CGFloat step = (w - 4) / n;
  CGFloat fontSize = MIN(15.5, step * 1.42);
  CGFloat amp = 20.0;
  for (NSInteger i = 0; i < n; i++) {
    NSString *ch = [text substringWithRange:NSMakeRange(i, 1)];
    CGFloat t = n > 1 ? (CGFloat)i / (CGFloat)(n - 1) : 0.5;
    CGFloat x = 2 + i * step + step * 0.5;
    CGFloat y = h * 0.12 + amp * (1.0 - pow((t - 0.5) * 2.0, 2.0));
    CGFloat angle = (t - 0.5) * 0.90;
    NSColor *color = [NSColor colorWithCalibratedHue:(CGFloat)i / (CGFloat)n saturation:0.72 brightness:0.92 alpha:1.0];
    NSFont *font = [NSFont systemFontOfSize:fontSize weight:NSFontWeightBold];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:ch attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: ps}];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *tf = [NSAffineTransform transform];
    [tf translateXBy:x yBy:y];
    [tf rotateByRadians:angle];
    [tf concat];
    [as drawAtPoint:NSMakePoint(-step / 2.0, 0)];
    [NSGraphicsContext restoreGraphicsState];
  }
}
@end


@interface CompressDropView : NSView
@property (weak) id dropTarget;
@property SEL dropAction;
@end
@implementation CompressDropView
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 12;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [[NSColor separatorColor] colorWithAlphaComponent:0.5].CGColor;
    [self registerForDraggedTypes:@[NSFilenamesPboardType, NSPasteboardTypeFileURL]];
  }
  return self;
}
- (NSArray<NSURL *> *)urls:(id<NSDraggingInfo>)info {
  NSArray *urls = [info.draggingPasteboard readObjectsForClasses:@[[NSURL class]] options:nil];
  if (!urls.count) {
    NSArray *paths = [info.draggingPasteboard propertyListForType:NSFilenamesPboardType];
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *p in paths) [a addObject:[NSURL fileURLWithPath:p]];
    urls = a;
  }
  return urls ?: @[];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  self.layer.borderColor = [NSColor controlAccentColor].CGColor;
  self.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.06].CGColor;
  return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)sender {
  self.layer.borderColor = [[NSColor separatorColor] colorWithAlphaComponent:0.5].CGColor;
  self.layer.backgroundColor = [NSColor clearColor].CGColor;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  self.layer.borderColor = [[NSColor separatorColor] colorWithAlphaComponent:0.5].CGColor;
  self.layer.backgroundColor = [NSColor clearColor].CGColor;
  NSArray *urls = [self urls:sender];
  if (urls.count && self.dropTarget && self.dropAction) {
    [self.dropTarget performSelector:self.dropAction withObject:urls];
    return YES;
  }
  return NO;
}
@end

@implementation Controller

- (NSImage *)characterImage:(CGFloat)size {
  NSString *p = [[NSBundle mainBundle] pathForResource:@"AppIcon2" ofType:@"icns"];
  NSImage *img = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
  if (!img) img = [NSImage imageNamed:NSImageNameApplicationIcon];
  if (!img) img = [NSImage imageNamed:NSImageNameApplicationIcon];
  img.size = NSMakeSize(size, size);
  img.template = NO;
  return img;
}

- (NSTextField *)label:(NSString *)s size:(CGFloat)sz bold:(BOOL)b color:(NSColor *)c {
  NSTextField *l = [NSTextField labelWithString:s];
  l.font = DLDisplayFont(sz, b);
  if (c) l.textColor = c;
  return l;
}

- (void)runSelfTest {
  __block int failed = 0;
  void (^check)(BOOL, NSString *) = ^(BOOL ok, NSString *name) {
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", name.UTF8String);
    if (!ok) failed = 1;
  };
  for (NSInteger i = 0; i < 6; i++) check([self viewForSection:i] != nil, [NSString stringWithFormat:@"section %ld", (long)i]);
  [self refreshGroups];
  check(self.groups.count >= 7, @"groups loaded");
  self.groupsSearch.stringValue = @"工具";
  [self groupsSearchChanged:nil];
  check(self.groupsFiltered.count == 1, @"exact group search");
  self.groupsSearch.stringValue = @"";
  self.groupsFilter = nil;
  [self refreshGroups];
  NSDictionary *preset = [self aiPresetForName:@"Anthropic Claude"];
  check([preset[@"url"] containsString:@"anthropic"], @"AI preset exact name");
  preset = [self aiPresetForName:@"千问"];
  check([preset[@"name"] containsString:@"通义千问"], @"AI preset alias");
  [self rebuildAIDisplay];
  check(self.aiVisibleEntries.count <= 2, @"AI two rows per page");
  check([self isProtectedUserPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]], @"protected path filter");
  check([[self aiCategoryForEntry:@{@"name": @"Kling", @"note": @"视频生成"}] isEqualToString:@"视频"], @"AI category inference");
  fprintf(stderr, failed ? "SELFTEST FAILED\n" : "SELFTEST OK\n");
  exit(failed);
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  // 单实例：避免重复 Dock 图标/菜单栏图标
  NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
  pid_t me = [[NSProcessInfo processInfo] processIdentifier];
  if (!getenv("DOCKLAUNCHERS_CENTER_SELFTEST")) {
    for (NSRunningApplication *ra in [NSRunningApplication runningApplicationsWithBundleIdentifier:bid]) {
      if (ra.processIdentifier != me) {
        [ra activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        exit(0);
      }
    }
  }
  if (getenv("DOCKLAUNCHERS_CENTER_SELFTEST")) {
    [self runSelfTest];
    return;
  }
  [self pruneStaleDockEntries];
  NSUserDefaults *ud0 = [NSUserDefaults standardUserDefaults];
  if (![ud0 boolForKey:@"centerMenuTextInit"]) {
    [ud0 setBool:YES forKey:@"centerMenuText"];
    [ud0 setBool:YES forKey:@"centerMenuTextInit"];
    [ud0 synchronize];
  }
  self.sampleSeconds = 2;
  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  self.statusItem.button.image = [self characterImage:18];
  self.statusItem.button.imagePosition = NSImageLeft;
  self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
  self.statusItem.button.title = @"";
  self.statusItem.button.target = self;
  self.statusItem.button.action = @selector(togglePopover:);
  NSNotificationCenter *wsnc = [[NSWorkspace sharedWorkspace] notificationCenter];
  for (NSString *n in @[NSWorkspaceDidMountNotification, NSWorkspaceDidUnmountNotification, NSWorkspaceDidRenameVolumeNotification]) {
    [wsnc addObserver:self selector:@selector(volumesChanged:) name:n object:nil];
  }
  [self applyThemeFromDefaults];
  [self setupMainMenu];
  [self installTranslationHotKey];
  [self buildWindow];
  [self buildPopover];
  [self applyThemeFromDefaults];
  self.diskKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
    if (e.keyCode == 49 && self.section == 2 && self.diskCollectionScroll.hidden == NO) {
      [self previewSelectedDiskFile];
      return nil;
    }
    return e;
  }];
  // 确保控制台自己出现在 Dock，并刷新图标缓存（先删后加）
  if (!getenv("DOCKLAUNCHERS_CENTER_SKIP_DOCK")) {
    NSString *selfPath = [[NSBundle mainBundle] bundlePath];
    [self removeDockEntry:selfPath];
    [self addDockEntry:selfPath label:@"DockLaunchers控制台"];
    [self ensureGroupDockEntries];
    [self killDock];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE_MULTI")) {
    NSString *arg = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE_MULTI")];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *x in [arg componentsSeparatedByString:@"|"]) if (x.length) [names addObject:x];
    [self deleteGroupNames:names];
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) {
    [self deleteGroupNames:@[[NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")]]];
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_CUSTOM_APPLY")) {
    NSString *arg = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_CUSTOM_APPLY")];
    NSArray *parts = [arg componentsSeparatedByString:@"|"];
    if (parts.count == 2) {
      self.dialogCustomIcon = parts[1];
      self.dialogSelectedBuiltin = -1;
      BOOL ok = [self applyIconToApp:parts[0]];
      fprintf(stderr, "CUSTOM_APPLY ok=%d\n", ok);
    }
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_MEMORY")) {
    NSString *dir = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_MEMORY")];
    [self rememberSaveDir:dir forApps:@[@{@"bid": @"com.test.saved", @"name": @"测试保存"}]];
    NSArray *files = [self userSavedFilesForApps:@[@{@"name": @"NeteaseMusic", @"label": @"网易云音乐", @"bid": @"com.netease.163music", @"path": @"/Applications/NeteaseMusic.app"}]];
    fprintf(stderr, "MEMORY count=%ld\n", (long)files.count);
    for (NSDictionary *d in files) fprintf(stderr, "MFILE %s\n", [d[@"path"] UTF8String]);
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DETECT")) {
    NSArray *files = [self userSavedFilesForApps:@[@{@"name": @"NeteaseMusic", @"label": @"网易云音乐", @"bid": @"com.netease.163music", @"path": @"/Applications/NeteaseMusic.app"}]];
    fprintf(stderr, "DETECT count=%ld\n", (long)files.count);
    for (NSDictionary *d in files) fprintf(stderr, "FILE %s\n", [d[@"path"] UTF8String]);
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_PICK")) {
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *p in @[@"/tmp/userfiles_code.m", @"/tmp/dock.plist", @"/tmp/icon_preview4.png"]) {
      if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
        [files addObject:@{@"path": p, @"name": [p lastPathComponent], @"type": [p pathExtension].uppercaseString, @"size": attr[NSFileSize] ?: @0, @"app": @"测试应用"}];
      }
    }
    [self pickUserFilesToDelete:files apps:@[]];
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_RENAME")) {
    NSString *arg = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_RENAME")];
    NSArray *parts = [arg componentsSeparatedByString:@"|"];
    if (parts.count == 2) {
      NSString *err = nil;
      BOOL ok = [self renameGroupFrom:parts[0] to:parts[1] error:&err];
      fprintf(stderr, "RENAME_TEST ok=%d err=%s\n", ok, [(err ?: @"") UTF8String]);
    }
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_EDIT")) {
    [self showSection:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSButton *b = [[NSButton alloc] init];
      b.tag = 0;
      [self editGroupRow:b];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_GROUP_SEARCH")) {
    [self showSection:1];
    [self showWindow:nil];
    self.groupsSearch.stringValue = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_GROUP_SEARCH")];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self groupsSearchChanged:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DISK")) {
    [self showSection:3];
    [self showWindow:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self refreshDiskAnalysis];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_POPOVER")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self togglePopover:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_POPOVER_TOOLS")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      self.quickTabs.selectedSegment = 3;
      [self quickTabChanged:nil];
      [self togglePopover:nil];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.popover.isShown && self.statusItem.button) {
          [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
        }
      });
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_RENDER_TOOLS")) {
    NSView *page = self.quickToolsPage;
    page.wantsLayer = YES;
    page.layer.backgroundColor = [NSColor whiteColor].CGColor;
    [page layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [page bitmapImageRepForCachingDisplayInRect:page.bounds];
    [page cacheDisplayInRect:page.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:@"/tmp/tools_page.png" atomically:YES];
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_HOVER")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self showTranslationWindow:nil];
      ShowDockHoverTip(@"选择文档", @"支持 txt / md / pdf / docx / 图片");
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_CONFIRM")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self confirmTranslateText:@"Hello world. This is a test of the confirmation dialog." origin:@"选中内容"];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_SHORTCUT")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self showTranslationWindow:nil];
      [self openShortcutSettings:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_TRANSLATE")) {
    [self showTranslationWindow:nil];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_TRANSLATE_RUN")) {
    [self showTranslationWindow:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      self.translationSourceView.string = @"Hello world. This is a translation test.";
      [self translationTranslate:nil];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      fprintf(stderr, "TRANSLATE_RESULT: %s\n", self.translationResultView.string.UTF8String ?: "");
      fprintf(stderr, "TRANSLATE_STATUS: %s\n", self.translationStatus.stringValue.UTF8String ?: "");
      exit(self.translationResultView.string.length ? 0 : 1);
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_COMPRESS")) {
    [self showCompressWindow:nil];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_SECTION")) {
    int sec = atoi(getenv("DOCKLAUNCHERS_CENTER_TEST_SECTION"));
    if (sec >= 0 && sec <= 5) [self showSection:sec];
    [self showWindow:nil];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_AI")) {
    [self showSection:2];
    [self showWindow:nil];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_REFRESH")) {
    [self showSection:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self refreshAllGroupsClicked:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_LETTER")) {
    [self showSection:2];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self letterIndexClicked:[NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_LETTER")]];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_ICON_MISSING")) {
    [self showSection:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self createGroup:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_CREATE_EMPTY")) {
    [self showSection:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self createGroup:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_CREATE")) {
    [self showSection:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self createGroup:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE_PROMPT")) {
    [self showSection:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self deleteGroupsClicked:nil];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_BACKUP")) {
    NSString *n = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_BACKUP")];
    [self backupGroupNames:@[n]];
    exit(0);
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_RESTORE")) {
    [self restoreGroupsClicked:nil];
    exit(0);
  }
  self.timer = [NSTimer scheduledTimerWithTimeInterval:self.sampleSeconds target:self selector:@selector(sample) userInfo:nil repeats:YES];
  [self sample];
  id autoSyncVal = [[NSUserDefaults standardUserDefaults] objectForKey:@"centerAutoSync"];
  BOOL autoSync = autoSyncVal ? [autoSyncVal boolValue] : YES;
  if (autoSync) [self startAutoSyncTimer];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"centerFileActivity"]) [self startActivityRecorder];
  [self showWindow:nil];
  if (getenv("DOCKLAUNCHERS_CENTER_SECTION")) {
    [self showSection:atoi(getenv("DOCKLAUNCHERS_CENTER_SECTION"))];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_SEARCH")) {
    [self showSection:4];
    self.uninstallSearch.stringValue = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_SEARCH")];
    [self reloadUninstallData];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_GROUP")) {
    [self showSection:4];
    self.uninstallScope = 1;
    self.uninstallScopeCtl.selectedSegment = 1;
    [self refreshUninstallGroupPopup];
    NSString *g = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_GROUP")];
    if ([self.uninstallGroupPopup itemWithTitle:g]) [self.uninstallGroupPopup selectItemWithTitle:g];
    [self reloadUninstallData];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_POPOVER")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self togglePopover:nil];
    });
  }
}

- (void)toggleSidebar:(id)sender {
  BOOL collapse = !self.sidebarCollapsed;
  self.sidebarCollapsed = collapse;
  __weak typeof(self) weakSelf = self;
  NSArray *nav = @[self.sideLive, self.sideGroups, self.sideAI, self.sideDisk, self.sideUninstall, self.sideSettings];
  NSArray *navTitles = @[@"实时数据", @"Dock 分组", @"AI 管理", @"磁盘分析", @"应用卸载", @"设置"];
  for (NSInteger i = 0; i < nav.count; i++) {
    NSButton *b = nav[i];
    if (collapse) {
      b.title = @"";
      b.imagePosition = NSImageOnly;
      b.alignment = NSTextAlignmentCenter;
      b.frame = NSMakeRect(4, 523 - i * 92.4, 36, 36);
    } else {
      b.title = navTitles[i];
      b.imagePosition = NSImageLeft;
      b.alignment = NSTextAlignmentLeft;
      b.frame = NSMakeRect(14, 521 - i * 92.4, 212, 40);
    }
  }
  if (collapse) {
    self.sidebarToggle.title = @"";
    self.sidebarToggle.image = [NSImage imageWithSystemSymbolName:@"sidebar.right" accessibilityDescription:@"展开侧边栏"];
    self.sidebarToggle.imagePosition = NSImageOnly;
    self.sidebarToggle.alignment = NSTextAlignmentCenter;
    self.sidebarToggle.persistentHighlight = YES;
    [self.sidebarToggle applyColor:[NSColor systemBrownColor] textColor:[NSColor whiteColor]];
  } else {
    for (NSView *v in self.sideView.subviews) v.hidden = NO;
    self.sidebarToggle.title = @"收起侧边栏";
    self.sidebarToggle.image = [NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:@"收起侧边栏"];
    self.sidebarToggle.imagePosition = NSImageLeft;
    self.sidebarToggle.alignment = NSTextAlignmentLeft;
    self.sidebarToggle.persistentHighlight = NO;
    [self.sidebarToggle applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
    ctx.duration = 0.22;
    NSRect win = weakSelf.window.contentView.bounds;
    weakSelf.sideView.animator.frame = NSMakeRect(0, 0, collapse ? 44 : 240, win.size.height);
    weakSelf.contentScroll.animator.frame = NSMakeRect(collapse ? 44 : 240, 0, win.size.width - (collapse ? 44 : 240), win.size.height);
    weakSelf.sidebarToggle.animator.frame = collapse ? NSMakeRect(6, 20, 32, 32) : NSMakeRect(14, 20, 212, 36);
  } completionHandler:^{
    if (collapse) {
      for (NSView *v in weakSelf.sideView.subviews) {
        if (![v isKindOfClass:[NSButton class]]) v.hidden = YES;
      }
    }
    [weakSelf layoutPageView:weakSelf.content.subviews.firstObject];
  }];
}

- (void)layoutCenterTitle {
  NSView *frameView = self.window.contentView.superview;
  if (!frameView || !self.centerTitleLabel) return;
  CGFloat w = frameView.bounds.size.width;
  CGFloat h = frameView.bounds.size.height;
  self.centerTitleLabel.frame = NSMakeRect((w - 440)/2.0, h - 30, 440, 24);
}
- (void)layoutPageView:(NSView *)v {
  if (!v) return;
  CGFloat aw = MAX(1, self.contentScroll.contentView.bounds.size.width);
  CGFloat ah = MAX(1, self.contentScroll.contentView.bounds.size.height);
  CGFloat zoom = self.uiZoom > 0 ? self.uiZoom : 1.0;
  // 以窗口宽度为主进行等比缩放：拉宽时整体数据同步放大，拉窄时缩小
  CGFloat scale = (aw / 750.0) * zoom;
  CGFloat w = 750.0 * scale, h = 660.0 * scale;
  CGFloat docW = MAX(aw, w + 24), docH = MAX(ah, h + 24);
  self.content.frame = NSMakeRect(0, 0, docW, docH);
  v.frame = NSMakeRect((docW - w) / 2.0, (docH - h) / 2.0, w, h);
  v.bounds = NSMakeRect(0, 0, 750, 660);
  CGFloat maxY = MAX(0, docH - self.contentScroll.contentView.bounds.size.height);
  [self.contentScroll.contentView scrollToPoint:NSMakePoint(0, maxY)];
  [self.contentScroll reflectScrolledClipView:self.contentScroll.contentView];
}

- (void)windowDidMove:(NSNotification *)notification {
  NSWindow *w = self.window;
  if (!w || w.isZoomed) return;
  NSRect vis = w.screen.visibleFrame;
  NSRect f = w.frame;
  CGFloat maxTop = NSMaxY(vis) - 2;
  if (NSMaxY(f) > maxTop) {
    f.origin.y = maxTop - f.size.height;
    if (f.origin.y < NSMinY(vis)) f.origin.y = NSMinY(vis);
    [w setFrame:f display:YES];
  }
}

- (void)windowDidResize:(NSNotification *)notification {
  [self layoutCenterTitle];
  [self layoutPageView:self.content.subviews.firstObject];
  [self updateDiskGalleryLayout];
}

static OSStatus TranslationHotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
  Controller *c = (__bridge Controller *)userData;
  EventHotKeyID hk = {0, 0};
  GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk);
  if (hk.id == 1) {
    [c beginScreenshotTranslation];
  } else if (hk.id == 2) [c translateSelectedText];
  else if (hk.id == 3) [c translateCurrentText];
  return noErr;
}

- (BOOL)registerHotKeyForAction:(NSInteger)action code:(UInt32)code modifiers:(UInt32)mods display:(NSString *)display {
  EventHotKeyRef old = action == 0 ? self.translationHotKey : (action == 1 ? self.selectionHotKey : self.translateHotKey);
  if (old) UnregisterEventHotKey(old);
  EventHotKeyID hid = {'DLTR', (UInt32)(action + 1)};
  EventHotKeyRef ref = NULL;
  OSStatus st = RegisterEventHotKey(code, mods, hid, GetApplicationEventTarget(), 0, &ref);
  if (st != noErr) return NO;
  if (action == 0) { self.translationHotKey = ref; self.shotKeyCode = code; self.shotModifiers = mods; self.shotShortcutDisplay = display; }
  else if (action == 1) { self.selectionHotKey = ref; self.selectionKeyCode = code; self.selectionModifiers = mods; self.selectionShortcutDisplay = display; }
  else { self.translateHotKey = ref; self.translateKeyCode = code; self.translateModifiers = mods; self.translateShortcutDisplay = display; }
  NSArray *kc = @[@"centerShotKeyCode", @"centerSelectKeyCode", @"centerTranslateKeyCode"];
  NSArray *km = @[@"centerShotModifiers", @"centerSelectModifiers", @"centerTranslateModifiers"];
  NSArray *kd = @[@"centerShotKeyDisplay", @"centerSelectKeyDisplay", @"centerTranslateKeyDisplay"];
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  [ud setInteger:code forKey:kc[action]];
  [ud setInteger:mods forKey:km[action]];
  [ud setObject:display forKey:kd[action]];
  [self refreshShortcutButtons];
  return YES;
}

- (void)installTranslationHotKey {
  EventTypeSpec es = {kEventClassKeyboard, kEventHotKeyPressed};
  InstallEventHandler(GetApplicationEventTarget(), TranslationHotKeyHandler, 1, &es, (__bridge void *)self, &_translationHotKeyHandler);
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  self.shotKeyCode = (UInt32)[ud integerForKey:@"centerShotKeyCode"];
  self.shotModifiers = (UInt32)[ud integerForKey:@"centerShotModifiers"];
  self.shotShortcutDisplay = [ud stringForKey:@"centerShotKeyDisplay"];
  if (!self.shotShortcutDisplay.length) { self.shotKeyCode = kVK_ANSI_T; self.shotModifiers = controlKey | optionKey; self.shotShortcutDisplay = @"⌃⌥T"; }
  self.selectionKeyCode = (UInt32)[ud integerForKey:@"centerSelectKeyCode"];
  self.selectionModifiers = (UInt32)[ud integerForKey:@"centerSelectModifiers"];
  self.selectionShortcutDisplay = [ud stringForKey:@"centerSelectKeyDisplay"];
  if (!self.selectionShortcutDisplay.length) { self.selectionKeyCode = kVK_ANSI_D; self.selectionModifiers = controlKey | optionKey; self.selectionShortcutDisplay = @"⌃⌥D"; }
  self.translateKeyCode = (UInt32)[ud integerForKey:@"centerTranslateKeyCode"];
  self.translateModifiers = (UInt32)[ud integerForKey:@"centerTranslateModifiers"];
  self.translateShortcutDisplay = [ud stringForKey:@"centerTranslateKeyDisplay"];
  if (!self.translateShortcutDisplay.length) { self.translateKeyCode = kVK_Return; self.translateModifiers = controlKey | optionKey; self.translateShortcutDisplay = @"⌃⌥↩"; }
  [self registerHotKeyForAction:0 code:self.shotKeyCode modifiers:self.shotModifiers display:self.shotShortcutDisplay];
  [self registerHotKeyForAction:1 code:self.selectionKeyCode modifiers:self.selectionModifiers display:self.selectionShortcutDisplay];
  [self registerHotKeyForAction:2 code:self.translateKeyCode modifiers:self.translateModifiers display:self.translateShortcutDisplay];
}

- (NSString *)shortcutDisplayForAction:(NSInteger)action {
  return action == 0 ? self.shotShortcutDisplay : (action == 1 ? self.selectionShortcutDisplay : self.translateShortcutDisplay);
}

- (void)refreshShortcutButtons {
  for (ColorHoverButton *b in self.shortcutButtons) {
    if (b.tag >= 0 && b.tag <= 2) b.title = [self shortcutDisplayForAction:b.tag];
  }
}

- (void)setupMainMenu {
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main"];
  NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"DockLaunchers" action:nil keyEquivalent:@""];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"DockLaunchers"];
  [appMenu addItemWithTitle:@"退出 DockLaunchers" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = appMenu;
  [mainMenu addItem:appItem];
  NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
  [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
  editItem.submenu = editMenu;
  [mainMenu addItem:editItem];
  NSApp.mainMenu = mainMenu;
}

- (void)buildWindow {
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,990,660)
                                            styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable)
                                              backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"DockLaunchers 控制台";
  self.window.titleVisibility = NSWindowTitleHidden;
  self.window.delegate = self;
  self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
  self.centerTitleLabel = [self label:[NSString stringWithFormat:@"DockLaunchers 控制台  v%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0"] size:16 bold:YES color:[NSColor systemOrangeColor]];
  self.centerTitleLabel.alignment = NSTextAlignmentCenter;
  [self.window.contentView.superview addSubview:self.centerTitleLabel];
  [self layoutCenterTitle];
  self.window.styleMask &= ~NSWindowStyleMaskResizable;
  self.window.contentMinSize = NSMakeSize(990, 660);
  self.window.contentMaxSize = NSMakeSize(990, 660);
  self.window.minSize = NSMakeSize(990, 688);
  self.window.maxSize = NSMakeSize(990, 688);
  self.window.releasedWhenClosed = NO;
  self.window.titlebarAppearsTransparent = NO;
  NSView *root = self.window.contentView;

  // 侧边栏
  NSView *side = [[NSView alloc] initWithFrame:NSMakeRect(0,0,240,660)];
  side.wantsLayer = YES;
  side.identifier = @"DLSidebar";
  side.layer.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance).CGColor;
  side.autoresizingMask = NSViewHeightSizable;
  [root addSubview:side];
  NSImageView *avatar = [[NSImageView alloc] initWithFrame:NSMakeRect(84, 580.5, 72, 72)];
  avatar.image = [self characterImage:72];
  [side addSubview:avatar];

  NSArray *titles = @[@"实时数据", @"Dock 分组", @"AI 管理", @"磁盘分析", @"应用卸载", @"设置"];
  NSArray *symbols = @[@"chart.line.uptrend.xyaxis", @"square.grid.2x2", @"sparkles", @"internaldrive", @"trash", @"gearshape"];
  CGFloat y = 521;
  NSMutableArray *btns = [NSMutableArray array];
  for (NSInteger i = 0; i < titles.count; i++) {
    NSButton *b = [NSButton buttonWithTitle:titles[i] target:self action:@selector(sideClicked:)];
    b.tag = i;
    b.frame = NSMakeRect(14, y, 212, 48);
    b.bordered = NO;
    b.alignment = NSTextAlignmentLeft;
    b.font = DLDisplayFont(14, YES);
    NSImage *navIcon = [[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:titles[i]] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightSemibold]];
    navIcon.template = YES;
    b.image = navIcon;
    b.imagePosition = NSImageLeft;
    b.contentTintColor = [NSColor secondaryLabelColor];
    b.wantsLayer = YES;
    b.layer.cornerRadius = 8;
    b.toolTip = titles[i];
    [side addSubview:b];
    [btns addObject:b];
    y -= 92.4;
  }
  self.sideLive = btns[0]; self.sideGroups = btns[1]; self.sideAI = btns[2]; self.sideDisk = btns[3]; self.sideUninstall = btns[4]; self.sideSettings = btns[5];


  self.sideView = side;
  self.contentScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(240, 0, 750, 660)];
  self.contentScroll.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
  self.contentScroll.hasVerticalScroller = YES;
  self.contentScroll.hasHorizontalScroller = YES;
  self.contentScroll.autohidesScrollers = YES;
  self.contentScroll.drawsBackground = YES;
  self.contentScroll.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
  self.content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 750, 660)];
  self.content.wantsLayer = YES;
  self.content.layer.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance).CGColor;
  self.contentScroll.documentView = self.content;
  [root addSubview:self.contentScroll];
  self.uiZoom = 1.0;
  self.sidebarToggle = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(14, 20, 212, 36)];
  self.sidebarToggle.title = @"收起侧边栏";
  self.sidebarToggle.hoverColor = [NSColor systemBrownColor];
  self.sidebarToggle.target = self;
  self.sidebarToggle.action = @selector(toggleSidebar:);
  self.sidebarToggle.toolTip = @"收起 / 展开侧边栏";
  [self.sidebarToggle applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [side addSubview:self.sidebarToggle];

  [self buildLiveView];
  [self showSection:0];
  [self installGroupsKeyMonitor];
}

- (void)sideClicked:(NSButton *)b { [self showSection:b.tag]; }

- (void)startAutoSyncTimer {
  [self.autoSyncTimer invalidate];
  self.autoSyncTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(autoSyncTick:) userInfo:nil repeats:YES];
}
- (void)autoSyncTick:(NSTimer *)t {
  NSInteger pruned = [self pruneStaleGroupListEntries];
  [self pruneStaleDockEntries];
  if (pruned > 0) {
    if (self.section == 1) [self refreshGroups];
    if (self.section == 2) [self reloadUninstallData];
    if (self.popover.isShown) [self rebuildQuickGroups];
  }
}
- (void)toggleAutoSync:(id)sender {
  BOOL on = (self.autoSyncCheck.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"centerAutoSync"];
  [self.autoSyncTimer invalidate];
  self.autoSyncTimer = nil;
  if (on) [self startAutoSyncTimer];
}

- (void)applyFlatButtonsInView:(NSView *)view {
  NSArray *primaryTitles = @[@"创建", @"保存", @"继续删除", @"卸载所选应用", @"确定删除所选", @"删除残留", @"备份并删除"];
  for (NSView *sub in view.subviews) {
    if ([sub isKindOfClass:[NSButton class]]) {
      NSButton *b = (NSButton *)sub;
      if ([b isKindOfClass:[ColorHoverButton class]]) { [self applyFlatButtonsInView:sub]; continue; }
      NSButtonCell *bc = (NSButtonCell *)b.cell;
      if (b.bezelStyle == NSBezelStyleRounded && bc.type != NSSwitchButton && bc.type != NSRadioButton) {
        b.bordered = NO;
        b.wantsLayer = YES;
        b.layer.cornerRadius = 9;
        b.layer.borderWidth = 1;
        b.layer.borderColor = [[NSColor whiteColor] colorWithAlphaComponent:0.4].CGColor;
        b.layer.shadowColor = [NSColor blackColor].CGColor;
        b.layer.shadowOpacity = 0.14;
        b.layer.shadowRadius = 2;
        b.layer.shadowOffset = CGSizeMake(0, -1.5);
        b.font = DLDisplayFont(12.5, YES);
        BOOL primary = [primaryTitles containsObject:b.title];
        if (primary) {
          b.layer.backgroundColor = [NSColor controlAccentColor].CGColor;
          NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
          ps.alignment = NSTextAlignmentCenter;
          b.attributedTitle = [[NSAttributedString alloc] initWithString:b.title attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: [NSColor whiteColor], NSParagraphStyleAttributeName: ps}];
        } else {
          b.layer.backgroundColor = DLButtonBackground().CGColor;
        }
      }
    }
    [self applyFlatButtonsInView:sub];
  }
}

- (NSView *)viewForSection:(NSInteger)idx {
  if (!self.builtSections) self.builtSections = [NSMutableSet set];
  switch (idx) {
    case 0:
      if (!self.liveView) { [self buildLiveView]; [self.builtSections addObject:@0]; }
      return self.liveView;
    case 1:
      if (!self.groupsView) { [self buildGroupsView]; [self.builtSections addObject:@1]; }
      return self.groupsView;
    case 2:
      if (!self.aiView) { [self buildAIView]; [self.builtSections addObject:@2]; }
      return self.aiView;
    case 3:
      if (!self.diskView) { [self buildDiskView]; [self.builtSections addObject:@3]; }
      return self.diskView;
    case 4:
      if (!self.uninstallView) { [self buildUninstallView]; [self.builtSections addObject:@4]; }
      return self.uninstallView;
    case 5:
      if (!self.settingsView) { [self buildSettingsView]; [self.builtSections addObject:@5]; }
      return self.settingsView;
  }
  return nil;
}

- (void)showSection:(NSInteger)idx {
  self.section = idx;
  for (NSView *v in self.content.subviews) [v removeFromSuperview];
  NSArray *btns = @[self.sideLive, self.sideGroups, self.sideAI, self.sideDisk, self.sideUninstall, self.sideSettings];
  NSArray *navColors = @[[NSColor systemGreenColor], [NSColor systemYellowColor], [NSColor systemBlueColor],
                         [NSColor systemOrangeColor], [NSColor systemPurpleColor], [NSColor systemRedColor]];
  for (NSInteger i = 0; i < btns.count; i++) {
    NSButton *b = btns[i];
    BOOL on = (i == idx);
    NSColor *accent = navColors[i];
    BOOL darkNav = ThemeIsDark(NSApp.effectiveAppearance);
    NSColor *normalText = darkNav ? [NSColor colorWithCalibratedWhite:0.92 alpha:1.0] : [NSColor labelColor];
    b.layer.backgroundColor = on ? [accent colorWithAlphaComponent:0.14].CGColor : [NSColor clearColor].CGColor;
    b.contentTintColor = on ? accent : (darkNav ? [NSColor colorWithCalibratedWhite:0.78 alpha:1.0] : [NSColor secondaryLabelColor]);
    NSFont *font = DLDisplayFont(14, on);
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    b.attributedTitle = [[NSAttributedString alloc] initWithString:b.title ?: @"" attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: (on ? accent : normalText), NSParagraphStyleAttributeName: ps}];
  }
  NSView *v = [self viewForSection:idx];
  v.autoresizingMask = NSViewNotSizable;
  [self.content addSubview:v];
  [self layoutPageView:v];
  [self applyFlatButtonsInView:v];
  if (idx == 1) {
    if (!self.groupsSelectedName.length && self.groups.count) {
      NSDictionary *first = self.groups.firstObject;
      self.groupsSelectedName = first[@"name"];
    }
    [self refreshGroups];
  }
  if (idx == 3) { [self refreshDiskVolumes]; [self updateDiskGalleryLayout]; }
  if (idx == 2) {
    [self rebuildAIDisplay];
    [self autoRefreshAIQuotas];
  }
  if (idx == 4) [self reloadUninstallData];
}

- (void)showWindow:(id)sender {
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  [self showWindow:nil];
  return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }

// ---------------- 实时数据 ----------------
- (void)buildLiveView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"本机实时状态" size:24 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"点击任一指标可在本机查看详细报告" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 420, 18); [v addSubview:sub];
  self.uptimeLabel = [self label:@"" size:9 bold:NO color:[NSColor tertiaryLabelColor]];
  self.uptimeLabel.alignment = NSTextAlignmentRight;
  self.uptimeLabel.maximumNumberOfLines = 1;
  self.uptimeLabel.frame = NSMakeRect(500, 620, 226, 22);
  [v addSubview:self.uptimeLabel];

  NSArray *titles = @[@"内存", @"磁盘", @"CPU", @"GPU", @"电源", @"网络"];
  NSArray *keys = @[@"memory", @"disk", @"cpu", @"gpu", @"power", @"network"];
  NSArray *colors = @[[NSColor systemGreenColor], [NSColor systemOrangeColor], [NSColor systemBlueColor],
                      [NSColor systemPurpleColor], [NSColor systemPinkColor], [NSColor systemTealColor]];
  CGFloat gap = 6, left = 18, width = 100;
  NSMutableArray *cols = [NSMutableArray array];
  for (NSInteger i = 0; i < 6; i++) {
    MetricColumnView *c = [[MetricColumnView alloc] initWithFrame:NSMakeRect(left + i*(width+gap), 255, width, 320)
                                                            title:titles[i] accent:colors[i] key:keys[i]
                                                           target:self action:@selector(metricClicked:)];
    [v addSubview:c];
    [cols addObject:c];
  }
  self.internalColumns = cols;
  self.externalVolumes = [NSMutableArray array];
  self.externalSelectedIndex = 0;
  self.externalColumn = [[MetricColumnView alloc] initWithFrame:NSMakeRect(0, 255, 100, 320)
                                                         title:@"外接存储"
                                                        accent:[NSColor systemIndigoColor]
                                                           key:@""
                                                          target:self action:@selector(metricClicked:)];
  self.externalColumn.hidden = YES;
  [v addSubview:self.externalColumn];
  self.externalPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(600, 578, 126, 24) pullsDown:NO];
  self.externalPopup.font = [NSFont systemFontOfSize:11];
  self.externalPopup.target = self;
  self.externalPopup.action = @selector(externalDiskChanged:);
  self.externalPopup.hidden = YES;
  [v addSubview:self.externalPopup];
  self.metricHostView = v;
  self.liveView = v;
  self.liveAIBoard = [self cardAt:NSMakeRect(18, 20, 714, 220)];
  [v addSubview:self.liveAIBoard];
  [self rebuildLiveAIBoard];
  [self refreshExternalVolumes];
}

- (NSArray<NSDictionary *> *)scanExternalVolumes {
  NSMutableArray *out = [NSMutableArray array];
  struct statfs *mounts = NULL;
  int n = getmntinfo(&mounts, MNT_NOWAIT);
  for (int i = 0; i < n; i++) {
    struct statfs *m = &mounts[i];
    NSString *mountPoint = [NSString stringWithUTF8String:m->f_mntonname];
    if (![mountPoint hasPrefix:@"/Volumes/"]) continue;
    if (!(m->f_flags & MNT_LOCAL)) continue;
    unsigned long long total = (unsigned long long)m->f_blocks * m->f_bsize;
    unsigned long long freeB = (unsigned long long)m->f_bavail * m->f_bsize;
    if (total < 100ULL * 1024 * 1024) continue;
    NSString *name = mountPoint.lastPathComponent;
    if (!name.length) name = @"外接存储";
    NSArray *skipNames = @[@"Recovery", @"EFI", @"Preboot", @"Update", @"VM", @"com.apple.recovery.boot"];
    BOOL skip = NO;
    for (NSString *sn in skipNames) if ([name caseInsensitiveCompare:sn] == NSOrderedSame || [name.lowercaseString containsString:sn.lowercaseString]) { skip = YES; break; }
    if (skip) continue;
    [out addObject:@{@"url": [NSURL fileURLWithPath:mountPoint], @"name": name, @"total": @(total), @"free": @(freeB)}];
  }
  [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
  }];
  return out;
}

- (void)layoutMetricColumns {
  NSInteger n = self.metricColumns.count;
  if (!n || !self.metricHostView) return;
  CGFloat gap = 6, left = 18;
  CGFloat width = MAX(62, (750 - left*2 - gap*(n-1)) / n);
  for (NSInteger i = 0; i < n; i++) {
    MetricColumnView *c = self.metricColumns[i];
    c.frame = NSMakeRect(left + i*(width+gap), 255, width, 320);
    [c.bar setNeedsDisplay:YES];
  }
}

- (void)styleExternalSelection {
  if (!self.externalVolumes.count) return;
  NSInteger idx = self.externalSelectedIndex;
  for (NSInteger i = 0; i < (NSInteger)self.externalPopup.numberOfItems; i++) {
    NSMenuItem *it = [self.externalPopup itemAtIndex:i];
    it.state = (i == idx) ? NSControlStateValueOn : NSControlStateValueOff;
  }
  NSString *name = self.externalVolumes[idx][@"name"] ?: @"外接存储";
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentLeft;
  NSAttributedString *attr = [[NSAttributedString alloc] initWithString:name attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: [NSColor systemIndigoColor], NSParagraphStyleAttributeName: ps}];
  self.externalPopup.attributedTitle = attr;
  self.externalPopup.wantsLayer = YES;
  self.externalPopup.layer.cornerRadius = 6;
  self.externalPopup.layer.backgroundColor = [[NSColor systemIndigoColor] colorWithAlphaComponent:0.12].CGColor;
  self.externalColumn.persistentHighlight = NO;
  [self.externalColumn refreshBorderForHover:NO];
}

- (void)updateExternalColumnDisplay {
  if (self.externalSelectedIndex < 0 || self.externalSelectedIndex >= (NSInteger)self.externalVolumes.count) return;
  NSDictionary *vol = self.externalVolumes[self.externalSelectedIndex];
  unsigned long long total = [vol[@"total"] unsignedLongLongValue];
  unsigned long long freeB = [vol[@"free"] unsignedLongLongValue];
  double pct = total ? (double)(total-freeB)/(double)total*100.0 : 0;
  [self.externalColumn setTitleText:@"外部磁盘"];
  self.externalColumn.metricKey = [NSString stringWithFormat:@"external:%@", [vol[@"url"] path]];
  [self.externalColumn setValueText:[NSString stringWithFormat:@"%.0f%%", pct]
                             detail:[NSString stringWithFormat:@"已用 %@\n可用 %@", [self gbString:total-freeB], [self gbString:freeB]]
                                bar:pct];
}

- (void)externalDiskChanged:(id)sender {
  self.externalSelectedIndex = self.externalPopup.indexOfSelectedItem;
  [self updateExternalColumnDisplay];
  [self styleExternalSelection];
}

- (void)rebuildLiveAIBoard {
  NSView *board = self.liveAIBoard;
  if (!board) return;
  for (NSView *sub in [board.subviews copy]) [sub removeFromSuperview];
  NSTextField *title = [self label:@"AI 服务余量" size:13 bold:YES color:nil];
  title.frame = NSMakeRect(16, 186, 240, 20); [board addSubview:title];
  NSTextField *sub = [self label:@"点击眼睛图标同步并显示实时余量" size:9.5 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(16, 166, 400, 16); [board addSubview:sub];
  NSTextField *hn = [self label:@"名称" size:10.5 bold:YES color:nil];
  hn.frame = NSMakeRect(20, 142, 260, 16); [board addSubview:hn];
  NSTextField *hq = [self label:@"余量" size:10.5 bold:YES color:nil];
  hq.alignment = NSTextAlignmentRight;
  hq.frame = NSMakeRect(600, 142, 90, 16); [board addSubview:hq];

  if (!self.aiEntries) [self loadAIEntries];
  NSInteger total = self.aiEntries.count;
  NSInteger pageCount = MAX(1, (total + 1) / 2);
  if (self.liveAIPage >= pageCount) self.liveAIPage = pageCount - 1;
  if (self.liveAIPage < 0) self.liveAIPage = 0;
  NSInteger startIdx = self.liveAIPage * 2;
  NSInteger showCount = MIN(2, MAX(0, total - startIdx));

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 44, 694, 74)];
  sv.hasVerticalScroller = NO; sv.drawsBackground = NO;
  CGFloat rowH = 32;
  CGFloat docH = MAX(64, showCount * rowH);
  NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, docH)];
  for (NSInteger k = 0; k < showCount; k++) {
    NSInteger i = startIdx + k;
    NSDictionary *e = self.aiEntries[i];
    CGFloat y = docH - (k + 1) * rowH;
    NSTextField *nm = [self label:e[@"name"] ?: @"" size:11 bold:YES color:nil];
    nm.lineBreakMode = NSLineBreakByTruncatingTail;
    nm.frame = NSMakeRect(10, y + 9, 470, 16); [doc addSubview:nm];
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(560, y + 4, 100, 24)];
    b.tag = i; b.bordered = NO; b.alignment = NSTextAlignmentRight;
    b.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightBold];
    b.contentTintColor = [NSColor controlAccentColor];
    b.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"显示余额"];
    b.imagePosition = NSImageOnly;
    b.target = self; b.action = @selector(liveAIBalanceClicked:);
    b.toolTip = @"点击眼睛图标同步余额";
    [doc addSubview:b];
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(10, y, 660, 1)];
    line.boxType = NSBoxSeparator; [doc addSubview:line];
  }
  sv.documentView = doc;
  [board addSubview:sv];

  ColorHoverButton *prev = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(570, 10, 34, 24)];
  prev.title = @"‹"; prev.hoverColor = [NSColor systemGreenColor];
  prev.target = self; prev.action = @selector(liveAIPrevPage:);
  [prev applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  prev.enabled = self.liveAIPage > 0; prev.alphaValue = prev.enabled ? 1.0 : 0.4;
  [board addSubview:prev];
  NSTextField *pageLabel = [self label:[NSString stringWithFormat:@"%ld/%ld", (long)(self.liveAIPage + 1), (long)pageCount] size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
  pageLabel.alignment = NSTextAlignmentCenter;
  pageLabel.frame = NSMakeRect(608, 12, 50, 16); [board addSubview:pageLabel];
  ColorHoverButton *next = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(662, 10, 34, 24)];
  next.title = @"›"; next.hoverColor = [NSColor systemGreenColor];
  next.target = self; next.action = @selector(liveAINextPage:);
  [next applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  next.enabled = self.liveAIPage < pageCount - 1; next.alphaValue = next.enabled ? 1.0 : 0.4;
  [board addSubview:next];

  if (!total) {
    NSTextField *empty = [self label:@"暂无 AI 服务，请先在 AI 管理中添加" size:11 bold:NO color:[NSColor tertiaryLabelColor]];
    empty.alignment = NSTextAlignmentCenter;
    empty.frame = NSMakeRect(16, 70, 682, 18); [board addSubview:empty];
  }
}

- (void)liveAIPrevPage:(id)sender {
  if (self.liveAIPage <= 0) return;
  self.liveAIPage--;
  [self rebuildLiveAIBoard];
}

- (void)liveAINextPage:(id)sender {
  self.liveAIPage++;
  [self rebuildLiveAIBoard];
}

- (void)liveAIBalanceClicked:(NSButton *)b {
  NSInteger idx = b.tag;
  if (idx < 0 || idx >= (NSInteger)self.aiEntries.count) return;
  b.enabled = NO;
  b.image = nil;
  b.title = @"同步中…";
  __weak typeof(self) weakSelf = self;
  __weak NSButton *weakBtn = b;
  [self syncAIQuotaAtIndex:idx completion:^(NSString *quota) {
    dispatch_async(dispatch_get_main_queue(), ^{
      weakBtn.enabled = YES;
      if (quota.length) {
        weakBtn.image = nil; weakBtn.title = quota; weakBtn.imagePosition = NSNoImage;
      } else {
        weakBtn.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"无余额数据"];
        weakBtn.imagePosition = NSImageOnly; weakBtn.title = @"";
        weakBtn.toolTip = @"该服务不支持自动查询，或未填写 API Key";
      }
      [weakSelf.aiTable reloadData];
      if (weakSelf.popover.isShown && weakSelf.quickTabs.selectedSegment == 2) [weakSelf rebuildQuickAITab];
    });
  }];
}

- (void)refreshExternalVolumes {
  if (!self.metricHostView) return;
  NSString *keepPath = nil;
  if (self.externalSelectedIndex >= 0 && self.externalSelectedIndex < (NSInteger)self.externalVolumes.count)
    keepPath = [self.externalVolumes[self.externalSelectedIndex][@"url"] path];
  NSArray *vols = [self scanExternalVolumes];
  [self.externalVolumes removeAllObjects];
  [self.externalVolumes addObjectsFromArray:vols];
  [self.externalPopup.menu removeAllItems];
  if (!vols.count) {
    self.externalColumn.hidden = YES;
    self.externalPopup.hidden = YES;
    self.metricColumns = self.internalColumns;
    [self layoutMetricColumns];
    return;
  }
  NSInteger sel = 0;
  for (NSInteger i = 0; i < (NSInteger)vols.count; i++) {
    [self.externalPopup addItemWithTitle:(vols[i][@"name"] ?: @"外接存储")];
    if (keepPath && [[vols[i][@"url"] path] isEqualToString:keepPath]) sel = i;
  }
  self.externalSelectedIndex = sel;
  [self.externalPopup selectItemAtIndex:sel];
  self.externalColumn.hidden = NO;
  self.externalPopup.hidden = NO;
  self.metricColumns = [self.internalColumns arrayByAddingObject:self.externalColumn];
  [self layoutMetricColumns];
  [self updateExternalColumnDisplay];
  [self styleExternalSelection];
  self.externalPopup.frame = NSMakeRect(self.externalColumn.frame.origin.x, 578, self.externalColumn.frame.size.width, 24);
  [self.metricHostView addSubview:self.externalPopup positioned:NSWindowAbove relativeTo:nil];
}

- (void)volumesChanged:(NSNotification *)note {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self refreshExternalVolumes];
  });
}

- (void)metricClicked:(NSString *)key {
  if ([key hasPrefix:@"external:"]) {
    NSString *path = [key substringFromIndex:9];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
    return;
  }
  NSString *url = nil;
  if ([key isEqualToString:@"memory"]) {
    [[NSWorkspace sharedWorkspace] launchApplication:@"Activity Monitor"];
    return;
  } else if ([key isEqualToString:@"disk"]) {
    url = @"x-apple.systempreferences:com.apple.settings.Storage";
    if (![[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]]) {
      [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/Disk Utility.app"]];
    }
    return;
  } else if ([key isEqualToString:@"cpu"]) {
    [[NSWorkspace sharedWorkspace] launchApplication:@"Activity Monitor"];
    return;
  } else if ([key isEqualToString:@"gpu"]) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/System Information.app"]];
    return;
  } else if ([key isEqualToString:@"power"]) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/System Information.app"]];
    return;
  } else if ([key isEqualToString:@"network"]) {
    url = @"x-apple.systempreferences:com.apple.Network-Settings.extension";
  }
  if (url) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

static BOOL ThemeIsDark(NSAppearance *ap) {
  NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
  if (t == 2) return YES;
  if (t == 1) return NO;
  return [[ap.name lowercaseString] containsString:@"dark"];
}

static NSColor *PageBackgroundForAppearance(NSAppearance *ap) {
  BOOL dark = ThemeIsDark(ap);
  return dark ? [NSColor colorWithCalibratedWhite:0.09 alpha:1.0] : [NSColor colorWithCalibratedWhite:1.0 alpha:1.0];
}

static NSColor *CardBackgroundForAppearance(NSAppearance *ap) {
  BOOL dark = ThemeIsDark(ap);
  return dark ? [NSColor colorWithCalibratedWhite:0.13 alpha:1.0] : [NSColor colorWithCalibratedWhite:1.0 alpha:1.0];
}
static NSColor *CardBorderForAppearance(NSAppearance *ap) {
  BOOL dark = ThemeIsDark(ap);
  return dark ? [NSColor colorWithCalibratedWhite:1.0 alpha:0.12] : [NSColor colorWithCalibratedWhite:0.0 alpha:0.08];
}

- (NSView *)cardAt:(NSRect)r {
  NSView *c = [[NSView alloc] initWithFrame:r];
  c.wantsLayer = YES;
  c.identifier = @"DLCard";
  c.layer.cornerRadius = 18;
  c.layer.backgroundColor = CardBackgroundForAppearance(NSApp.effectiveAppearance).CGColor;
  c.layer.shadowColor = [NSColor blackColor].CGColor;
  c.layer.shadowOpacity = 0.0;
  c.layer.shadowRadius = 12;
  c.layer.shadowOffset = CGSizeMake(0, -4);
  c.layer.borderWidth = 1;
  c.layer.borderColor = CardBorderForAppearance(NSApp.effectiveAppearance).CGColor;
  return c;
}

- (void)openGroupsFolder:(id)sender { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:GroupDir()]]; }

// ---------------- Dock 分组 ----------------
- (NSString *)backupBaseDir {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DockLaunchers/backup"];
}
- (NSString *)groupBackupRoot {
  return [[self backupBaseDir] stringByAppendingPathComponent:@"groups"];
}
- (NSString *)lastDeleteBatchPath {
  return [[self backupBaseDir] stringByAppendingPathComponent:@"last_delete.plist"];
}

- (NSDictionary *)lastDeleteBatch {
  NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self lastDeleteBatchPath]];
  return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

- (void)saveLastDeleteBatch:(NSArray<NSString *> *)names {
  [[NSFileManager defaultManager] createDirectoryAtPath:[self backupBaseDir] withIntermediateDirectories:YES attributes:nil error:NULL];
  if (!names.count) { [[NSFileManager defaultManager] removeItemAtPath:[self lastDeleteBatchPath] error:NULL]; return; }
  [@{@"names": names, @"date": [NSDate date]} writeToFile:[self lastDeleteBatchPath] atomically:YES];
}

- (BOOL)isGroupBackedUp:(NSString *)name {
  NSString *dir = [[self groupBackupRoot] stringByAppendingPathComponent:name];
  return [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]]];
}

- (BOOL)backupGroupNamed:(NSString *)name {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *app = [[GroupDir() stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"app"];
  if (![fm fileExistsAtPath:app]) return NO;
  NSString *dst = [[self groupBackupRoot] stringByAppendingPathComponent:name];
  [fm removeItemAtPath:dst error:NULL];
  [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:NULL];
  if (![fm copyItemAtPath:app toPath:[dst stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]] error:NULL]) return NO;
  NSString *list = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]];
  if ([fm fileExistsAtPath:list]) [fm copyItemAtPath:list toPath:[dst stringByAppendingPathComponent:@"list.txt"] error:NULL];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
  NSString *bid = info[@"CFBundleIdentifier"];
  if (bid.length) {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/defaults";
    t.arguments = @[@"export", bid, [dst stringByAppendingPathComponent:@"prefs.plist"]];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
  }
  return YES;
}

- (void)backupGroupNames:(NSArray<NSString *> *)names {
  NSInteger ok = 0;
  for (NSString *n in names) if ([self backupGroupNamed:n]) ok++;
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_SILENT")) { fprintf(stderr, "BACKUP_TEST ok=%ld\n", (long)ok); return; }
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = @"备份完成";
  a.informativeText = [NSString stringWithFormat:@"已备份 %ld 个分组到本机：\n%@", (long)ok, [self backupBaseDir]];
  [a runModal];
}

- (void)runAdminTrashPaths:(NSArray<NSString *> *)paths {
  if (!paths.count) return;
  NSMutableString *body = [NSMutableString stringWithString:@"#!/bin/sh\n"];
  NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
  NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
  [body appendFormat:@"mkdir -p \"%@\"\n", trash];
  NSInteger idx = 0;
  for (NSString *p in paths) [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/%@-%ld-%@\"\n", p, p, trash, stamp, (long)idx++, [p lastPathComponent]];
  [body appendString:@"/usr/bin/killall -KILL Dock 2>/dev/null\n"];
  NSString *sp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"docklaunchers-center-groups.sh"];
  [body writeToFile:sp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:sp error:NULL];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/osascript";
  t.arguments = @[@"-e", [NSString stringWithFormat:@"do shell script \"/bin/sh %@\" with administrator privileges", sp]];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
}

- (NSArray<NSString *> *)targetGroupNamesFromSelection {
  if (self.selectedGroups.count > 0) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *g in self.groups) {
      if ([self.selectedGroups containsObject:g[@"name"]]) [out addObject:g[@"name"]];
    }
    return out;
  }
  NSMutableArray *all = [NSMutableArray array];
  for (NSDictionary *g in self.groups) [all addObject:g[@"name"]];
  return all;
}

- (void)backupGroupsClicked:(id)sender {
  NSArray *names = [self targetGroupNamesFromSelection];
  if (!names.count) {
    NSAlert *a = [[NSAlert alloc] init];
    a.icon = [self characterImage:64];
    a.messageText = @"没有可备份的分组";
    a.informativeText = @"当前没有已安装的 Dock 分组。";
    [a runModal];
    return;
  }
  [self backupGroupNames:names];
}

- (void)deleteGroupsClicked:(id)sender {
  NSArray *names = [self targetGroupNamesFromSelection];
  if (!names.count) return;
  [self deleteGroupNames:names];
}

- (BOOL)groupIsEmpty:(NSString *)name {
  NSString *list = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]];
  NSString *content = [NSString stringWithContentsOfFile:list encoding:NSUTF8StringEncoding error:NULL] ?: @"";
  for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (line.length && ![line hasPrefix:@"#"]) return NO;
  }
  return YES;
}

- (void)emptyGroupCheckToggled:(NSButton *)b {
  BOOL anyChecked = NO;
  for (NSButton *cb in self.emptyGroupCheckboxes) if (cb.state == NSControlStateValueOn) { anyChecked = YES; break; }
  self.emptyContinueButton.enabled = !anyChecked;
  self.emptyContinueButton.alphaValue = anyChecked ? 0.5 : 1.0;
}

- (BOOL)confirmEmptyGroups:(NSArray<NSString *> *)emptyNames {
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = @"有空实例";
  a.informativeText = @"以下分组的应用列表为空，删除时不会备份。请取消勾选后才能继续删除；点「取消」会清空当前选择。";
  CGFloat h = MIN(64 + emptyNames.count * 30, 300);
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, h)];
  NSMutableArray *boxes = [NSMutableArray array];
  CGFloat y = h - 30;
  for (NSString *n in emptyNames) {
    NSButton *cb = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"空实例：%@", n] target:self action:@selector(emptyGroupCheckToggled:)];
    cb.state = NSControlStateValueOn;
    cb.frame = NSMakeRect(10, y, 470, 24);
    [v addSubview:cb];
    [boxes addObject:cb];
    y -= 30;
  }
  self.emptyGroupCheckboxes = boxes;
  a.accessoryView = v;
  NSButton *cont = [a addButtonWithTitle:@"继续删除"];
  cont.enabled = NO;
  cont.alphaValue = 0.5;
  self.emptyContinueButton = cont;
  [a addButtonWithTitle:@"取消"];
  NSModalResponse r = [a runModal];
  return (r == NSAlertFirstButtonReturn);
}

- (void)deleteEmptyGroupDirect:(NSString *)name {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *app = [[GroupDir() stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"app"];
  NSString *list = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]];
  [self removeDockEntry:app];
  NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
  [fm createDirectoryAtPath:trash withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
  NSInteger idx = 0;
  for (NSString *p in @[app, list]) {
    if (![fm fileExistsAtPath:p]) continue;
    BOOL ok = [fm trashItemAtURL:[NSURL fileURLWithPath:p] resultingItemURL:nil error:NULL];
    if (!ok) {
      NSString *dst = [trash stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%ld-%@", stamp, (long)idx++, [p lastPathComponent]]];
      [fm moveItemAtPath:p toPath:dst error:NULL];
    }
  }
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];
}

- (void)deleteGroupNames:(NSArray<NSString *> *)names {
  if (!names.count) return;
  NSMutableArray *empty = [NSMutableArray array];
  for (NSString *n in names) if ([self groupIsEmpty:n]) [empty addObject:n];
  if (names.count == 1 && empty.count == 1) { [self deleteEmptyGroupDirect:names.firstObject]; return; }
  if (empty.count) {
    if (![self confirmEmptyGroups:empty]) {
      if (!self.selectedGroups) self.selectedGroups = [NSMutableSet set];
      [self.selectedGroups removeAllObjects];
      [self refreshGroups];
      return;
    }
  }
  [self finalizeDeleteGroupNames:names backup:YES];
}

- (void)finalizeDeleteGroupNames:(NSArray<NSString *> *)names backup:(BOOL)backup {
  BOOL testMode = getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE") != NULL;
  NSMutableArray *backupNames = [NSMutableArray array];
  for (NSString *n in names) if (![self groupIsEmpty:n]) [backupNames addObject:n];
  if (backup && !testMode) {
    NSAlert *bk = [[NSAlert alloc] init];
    bk.icon = [self characterImage:64];
    bk.messageText = @"删除前必须先备份";
    bk.informativeText = [NSString stringWithFormat:@"将先备份 %ld 个非空分组，然后再执行删除。空实例不会备份。", (long)backupNames.count];
    [bk addButtonWithTitle:@"备份并删除"];
    [bk addButtonWithTitle:@"取消"];
    if ([bk runModal] != NSAlertFirstButtonReturn) return;
  }
  if (backup) for (NSString *n in backupNames) [self backupGroupNamed:n];
  if (!testMode) {
    NSAlert *c = [[NSAlert alloc] init];
    c.icon = [self characterImage:64];
    c.messageText = [NSString stringWithFormat:@"确认删除 %ld 个分组？", (long)names.count];
    c.informativeText = @"只会删除 Dock 分组本身（App 与列表移到废纸篓），不会卸载分组里的应用。5 秒后可点击「是」。";
    [c addButtonWithTitle:@"是（5）"];
    [c addButtonWithTitle:@"否"];
    NSButton *yes = c.buttons[0]; yes.enabled = NO;
    for (int sec = 5; sec >= 1; sec--) {
      int remain = sec - 1;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((5-sec+1)*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (remain > 0) yes.title = [NSString stringWithFormat:@"是（%d）", remain];
        else { yes.title = @"是"; yes.enabled = YES; }
      });
    }
    if ([c runModal] != NSAlertFirstButtonReturn) return;
  }
  NSMutableArray *trashPaths = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *n in names) {
    NSString *app = [[GroupDir() stringByAppendingPathComponent:n] stringByAppendingPathExtension:@"app"];
    NSString *list = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"txt"]];
    if ([fm fileExistsAtPath:app]) [trashPaths addObject:app];
    if ([fm fileExistsAtPath:list]) [trashPaths addObject:list];
    [self removeDockEntry:app];
  }
  if (testMode) {
    for (NSString *p in trashPaths) [fm trashItemAtURL:[NSURL fileURLWithPath:p] resultingItemURL:nil error:NULL];
  } else {
    [self runAdminTrashPaths:trashPaths];
  }
  NSMutableArray *deleted = [NSMutableArray array];
  NSMutableArray *failed = [NSMutableArray array];
  for (NSString *n in names) {
    NSString *app = [[GroupDir() stringByAppendingPathComponent:n] stringByAppendingPathExtension:@"app"];
    if ([fm fileExistsAtPath:app]) { [failed addObject:n]; continue; }
    [deleted addObject:n];
  }
  NSMutableArray *restorable = [NSMutableArray array];
  for (NSString *n in deleted) if ([self isGroupBackedUp:n]) [restorable addObject:n];
  [self saveLastDeleteBatch:restorable];
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];
  if (failed.count && !testMode) {
    NSAlert *f = [[NSAlert alloc] init];
    f.icon = [self characterImage:64];
    f.messageText = @"部分分组未删除";
    f.informativeText = [NSString stringWithFormat:@"%@ 删除失败（可能取消了管理员授权），未删除的分组不会进入恢复列表。", [failed componentsJoinedByString:@"、"]];
    [f runModal];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) fprintf(stderr, "DELETE_TEST remaining=%ld\n", (long)failed.count);
}

- (void)restoreGroupsClicked:(id)sender {
  NSDictionary *batch = [self lastDeleteBatch];
  NSArray *names = batch[@"names"] ?: @[];
  if (!names.count) {
    NSAlert *a = [[NSAlert alloc] init];
    a.icon = [self characterImage:64];
    a.messageText = @"没有需要恢复的分组";
    a.informativeText = @"没有找到最近一次删除记录。";
    [a runModal];
    return;
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *root = [self groupBackupRoot];
  NSMutableArray *restored = [NSMutableArray array];
  NSMutableArray *missing = [NSMutableArray array];
  for (NSString *n in names) {
    NSString *appBackup = [[root stringByAppendingPathComponent:n] stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"app"]];
    NSString *installed = [[GroupDir() stringByAppendingPathComponent:n] stringByAppendingPathExtension:@"app"];
    if (![fm fileExistsAtPath:appBackup]) { [missing addObject:n]; continue; }
    if ([fm fileExistsAtPath:installed]) continue;
    if (![fm copyItemAtPath:appBackup toPath:installed error:NULL]) { [missing addObject:n]; continue; }
    NSString *listBackup = [[root stringByAppendingPathComponent:n] stringByAppendingPathComponent:@"list.txt"];
    NSString *listsDir = [GroupDir() stringByAppendingPathComponent:@"lists"];
    [fm createDirectoryAtPath:listsDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *listDst = [listsDir stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"txt"]];
    if ([fm fileExistsAtPath:listBackup] && ![fm fileExistsAtPath:listDst]) [fm copyItemAtPath:listBackup toPath:listDst error:NULL];
    NSString *prefs = [[root stringByAppendingPathComponent:n] stringByAppendingPathComponent:@"prefs.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[installed stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *bid = info[@"CFBundleIdentifier"];
    if (bid.length && [fm fileExistsAtPath:prefs]) {
      NSTask *t = [[NSTask alloc] init];
      t.launchPath = @"/usr/bin/defaults";
      t.arguments = @[@"import", bid, prefs];
      @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    }
    NSTask *sign = [[NSTask alloc] init];
    sign.launchPath = @"/usr/bin/codesign";
    sign.arguments = @[@"--force", @"--deep", @"--sign", @"-", installed];
    @try { [sign launch]; [sign waitUntilExit]; } @catch (NSException *e) {}
    NSTask *reg = [[NSTask alloc] init];
    reg.launchPath = @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
    reg.arguments = @[@"-f", installed];
    @try { [reg launch]; [reg waitUntilExit]; } @catch (NSException *e) {}
    // 用当前分组的可执行文件升级恢复的旧分组，保证新逻辑生效
    for (NSString *tf in [fm contentsOfDirectoryAtPath:GroupDir() error:NULL]) {
      if (![tf hasSuffix:@".app"]) continue;
      NSString *tpath = [GroupDir() stringByAppendingPathComponent:tf];
      if ([tpath isEqualToString:installed]) continue;
      NSString *srcUI = [tpath stringByAppendingPathComponent:@"Contents/MacOS/ui"];
      NSString *dstUI = [installed stringByAppendingPathComponent:@"Contents/MacOS/ui"];
      if ([fm fileExistsAtPath:srcUI]) {
        [fm removeItemAtPath:dstUI error:NULL];
        if ([fm copyItemAtPath:srcUI toPath:dstUI error:NULL]) {
          NSTask *cs = [[NSTask alloc] init];
          cs.launchPath = @"/usr/bin/codesign";
          cs.arguments = @[@"--force", @"--deep", @"--sign", @"-", installed];
          @try { [cs launch]; [cs waitUntilExit]; } @catch (NSException *e) {}
        }
        break;
      }
    }
    [self addDockEntry:installed label:n];
    [restored addObject:n];
  }
  if (restored.count) [self saveLastDeleteBatch:@[]];
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_SILENT")) { fprintf(stderr, "RESTORE_TEST count=%ld\n", (long)restored.count); return; }
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = restored.count ? @"恢复完成" : @"没有需要恢复的分组";
  NSMutableString *info = [NSMutableString string];
  if (restored.count) [info appendFormat:@"已恢复最近一次删除的：%@", [restored componentsJoinedByString:@"、"]];
  else [info appendString:@"最近一次删除的分组都已存在或备份缺失。"];
  if (missing.count) [info appendFormat:@"\n缺少备份：%@", [missing componentsJoinedByString:@"、"]];
  a.informativeText = info;
  [a runModal];
}

- (void)buildGroupsView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"Dock 分组" size:24 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"管理已安装的分组；新建/删除会同步 Dock 图标" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 430, 18); [v addSubview:sub];
  self.groupsSearch = [[NSSearchField alloc] initWithFrame:NSMakeRect(480, 580, 246, 26)];
  self.groupsSearch.placeholderString = @"搜索分组，回车定位";
  self.groupsSearch.target = self;
  self.groupsSearch.action = @selector(groupsSearchChanged:);
  self.groupsSearch.appearance = NSApp.effectiveAppearance;
  [v addSubview:self.groupsSearch];

  NSArray *toolDefs = @[
    @[@"新建分组…", @"新建一个 Dock 分组，可自定义名称、图标和内置应用", @(24), @(120), [NSColor systemBlueColor], @"createGroup:"],
    @[@"刷新", @"重新读取已安装分组，并刷新 Dock 中的图标", @(152), @(80), [NSColor systemGreenColor], @"refreshAllGroupsClicked:"],
    @[@"打开文件夹", @"在 Finder 中打开分组 App 所在的文件夹", @(240), @(110), [NSColor systemYellowColor], @"openGroupsFolder:"],
    @[@"一键备份", @"备份所有已安装分组的数据和图标", @(360), @(100), [NSColor systemPurpleColor], @"backupGroupsClicked:"],
    @[@"一键删除", @"删除勾选的分组；会先要求备份并二次确认", @(468), @(100), [NSColor systemRedColor], @"deleteGroupsClicked:"],
    @[@"一键恢复", @"从最近一次删除备份恢复分组", @(576), @(100), [NSColor systemOrangeColor], @"restoreGroupsClicked:"]];
  for (NSArray *d in toolDefs) {
    ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect([d[2] doubleValue], 540, [d[3] doubleValue], 32)];
    b.title = d[0]; b.toolTip = d[1]; b.hoverColor = d[4];
    b.target = self; b.action = NSSelectorFromString(d[5]);
    [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
    [v addSubview:b];
  }

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 60, 710, 460)];
  sv.hasVerticalScroller = YES;
  sv.drawsBackground = NO;
  self.groupsList = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,690,10)];
  sv.documentView = self.groupsList;
  self.groupsScroll = sv;
  [v addSubview:sv];
  self.groupsPrevButton = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(566, 24, 34, 26)];
  self.groupsPrevButton.title = @"‹"; self.groupsPrevButton.hoverColor = [NSColor systemGreenColor];
  self.groupsPrevButton.target = self; self.groupsPrevButton.action = @selector(groupsPrevPage:);
  [self.groupsPrevButton applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:self.groupsPrevButton];
  self.groupsPageLabel = [self label:@"1/1" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
  self.groupsPageLabel.alignment = NSTextAlignmentCenter;
  self.groupsPageLabel.frame = NSMakeRect(604, 30, 44, 16); [v addSubview:self.groupsPageLabel];
  self.groupsNextButton = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(652, 24, 34, 26)];
  self.groupsNextButton.title = @"›"; self.groupsNextButton.hoverColor = [NSColor systemGreenColor];
  self.groupsNextButton.target = self; self.groupsNextButton.action = @selector(groupsNextPage:);
  [self.groupsNextButton applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:self.groupsNextButton];
  self.groupsView = v;
}

- (void)pruneStaleDockEntries {
  @try {
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!raw) return;
    NSArray *apps = CFBridgingRelease(raw);
    NSMutableArray *keep = [NSMutableArray array];
    NSMutableSet *seenPaths = [NSMutableSet set];
    BOOL changed = NO;
    NSString *gd = [GroupDir() stringByAppendingString:@"/"];
    for (id item in apps) {
      NSString *u = nil;
      @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
      NSString *path = DockEntryPath(u);
      BOOL ours = IsOurDockEntry(item);
      BOOL missing = (path.length && [path hasPrefix:@"/"] && ![[NSFileManager defaultManager] fileExistsAtPath:path]);
      if (missing && ours) { changed = YES; continue; }
      // 控制台只保留当前安装路径那一条，清掉 build 目录等重复条目
      NSString *bid = nil;
      @try { bid = item[@"tile-data"][@"bundle-identifier"]; } @catch (NSException *e) {}
      if ([bid isEqualToString:@"com.docklaunchers.center"]) {
        NSString *selfPath = [[[NSBundle mainBundle] bundlePath] stringByStandardizingPath];
        if (![path isEqualToString:selfPath]) { changed = YES; continue; }
      }
      if (ours && path.length && [seenPaths containsObject:path]) { changed = YES; continue; }
      if (path.length) [seenPaths addObject:path];
      [keep addObject:item];
    }
    if (changed) {
      CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)keep, CFSTR("com.apple.dock"));
      CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
      [self killDock];
    }
  } @catch (NSException *e) {}
}

- (NSInteger)pruneStaleGroupListEntries {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSInteger removed = 0;
  NSString *listsDir = [GroupDir() stringByAppendingPathComponent:@"lists"];
  for (NSString *f in [fm contentsOfDirectoryAtPath:listsDir error:NULL]) {
    if (![f hasSuffix:@".txt"]) continue;
    NSString *path = [listsDir stringByAppendingPathComponent:f];
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!content) continue;
    NSMutableArray *keep = [NSMutableArray array];
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
    [[keep componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  return removed;
}

- (void)refreshAllGroupsClicked:(id)sender {
  NSFileManager *fm = [NSFileManager defaultManager];
  // 1) 关闭所有已打开的分组窗口（不论是否钉住）
  NSMutableArray *bundleIds = [NSMutableArray array];
  NSArray *items = [fm contentsOfDirectoryAtPath:GroupDir() error:NULL];
  for (NSString *f in items) {
    if (![f hasSuffix:@".app"]) continue;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[[GroupDir() stringByAppendingPathComponent:f] stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    if (info[@"CFBundleIdentifier"]) [bundleIds addObject:info[@"CFBundleIdentifier"]];
  }
  NSInteger closed = 0;
  for (NSRunningApplication *ra in [[NSWorkspace sharedWorkspace] runningApplications]) {
    NSString *bid = ra.bundleIdentifier ?: @"";
    if ([bid isEqualToString:@"com.docklaunchers.center"]) continue;
    if ([bundleIds containsObject:bid] || [[ra.bundleURL path] hasPrefix:GroupDir()]) {
      if ([ra forceTerminate]) closed++;   // 强制关闭，钉住也无效
    }
  }
  NSInteger pruned = [self pruneStaleGroupListEntries];
  // 2) 重建 Dock 条目（刷新图标）
  NSInteger icons = 0;
  for (NSString *f in items) {
    if (![f hasSuffix:@".app"]) continue;
    NSString *p = [GroupDir() stringByAppendingPathComponent:f];
    NSString *label = [f stringByDeletingPathExtension];
    [self removeDockEntry:p];
    [self addDockEntry:p label:label];
    icons++;
    NSTask *ls = [[NSTask alloc] init];
    ls.launchPath = @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
    ls.arguments = @[@"-f", p];
    @try { [ls launch]; } @catch (NSException *e) {}
  }
  // 3) 清理分组应用缓存与保存状态
  NSInteger caches = 0;
  NSArray *cacheRoots = @[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"],
                          [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Saved Application State"]];
  for (NSString *root in cacheRoots) {
    for (NSString *f in [fm contentsOfDirectoryAtPath:root error:NULL]) {
      if (![f hasPrefix:@"com.docklaunchers."]) continue;
      if ([fm removeItemAtPath:[root stringByAppendingPathComponent:f] error:NULL]) caches++;
    }
  }
  // 4) 刷新 Dock 与图标服务
  NSTask *k1 = [[NSTask alloc] init];
  k1.launchPath = @"/usr/bin/killall";
  k1.arguments = @[@"iconservicesagent"];
  @try { [k1 launch]; } @catch (NSException *e) {}
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = @"刷新完成";
  a.informativeText = [NSString stringWithFormat:@"已关闭 %ld 个分组窗口\n已刷新 %ld 个 Dock 图标\n已清理 %ld 项缓存\n已移除 %ld 个失效条目", (long)closed, (long)icons, (long)caches, (long)pruned];
  [a runModal];
}

- (void)refreshGroups {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *items = [[fm contentsOfDirectoryAtPath:GroupDir() error:NULL] sortedArrayUsingSelector:@selector(localizedCompare:)];
  NSMutableArray *gs = [NSMutableArray array];
  for (NSString *f in items) {
    if (![f hasSuffix:@".app"]) continue;
    NSString *p = [GroupDir() stringByAppendingPathComponent:f];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: [f stringByDeletingPathExtension];
    [gs addObject:@{@"name": [f stringByDeletingPathExtension], @"display": name, @"path": p}];
  }
  self.groups = gs;
  if (self.groupsSelectedName.length) {
    BOOL exists = NO;
    for (NSDictionary *g in gs) if ([g[@"name"] isEqualToString:self.groupsSelectedName]) { exists = YES; break; }
    if (!exists) self.groupsSelectedName = nil;
  }
  NSMutableArray *filtered = [NSMutableArray array];
  NSString *q = self.groupsFilter.lowercaseString;
  BOOL exactExists = NO;
  if (q.length) {
    for (NSDictionary *g in gs) {
      if ([[(NSString *)(g[@"name"] ?: @"") lowercaseString] isEqualToString:q] || [[(NSString *)(g[@"display"] ?: @"") lowercaseString] isEqualToString:q]) { exactExists = YES; break; }
    }
  }
  for (NSInteger i = 0; i < (NSInteger)gs.count; i++) {
    NSDictionary *g = gs[i];
    if (q.length) {
      NSString *name = [(NSString *)(g[@"name"] ?: @"") lowercaseString];
      NSString *display = [(NSString *)(g[@"display"] ?: @"") lowercaseString];
      if (exactExists) {
        if (![name isEqualToString:q] && ![display isEqualToString:q]) continue;
      } else {
        NSString *hay = [NSString stringWithFormat:@"%@ %@", name, display];
        if ([hay rangeOfString:q].location == NSNotFound) continue;
      }
    }
    [filtered addObject:@{@"group": g, @"index": @(i)}];
  }
  self.groupsFiltered = filtered;
  NSInteger total = filtered.count;
  NSInteger pages = MAX(1, (total + 3) / 4);
  if (self.groupsPage >= pages) self.groupsPage = pages - 1;
  if (self.groupsPage < 0) self.groupsPage = 0;
  NSInteger startIdx = self.groupsPage * 4;
  NSInteger endIdx = MIN(total, startIdx + 4);
  self.groupsPageLabel.stringValue = [NSString stringWithFormat:@"%ld/%ld", (long)(self.groupsPage + 1), (long)pages];
  self.groupsPrevButton.enabled = self.groupsPage > 0;
  self.groupsNextButton.enabled = self.groupsPage < pages - 1;
  self.groupsPrevButton.alphaValue = self.groupsPrevButton.enabled ? 1.0 : 0.4;
  self.groupsNextButton.alphaValue = self.groupsNextButton.enabled ? 1.0 : 0.4;

  for (NSView *x in [self.groupsList.subviews copy]) [x removeFromSuperview];
  NSInteger visibleCount = MAX(1, endIdx - startIdx);
  CGFloat listH = MAX(300, self.groupsScroll.contentView.bounds.size.height);
  CGFloat rowGap = 8;
  // 始终按每页 4 行的尺寸布局，搜索结果不足 4 行时不会把单行拉成整屏
  CGFloat rowH = (listH - rowGap * 5) / 4.0;
  rowH = MAX(64, rowH);
  CGFloat y = rowGap;
  for (NSInteger k = startIdx; k < endIdx; k++) {
    NSDictionary *g = filtered[k][@"group"];
    NSInteger idx = [filtered[k][@"index"] integerValue];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(6, y, 670, rowH)];
    row.wantsLayer = YES;
    BOOL sel = self.groupsSelectedName.length && [g[@"name"] isEqualToString:self.groupsSelectedName];
    BOOL hl = self.groupsHighlightedName.length && [g[@"name"] isEqualToString:self.groupsHighlightedName];
    CGColorRef bg = sel ? [[NSColor systemOrangeColor] colorWithAlphaComponent:0.18].CGColor : (hl ? [[NSColor systemYellowColor] colorWithAlphaComponent:0.20].CGColor : DLRowBackground().CGColor);
    row.layer.backgroundColor = bg;
    row.layer.cornerRadius = 12;
    row.layer.borderWidth = (sel || hl) ? 2 : 0;
    row.layer.borderColor = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.65].CGColor;
    NSClickGestureRecognizer *rowClick = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(groupRowClicked:)];
    rowClick.numberOfClicksRequired = 1;
    objc_setAssociatedObject(row, "GroupRowName", g[@"name"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [row addGestureRecognizer:rowClick];
    if (!self.selectedGroups) self.selectedGroups = [NSMutableSet set];
    NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleGroupSelection:)];
    cb.frame = NSMakeRect(8, (rowH - 18) / 2.0, 18, 18);
    cb.tag = idx;
    cb.state = [self.selectedGroups containsObject:g[@"name"]] ? NSControlStateValueOn : NSControlStateValueOff;
    [row addSubview:cb];
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(32, (rowH - 48) / 2.0, 48, 48)];
    icon.image = [[NSWorkspace sharedWorkspace] iconForFile:g[@"path"]];
    [row addSubview:icon];
    NSTextField *nm = [self label:g[@"display"] size:16 bold:YES color:nil];
    nm.frame = NSMakeRect(94, rowH / 2.0 + 3, 130, 20); [row addSubview:nm];
    NSTextField *pt = [self label:g[@"path"] size:10 bold:NO color:[NSColor secondaryLabelColor]];
    pt.frame = NSMakeRect(94, rowH / 2.0 - 19, 130, 16); [row addSubview:pt];
    NSArray *rowDefs = @[
      @[@"打开", @"打开该分组的启动器窗口", @(236), [NSColor systemGreenColor], @"openGroupRow:"],
      @[@"编辑", @"修改该分组的名称、图标和应用列表", @(352), [NSColor systemYellowColor], @"editGroupRow:"],
      @[@"备份", @"备份该分组的数据和图标", @(468), [NSColor systemBlueColor], @"backupGroupRow:"],
      @[@"删除", @"删除该分组；删除前会要求备份并二次确认", @(584), [NSColor systemRedColor], @"deleteGroupRow:"]];
    for (NSArray *d in rowDefs) {
      ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect([d[2] doubleValue], (rowH - 30) / 2.0, 86, 30)];
      b.title = d[0]; b.toolTip = d[1]; b.hoverColor = d[3];
      b.target = self; b.action = NSSelectorFromString(d[4]); b.tag = idx;
      [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
      [row addSubview:b];
    }
    [self.groupsList addSubview:row];
    y += rowH + rowGap;
  }
  self.groupsList.frame = NSMakeRect(0,0,690,MAX(listH, y+rowGap));
  [self.groupsScroll.contentView scrollToPoint:NSMakePoint(0, 0)];
  [self applyFlatButtonsInView:self.groupsView];
  [self.groupsScroll.contentView scrollToPoint:NSMakePoint(0, 0)];
}

- (void)groupsSearchChanged:(id)sender {
  NSString *q = [self.groupsSearch.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  self.groupsFilter = q;
  self.groupsPage = 0;
  self.groupsHighlightedName = nil;
  self.groupsSelectedName = nil;
  if (q.length) {
    NSString *ql = q.lowercaseString;
    for (NSDictionary *g in self.groups) {
      if ([[(NSString *)(g[@"name"] ?: @"") lowercaseString] isEqualToString:ql] || [[(NSString *)(g[@"display"] ?: @"") lowercaseString] isEqualToString:ql]) { self.groupsHighlightedName = g[@"name"]; break; }
    }
    if (!self.groupsHighlightedName) {
      for (NSDictionary *g in self.groups) {
        NSString *hay = [[NSString stringWithFormat:@"%@ %@", g[@"name"] ?: @"", g[@"display"] ?: @""] lowercaseString];
        if ([hay rangeOfString:ql].location != NSNotFound) { self.groupsHighlightedName = g[@"name"]; break; }
      }
    }
    if (!self.groupsHighlightedName) [self showToast:@"未找到匹配的分组"];
    self.groupsSelectedName = self.groupsHighlightedName;
  }
  [self refreshGroups];
}

- (void)groupRowClicked:(NSClickGestureRecognizer *)g {
  NSString *name = objc_getAssociatedObject(g.view, "GroupRowName");
  if (!name.length) return;
  self.groupsSelectedName = name;
  [self refreshGroups];
}

- (void)moveGroupSelectionBy:(NSInteger)delta {
  NSArray *list = self.groupsFiltered ?: @[];
  if (!list.count) return;
  NSInteger pos = -1;
  for (NSInteger i = 0; i < (NSInteger)list.count; i++) {
    NSDictionary *g = list[i][@"group"];
    if ([g[@"name"] isEqualToString:self.groupsSelectedName]) { pos = i; break; }
  }
  if (pos < 0) pos = delta > 0 ? -1 : 0;
  NSInteger next = pos + delta;
  if (next < 0) next = 0;
  if (next >= (NSInteger)list.count) next = list.count - 1;
  NSDictionary *g = list[next][@"group"];
  self.groupsSelectedName = g[@"name"];
  self.groupsPage = next / 4;
  [self refreshGroups];
}

- (void)installGroupsKeyMonitor {
  if (self.groupsKeyMonitor) return;
  __weak typeof(self) weakSelf = self;
  self.groupsKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
    if (!weakSelf.window.isKeyWindow || weakSelf.popover.isShown) return e;
    if (weakSelf.section != 1) return e;
    if (e.keyCode == 126 || e.keyCode == 125) {
      [weakSelf moveGroupSelectionBy:(e.keyCode == 125 ? 1 : -1)];
      return nil;
    }
    return e;
  }];
}

- (void)groupsPrevPage:(id)sender {
  if (self.groupsPage <= 0) return;
  self.groupsPage--;
  [self refreshGroups];
}

- (void)groupsNextPage:(id)sender {
  self.groupsPage++;
  [self refreshGroups];
}

- (void)openGroupRow:(NSButton *)b {
  NSInteger i = b.tag;
  if (i < 0 || i >= (NSInteger)self.groups.count) return;
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:self.groups[i][@"path"]]];
}

- (void)toggleGroupSelection:(NSButton *)b {
  NSInteger i = b.tag;
  if (i < 0 || i >= (NSInteger)self.groups.count) return;
  if (!self.selectedGroups) self.selectedGroups = [NSMutableSet set];
  NSString *n = self.groups[i][@"name"];
  if ([self.selectedGroups containsObject:n]) [self.selectedGroups removeObject:n];
  else [self.selectedGroups addObject:n];
  b.state = [self.selectedGroups containsObject:n] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)backupGroupRow:(NSButton *)b {
  NSInteger i = b.tag;
  if (i < 0 || i >= (NSInteger)self.groups.count) return;
  NSString *n = self.groups[i][@"name"];
  [self backupGroupNames:@[n]];
}

- (void)deleteGroupRow:(NSButton *)b {
  NSInteger i = b.tag;
  if (i < 0 || i >= (NSInteger)self.groups.count) return;
  [self deleteGroupNames:@[self.groups[i][@"name"]]];
}

- (NSImage *)groupIconImage:(NSString *)file {
  NSString *p = [[NSBundle mainBundle] pathForResource:file ofType:@"icns" inDirectory:@"GroupIcons"];
  return p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
}

- (void)refreshDialogIconSelection {
  for (NSButton *b in self.dialogIconButtons) {
    if (self.dialogIconsMissing) {
      b.layer.borderWidth = 2.0;
      b.layer.borderColor = [NSColor systemRedColor].CGColor;
      b.layer.cornerRadius = 12;
      continue;
    }
    BOOL sel = (b.tag == self.dialogSelectedBuiltin)
            || ((self.dialogSelectedBuiltin == -2 || self.dialogCustomIcon.length) && b.tag == 98);
    b.layer.borderWidth = sel ? 3.0 : 1.0;
    b.layer.borderColor = (sel ? [NSColor controlAccentColor] : [NSColor colorWithCalibratedWhite:0.85 alpha:1.0]).CGColor;
    b.layer.cornerRadius = 12;
  }
}

- (void)dialogIconClicked:(NSButton *)b {
  self.dialogIconsMissing = NO;
  if (b.tag == 99) { self.dialogSelectedBuiltin = -1; self.dialogCustomIcon = nil; }
  else { self.dialogSelectedBuiltin = b.tag; self.dialogCustomIcon = nil; }
  if (self.dialogIconButtons.count && self.dialogFirstIconImage && b.tag != 98) {
    ((NSButton *)self.dialogIconButtons.firstObject).image = self.dialogFirstIconImage;
  }
  [self refreshDialogIconSelection];
}

- (void)dialogChooseCustomIcon:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES; panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
  panel.allowedFileTypes = @[@"icns", @"png", @"jpg", @"jpeg", @"tiff"];
  void (^apply)(NSURL *url) = ^(NSURL *url) {
    if (!url) return;
    self.dialogCustomIcon = url.path;
    self.dialogSelectedBuiltin = -1;
    self.dialogIconsMissing = NO;
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:url.path];
    if (img && self.dialogIconButtons.count) ((NSButton *)self.dialogIconButtons.firstObject).image = img;
    [self refreshDialogIconSelection];
  };
  NSWindow *modalWin = [NSApp modalWindow];
  if (modalWin) {
    [panel beginSheetModalForWindow:modalWin completionHandler:^(NSModalResponse r) {
      if (r == NSModalResponseOK) apply(panel.URL);
    }];
  } else {
    if ([panel runModal] == NSModalResponseOK) apply(panel.URL);
  }
}

- (BOOL)applyIconToApp:(NSString *)app {
  NSString *resDir = [app stringByAppendingPathComponent:@"Contents/Resources"];
  [[NSFileManager defaultManager] createDirectoryAtPath:resDir withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *dst = [resDir stringByAppendingPathComponent:@"AppIcon.icns"];
  NSString *src = nil;
  if (self.dialogSelectedBuiltin >= 0 && self.dialogSelectedBuiltin < (NSInteger)self.dialogIconButtons.count) {
    NSButton *b = self.dialogIconButtons[self.dialogSelectedBuiltin];
    src = [[NSBundle mainBundle] pathForResource:b.toolTip ofType:@"icns" inDirectory:@"GroupIcons"];
  } else if (self.dialogCustomIcon.length) {
    if ([[self.dialogCustomIcon pathExtension].lowercaseString isEqualToString:@"icns"]) {
      src = self.dialogCustomIcon;
    } else {
      NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"dl-custom-icon.icns"];
      NSTask *t = [[NSTask alloc] init];
      t.launchPath = @"/usr/bin/sips";
      t.arguments = @[@"-s", @"format", @"icns", @"--resampleHeightWidth", @"1024", @"1024", self.dialogCustomIcon, @"--out", tmp];
      @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
      if (t.terminationStatus == 0) src = tmp;
    }
  }
  if (!src) return YES;
  [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
  if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:NULL]) return NO;
  NSString *plist = [app stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:plist] mutableCopy] ?: [NSMutableDictionary dictionary];
  info[@"CFBundleIconFile"] = @"AppIcon";
  [info writeToFile:plist atomically:YES];
  return YES;
}

- (BOOL)renameGroupFrom:(NSString *)oldName to:(NSString *)newName error:(NSString **)err {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *oldApp = [[GroupDir() stringByAppendingPathComponent:oldName] stringByAppendingPathExtension:@"app"];
  NSString *newApp = [[GroupDir() stringByAppendingPathComponent:newName] stringByAppendingPathExtension:@"app"];
  if (![fm fileExistsAtPath:oldApp]) { if (err) *err = @"原分组不存在"; return NO; }
  if ([fm fileExistsAtPath:newApp]) { if (err) *err = @"同名分组已存在"; return NO; }
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[oldApp stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
  NSString *bid = info[@"CFBundleIdentifier"];
  for (NSRunningApplication *ra in [[NSWorkspace sharedWorkspace] runningApplications]) {
    if ([ra.bundleIdentifier isEqualToString:bid]) [ra forceTerminate];
  }
  [self removeDockEntry:oldApp];
  if (![fm moveItemAtPath:oldApp toPath:newApp error:NULL]) {
    if (err) *err = @"重命名分组 App 失败";
    [self addDockEntry:oldApp label:oldName];
    return NO;
  }
  NSString *oldList = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[oldName stringByAppendingPathExtension:@"txt"]];
  NSString *newList = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[newName stringByAppendingPathExtension:@"txt"]];
  if ([fm fileExistsAtPath:oldList]) [fm moveItemAtPath:oldList toPath:newList error:NULL];
  NSString *oldBk = [[self groupBackupRoot] stringByAppendingPathComponent:oldName];
  NSString *newBk = [[self groupBackupRoot] stringByAppendingPathComponent:newName];
  if ([fm fileExistsAtPath:oldBk] && ![fm fileExistsAtPath:newBk]) [fm moveItemAtPath:oldBk toPath:newBk error:NULL];
  NSString *plist = [newApp stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSMutableDictionary *ni = [[NSDictionary dictionaryWithContentsOfFile:plist] mutableCopy];
  ni[@"CFBundleName"] = newName;
  ni[@"CFBundleDisplayName"] = newName;
  [ni writeToFile:plist atomically:YES];
  NSTask *sign = [[NSTask alloc] init];
  sign.launchPath = @"/usr/bin/codesign";
  sign.arguments = @[@"--force", @"--deep", @"--sign", @"-", newApp];
  @try { [sign launch]; [sign waitUntilExit]; } @catch (NSException *e) {}
  NSTask *reg = [[NSTask alloc] init];
  reg.launchPath = @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
  reg.arguments = @[@"-f", newApp];
  @try { [reg launch]; [reg waitUntilExit]; } @catch (NSException *e) {}
  return YES;
}

static BOOL ValidGroupName(NSString *raw) {
  if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return NO;
  NSString *trim = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return trim.length > 0 && [trim isEqualToString:raw];
}

- (void)highlightNameField:(NSTextField *)tf on:(BOOL)on {
  tf.wantsLayer = YES;
  tf.layer.cornerRadius = 5;
  tf.layer.borderWidth = on ? 2.0 : 0.0;
  tf.layer.borderColor = on ? [NSColor systemRedColor].CGColor : [NSColor clearColor].CGColor;
}

- (void)showInfoAlert:(NSString *)title info:(NSString *)info {
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = title;
  a.informativeText = info;
  [a addButtonWithTitle:@"好"];
  [a runModal];
}

- (void)showSheetMessage:(NSString *)title info:(NSString *)info parent:(NSWindow *)parent {
  NSAlert *s = [[NSAlert alloc] init];
  s.icon = [self characterImage:64];
  s.messageText = title;
  s.informativeText = info;
  [s addButtonWithTitle:@"好"];
  if (parent) [s beginSheetModalForWindow:parent completionHandler:nil];
  else [s runModal];
}

- (void)showAutoCloseSheet:(NSString *)title info:(NSString *)info parent:(NSWindow *)parent {
  NSAlert *s = [[NSAlert alloc] init];
  s.icon = [self characterImage:64];
  s.messageText = title;
  s.informativeText = info;
  [s addButtonWithTitle:@"好"];
  if (!parent) { [s runModal]; return; }
  [s beginSheetModalForWindow:parent completionHandler:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [parent endSheet:s.window];
    [s.window orderOut:nil];
  });
}

- (void)dialogCancelClicked:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }

- (void)setDialogIconButtons:(NSArray *)buttons {
  _dialogIconButtons = [buttons mutableCopy];
  [self refreshDialogIconSelection];
}

- (NSButton *)dialogCreateButtonWithTitle:(NSString *)title action:(SEL)action {
  NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
  b.bezelStyle = NSBezelStyleRounded;
  b.frame = NSMakeRect(470, 40, 130, 32);
  b.keyEquivalent = @"\r";
  return b;
}

- (void)buildCreateDialogViews:(NSView *)v {
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 310, 600, 26)];
  tf.placeholderString = @"分组名，如 设计";
  [v addSubview:tf];
  self.dialogNameField = tf;
  NSTextField *l1 = [self label:@"Dock 图标（请选择一个图标）" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  l1.frame = NSMakeRect(10, 284, 600, 16); [v addSubview:l1];
  NSArray *names = @[@"工作组", @"聊天组", @"外网组", @"影音组", @"Ai组", @"Docker组", @"工具组"];
  NSMutableArray *btns = [NSMutableArray array];
  for (NSInteger i = 0; i < names.count; i++) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(10 + i * 86, 196, 74, 74)];
    b.image = [self groupIconImage:names[i]];
    b.imageScaling = NSImageScaleProportionallyUpOrDown;
    b.bordered = NO;
    b.tag = i;
    b.toolTip = names[i];
    b.target = self;
    b.action = @selector(dialogIconClicked:);
    b.wantsLayer = YES;
    [v addSubview:b];
    [btns addObject:b];
  }
  self.dialogSelectedBuiltin = -1;
  self.dialogCustomIcon = nil;
  self.dialogIconsMissing = NO;
  [self setDialogIconButtons:btns];
  self.dialogFirstIconImage = ((NSButton *)btns.firstObject).image;
  NSButton *custom = [NSButton buttonWithTitle:@"自定义图标…" target:self action:@selector(dialogChooseCustomIcon:)];
  custom.frame = NSMakeRect(10, 150, 140, 32);
  custom.bezelStyle = NSBezelStyleRounded;
  [v addSubview:custom];
  NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(dialogCancelClicked:)];
  cancel.frame = NSMakeRect(330, 40, 120, 32);
  cancel.bezelStyle = NSBezelStyleRounded;
  [v addSubview:cancel];
  [v addSubview:[self dialogCreateButtonWithTitle:@"创建" action:@selector(createDialogSubmit:)]];
}

- (void)createDialogSubmit:(id)sender {
  NSString *raw = self.dialogNameField.stringValue ?: @"";
  if (!ValidGroupName(raw)) {
    [self highlightNameField:self.dialogNameField on:YES];
    [self showSheetMessage:@"请填写有效的分组名" info:@"分组名不能为空，且前后不能有空格。" parent:[NSApp modalWindow]];
    return;
  }
  if (self.dialogSelectedBuiltin < 0 && self.dialogCustomIcon.length == 0) {
    self.dialogIconsMissing = YES;
    [self refreshDialogIconSelection];
    [self showSheetMessage:@"图标还未设置" info:@"请从上方选择一个 Dock 图标，或使用自定义图标。" parent:[NSApp modalWindow]];
    return;
  }
  self.dialogIconsMissing = NO;
  [self refreshDialogIconSelection];
  NSString *name = raw;
  while ([name hasSuffix:@"组"] && name.length > 1) name = [name substringToIndex:name.length-1];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *items = [fm contentsOfDirectoryAtPath:GroupDir() error:NULL];
  NSString *tpl = nil;
  for (NSString *f in items) if ([f hasSuffix:@".app"]) { tpl = [GroupDir() stringByAppendingPathComponent:f]; break; }
  if (!tpl) { [self showSheetMessage:@"创建失败" info:@"没有可用于模板的分组。" parent:[NSApp modalWindow]]; return; }
  NSString *dst = [GroupDir() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
  if ([fm fileExistsAtPath:dst]) {
    [self showSheetMessage:@"同名分组已存在" info:@"请换一个名称。" parent:[NSApp modalWindow]];
    return;
  }
  if (![fm copyItemAtPath:tpl toPath:dst error:NULL]) {
    [self showSheetMessage:@"创建失败" info:@"复制模板分组失败。" parent:[NSApp modalWindow]];
    return;
  }
  NSString *plist = [dst stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:plist] mutableCopy];
  info[@"CFBundleName"] = name;
  info[@"CFBundleDisplayName"] = name;
  info[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.docklaunchers.g%lu", (unsigned long)([[NSDate date] timeIntervalSince1970]*1000)];
  [info writeToFile:plist atomically:YES];
  [self applyIconToApp:dst];
  NSString *lists = [GroupDir() stringByAppendingPathComponent:@"lists"];
  [fm createDirectoryAtPath:lists withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *listFile = [lists stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]];
  if (![fm fileExistsAtPath:listFile]) [@"" writeToFile:listFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  NSTask *sign = [[NSTask alloc] init];
  sign.launchPath = @"/usr/bin/codesign";
  sign.arguments = @[@"--force", @"--deep", @"--sign", @"-", dst];
  @try { [sign launch]; [sign waitUntilExit]; } @catch (NSException *e) {}
  NSTask *reg = [[NSTask alloc] init];
  reg.launchPath = @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
  reg.arguments = @[@"-f", dst];
  @try { [reg launch]; [reg waitUntilExit]; } @catch (NSException *e) {}
  [self addDockEntry:dst label:name];
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];

  NSWindow *parent = [NSApp modalWindow];
  NSAlert *q = [[NSAlert alloc] init];
  q.icon = [self characterImage:64];
  q.messageText = @"创建成功";
  q.informativeText = [NSString stringWithFormat:@"分组「%@」已创建。是否立即打开？", name];
  [q addButtonWithTitle:@"打开"];
  [q addButtonWithTitle:@"不打开"];
  [q beginSheetModalForWindow:parent completionHandler:^(NSModalResponse r) {
    if (r == NSAlertFirstButtonReturn) {
      self.dialogPendingOpen = dst;
      [NSApp stopModalWithCode:NSModalResponseOK];
    } else {
      self.dialogNameField.stringValue = @"";
      [self highlightNameField:self.dialogNameField on:NO];
      [self showSheetMessage:@"创建成功" info:[NSString stringWithFormat:@"「%@」已创建，控制台 / Dock / 菜单栏已同步。", name] parent:parent];
    }
  }];
}

- (void)testIconMissingTimer:(NSTimer *)t {
  self.dialogNameField.stringValue = @"测试分组";
  [self createDialogSubmit:nil];
}

- (void)createGroup:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"新建分组";
  a.informativeText = @"输入分组名，并选择 Dock 图标样式。";
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 380)];
  [self buildCreateDialogViews:v];
  a.accessoryView = v;
  [a addButtonWithTitle:@"取消"];
  a.buttons.firstObject.hidden = YES;
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_CREATE_EMPTY")) {
    NSTimer *t = [NSTimer timerWithTimeInterval:1.2 target:self selector:@selector(createDialogSubmit:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_LETTER")) {
    [self showSection:2];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self letterIndexClicked:[NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_LETTER")]];
    });
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_ICON_MISSING")) {
    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(testIconMissingTimer:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
  }
  NSModalResponse r = [a runModal];
  if (r == NSModalResponseOK && self.dialogPendingOpen.length) {
    NSString *p = self.dialogPendingOpen;
    self.dialogPendingOpen = nil;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:p]];
    [self showInfoAlert:@"创建成功" info:@"已打开新分组，控制台 / Dock / 菜单栏已同步。"];
  }
}

- (void)editDialogSubmit:(id)sender {
  NSInteger idx = self.dialogEditIndex;
  if (idx < 0 || idx >= (NSInteger)self.groups.count) { [NSApp stopModalWithCode:NSModalResponseCancel]; return; }
  NSDictionary *g = self.groups[idx];
  NSString *raw = self.dialogNameField.stringValue ?: @"";
  if (!ValidGroupName(raw)) {
    [self highlightNameField:self.dialogNameField on:YES];
    self.dialogNameField.stringValue = @"";
    [self showAutoCloseSheet:@"无效字符" info:@"分组名不能为空，前后不能有空格；中间可以带空格。" parent:[NSApp modalWindow]];
    return;
  }
  NSString *newName = raw;
  while ([newName hasSuffix:@"组"] && newName.length > 1) newName = [newName substringToIndex:newName.length-1];
  NSString *oldName = g[@"name"];
  BOOL nameChanged = ![newName isEqualToString:oldName];
  BOOL iconChanged = (self.dialogSelectedBuiltin >= 0) || self.dialogCustomIcon.length > 0;
  if (!nameChanged && !iconChanged) {
    [self showSheetMessage:@"没有修改" info:@"名称和图标都没有变化。" parent:[NSApp modalWindow]];
    return;
  }
  NSString *err = nil;
  NSString *targetApp = g[@"path"];
  NSString *display = g[@"display"];
  if (nameChanged) {
    if (![self renameGroupFrom:oldName to:newName error:&err]) {
      [self showSheetMessage:@"编辑失败" info:(err ?: @"请重试") parent:[NSApp modalWindow]];
      return;
    }
    targetApp = [[GroupDir() stringByAppendingPathComponent:newName] stringByAppendingPathExtension:@"app"];
    display = newName;
  }
  if (iconChanged) {
    [self applyIconToApp:targetApp];
    NSTask *sign = [[NSTask alloc] init];
    sign.launchPath = @"/usr/bin/codesign";
    sign.arguments = @[@"--force", @"--deep", @"--sign", @"-", targetApp];
    @try { [sign launch]; [sign waitUntilExit]; } @catch (NSException *e) {}
  }
  [self removeDockEntry:targetApp];
  [self addDockEntry:targetApp label:display];
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];
  self.dialogPendingEditName = display;
  [NSApp stopModalWithCode:NSModalResponseOK];
}

- (void)editGroupRow:(NSButton *)sender {
  NSInteger idx = sender.tag;
  if (idx < 0 || idx >= (NSInteger)self.groups.count) return;
  NSDictionary *g = self.groups[idx];
  self.dialogEditIndex = idx;
  self.dialogSelectedBuiltin = -2;
  self.dialogCustomIcon = nil;
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"编辑分组";
  a.informativeText = @"修改分组名称或 Dock 图标；不选图标则保持当前图标。";
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 380)];
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 310, 600, 26)];
  tf.stringValue = g[@"display"];
  [v addSubview:tf];
  self.dialogNameField = tf;
  NSTextField *l1 = [self label:@"Dock 图标（默认保持当前图标）" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  l1.frame = NSMakeRect(10, 284, 600, 16); [v addSubview:l1];
  NSButton *cur = [[NSButton alloc] initWithFrame:NSMakeRect(10, 196, 74, 74)];
  cur.image = [[NSWorkspace sharedWorkspace] iconForFile:g[@"path"]];
  cur.imageScaling = NSImageScaleProportionallyUpOrDown;
  cur.bordered = NO;
  cur.tag = 98;
  cur.toolTip = @"当前图标";
  cur.target = self;
  cur.action = @selector(dialogIconClicked:);
  cur.wantsLayer = YES;
  [v addSubview:cur];
  NSMutableArray *btns = [NSMutableArray arrayWithObject:cur];
  self.dialogFirstIconImage = cur.image;
  NSArray *names = @[@"工作组", @"聊天组", @"外网组", @"影音组", @"Ai组", @"Docker组", @"工具组"];
  for (NSInteger i = 0; i < names.count; i++) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(94 + i * 72, 196, 64, 64)];
    b.image = [self groupIconImage:names[i]];
    b.imageScaling = NSImageScaleProportionallyUpOrDown;
    b.bordered = NO;
    b.tag = i;
    b.toolTip = names[i];
    b.target = self;
    b.action = @selector(dialogIconClicked:);
    b.wantsLayer = YES;
    [v addSubview:b];
    [btns addObject:b];
  }
  [self setDialogIconButtons:btns];
  NSButton *custom = [NSButton buttonWithTitle:@"自定义图标…" target:self action:@selector(dialogChooseCustomIcon:)];
  custom.frame = NSMakeRect(10, 150, 140, 32);
  custom.bezelStyle = NSBezelStyleRounded;
  [v addSubview:custom];
  NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(dialogCancelClicked:)];
  cancel.frame = NSMakeRect(330, 40, 120, 32);
  cancel.bezelStyle = NSBezelStyleRounded;
  [v addSubview:cancel];
  [v addSubview:[self dialogCreateButtonWithTitle:@"保存" action:@selector(editDialogSubmit:)]];
  a.accessoryView = v;
  [a addButtonWithTitle:@"取消"];
  a.buttons.firstObject.hidden = YES;
  NSModalResponse r = [a runModal];
  if (r == NSModalResponseOK && self.dialogPendingEditName.length) {
    NSString *n = self.dialogPendingEditName;
    self.dialogPendingEditName = nil;
    [self showInfoAlert:@"编辑完成" info:[NSString stringWithFormat:@"分组「%@」已更新，控制台 / Dock / 菜单栏已同步。", n]];
  }
}

// ---------------- Dock 条目 ----------------
- (void)ensureGroupDockEntries {
  NSString *dir = [GroupDir() stringByAppendingPathComponent:@"DockLaunchers"];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *files = [fm contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
  for (NSString *f in files) {
    if (![f hasSuffix:@".app"]) continue;
    NSString *path = [dir stringByAppendingPathComponent:f];
    if (![fm fileExistsAtPath:[path stringByAppendingPathComponent:@"Contents/Info.plist"]]) continue;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *bid = info[@"CFBundleIdentifier"] ?: @"";
    if (![bid hasPrefix:@"com.docklaunchers."]) continue;
    if ([bid isEqualToString:@"com.docklaunchers.center"]) continue;
    NSString *label = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: [[f stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"DockLaunchers" withString:@""];
    [self addDockEntry:path label:label];
  }
}

- (void)addDockEntry:(NSString *)path label:(NSString *)label {
  @try {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"] ?: label;
    NSString *enc = [[path stringByAppendingString:@"/"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *url = [NSString stringWithFormat:@"file://%@", enc];
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    NSMutableArray *apps = raw ? [CFBridgingRelease(raw) mutableCopy] : [NSMutableArray array];
    for (id item in apps) {
      NSString *u = nil; @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
      if (u && [DockEntryPath(u) isEqualToString:[path stringByStandardizingPath]]) return;
    }
    [apps addObject:@{@"tile-data": @{@"file-data": @{@"_CFURLString": url, @"_CFURLStringType": @15},
                                      @"file-label": label, @"file-type": @41,
                                      @"bundle-identifier": bid, @"dock-extra": @NO},
                      @"tile-type": @"file-tile"}];
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)apps, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  } @catch (NSException *e) {}
}

- (void)removeDockEntry:(NSString *)path {
  @try {
    NSString *enc = [[path stringByAppendingString:@"/"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!raw) return;
    NSArray *apps = CFBridgingRelease(raw);
    NSMutableArray *keep = [NSMutableArray array];
    for (id item in apps) {
      NSString *u = nil; @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
      if (u && [DockEntryPath(u) isEqualToString:[path stringByStandardizingPath]]) continue;
      [keep addObject:item];
    }
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)keep, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  } @catch (NSException *e) {}
}

- (void)killDock {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/killall";
    t.arguments = @[@"-KILL", @"Dock"];
    @try { [t launch]; } @catch (NSException *e) {}
  });
}

// ---------------- 应用卸载 ----------------
- (NSArray<NSDictionary *> *)diskMountList {
  NSMutableArray *out = [NSMutableArray array];
  struct statfs *mounts = NULL;
  int n = getmntinfo(&mounts, MNT_NOWAIT);
  for (int i = 0; i < n; i++) {
    struct statfs *m = &mounts[i];
    if (!(m->f_flags & MNT_LOCAL)) continue;
    NSString *mp = [NSString stringWithUTF8String:m->f_mntonname];
    if (![mp isEqualToString:@"/"] && ![mp hasPrefix:@"/Volumes/"]) continue;
    unsigned long long total = (unsigned long long)m->f_blocks * m->f_bsize;
    unsigned long long freeB = (unsigned long long)m->f_bavail * m->f_bsize;
    if (total == 0) continue;
    NSString *name = [mp isEqualToString:@"/"] ? @"内置磁盘" : mp.lastPathComponent;
    [out addObject:@{@"mount": mp, @"name": name, @"total": @(total), @"free": @(freeB)}];
  }
  [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    if ([a[@"mount"] isEqualToString:@"/"]) return NSOrderedAscending;
    if ([b[@"mount"] isEqualToString:@"/"]) return NSOrderedDescending;
    return [a[@"name"] compare:b[@"name"]];
  }];
  return out;
}

- (unsigned long long)diskSizeOfPaths:(NSArray<NSString *> *)paths {
  NSFileManager *fm = [NSFileManager defaultManager];
  unsigned long long total = 0;
  for (NSString *path in paths) {
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;
    if (!isDir) {
      NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
      if (attr) total += [attr[NSFileSize] unsignedLongLongValue];
      continue;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:url includingPropertiesForKeys:@[NSURLFileAllocatedSizeKey, NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
    for (NSURL *u in en) {
      id v = nil;
      if ([u getResourceValue:&v forKey:NSURLFileAllocatedSizeKey error:NULL] && [v isKindOfClass:[NSNumber class]]) total += [v unsignedLongLongValue];
    }
  }
  return total;
}

- (NSString *)aiStorePath {
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DockLaunchers"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
  return [dir stringByAppendingPathComponent:@"ai_entries.json"];
}
- (void)loadAIEntries {
  NSData *d = [NSData dataWithContentsOfFile:[self aiStorePath]];
  self.aiEntries = d ? ([[NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] mutableCopy] ?: [NSMutableArray array]) : [NSMutableArray array];
  if (!self.aiSelected) self.aiSelected = [NSMutableSet set];
  if (!self.aiRevealedNames) self.aiRevealedNames = [NSMutableSet set];
}
- (void)saveAIEntries {
  NSData *d = [NSJSONSerialization dataWithJSONObject:self.aiEntries options:NSJSONWritingPrettyPrinted error:NULL];
  [d writeToFile:[self aiStorePath] atomically:YES];
}
- (void)buildAIView {
  AIDropView *v = [[AIDropView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  v.dropTarget = self;
  v.dropAction = @selector(aiHandleDroppedFiles:);
  NSTextField *h = [self label:@"AI 管理" size:24 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"集中管理 AI 服务、API 地址与密钥" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 500, 18); [v addSubview:sub];

  [self loadAIEntries];
  ColorHoverButton *add = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(24, 540, 120, 30)];
  add.title = @"+ 新增 AI 服务"; add.hoverColor = [NSColor systemBlueColor];
  add.target = self; add.action = @selector(aiAddEntry:);
  [add applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:add];
  ColorHoverButton *all = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(182, 540, 70, 30)];
  all.title = @"全选"; all.hoverColor = [NSColor systemOrangeColor]; all.target = self; all.action = @selector(aiSelectAll:);
  [all applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:all];
  ColorHoverButton *none = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(290, 540, 70, 30)];
  none.title = @"全不选"; none.hoverColor = [NSColor systemYellowColor]; none.target = self; none.action = @selector(aiSelectNone:);
  [none applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:none];
  ColorHoverButton *backupAll = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(398, 540, 90, 30)];
  backupAll.title = @"一键备份"; backupAll.hoverColor = [NSColor systemPurpleColor]; backupAll.target = self; backupAll.action = @selector(aiBackupAll:);
  [backupAll applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:backupAll];
  ColorHoverButton *delAll = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(526, 540, 90, 30)];
  delAll.title = @"一键删除"; delAll.hoverColor = [NSColor systemRedColor]; delAll.target = self; delAll.action = @selector(aiDeleteSelected:);
  [delAll applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:delAll];
  ColorHoverButton *refreshAll = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(654, 540, 70, 30)];
  refreshAll.title = @"刷新"; refreshAll.hoverColor = [NSColor systemGreenColor]; refreshAll.target = self; refreshAll.action = @selector(aiReload:);
  [refreshAll applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:refreshAll];

  NSView *card = [self cardAt:NSMakeRect(24, 70, 700, 450)];
  [v addSubview:card];
  self.aiCategoryButton = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(8, 410, 170, 28)];
  self.aiCategoryButton.title = @"分类：全部";
  self.aiCategoryButton.hoverColor = [NSColor systemBlueColor];
  self.aiCategoryButton.target = self;
  self.aiCategoryButton.action = @selector(aiCategoryClicked:);
  [self.aiCategoryButton applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [card addSubview:self.aiCategoryButton];
  self.aiSearchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(190, 410, 300, 28)];
  self.aiSearchField.placeholderString = @"搜索名称、备注、链接或分类";
  self.aiSearchField.font = [NSFont systemFontOfSize:11.5];
  self.aiSearchField.appearance = NSApp.effectiveAppearance;
  self.aiSearchField.target = self;
  self.aiSearchField.action = @selector(aiSearchChanged:);
  [self.aiSearchField setContinuous:YES];
  [card addSubview:self.aiSearchField];
  self.aiCategory = @"全部";
  self.aiTable = [[NSTableView alloc] initWithFrame:NSMakeRect(8, 8, 684, 390)];
  self.aiTable.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
  self.aiTable.rowHeight = 56;
  self.aiTable.usesAlternatingRowBackgroundColors = NO;
  self.aiTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
  self.aiTable.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
  self.aiTable.dataSource = self;
  self.aiTable.delegate = self;
  NSArray *cols = @[@[@"sel", @"", @24], @[@"ainame", @"名称", @120], @[@"quota", @"余量", @90],
                    @[@"endpoint", @"链接地址(API)", @100], @[@"api", @"API Key", @80],
                    @[@"note", @"备注(用途)", @100], @[@"aiactions", @"操作", @130]];
  for (NSArray *c in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1]; col.width = [c[2] doubleValue];
    [self.aiTable addTableColumn:col];
  }
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 8, 684, 434)];
  sv.documentView = self.aiTable;
  sv.hasVerticalScroller = YES;
  sv.hasHorizontalScroller = NO;
  sv.autohidesScrollers = YES;
  sv.drawsBackground = NO;
  [card addSubview:sv];
  NSScrollView *aiScroll = sv;
  aiScroll.frame = NSMakeRect(8, 8, 684, 390);

  ColorHoverButton *decrypt = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(24, 26, 140, 30)];
  decrypt.title = @"解密备份…"; decrypt.hoverColor = [NSColor systemTealColor];
  decrypt.target = self; decrypt.action = @selector(aiDecryptBackup:);
  [decrypt applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:decrypt];
  ColorHoverButton *importBtn = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(174, 26, 110, 30)];
  importBtn.title = @"导入数据…"; importBtn.hoverColor = [NSColor systemBlueColor];
  importBtn.target = self; importBtn.action = @selector(aiImportData:);
  [importBtn applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:importBtn];
  ColorHoverButton *exportBtn = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(294, 26, 110, 30)];
  exportBtn.title = @"导出数据…"; exportBtn.hoverColor = [NSColor systemPurpleColor];
  exportBtn.target = self; exportBtn.action = @selector(aiExportData:);
  [exportBtn applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:exportBtn];
  ColorHoverButton *quotaBtn = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(414, 26, 110, 30)];
  quotaBtn.title = @"刷新余量"; quotaBtn.hoverColor = [NSColor systemGreenColor];
  quotaBtn.target = self; quotaBtn.action = @selector(refreshAIQuotas:);
  [quotaBtn applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:quotaBtn];
  self.aiPrevButton = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(540, 26, 40, 30)];
  self.aiPrevButton.title = @"‹"; self.aiPrevButton.hoverColor = [NSColor systemBlueColor];
  self.aiPrevButton.target = self; self.aiPrevButton.action = @selector(aiPrevPage:);
  [self.aiPrevButton applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:self.aiPrevButton];
  self.aiPageLabel = [self label:@"第 1/1 页" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  self.aiPageLabel.alignment = NSTextAlignmentCenter;
  self.aiPageLabel.frame = NSMakeRect(584, 32, 80, 18); [v addSubview:self.aiPageLabel];
  self.aiNextButton = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(668, 26, 40, 30)];
  self.aiNextButton.title = @"›"; self.aiNextButton.hoverColor = [NSColor systemBlueColor];
  self.aiNextButton.target = self; self.aiNextButton.action = @selector(aiNextPage:);
  [self.aiNextButton applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [v addSubview:self.aiNextButton];

  self.aiView = v;
}

- (NSString *)quotaProviderKeyForEntry:(NSDictionary *)e {
  NSString *hay = [NSString stringWithFormat:@"%@ %@", e[@"name"] ?: @"", e[@"endpoint"] ?: @""].lowercaseString;
  if ([hay containsString:@"deepseek"]) return @"deepseek";
  if ([hay containsString:@"moonshot"] || [hay containsString:@"kimi"]) return @"kimi";
  if ([hay containsString:@"siliconflow"]) return @"siliconflow";
  if ([hay containsString:@"openrouter"]) return @"openrouter";
  return nil;
}

- (void)autoRefreshAIQuotas {
  if (self.aiQuotaRefreshing) return;
  if (self.lastAIQuotaRefresh && -[self.lastAIQuotaRefresh timeIntervalSinceNow] < 300) return;
  BOOL has = NO;
  for (NSDictionary *e in self.aiEntries) if ([e[@"api"] length] && [self quotaProviderKeyForEntry:e]) { has = YES; break; }
  if (has) [self refreshAIQuotas:nil];
}

- (void)refreshAIQuotas:(id)sender {
  if (self.aiQuotaRefreshing) return;
  NSMutableArray *targets = [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)self.aiEntries.count; i++) {
    NSDictionary *e = self.aiEntries[i];
    NSString *key = [self quotaProviderKeyForEntry:e];
    if (key && [e[@"api"] length]) [targets addObject:@[@(i), key]];
  }
  if (!targets.count) { [self showToast:@"没有可自动查询余额的服务，请先填写 API Key"]; return; }
  self.aiQuotaRefreshing = YES;
  self.lastAIQuotaRefresh = [NSDate date];
  NSMutableDictionary *quotaMap = [NSMutableDictionary dictionary];
  dispatch_group_t group = dispatch_group_create();
  for (NSArray *pair in targets) {
    NSInteger idx = [pair[0] integerValue];
    NSString *provider = pair[1];
    NSDictionary *e = self.aiEntries[idx];
    NSString *apiKey = e[@"api"];
    NSString *url = nil;
    if ([provider isEqualToString:@"deepseek"]) url = @"https://api.deepseek.com/user/balance";
    else if ([provider isEqualToString:@"kimi"]) url = @"https://api.moonshot.cn/v1/users/me/balance";
    else if ([provider isEqualToString:@"siliconflow"]) url = @"https://api.siliconflow.cn/v1/user/info";
    else if ([provider isEqualToString:@"openrouter"]) url = @"https://openrouter.ai/api/v1/credits";
    if (!url) continue;
    dispatch_group_enter(group);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
      NSString *quota = nil;
      if (data.length && !err) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([provider isEqualToString:@"deepseek"] && [obj isKindOfClass:[NSDictionary class]]) {
          NSArray *infos = obj[@"balance_infos"];
          if ([infos isKindOfClass:[NSArray class]] && infos.count) {
            NSDictionary *b = infos.firstObject;
            quota = [NSString stringWithFormat:@"%@ %@", b[@"total_balance"] ?: @"", b[@"currency"] ?: @""];
          }
        } else if ([provider isEqualToString:@"kimi"] && [obj isKindOfClass:[NSDictionary class]]) {
          NSDictionary *d = obj[@"data"];
          if ([d isKindOfClass:[NSDictionary class]]) quota = [NSString stringWithFormat:@"¥%@", d[@"available_balance"] ?: @"?"];
        } else if ([provider isEqualToString:@"siliconflow"] && [obj isKindOfClass:[NSDictionary class]]) {
          NSDictionary *d = obj[@"data"];
          if ([d isKindOfClass:[NSDictionary class]]) quota = [NSString stringWithFormat:@"¥%@", d[@"balance"] ?: d[@"chargeBalance"] ?: @"?"];
        } else if ([provider isEqualToString:@"openrouter"] && [obj isKindOfClass:[NSDictionary class]]) {
          NSDictionary *d = obj[@"data"];
          if ([d isKindOfClass:[NSDictionary class]]) {
            double credits = [d[@"total_credits"] doubleValue];
            double usage = [d[@"total_usage"] doubleValue];
            quota = [NSString stringWithFormat:@"$%.2f", MAX(0, credits - usage)];
          }
        }
      }
      if (quota.length) @synchronized (quotaMap) { quotaMap[@(idx)] = quota; }
      dispatch_group_leave(group);
    }];
    [task resume];
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    for (NSNumber *n in quotaMap) {
      NSInteger i = n.integerValue;
      if (i >= 0 && i < (NSInteger)self.aiEntries.count) {
        NSMutableDictionary *m = [self.aiEntries[i] mutableCopy];
        m[@"quota"] = quotaMap[n];
        self.aiEntries[i] = m;
      }
    }
    self.aiQuotaRefreshing = NO;
    for (NSArray *pair in targets) {
      NSInteger i = [pair[0] integerValue];
      if (quotaMap[@(i)] || i >= (NSInteger)self.aiEntries.count) continue;
      NSMutableDictionary *m = [self.aiEntries[i] mutableCopy];
      NSString *old = m[@"quota"] ?: @"";
      if (!old.length || [old isEqualToString:@"未填写"]) m[@"quota"] = @"查询失败";
      self.aiEntries[i] = m;
    }
    [self saveAIEntries];
    [self rebuildAIDisplay];
    if (quotaMap.count) {
      [self showToast:[NSString stringWithFormat:@"已更新 %ld 个服务的余量", (long)quotaMap.count]];
    } else {
      [self showToast:@"未查询到余量，请检查 Key 或该服务是否支持余额接口"];
    }
  });
}

- (NSString *)aiCategoryForEntry:(NSDictionary *)e {
  NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", e[@"name"] ?: @"", e[@"note"] ?: @"", e[@"endpoint"] ?: @""].lowercaseString;
  if ([hay containsString:@"视频"]) return @"视频";
  if ([hay containsString:@"图像"] || [hay containsString:@"图片"]) return @"图像";
  if ([hay containsString:@"语音"]) return @"语音";
  if ([hay containsString:@"多模态"]) return @"多模态";
  if ([hay containsString:@"聚合"] || [hay containsString:@"路由"] || [hay containsString:@"模型托管"]) return @"聚合";
  if ([hay containsString:@"代码"]) return @"代码";
  if ([hay containsString:@"对话"] || [hay containsString:@"推理"]) return @"对话";
  return @"其他";
}

- (void)aiSearchChanged:(id)sender {
  self.aiPage = 0;
  [self rebuildAIDisplay];
}

- (void)rebuildAIDisplay {
  NSString *query = [self.aiSearchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSString *q = query.lowercaseString;
  NSMutableArray *filtered = [NSMutableArray array];
  for (NSDictionary *e in self.aiEntries) {
    if (self.aiCategory.length && ![self.aiCategory isEqualToString:@"全部"]) {
      if (![[self aiCategoryForEntry:e] isEqualToString:self.aiCategory]) continue;
    }
    if (q.length) {
      NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@ %@", e[@"name"] ?: @"", e[@"quota"] ?: @"", e[@"endpoint"] ?: @"", e[@"note"] ?: @"", [self aiCategoryForEntry:e]].lowercaseString;
      if ([hay rangeOfString:q].location == NSNotFound) continue;
    }
    [filtered addObject:e];
  }
  NSInteger total = filtered.count;
  NSInteger maxPage = MAX(0, (total - 1) / 8);
  if (self.aiPage > maxPage) self.aiPage = maxPage;
  if (self.aiPage < 0) self.aiPage = 0;
  NSInteger start = self.aiPage * 8;
  NSInteger len = MIN(8, MAX(0, total - start));
  self.aiVisibleEntries = len > 0 ? [filtered subarrayWithRange:NSMakeRange(start, len)] : @[];
  [self.aiTable reloadData];
  NSInteger pages = MAX(1, (total + 7) / 8);
  self.aiPageLabel.stringValue = [NSString stringWithFormat:@"第 %ld/%ld 页", (long)(self.aiPage + 1), (long)pages];
  self.aiPrevButton.enabled = self.aiPage > 0;
  self.aiNextButton.enabled = self.aiPage < maxPage;
  self.aiPrevButton.alphaValue = self.aiPrevButton.enabled ? 1.0 : 0.4;
  self.aiNextButton.alphaValue = self.aiNextButton.enabled ? 1.0 : 0.4;
  if (self.liveAIBoard) [self rebuildLiveAIBoard];
}

- (void)aiPrevPage:(id)sender {
  if (self.aiPage <= 0) return;
  self.aiPage--;
  [self rebuildAIDisplay];
}

- (void)aiNextPage:(id)sender {
  self.aiPage++;
  [self rebuildAIDisplay];
}

- (void)aiCategoryClicked:(id)sender {
  NSArray *cats = @[@"全部", @"对话", @"多模态", @"图像", @"视频", @"语音", @"聚合", @"代码", @"其他"];
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"分类"];
  for (NSString *c in cats) {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:c action:@selector(aiCategoryChosen:) keyEquivalent:@""];
    it.target = self; it.representedObject = c;
    [menu addItem:it];
  }
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, self.aiCategoryButton.bounds.size.height + 2) inView:self.aiCategoryButton];
}

- (void)aiCategoryChosen:(NSMenuItem *)item {
  self.aiCategory = item.representedObject ?: @"全部";
  self.aiCategoryButton.title = [NSString stringWithFormat:@"分类：%@", self.aiCategory];
  self.aiPage = 0;
  [self rebuildAIDisplay];
}

- (void)applyAISearchHighlight:(NSTextField *)label text:(NSString *)text baseColor:(NSColor *)base {
  NSString *q = self.aiSearchField.stringValue;
  if (!q.length || !text.length) return;
  NSRange r = [text rangeOfString:q options:NSCaseInsensitiveSearch];
  if (r.location == NSNotFound) return;
  NSFont *font = label.font ?: [NSFont systemFontOfSize:11];
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
  NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: base ?: [NSColor labelColor], NSParagraphStyleAttributeName: ps}];
  [as addAttribute:NSBackgroundColorAttributeName value:[[NSColor systemYellowColor] colorWithAlphaComponent:0.35] range:r];
  [as addAttribute:NSForegroundColorAttributeName value:[NSColor labelColor] range:r];
  label.attributedStringValue = as;
}

- (void)aiSelectAll:(id)sender {
  [self.aiSelected removeAllObjects];
  for (NSDictionary *e in self.aiEntries) if (e[@"name"]) [self.aiSelected addObject:e[@"name"]];
  [self rebuildAIDisplay];
}
- (void)aiSelectNone:(id)sender {
  [self.aiSelected removeAllObjects];
  [self rebuildAIDisplay];
}
- (void)aiRowToggle:(NSButton *)b {
  NSInteger row = b.tag;
  if (row < 0 || row >= (NSInteger)self.aiVisibleEntries.count) return;
  NSString *name = self.aiVisibleEntries[row][@"name"] ?: @"";
  if ([self.aiSelected containsObject:name]) [self.aiSelected removeObject:name]; else [self.aiSelected addObject:name];
  [self rebuildAIDisplay];
}
- (BOOL)requestAdminAuthentication {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/osascript";
  t.arguments = @[@"-e", @"do shell script \"exit 0\" with administrator privileges"];
  t.standardOutput = [NSPipe pipe];
  t.standardError = [NSPipe pipe];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return NO; }
  return t.terminationStatus == 0;
}

- (void)aiToggleReveal:(NSButton *)b {
  NSInteger row = b.tag;
  if (row < 0 || row >= (NSInteger)self.aiVisibleEntries.count) return;
  NSString *name = self.aiVisibleEntries[row][@"name"] ?: @"";
  if ([self.aiRevealedNames containsObject:name]) {
    [self.aiRevealedNames removeObject:name];
    [self rebuildAIDisplay];
    return;
  }
  if (![self requestAdminAuthentication]) return;
  [self.aiRevealedNames addObject:name];
  [self rebuildAIDisplay];
  [self showToast:@"已验证管理员身份，API Key 临时显示"];
}

- (NSInteger)showChoiceDialogTitle:(NSString *)title message:(NSString *)message options:(NSArray *)options colors:(NSArray *)colors {
  CGFloat h = 110 + options.count * 46;
  NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, h)
                                            styleMask:(NSWindowStyleMaskTitled)
                                              backing:NSBackingStoreBuffered defer:NO];
  w.title = title;
  w.backgroundColor = [NSColor windowBackgroundColor];
  NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, h)];
  w.contentView = cv;
  NSTextField *t = [self label:title size:17 bold:YES color:nil];
  t.frame = NSMakeRect(24, h - 44, 412, 24); [cv addSubview:t];
  NSTextField *m = [self label:message size:11.5 bold:NO color:[NSColor secondaryLabelColor]];
  m.frame = NSMakeRect(24, h - 100, 412, 48);
  m.maximumNumberOfLines = 3; m.lineBreakMode = NSLineBreakByWordWrapping;
  [cv addSubview:m];
  for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
    ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(24, h - 120 - i*42, 412, 34)];
    b.title = options[i];
    b.hoverColor = i < (NSInteger)colors.count ? colors[i] : [NSColor systemGrayColor];
    b.tag = i;
    b.target = self;
    b.action = @selector(choiceDialogClicked:);
    [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
    [cv addSubview:b];
  }
  NSModalResponse r = [NSApp runModalForWindow:w];
  [w orderOut:nil];
  return r;
}

- (void)choiceDialogClicked:(NSButton *)b {
  [NSApp stopModalWithCode:b.tag];
}

- (NSString *)localizedAppNameForURL:(NSURL *)u {
  NSString *p = u.path;
  NSBundle *b = [NSBundle bundleWithURL:u];
  NSDictionary *loc = b.localizedInfoDictionary;
  NSString *name = loc[@"CFBundleDisplayName"] ?: loc[@"CFBundleName"];
  if (!name.length) {
    for (NSString *lang in @[@"zh-Hans", @"zh_CN", @"zh-Hant", @"zh-HK"]) {
      NSString *sp = [p stringByAppendingPathComponent:[NSString stringWithFormat:@"Contents/Resources/%@.lproj/InfoPlist.strings", lang]];
      NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:sp];
      name = d[@"CFBundleDisplayName"] ?: d[@"CFBundleName"];
      if (name.length) break;
    }
  }
  if (!name.length) {
    name = [[NSFileManager defaultManager] displayNameAtPath:p];
    if ([name.pathExtension.lowercaseString isEqualToString:@"app"]) name = [name stringByDeletingPathExtension];
  }
  if (!name.length) {
    NSDictionary *info = b.infoDictionary;
    name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: [p.lastPathComponent stringByDeletingPathExtension];
  }
  return name ?: @"";
}

- (NSArray *)compatibleAppsForTextFile:(NSString *)path {
  CFArrayRef urls = LSCopyApplicationURLsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kLSRolesViewer | kLSRolesEditor);
  NSArray *list = urls ? CFBridgingRelease(urls) : @[];
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  NSMutableSet *seenNames = [NSMutableSet set];
  NSString *selfPath = [[[NSBundle mainBundle] bundlePath] stringByStandardizingPath];
  for (NSURL *u in list) {
    NSString *p = u.path;
    if (!p.length || [p isEqualToString:selfPath]) continue;
    if ([seen containsObject:p]) continue;
    [seen addObject:p];
    NSString *name = [self localizedAppNameForURL:u];
    if (!name.length) continue;
    if ([seenNames containsObject:name]) continue;
    [seenNames addObject:name];
    [out addObject:@{@"name": name, @"url": u}];
  }
  [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"name"] localizedStandardCompare:b[@"name"]];
  }];
  return out;
}

- (NSURL *)chooseBackupApplicationFrom:(NSArray *)apps {
  if (!apps.count) return nil;
  CGFloat rowsH = apps.count * 40.0;
  CGFloat h = MIN(600, 150 + rowsH);
  NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, h)
                                            styleMask:NSWindowStyleMaskTitled
                                              backing:NSBackingStoreBuffered defer:NO];
  w.title = @"选择备份目标应用";
  w.backgroundColor = [NSColor windowBackgroundColor];
  NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, h)];
  w.contentView = cv;
  NSTextField *t = [self label:@"选择备份目标应用" size:17 bold:YES color:nil];
  t.frame = NSMakeRect(24, h - 44, 432, 24); [cv addSubview:t];
  NSTextField *m = [self label:@"以下应用支持打开备份 txt；音乐类等不支持文本的应用不会出现。" size:11.5 bold:NO color:[NSColor secondaryLabelColor]];
  m.frame = NSMakeRect(24, h - 72, 432, 20); [cv addSubview:m];
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 70, 432, h - 150)];
  sv.hasVerticalScroller = YES; sv.drawsBackground = NO;
  NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 416, MAX(rowsH, 1))];
  for (NSInteger i = 0; i < (NSInteger)apps.count; i++) {
    NSDictionary *d = apps[i];
    ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(0, rowsH - (i+1)*38, 410, 34)];
    b.title = d[@"name"]; b.hoverColor = [NSColor systemBlueColor];
    b.image = [[NSWorkspace sharedWorkspace] iconForFile:[d[@"url"] path]];
    b.imageScaling = NSImageScaleProportionallyDown;
    b.imagePosition = NSImageLeft;
    b.tag = i;
    b.target = self; b.action = @selector(backupAppChoiceClicked:);
    [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
    [doc addSubview:b];
  }
  sv.documentView = doc;
  [cv addSubview:sv];
  ColorHoverButton *cancel = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(24, 22, 432, 34)];
  cancel.title = @"取消"; cancel.hoverColor = [NSColor systemGrayColor];
  cancel.tag = -1; cancel.target = self; cancel.action = @selector(backupAppChoiceClicked:);
  [cancel applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [cv addSubview:cancel];
  self.backupAppChoices = apps;
  NSModalResponse r = [NSApp runModalForWindow:w];
  [w orderOut:nil];
  if (r < 0 || r >= (NSInteger)apps.count) return nil;
  return apps[r][@"url"];
}

- (void)backupAppChoiceClicked:(NSButton *)b {
  [NSApp stopModalWithCode:b.tag];
}

- (BOOL)backupAIEntriesToOtherApp:(NSArray *)entries singleName:(NSString *)singleName {
  NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy-MM-dd HH:mm";
  NSMutableString *txt = [NSMutableString string];
  [txt appendFormat:@"DockLaunchers AI 备份\n时间：%@\n\n", [df stringFromDate:[NSDate date]]];
  for (NSDictionary *e in entries) {
    [txt appendFormat:@"名称：%@\n余量：%@\n链接地址：%@\nAPI Key：%@\n备注：%@\n------------\n",
     e[@"name"] ?: @"", e[@"quota"] ?: @"", e[@"endpoint"] ?: @"", e[@"api"] ?: @"", e[@"note"] ?: @""];
  }
  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DockLaunchers-AI备份.txt"];
  [txt writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  NSArray *apps = [self compatibleAppsForTextFile:tmp];
  if (!apps.count) {
    [self showToast:@"没有找到可打开 txt 的应用"];
    return NO;
  }
  NSURL *appURL = [self chooseBackupApplicationFrom:apps];
  if (!appURL) return NO;

  [[NSWorkspace sharedWorkspace] openURLs:@[[NSURL fileURLWithPath:tmp]]
                 withApplicationAtURL:appURL
                        configuration:[NSWorkspaceOpenConfiguration configuration]
                    completionHandler:^(NSRunningApplication *app, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (error) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:txt forType:NSPasteboardTypeString];
        [self showToast:@"应用打开失败，已复制备份内容到剪贴板"];
      } else {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:txt forType:NSPasteboardTypeString];
        NSAlert *hint = [[NSAlert alloc] init];
        hint.messageText = [NSString stringWithFormat:@"已用「%@」打开备份", app.localizedName ?: @"所选应用"];
        hint.informativeText = @"备份内容已复制到剪贴板。如果应用没有自动导入，请在应用内粘贴或导入打开的 txt 文件。";
        [hint addButtonWithTitle:@"好"];
        [hint addButtonWithTitle:@"在访达中显示文件"];
        if ([hint runModal] == NSAlertSecondButtonReturn) {
          [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:tmp]]];
        }
      }
    });
  }];
  return YES;
}

- (void)backupAIEntriesToNotes:(NSArray *)entries singleName:(NSString *)singleName {
  NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy-MM-dd HH:mm";
  NSString *title = [NSString stringWithFormat:@"DockLaunchers AI 备份 %@", [df stringFromDate:[NSDate date]]];
  NSMutableString *bodyText = [NSMutableString string];
  for (NSDictionary *e in entries) {
    [bodyText appendFormat:@"名称：%@\n余量：%@\n链接地址：%@\nAPI Key：%@\n备注：%@\n------------\n",
     e[@"name"] ?: @"", e[@"quota"] ?: @"", e[@"endpoint"] ?: @"", e[@"api"] ?: @"", e[@"note"] ?: @""];
  }
  // 优先使用系统共享服务「备忘录」，无需自动化权限
  NSArray *services = [NSSharingService sharingServicesForItems:@[bodyText]];
  for (NSSharingService *svc in services) {
    if ([svc.title isEqualToString:@"Notes"] || [svc.title containsString:@"备忘录"]) {
      if ([svc canPerformWithItems:@[bodyText]]) {
        [svc performWithItems:@[bodyText]];
        [self showToast:@"已发送到备忘录"];
        return;
      }
    }
  }
  NSString *escaped = [bodyText stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br>"];
  NSString *source = [NSString stringWithFormat:@"tell application \"Notes\"\nset theTitle to \"%@\"\nset theBody to \"%@\"\nmake new note with properties {name:theTitle, body:theBody}\nend tell", title, escaped];
  NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
  NSDictionary *error = nil;
  NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
  if (!result) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"需要「备忘录」自动化权限";
    a.informativeText = [NSString stringWithFormat:@"控制台没有控制「备忘录」的权限。\n\n请打开：系统设置 → 隐私与安全性 → 自动化，找到「DockLaunchers 控制台」，勾选「备忘录」。\n\n系统返回：%@", error[NSAppleScriptErrorMessage] ?: @"未授权"];
    [a addButtonWithTitle:@"打开系统设置"];
    [a addButtonWithTitle:@"重试"];
    [a addButtonWithTitle:@"取消"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertFirstButtonReturn) {
      [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"]];
    } else if (r == NSAlertSecondButtonReturn) {
      [self backupAIEntriesToNotes:entries singleName:singleName];
    }
    return;
  }
  [self showToast:@"已备份到备忘录"];
}

- (void)runAIBackupForEntries:(NSArray *)entries singleName:(NSString *)singleName {
  if (!entries.count) { [self showToast:@"暂无可备份数据"]; return; }
  while (YES) {
  NSInteger choice = [self showChoiceDialogTitle:@"选择 AI 备份方式"
                                       message:@"普通备份会写入可读 txt；加密备份生成 .enc；也可以写入「备忘录」。备份内容可能包含明文 API Key。"
                                       options:@[@"普通备份", @"加密备份", @"备份到备忘录", @"取消"]
                                        colors:@[[NSColor systemBlueColor], [NSColor systemPurpleColor], [NSColor systemOrangeColor], [NSColor systemGrayColor]]];
  if (choice < 0 || choice == 3) return;
  if (choice == 2) { [self backupAIEntriesToNotes:entries singleName:singleName]; return; }
  BOOL encrypt = (choice == 1);
  NSString *password = nil;
  if (encrypt) {
    NSAlert *pwd = [[NSAlert alloc] init];
    pwd.messageText = @"设置备份密码";
    pwd.informativeText = @"密码不会保存，遗失后无法恢复备份。";
    [pwd addButtonWithTitle:@"确定"];
    [pwd addButtonWithTitle:@"取消"];
    NSView *pv = [[NSView alloc] initWithFrame:NSMakeRect(0,0,360,90)];
    NSTextField *l1 = [self label:@"密码" size:11 bold:NO color:[NSColor secondaryLabelColor]];
    l1.frame = NSMakeRect(4, 56, 60, 18); [pv addSubview:l1];
    NSSecureTextField *f1 = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(70, 52, 270, 24)];
    [pv addSubview:f1];
    NSTextField *l2 = [self label:@"再次输入" size:11 bold:NO color:[NSColor secondaryLabelColor]];
    l2.frame = NSMakeRect(4, 18, 60, 18); [pv addSubview:l2];
    NSSecureTextField *f2 = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(70, 14, 270, 24)];
    [pv addSubview:f2];
    pwd.accessoryView = pv;
    if ([pwd runModal] != NSAlertFirstButtonReturn) continue;
    if (f1.stringValue.length < 4) { [self showToast:@"密码至少 4 位"]; continue; }
    if (![f1.stringValue isEqualToString:f2.stringValue]) { [self showToast:@"两次密码不一致"]; continue; }
    password = f1.stringValue;
  }

  NSAlert *pick = [[NSAlert alloc] init];
  pick.messageText = @"选择备份位置";
  pick.informativeText = @"接下来会打开访达选择文件夹，并在其中创建备份文件夹和文件。";
  [pick addButtonWithTitle:@"选择文件夹"];
  [pick addButtonWithTitle:@"取消"];
  if ([pick runModal] != NSAlertFirstButtonReturn) continue;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.allowsMultipleSelection = NO;
  panel.prompt = @"选择此文件夹"; panel.message = @"选择 AI 备份保存位置";
  if ([panel runModal] != NSModalResponseOK) continue;

  NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyyMMdd-HHmmss";
  NSString *folderName = [NSString stringWithFormat:@"DockLaunchers-AI备份-%@", [df stringFromDate:[NSDate date]]];
  NSString *destDir = [panel.URL.path stringByAppendingPathComponent:folderName];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *err = nil;
  if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:&err]) {
    [self showToast:@"创建备份文件夹失败"]; continue;
  }
  NSMutableString *txt = [NSMutableString string];
  [txt appendFormat:@"DockLaunchers AI 备份\n时间：%@\n\n", [NSDate date]];
  for (NSDictionary *e in entries) {
    [txt appendFormat:@"名称：%@\n余量：%@\n链接地址：%@\nAPI Key：%@\n备注：%@\n------------\n",
     e[@"name"] ?: @"", e[@"quota"] ?: @"", e[@"endpoint"] ?: @"", e[@"api"] ?: @"", e[@"note"] ?: @""];
  }
  NSString *baseName = singleName.length ? singleName : @"ai-backup";
  NSString *finalPath = nil;
  NSString *shownPath = nil;
  if (encrypt) {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dl-ai-%d.txt", arc4random()]];
    [txt writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    shownPath = [destDir stringByAppendingPathComponent:[baseName stringByAppendingString:@".enc"]];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/openssl";
    t.arguments = @[@"enc", @"-aes-256-cbc", @"-pbkdf2", @"-salt", @"-in", tmp, @"-out", shownPath, @"-pass", @"stdin"];
    NSPipe *inPipe = [NSPipe pipe];
    t.standardInput = inPipe;
    t.standardError = [NSPipe pipe];
    @try {
      [t launch];
      NSData *pd = [[password stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
      [inPipe.fileHandleForWriting writeData:pd];
      [inPipe.fileHandleForWriting closeFile];
      [t waitUntilExit];
    } @catch (NSException *e) {}
    int status = t.isRunning ? -1 : t.terminationStatus;
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    if (status != 0 || ![[NSFileManager defaultManager] fileExistsAtPath:shownPath]) {
      [self showToast:@"加密备份失败"]; return;
    }
    finalPath = shownPath;
  } else {
    shownPath = [destDir stringByAppendingPathComponent:[baseName stringByAppendingString:@".txt"]];
    [txt writeToFile:shownPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    finalPath = shownPath;
  }

  NSAlert *done = [[NSAlert alloc] init];
  done.messageText = encrypt ? @"加密备份完成" : @"备份完成";
  NSString *extra = encrypt ? [NSString stringWithFormat:@"\n\n解密命令：\nopenssl enc -d -aes-256-cbc -pbkdf2 -in \"%@\" -out \"%@\"", finalPath, [finalPath stringByDeletingPathExtension]] : @"";
  done.informativeText = [NSString stringWithFormat:@"已写入 %ld 条数据：\n%@%@", (long)entries.count, finalPath, extra];
  [done addButtonWithTitle:@"在访达中显示"];
  [done addButtonWithTitle:@"好"];
  if ([done runModal] == NSAlertFirstButtonReturn) {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:finalPath]]];
  }
  return;
  }
}

- (void)aiDecryptBackup:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES; panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
  panel.message = @"选择加密备份文件（.enc）";
  panel.prompt = @"解密";
  if ([panel runModal] != NSModalResponseOK) return;
  NSString *encPath = panel.URL.path;

  NSAlert *pwd = [[NSAlert alloc] init];
  pwd.messageText = @"输入备份密码";
  pwd.informativeText = @"用于解密所选备份文件，密码不会保存。";
  [pwd addButtonWithTitle:@"解密"];
  [pwd addButtonWithTitle:@"取消"];
  NSSecureTextField *f = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  pwd.accessoryView = f;
  if ([pwd runModal] != NSAlertFirstButtonReturn || !f.stringValue.length) return;

  NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dl-ai-decrypt-%d.txt", arc4random()]];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/openssl";
  t.arguments = @[@"enc", @"-d", @"-aes-256-cbc", @"-pbkdf2", @"-in", encPath, @"-out", outPath, @"-pass", @"stdin"];
  NSPipe *inPipe = [NSPipe pipe];
  t.standardInput = inPipe;
  t.standardError = [NSPipe pipe];
  @try {
    [t launch];
    NSData *pd = [[f.stringValue stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    [inPipe.fileHandleForWriting writeData:pd];
    [inPipe.fileHandleForWriting closeFile];
    [t waitUntilExit];
  } @catch (NSException *e) { [self showToast:@"解密失败"]; return; }
  NSString *text = [NSString stringWithContentsOfFile:outPath encoding:NSUTF8StringEncoding error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];
  if (!text.length) {
    NSAlert *bad = [[NSAlert alloc] init];
    bad.messageText = @"解密失败";
    bad.informativeText = @"密码错误或文件不是有效的加密备份。";
    [bad runModal];
    return;
  }
  NSAlert *show = [[NSAlert alloc] init];
  show.messageText = @"解密完成";
  show.informativeText = @"下方是解密后的备份内容：";
  [show addButtonWithTitle:@"保存为 txt"];
  [show addButtonWithTitle:@"关闭"];
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 520, 300)];
  sv.hasVerticalScroller = YES;
  NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 520, 300)];
  tv.editable = NO; tv.string = text;
  tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  sv.documentView = tv;
  show.accessoryView = sv;
  if ([show runModal] == NSAlertFirstButtonReturn) {
    NSSavePanel *sp = [NSSavePanel savePanel];
    sp.nameFieldStringValue = @"ai-backup-decrypted.txt";
    if ([sp runModal] == NSModalResponseOK) {
      [text writeToFile:sp.URL.path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
      [self showToast:@"解密内容已保存"];
    }
  }
}

- (NSString *)csvEscaped:(NSString *)v {
  NSString *s = v ?: @"";
  s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
  s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
  return [NSString stringWithFormat:@"\"%@\"", s];
}

- (void)aiExportData:(id)sender {
  NSSavePanel *sp = [NSSavePanel savePanel];
  sp.nameFieldStringValue = @"ai-services.json";
  sp.allowedFileTypes = @[@"json", @"csv"];
  if ([sp runModal] != NSModalResponseOK) return;
  NSString *path = sp.URL.path;
  if ([path.pathExtension.lowercaseString isEqualToString:@"csv"]) {
    NSMutableString *csv = [NSMutableString stringWithString:@"名称,余量,链接地址(API),API Key,备注\n"];
    for (NSDictionary *e in self.aiEntries) {
      [csv appendFormat:@"%@,%@,%@,%@,%@\n", [self csvEscaped:e[@"name"]], [self csvEscaped:e[@"quota"]],
       [self csvEscaped:e[@"endpoint"]], [self csvEscaped:e[@"api"]], [self csvEscaped:e[@"note"]]];
    }
    [csv writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  } else {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.aiEntries options:NSJSONWritingPrettyPrinted error:NULL];
    [d writeToFile:path atomically:YES];
  }
  [self showToast:@"已导出 AI 数据"];
}

- (NSArray<NSString *> *)parseCSVLine:(NSString *)line {
  NSMutableArray *out = [NSMutableArray array];
  NSMutableString *cur = [NSMutableString string];
  BOOL inQ = NO;
  for (NSUInteger i = 0; i < line.length; i++) {
    unichar c = [line characterAtIndex:i];
    if (c == '"') {
      if (inQ && i + 1 < line.length && [line characterAtIndex:i+1] == '"') { [cur appendString:@"\""]; i++; }
      else inQ = !inQ;
    } else if (c == ',' && !inQ) {
      [out addObject:[cur copy]]; [cur setString:@""];
    } else {
      [cur appendFormat:@"%C", c];
    }
  }
  [out addObject:[cur copy]];
  return out;
}

- (void)aiEndpointDoubleClicked:(NSClickGestureRecognizer *)g {
  NSString *url = objc_getAssociatedObject(g.view, "AILinkURL");
  if (!url.length) return;
  if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) url = [@"https://" stringByAppendingString:url];
  NSURL *u = [NSURL URLWithString:url];
  if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}

- (void)aiHandleDroppedFiles:(NSArray<NSURL *> *)urls {
  if (!urls.count) return;
  for (NSURL *u in urls) [self importAIDataFromPath:u.path];
}

- (void)aiImportData:(id)sender {
  NSOpenPanel *op = [NSOpenPanel openPanel];
  op.canChooseFiles = YES; op.canChooseDirectories = NO; op.allowsMultipleSelection = NO;
  op.allowedFileTypes = @[@"json", @"csv", @"txt"];
  op.message = @"选择要导入的 AI 数据（JSON / CSV）";
  if ([op runModal] != NSModalResponseOK) return;
  [self importAIDataFromPath:op.URL.path];
}

- (void)importAIDataFromPath:(NSString *)path {
  NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  if (!content.length) { [self showToast:@"文件为空或无法读取"]; return; }
  NSMutableArray *incoming = [NSMutableArray array];
  NSString *trimmed = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSData *jsonData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
  id obj = nil;
  if ([trimmed hasPrefix:@"["] || [trimmed hasPrefix:@"{"]) {
    obj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL];
  }
  if ([obj isKindOfClass:[NSArray class]]) {
    for (id item in obj) {
      if (![item isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary *d = item;
      NSString *name = d[@"name"] ?: d[@"名称"];
      if (!name.length) continue;
      [incoming addObject:@{@"name": name,
                            @"quota": d[@"quota"] ?: d[@"余量"] ?: @"",
                            @"endpoint": d[@"endpoint"] ?: d[@"链接地址(API)"] ?: d[@"链接地址"] ?: @"",
                            @"api": d[@"api"] ?: d[@"API Key"] ?: d[@"apikey"] ?: @"",
                            @"note": d[@"note"] ?: d[@"备注"] ?: @""}];
    }
  } else {
    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL first = YES;
    for (NSString *line in lines) {
      if (!line.length) continue;
      NSArray *cols = [self parseCSVLine:line];
      if (first && cols.count && ([cols[0] containsString:@"名称"] || [[cols[0] lowercaseString] containsString:@"name"])) { first = NO; continue; }
      first = NO;
      if (cols.count < 2) continue;
      NSString *name = [cols[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (!name.length) continue;
      [incoming addObject:@{@"name": name,
                            @"quota": cols.count > 1 ? cols[1] : @"",
                            @"endpoint": cols.count > 2 ? cols[2] : @"",
                            @"api": cols.count > 3 ? cols[3] : @"",
                            @"note": cols.count > 4 ? cols[4] : @""}];
    }
  }
  if (!incoming.count) { [self showToast:@"没有识别到可导入的数据"]; return; }
  NSInteger added = 0, updated = 0;
  for (NSDictionary *e in incoming) {
    NSInteger idx = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)self.aiEntries.count; i++) {
      if ([self.aiEntries[i][@"name"] ?: @"" isEqualToString:e[@"name"]]) { idx = i; break; }
    }
    if (idx == NSNotFound) { [self.aiEntries addObject:e]; added++; }
    else { self.aiEntries[idx] = e; updated++; }
  }
  [self saveAIEntries];
  self.aiPage = 0;
  [self rebuildAIDisplay];
  [self showToast:[NSString stringWithFormat:@"导入完成：新增 %ld，更新 %ld", (long)added, (long)updated]];
}

- (NSArray *)aiPresets {
  static NSArray *presets;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    presets = @[
      @{@"name":@"DeepSeek 深度求索", @"aliases":@[@"deepseek", @"深度求索", @"深度探索"], @"url":@"https://platform.deepseek.com/api_keys", @"type":@"通用对话/推理/代码"},
      @{@"name":@"OpenAI ChatGPT", @"aliases":@[@"openai", @"chatgpt", @"gpt", @"奥尔特曼"], @"url":@"https://platform.openai.com/api-keys", @"type":@"通用对话/多模态/推理"},
      @{@"name":@"Anthropic Claude", @"aliases":@[@"claude", @"anthropic", @"克劳德"], @"url":@"https://console.anthropic.com/settings/keys", @"type":@"长文本/推理/代码/多模态"},
      @{@"name":@"Google Gemini", @"aliases":@[@"gemini", @"谷歌", @"google ai", @"巴德"], @"url":@"https://aistudio.google.com/app/apikey", @"type":@"多模态/长上下文/推理"},
      @{@"name":@"xAI Grok", @"aliases":@[@"grok", @"xai", @"马斯克ai"], @"url":@"https://console.x.ai", @"type":@"通用对话/推理/实时信息"},
      @{@"name":@"Mistral AI", @"aliases":@[@"mistral", @"米斯特拉尔"], @"url":@"https://console.mistral.ai/api-keys", @"type":@"通用对话/代码/多模态"},
      @{@"name":@"Moonshot Kimi", @"aliases":@[@"kimi", @"moonshot", @"月之暗面"], @"url":@"https://platform.moonshot.cn/console/api-keys", @"type":@"长文本/中文对话/文件理解"},
      @{@"name":@"智谱 GLM", @"aliases":@[@"智谱", @"glm", @"chatglm", @"bigmodel"], @"url":@"https://bigmodel.cn/usercenter/apikeys", @"type":@"中文对话/推理/多模态/Agent"},
      @{@"name":@"通义千问 Qwen", @"aliases":@[@"通义千问", @"千问", @"qwen", @"通义", @"百炼", @"dashscope"], @"url":@"https://bailian.console.aliyun.com/?apiKey=1#/api-key", @"type":@"中文对话/多模态/代码/Agent"},
      @{@"name":@"文心一言 百度千帆", @"aliases":@[@"文心", @"文心一言", @"百度千帆", @"千帆", @"ernie"], @"url":@"https://console.bce.baidu.com/qianfan/ais/console/applicationConsole/application", @"type":@"中文对话/知识问答/多模态"},
      @{@"name":@"腾讯混元", @"aliases":@[@"混元", @"腾讯混元", @"hunyuan"], @"url":@"https://console.cloud.tencent.com/hunyuan/api-key", @"type":@"中文对话/多模态/图像生成"},
      @{@"name":@"豆包 火山方舟", @"aliases":@[@"豆包", @"火山方舟", @"火山", @"方舟", @"doubao", @"volcengine"], @"url":@"https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey", @"type":@"中文对话/多模态/语音/视频"},
      @{@"name":@"MiniMax 海螺", @"aliases":@[@"minimax", @"海螺", @"海螺ai"], @"url":@"https://platform.minimaxi.com/user-center/basic-information/interface-key", @"type":@"中文对话/语音/视频生成"},
      @{@"name":@"百川智能", @"aliases":@[@"百川", @"baichuan"], @"url":@"https://platform.baichuan-ai.com/console/apikey", @"type":@"中文对话/医疗/推理"},
      @{@"name":@"零一万物 Yi", @"aliases":@[@"零一万物", @"yi", @"01.ai", @"lingyiwanwu"], @"url":@"https://platform.lingyiwanwu.com/apikeys", @"type":@"通用对话/长文本/代码"},
      @{@"name":@"阶跃星辰 StepFun", @"aliases":@[@"阶跃", @"阶跃星辰", @"stepfun"], @"url":@"https://platform.stepfun.com/interface-key", @"type":@"多模态/语音/图像生成"},
      @{@"name":@"讯飞星火", @"aliases":@[@"讯飞", @"星火", @"讯飞星火", @"iflytek", @"spark"], @"url":@"https://console.xfyun.cn/services/bmx1", @"type":@"中文对话/语音/教育"},
      @{@"name":@"商汤日日新", @"aliases":@[@"商汤", @"日日新", @"sensenova"], @"url":@"https://console.sensecore.cn", @"type":@"中文对话/多模态/视觉"},
      @{@"name":@"SiliconFlow 硅基流动", @"aliases":@[@"硅基流动", @"siliconflow"], @"url":@"https://cloud.siliconflow.cn/account/ak", @"type":@"模型聚合/开源模型/图像/语音"},
      @{@"name":@"OpenRouter", @"aliases":@[@"openrouter"], @"url":@"https://openrouter.ai/keys", @"type":@"多模型聚合/路由/比价"},
      @{@"name":@"Groq", @"aliases":@[@"groq"], @"url":@"https://console.groq.com/keys", @"type":@"超高速推理/开源模型"},
      @{@"name":@"Together AI", @"aliases":@[@"together"], @"url":@"https://api.together.xyz/settings/api-keys", @"type":@"开源模型/微调/图像生成"},
      @{@"name":@"Fireworks AI", @"aliases":@[@"fireworks"], @"url":@"https://fireworks.ai/account/api-keys", @"type":@"高性能推理/开源模型"},
      @{@"name":@"Cohere", @"aliases":@[@"cohere"], @"url":@"https://dashboard.cohere.com/api-keys", @"type":@"企业检索/RAG/多语言"},
      @{@"name":@"Perplexity", @"aliases":@[@"perplexity", @"困惑度"], @"url":@"https://www.perplexity.ai/settings/api", @"type":@"联网搜索问答/研究"},
      @{@"name":@"Hugging Face", @"aliases":@[@"huggingface", @"hugging face", @"hf"], @"url":@"https://huggingface.co/settings/tokens", @"type":@"开源模型/推理/数据集"},
      @{@"name":@"Replicate", @"aliases":@[@"replicate"], @"url":@"https://replicate.com/account/api-tokens", @"type":@"模型托管/图像/视频"},
      @{@"name":@"Stability AI", @"aliases":@[@"stability", @"stable diffusion", @"sd"], @"url":@"https://platform.stability.ai/account/keys", @"type":@"图像生成/编辑/3D"},
      @{@"name":@"Runway", @"aliases":@[@"runway"], @"url":@"https://dev.runwayml.com", @"type":@"视频生成/图像编辑"},
      @{@"name":@"Luma AI", @"aliases":@[@"luma"], @"url":@"https://lumalabs.ai/dashboard/api-keys", @"type":@"视频生成/3D"},
      @{@"name":@"可灵 Kling", @"aliases":@[@"可灵", @"kling"], @"url":@"https://klingai.com/dev", @"type":@"视频生成/图像生成"},
      @{@"name":@"即梦 Jimeng", @"aliases":@[@"即梦", @"jimeng"], @"url":@"https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey", @"type":@"图像生成/视频生成"},
      @{@"name":@"Azure OpenAI", @"aliases":@[@"azure", @"azure openai"], @"url":@"https://portal.azure.com", @"type":@"企业部署/通用对话/多模态"},
      @{@"name":@"AWS Bedrock", @"aliases":@[@"bedrock", @"aws"], @"url":@"https://console.aws.amazon.com/bedrock", @"type":@"企业部署/多模型/Agent"},
      @{@"name":@"GitHub Models", @"aliases":@[@"github models", @"github"], @"url":@"https://github.com/settings/tokens", @"type":@"开发者模型试用/通用对话"},
      @{@"name":@"Cloudflare Workers AI", @"aliases":@[@"cloudflare", @"workers ai"], @"url":@"https://dash.cloudflare.com/profile/api-tokens", @"type":@"边缘推理/开源模型/图像"},
      @{@"name":@"Novita AI", @"aliases":@[@"novita"], @"url":@"https://novita.ai/settings/key-management", @"type":@"模型聚合/图像/视频"},
      @{@"name":@"DeepInfra", @"aliases":@[@"deepinfra"], @"url":@"https://deepinfra.com/dash/api_keys", @"type":@"开源模型推理/图像"}
    ];
  });
  return presets;
}

- (NSDictionary *)aiPresetForName:(NSString *)raw {
  NSString *n = [[raw lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
  if (n.length < 2) return nil;
  NSDictionary *best = nil; NSUInteger bestLen = 0;
  for (NSDictionary *p in [self aiPresets]) {
    for (NSString *alias in p[@"aliases"]) {
      if ([n containsString:alias] && alias.length > bestLen) { best = p; bestLen = alias.length; }
    }
  }
  return best;
}

- (void)applyAIPresetAutofill {
  if (!self.dialogAIName) return;
  NSString *name = self.dialogAIName.stringValue ?: @"";
  NSDictionary *preset = nil;
  for (NSDictionary *p in [self aiPresets]) {
    if ([p[@"name"] isEqualToString:name]) { preset = p; break; }
  }
  if (!preset) preset = [self aiPresetForName:name];
  if (!preset) { self.dialogAIStatus.stringValue = @"未识别到预设服务，可手动填写地址"; return; }
  self.dialogAIEndpoint.stringValue = preset[@"url"] ?: @"";
  if (!self.dialogAINote.stringValue.length) self.dialogAINote.stringValue = preset[@"type"] ?: @"";
  self.dialogAIStatus.stringValue = [NSString stringWithFormat:@"已识别：%@ · 已自动填写 Key 获取地址", preset[@"name"]];
}

- (void)controlTextDidChange:(NSNotification *)note {
  if (note.object != self.dialogAIName) return;
  [self applyAIPresetAutofill];
}

- (void)comboBoxSelectionDidChange:(NSNotification *)note {
  if (note.object != self.dialogAIName) return;
  NSComboBox *cb = note.object;
  NSInteger idx = cb.indexOfSelectedItem;
  if (idx >= 0 && idx < cb.numberOfItems) {
    cb.stringValue = [cb itemObjectValueAtIndex:idx];
  }
  [self applyAIPresetAutofill];
}

- (void)aiAddEntry:(id)sender { [self aiShowEntryDialogForIndex:-1]; }

- (void)aiShowEntryDialogForIndex:(NSInteger)idx {
  BOOL editing = idx >= 0 && idx < (NSInteger)self.aiEntries.count;
  NSDictionary *old = editing ? self.aiEntries[idx] : @{};
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = editing ? @"编辑 AI 服务" : @"新增 AI 服务";
  a.informativeText = @"输入 AI 名称即可自动识别并填写 API Key 获取地址；支持官方名和常用别名，例如千问 / Qwen / 通义千问。";
  [a addButtonWithTitle:@"保存"];
  [a addButtonWithTitle:@"取消"];
  NSView *av = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 250)];
  NSArray *labels = @[@"名称", @"余量", @"链接地址", @"API Key", @"备注"];
  NSArray *keys = @[@"name", @"quota", @"endpoint", @"api", @"note"];
  NSMutableArray *fields = [NSMutableArray array];
  for (NSInteger i = 0; i < labels.count; i++) {
    NSTextField *lab = [self label:labels[i] size:11.5 bold:NO color:[NSColor secondaryLabelColor]];
    lab.frame = NSMakeRect(8, 214 - i*38, 100, 18); [av addSubview:lab];
    NSTextField *tf;
    if (i == 0) {
      NSComboBox *cb = [[NSComboBox alloc] initWithFrame:NSMakeRect(112, 208 - i*38, 370, 26)];
      for (NSDictionary *p in [self aiPresets]) [cb addItemWithObjectValue:p[@"name"]];
      cb.editable = YES; cb.completes = YES; cb.delegate = self;
      tf = cb; self.dialogAIName = cb;
    } else {
      tf = [[NSTextField alloc] initWithFrame:NSMakeRect(112, 208 - i*38, 370, 26)];
      if (i == 1) self.dialogAIQuota = tf;
      if (i == 2) self.dialogAIEndpoint = tf;
      if (i == 3) self.dialogAIApi = tf;
      if (i == 4) self.dialogAINote = tf;
    }
    tf.stringValue = old[keys[i]] ?: @"";
    [av addSubview:tf]; [fields addObject:tf];
  }
  self.dialogAIStatus = [self label:@"" size:10.5 bold:NO color:[NSColor systemGreenColor]];
  self.dialogAIStatus.frame = NSMakeRect(8, 4, 480, 16);
  [av addSubview:self.dialogAIStatus];
  a.accessoryView = av;
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSMutableDictionary *entry = [NSMutableDictionary dictionary];
  for (NSInteger i = 0; i < keys.count; i++) entry[keys[i]] = ((NSTextField *)fields[i]).stringValue ?: @"";
  if (![entry[@"name"] length]) { [self showToast:@"名称不能为空"]; return; }
  if (![entry[@"endpoint"] length]) {
    NSDictionary *preset = [self aiPresetForName:entry[@"name"]];
    if (preset) {
      entry[@"endpoint"] = preset[@"url"] ?: @"";
      if (![entry[@"note"] length]) entry[@"note"] = preset[@"type"] ?: @"";
    }
  }
  if (editing) self.aiEntries[idx] = entry;
  else {
    NSInteger exist = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)self.aiEntries.count; i++) if ([self.aiEntries[i][@"name"] ?: @"" isEqualToString:entry[@"name"]]) { exist = i; break; }
    if (exist == NSNotFound) [self.aiEntries addObject:entry]; else self.aiEntries[exist] = entry;
  }
  [self saveAIEntries];
  self.aiPage = 0;
  [self rebuildAIDisplay];
  [self showToast:editing ? @"AI 服务已更新" : @"AI 服务已添加"];
  if ([entry[@"api"] length]) {
    [self performSelector:@selector(refreshAIQuotas:) withObject:nil afterDelay:0.4];
  }
}

- (void)aiBackupRow:(NSButton *)b {
  NSInteger row = b.tag;
  if (row < 0 || row >= (NSInteger)self.aiVisibleEntries.count) return;
  NSDictionary *entry = self.aiVisibleEntries[row];
  NSString *name = entry[@"name"] ?: @"AI备份";
  [self runAIBackupForEntries:@[entry] singleName:name];
}

- (void)aiDeleteSelected:(id)sender {
  NSMutableArray *targets = [NSMutableArray array];
  for (NSDictionary *e in self.aiEntries) {
    NSString *name = e[@"name"] ?: @"";
    if ([self.aiSelected containsObject:name]) [targets addObject:name];
  }
  if (!targets.count) { [self showToast:@"请先勾选要删除的服务"]; return; }
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = [NSString stringWithFormat:@"删除 %ld 条 AI 服务？", (long)targets.count];
  a.informativeText = [targets componentsJoinedByString:@"、"];
  [a addButtonWithTitle:@"删除"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  if (![self requestAdminAuthentication]) {
    [self showToast:@"管理员验证失败，已取消删除"];
    return;
  }
  for (NSString *n in targets) {
    for (NSInteger i = (NSInteger)self.aiEntries.count - 1; i >= 0; i--) {
      if ([self.aiEntries[i][@"name"] ?: @"" isEqualToString:n]) [self.aiEntries removeObjectAtIndex:i];
    }
    [self removeAIBackupsForName:n];
  }
  [self.aiSelected removeAllObjects];
  [self saveAIEntries];
  self.aiPage = 0;
  [self rebuildAIDisplay];
  [self showToast:@"已删除所选数据与本地备份"];
}

- (void)aiReload:(id)sender {
  [self loadAIEntries];
  [self.aiSelected removeAllObjects];
  [self.aiRevealedNames removeAllObjects];
  self.aiPage = 0;
  [self rebuildAIDisplay];
  [self showToast:@"已刷新 AI 服务数据"];
}

- (void)aiBackupAll:(id)sender {
  [self runAIBackupForEntries:self.aiEntries singleName:nil];
}

- (void)removeAIBackupsForName:(NSString *)name {
  if (!name.length) return;
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DockLaunchers/backup/ai"];
  NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
  for (NSString *f in files) {
    if ([f hasPrefix:[name stringByAppendingString:@"-"]]) {
      [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:f] error:NULL];
    }
  }
}

- (void)aiDeleteRow:(NSButton *)b {
  NSInteger row = b.tag;
  if (row < 0 || row >= (NSInteger)self.aiVisibleEntries.count) return;
  NSString *name = self.aiVisibleEntries[row][@"name"] ?: @"";
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"删除该 AI 服务？";
  a.informativeText = [NSString stringWithFormat:@"将删除控制台中的数据，并清理本地备份：%@", name];
  [a addButtonWithTitle:@"删除"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  if (![self requestAdminAuthentication]) {
    [self showToast:@"管理员验证失败，已取消删除"];
    return;
  }
  for (NSInteger i = (NSInteger)self.aiEntries.count - 1; i >= 0; i--) {
    if ([self.aiEntries[i][@"name"] ?: @"" isEqualToString:name]) [self.aiEntries removeObjectAtIndex:i];
  }
  [self.aiSelected removeObject:name];
  [self saveAIEntries];
  [self removeAIBackupsForName:name];
  [self rebuildAIDisplay];
  [self showToast:@"已删除数据与本地备份"];
}

- (void)buildDiskView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"文件管理" size:24 bold:YES color:nil];
  h.frame = NSMakeRect(24, 600, 300, 32); [v addSubview:h];

  self.diskVolumePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(154, 560, 150, 28) pullsDown:NO];
  [self.diskVolumePopup addItemsWithTitles:@[@"本地磁盘", @"外部磁盘", @"相册"]];
  self.diskVolumePopup.target = self;
  self.diskVolumePopup.action = @selector(diskVolumeChanged:);
  self.diskVolumePopup.toolTip = @"外部磁盘扫描需要「可移除宗卷」访问权限";
  [v addSubview:self.diskVolumePopup];

  self.diskDateButton = [NSButton buttonWithTitle:@"选择日期" target:self action:@selector(showDatePopover:)];
  self.diskDateButton.frame = NSMakeRect(329, 560, 150, 28);
  [v addSubview:self.diskDateButton];

  NSButton *clearDate = [NSButton buttonWithTitle:@"全部日期" target:self action:@selector(diskClearDate:)];
  clearDate.frame = NSMakeRect(504, 560, 86, 28);
  [v addSubview:clearDate];

  NSButton *refresh = [NSButton buttonWithTitle:@"刷新分析" target:self action:@selector(refreshDiskAnalysis)];
  refresh.frame = NSMakeRect(615, 560, 110, 28);
  [v addSubview:refresh];
  self.diskBackButton = [[NSButton alloc] initWithFrame:NSMakeRect(24, 560, 40, 32)];
  self.diskBackButton.bordered = NO;
  self.diskBackButton.wantsLayer = YES;
  self.diskBackButton.layer.cornerRadius = 9;
  self.diskBackButton.layer.backgroundColor = [NSColor quaternaryLabelColor].CGColor;
  NSImage *backImg = [NSImage imageWithSystemSymbolName:@"chevron.backward" accessibilityDescription:@"后退"];
  backImg = [backImg imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightSemibold]];
  self.diskBackButton.image = backImg;
  self.diskBackButton.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.diskBackButton.contentTintColor = [NSColor systemYellowColor];
  self.diskBackButton.toolTip = @"后退";
  self.diskBackButton.target = self;
  self.diskBackButton.action = @selector(diskGoBack:);
  [v addSubview:self.diskBackButton];

  self.diskForwardButton = [[NSButton alloc] initWithFrame:NSMakeRect(89, 560, 40, 32)];
  self.diskForwardButton.bordered = NO;
  self.diskForwardButton.wantsLayer = YES;
  self.diskForwardButton.layer.cornerRadius = 9;
  self.diskForwardButton.layer.backgroundColor = [NSColor quaternaryLabelColor].CGColor;
  NSImage *fwdImg = [NSImage imageWithSystemSymbolName:@"chevron.forward" accessibilityDescription:@"前进"];
  fwdImg = [fwdImg imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightSemibold]];
  self.diskForwardButton.image = fwdImg;
  self.diskForwardButton.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.diskForwardButton.contentTintColor = [NSColor systemGreenColor];
  self.diskForwardButton.toolTip = @"前进";
  self.diskForwardButton.target = self;
  self.diskForwardButton.action = @selector(diskGoForward:);
  [v addSubview:self.diskForwardButton];
  self.diskBackStack = [NSMutableArray array];
  self.diskForwardStack = [NSMutableArray array];

  self.diskSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 538, 16, 16)];
  self.diskSpinner.style = NSProgressIndicatorStyleSpinning;
  self.diskSpinner.controlSize = NSControlSizeSmall;
  self.diskSpinner.displayedWhenStopped = NO;
  [v addSubview:self.diskSpinner];
  self.diskStatus = [self label:@"请选择来源后点击刷新分析" size:10.5 bold:NO color:[NSColor tertiaryLabelColor]];
  self.diskStatus.frame = NSMakeRect(46, 538, 678, 18);
  [v addSubview:self.diskStatus];

  NSView *card = [self cardAt:NSMakeRect(24, 64, 700, 452)];
  [v addSubview:card];
  self.diskCard = card;

  DiskTypeControl *seg = [[DiskTypeControl alloc] initWithFrame:NSMakeRect(16, 408, 240, 28) target:self action:@selector(diskFilterChanged:)];
  self.diskTypeSegment = seg;
  seg.selectedSegment = -1;
  [card addSubview:seg];
  NSTextField *readonly = [self label:@"只读浏览 · 不会修改或删除文件" size:9.5 bold:NO color:[NSColor tertiaryLabelColor]];
  readonly.frame = NSMakeRect(270, 414, 260, 16);
  [card addSubview:readonly];

  self.diskHintLabel = [self label:@"选择磁盘并点击「刷新分析」后显示文件" size:12 bold:NO color:[NSColor tertiaryLabelColor]];
  self.diskHintLabel.alignment = NSTextAlignmentCenter;
  self.diskHintLabel.frame = NSMakeRect(16, 190, 668, 24);
  [card addSubview:self.diskHintLabel];

  self.diskTable = [[NSTableView alloc] initWithFrame:NSMakeRect(16, 40, 668, 360)];
  self.diskTable.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
  self.diskTable.rowHeight = 26;
  self.diskTable.usesAlternatingRowBackgroundColors = NO;
  self.diskTable.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
  self.diskTable.dataSource = self;
  self.diskTable.delegate = self;
  self.diskTable.target = self;
  self.diskTable.doubleAction = @selector(diskRowDoubleClicked:);
  for (NSArray *c in @[@[@"名称", @230, @"name"], @[@"日期", @130, @"date"], @[@"大小", @80, @"size"], @[@"类型", @60, @"kind"], @[@"路径", @168, @"path"]]) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[2]];
    col.title = c[0];
    col.width = [c[1] doubleValue];
    BOOL numeric = [c[2] isEqualToString:@"size"];
    col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c[2] ascending:!numeric];
    [self.diskTable addTableColumn:col];
  }
  self.diskScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 40, 668, 360)];
  self.diskScroll.documentView = self.diskTable;
  self.diskScroll.hasVerticalScroller = YES;
  self.diskScroll.borderType = NSNoBorder;
  self.diskScroll.drawsBackground = NO;
  [card addSubview:self.diskScroll];

  NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
  layout.itemSize = NSMakeSize(200, 200);
  layout.minimumInteritemSpacing = 10;
  layout.minimumLineSpacing = 10;
  layout.sectionInset = NSEdgeInsetsMake(10, 10, 10, 10);
  self.diskFlowLayout = layout;
  self.diskCollection = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 668, 388)];
  self.diskCollection.collectionViewLayout = layout;
  self.diskCollection.dataSource = self;
  self.diskCollection.delegate = self;
  self.diskCollection.wantsLayer = YES;
  self.diskCollection.layer.backgroundColor = [NSColor whiteColor].CGColor;
  self.diskCollection.selectable = YES;
  self.diskCollection.allowsMultipleSelection = NO;
  [self.diskCollection registerClass:[DiskGalleryItem class] forItemWithIdentifier:@"galleryItem"];
  self.diskCollectionScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 40, 668, 360)];
  self.diskCollectionScroll.documentView = self.diskCollection;
  self.diskCollectionScroll.hasVerticalScroller = YES;
  self.diskCollectionScroll.borderType = NSNoBorder;
  self.diskCollectionScroll.drawsBackground = NO;
  self.diskCollectionScroll.hidden = YES;
  [card addSubview:self.diskCollectionScroll];
  NSClickGestureRecognizer *dbl = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(diskGalleryDoubleClick:)];
  dbl.numberOfClicksRequired = 2;
  [self.diskCollection addGestureRecognizer:dbl];
  self.diskPathControl = [[NSPathControl alloc] initWithFrame:NSMakeRect(16, 8, 668, 24)];
  self.diskPathControl.pathStyle = NSPathStyleStandard;
  self.diskPathControl.target = self;
  self.diskPathControl.action = @selector(diskPathControlClicked:);
  self.diskPathControl.hidden = YES;
  [card addSubview:self.diskPathControl];

  self.diskPrevPageButton = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(566, 26, 34, 26)];
  self.diskPrevPageButton.title = @"‹"; self.diskPrevPageButton.hoverColor = [NSColor systemGreenColor];
  self.diskPrevPageButton.target = self; self.diskPrevPageButton.action = @selector(diskPrevGalleryPage:);
  [self.diskPrevPageButton applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  self.diskPrevPageButton.hidden = YES; [v addSubview:self.diskPrevPageButton];
  self.diskPageLabel = [self label:@"1/1" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
  self.diskPageLabel.alignment = NSTextAlignmentCenter;
  self.diskPageLabel.frame = NSMakeRect(604, 32, 44, 16);
  self.diskPageLabel.hidden = YES; [v addSubview:self.diskPageLabel];
  self.diskNextPageButton = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(652, 26, 34, 26)];
  self.diskNextPageButton.title = @"›"; self.diskNextPageButton.hoverColor = [NSColor systemGreenColor];
  self.diskNextPageButton.target = self; self.diskNextPageButton.action = @selector(diskNextGalleryPage:);
  [self.diskNextPageButton applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  self.diskNextPageButton.hidden = YES; [v addSubview:self.diskNextPageButton];
  self.diskSelectedIndex = -1;
  self.diskScroll.hidden = YES;

  self.diskFileData = @[];
  self.diskFileFiltered = @[];
  self.diskView = v;
  [self refreshDiskVolumes];
}

- (void)refreshDiskVolumes {
  [self styleDiskSource];
}

- (void)styleDiskSource {
  NSInteger idx = MAX(0, self.diskVolumePopup.indexOfSelectedItem);
  NSArray *names = @[@"本地磁盘", @"外部磁盘", @"相册"];
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentLeft;
  NSColor *textColor = self.diskSourcePicked ? [NSColor systemIndigoColor] : [NSColor labelColor];
  self.diskVolumePopup.attributedTitle = [[NSAttributedString alloc] initWithString:names[idx] attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:(self.diskSourcePicked ? NSFontWeightSemibold : NSFontWeightRegular)], NSForegroundColorAttributeName: textColor, NSParagraphStyleAttributeName: ps}];
  self.diskVolumePopup.wantsLayer = YES;
  self.diskVolumePopup.layer.cornerRadius = 6;
  self.diskVolumePopup.layer.backgroundColor = (self.diskSourcePicked ? [[NSColor systemIndigoColor] colorWithAlphaComponent:0.12] : [NSColor clearColor]).CGColor;
}

- (void)diskVolumeChanged:(id)sender {
  self.diskSourcePicked = YES;
  [self styleDiskSource];
  self.diskCurrentPath = nil;
  [self.diskBackStack removeAllObjects];
  [self.diskForwardStack removeAllObjects];
  self.diskFileData = @[];
  self.diskFileFiltered = @[];
  self.diskGalleryItems = @[];
  self.diskAllGalleryItems = @[];
  self.diskGalleryPage = 0;
  [self applyDiskGalleryPage];
  [self.diskCollection reloadData];
  [self.diskTable reloadData];
  self.diskCollectionScroll.hidden = YES;
  self.diskScroll.hidden = YES;
  self.diskPathControl.hidden = YES;
  self.diskHintLabel.hidden = NO;
  self.diskHintLabel.stringValue = @"点击「刷新分析」开始浏览";
  self.diskTypeSegment.hidden = NO;
  self.diskStatus.stringValue = [NSString stringWithFormat:@"已选择 %@，点击「刷新分析」", self.diskVolumePopup.titleOfSelectedItem ?: @"来源"];
  self.diskStatus.textColor = [NSColor tertiaryLabelColor];
  [self updateDiskNavButtons];
}

- (NSString *)diskKindForPath:(NSString *)path {
  NSString *ext = path.pathExtension.lowercaseString;
  NSSet *imgs = [NSSet setWithObjects:@"jpg",@"jpeg",@"png",@"heic",@"heif",@"gif",@"tiff",@"tif",@"webp",@"bmp",@"raw",@"dng",@"cr2",@"nef",nil];
  NSSet *vids = [NSSet setWithObjects:@"mp4",@"mov",@"mkv",@"avi",@"m4v",@"webm",@"wmv",@"flv",@"mpg",@"mpeg",nil];
  if ([imgs containsObject:ext]) return @"图片";
  if ([vids containsObject:ext]) return @"视频";
  return @"文件";
}

- (void)updateDiskNavButtons {
  self.diskBackButton.enabled = self.diskBackStack.count > 0;
  self.diskForwardButton.enabled = self.diskForwardStack.count > 0;
}

- (void)loadDiskDirectory:(NSString *)path recordHistory:(BOOL)record {
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return;
  if ([self isProtectedUserPath:path]) {
    [self showToast:@"该目录受系统保护，已跳过以避免授权弹窗"];
    return;
  }
  if (record && self.diskCurrentPath.length) [self.diskBackStack addObject:self.diskCurrentPath];
  if (record) [self.diskForwardStack removeAllObjects];
  self.diskCurrentPath = path;
  [self updateDiskNavButtons];
  self.diskPathControl.URL = [NSURL fileURLWithPath:path];
  self.diskPathControl.hidden = NO;
  NSArray *names = [[fm contentsOfDirectoryAtPath:path error:NULL] ?: @[] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a localizedStandardCompare:b]; }];
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *name in names) {
    if ([name hasPrefix:@"."]) continue;
    NSString *full = [path stringByAppendingPathComponent:name];
    if ([self isProtectedUserPath:full]) {
      // 受保护目录不读取内容、不统计数量，避免触发系统授权弹窗
      [items addObject:@{@"name": name, @"path": full, @"isDir": @YES, @"count": @0, @"browser": @YES, @"kind": @"文件夹", @"date": [NSDate date], @"size": @0}];
      continue;
    }
    BOOL d = NO;
    [fm fileExistsAtPath:full isDirectory:&d];
    NSInteger count = 0;
    if (d) count = (NSInteger)(([fm contentsOfDirectoryAtPath:full error:NULL] ?: @[]).count);
    [items addObject:@{@"name": name, @"path": full, @"isDir": @(d), @"count": @(count), @"browser": @YES, @"kind": d ? @"文件夹" : [self diskKindForPath:full], @"date": [NSDate date], @"size": @0}];
  }
  [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    if ([a[@"isDir"] boolValue] != [b[@"isDir"] boolValue]) return [a[@"isDir"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
    return [a[@"name"] localizedStandardCompare:b[@"name"]];
  }];
  self.diskFileData = items;
  self.diskAllGalleryItems = items;
  self.diskGalleryPage = 0;
  self.diskFileFiltered = items;
  self.diskScroll.hidden = YES;
  self.diskCollectionScroll.hidden = NO;
  self.diskTypeSegment.hidden = YES;
  self.diskHintLabel.hidden = items.count > 0;
  self.diskHintLabel.stringValue = items.count ? @"" : @"文件夹为空";
  [self applyDiskGalleryPage];
  [self updateDiskGalleryLayout];
  [self.diskCollection.window makeFirstResponder:self.diskCollection];
  self.diskStatus.stringValue = [NSString stringWithFormat:@"%@ · %ld 个项目", path.lastPathComponent.length ? path.lastPathComponent : path, (long)items.count];
  self.diskStatus.textColor = [NSColor secondaryLabelColor];
  [self.diskSpinner stopAnimation:nil];
}

- (void)diskGoBack:(id)sender {
  if (!self.diskBackStack.count) return;
  NSString *p = self.diskBackStack.lastObject;
  [self.diskBackStack removeLastObject];
  if (self.diskCurrentPath.length) [self.diskForwardStack addObject:self.diskCurrentPath];
  [self loadDiskDirectory:p recordHistory:NO];
}

- (void)diskGoForward:(id)sender {
  if (!self.diskForwardStack.count) return;
  NSString *p = self.diskForwardStack.lastObject;
  [self.diskForwardStack removeLastObject];
  if (self.diskCurrentPath.length) [self.diskBackStack addObject:self.diskCurrentPath];
  [self loadDiskDirectory:p recordHistory:NO];
}

- (void)diskPathControlClicked:(NSPathControl *)sender {
  NSURL *url = sender.clickedPathItem.URL;
  if (url.isFileURL && ![url.path isEqualToString:self.diskCurrentPath]) {
    [self loadDiskDirectory:url.path recordHistory:YES];
  }
}

- (void)refreshDiskAnalysis {
  if (!self.diskTable) return;
  NSInteger src = self.diskVolumePopup.indexOfSelectedItem;
  if (src == 1) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"扫描外部磁盘";
    a.informativeText = @"外部磁盘需要「可移除宗卷」访问权限。如果结果为空或很少，请到系统设置 → 隐私与安全性 → 文件与文件夹中允许。\n\n是否继续扫描？";
    [a addButtonWithTitle:@"继续扫描"];
    [a addButtonWithTitle:@"打开设置"];
    [a addButtonWithTitle:@"取消"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertSecondButtonReturn) {
      [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"]];
      return;
    }
    if (r == NSAlertThirdButtonReturn) return;
  }
  if (src == 0 || src == 1) {
    NSString *start = self.diskCurrentPath;
    if (!start.length) {
      if (src == 0) start = NSHomeDirectory();
      else {
        NSArray *ext = [self scanExternalVolumes];
        start = ext.count ? [ext.firstObject[@"url"] path] : @"/Volumes";
      }
    }
    [self loadDiskDirectory:start recordHistory:YES];
    return;
  }
  NSMutableArray *roots = [NSMutableArray array];
  NSString *label = @"";
  if (src == 0) {
    label = @"本地磁盘";
    [roots addObject:@"/Applications"];
    [roots addObject:@"/Library"];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"centerScanPersonalMedia"]) {
      [roots addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Music"]];
      [roots addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Movies"]];
      [roots addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]];
    }
  } else if (src == 1) {
    NSArray *ext = [self scanExternalVolumes];
    if (!ext.count) {
      self.diskStatus.stringValue = @"未检测到外部磁盘";
      self.diskStatus.textColor = [NSColor systemRedColor];
      [self.diskSpinner stopAnimation:nil];
      return;
    }
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *vol in ext) {
      [roots addObject:[vol[@"url"] path]];
      if (vol[@"name"]) [names addObject:vol[@"name"]];
    }
    label = names.count ? [names componentsJoinedByString:@" + "] : @"外部磁盘";
  } else {
    label = @"相册";
    BOOL fullAlbum = [[NSUserDefaults standardUserDefaults] boolForKey:@"centerAlbumFullLibrary"];
    if (fullAlbum) {
      // PhotoKit 分支在后台处理，这里不预扫描路径
    } else {
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"] error:NULL] ?: @[];
    for (NSString *it in items) {
      if (![it.pathExtension.lowercaseString isEqualToString:@"photoslibrary"]) continue;
      NSString *orig = [[[NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"] stringByAppendingPathComponent:it] stringByAppendingPathComponent:@"originals"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:orig]) [roots addObject:orig];
    }
    if (!roots.count) {
      self.diskStatus.stringValue = @"未找到照片图库";
      [self.diskSpinner stopAnimation:nil];
      return;
    }
    }
  }
  self.diskStatus.stringValue = [NSString stringWithFormat:@"正在分析 %@…", label];
  self.diskStatus.textColor = [NSColor secondaryLabelColor];
  [self.diskSpinner startAnimation:nil];
  self.diskHintLabel.stringValue = @"正在扫描，请稍候…";
  self.diskHintLabel.hidden = NO;
  self.diskFileFiltered = @[];
  [self.diskTable reloadData];
  self.diskGeneration++;
  NSInteger gen = self.diskGeneration;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSMutableArray *files = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL fullAlbum = (src == 2 && [[NSUserDefaults standardUserDefaults] boolForKey:@"centerAlbumFullLibrary"]);
    if (fullAlbum) {
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) { dispatch_semaphore_signal(sem); }];
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
      PHAuthorizationStatus auth = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
      if (auth != PHAuthorizationStatusAuthorized && auth != PHAuthorizationStatusLimited) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf.diskSpinner stopAnimation:nil];
          weakSelf.diskStatus.stringValue = @"未授权照片图库，请在系统设置中允许访问";
          weakSelf.diskStatus.textColor = [NSColor systemRedColor];
        });
        return;
      }
      PHFetchOptions *opts = [[PHFetchOptions alloc] init];
      opts.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
      PHFetchResult<PHAsset *> *result = [PHAsset fetchAssetsWithOptions:opts];
      for (PHAsset *asset in result) {
        NSString *kind = asset.mediaType == PHAssetMediaTypeVideo ? @"视频" : @"图片";
        NSString *name = asset.localIdentifier;
        PHAssetResource *res = [PHAssetResource assetResourcesForAsset:asset].firstObject;
        if (res.originalFilename.length) name = res.originalFilename;
        NSDate *d = asset.creationDate ?: [NSDate date];
        [files addObject:@{@"name": name, @"path": @"", @"size": @0, @"kind": kind, @"date": d, @"assetID": asset.localIdentifier}];
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (gen != weakSelf.diskGeneration) return;
        weakSelf.diskFileData = files;
        weakSelf.diskFileFiltered = @[];
        weakSelf.diskTypeSegment.selectedSegment = -1;
        [weakSelf.diskTable reloadData];
        NSInteger ni = 0, nv = 0;
        for (NSDictionary *d in files) { if ([d[@"kind"] isEqualToString:@"图片"]) ni++; else nv++; }
        [weakSelf.diskSpinner stopAnimation:nil];
        weakSelf.diskHintLabel.hidden = NO;
        weakSelf.diskHintLabel.stringValue = @"刷新完成，点击上方「图片 / 视频」查看相册";
        weakSelf.diskScroll.hidden = YES;
        weakSelf.diskCollectionScroll.hidden = YES;
        weakSelf.diskStatus.stringValue = [NSString stringWithFormat:@"分析完成 · 相册 · 图片 %ld · 视频 %ld", (long)ni, (long)nv];
        weakSelf.diskStatus.textColor = [NSColor systemGreenColor];
      });
      return;
    }
    for (NSString *root in roots) {
      if ([self isProtectedUserPath:root]) continue;
      if (![fm fileExistsAtPath:root]) continue;
      NSURL *url = [NSURL fileURLWithPath:root];
      NSDirectoryEnumerator *en = [fm enumeratorAtURL:url includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLFileAllocatedSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
      for (NSURL *u in en) {
        id isReg = nil;
        if (![u getResourceValue:&isReg forKey:NSURLIsRegularFileKey error:NULL] || ![isReg boolValue]) continue;
        id sz = nil; unsigned long long size = 0;
        if ([u getResourceValue:&sz forKey:NSURLFileAllocatedSizeKey error:NULL] && [sz isKindOfClass:[NSNumber class]]) size = [sz unsignedLongLongValue];
        if (!size) { if ([u getResourceValue:&sz forKey:NSURLFileSizeKey error:NULL] && [sz isKindOfClass:[NSNumber class]]) size = [sz unsignedLongLongValue]; }
        NSString *path = u.path;
        NSString *kind = [weakSelf diskKindForPath:path];
        if (src == 2 && ![kind isEqualToString:@"图片"] && ![kind isEqualToString:@"视频"]) continue;
        id dval = nil; NSDate *fdate = nil;
        if ([u getResourceValue:&dval forKey:NSURLContentModificationDateKey error:NULL] && [dval isKindOfClass:[NSDate class]]) fdate = dval;
        if (!fdate) fdate = [NSDate date];
        [files addObject:@{@"name": path.lastPathComponent, @"path": path, @"size": @(size), @"kind": kind, @"date": fdate}];
        if (files.count % 100 == 0) {
          NSInteger scanned = files.count;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != weakSelf.diskGeneration) return;
            weakSelf.diskStatus.stringValue = [NSString stringWithFormat:@"正在分析 %@… 已扫描 %ld 个文件", label, (long)scanned];
          });
        }
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gen != weakSelf.diskGeneration) return;
      weakSelf.diskFileData = files;
      weakSelf.diskFileFiltered = @[];
      weakSelf.diskTypeSegment.selectedSegment = -1;
      [weakSelf.diskTable reloadData];
      NSInteger nf = 0, ni = 0, nv = 0;
      for (NSDictionary *d in files) {
        if ([d[@"kind"] isEqualToString:@"图片"]) ni++;
        else if ([d[@"kind"] isEqualToString:@"视频"]) nv++;
        else nf++;
      }
      weakSelf.diskHintLabel.hidden = NO;
      weakSelf.diskHintLabel.stringValue = @"刷新完成，点击上方「文件 / 图片 / 视频」查看";
      weakSelf.diskScroll.hidden = YES;
      weakSelf.diskCollectionScroll.hidden = YES;
      [weakSelf.diskSpinner stopAnimation:nil];
      weakSelf.diskStatus.stringValue = [NSString stringWithFormat:@"分析完成 · %@ · 文件 %ld · 图片 %ld · 视频 %ld", label, (long)nf, (long)ni, (long)nv];
      weakSelf.diskStatus.textColor = [NSColor systemGreenColor];
    });
  });
}

- (void)applyDiskGalleryPage {
  NSInteger total = self.diskAllGalleryItems.count;
  NSInteger pages = MAX(1, (total + 5) / 6);
  if (self.diskGalleryPage >= pages) self.diskGalleryPage = pages - 1;
  if (self.diskGalleryPage < 0) self.diskGalleryPage = 0;
  NSInteger start = self.diskGalleryPage * 6;
  NSInteger len = MIN(6, MAX(0, total - start));
  self.diskGalleryItems = len > 0 ? [self.diskAllGalleryItems subarrayWithRange:NSMakeRange(start, len)] : @[];
  [self.diskCollection reloadData];
  self.diskPageLabel.stringValue = [NSString stringWithFormat:@"%ld/%ld", (long)(self.diskGalleryPage + 1), (long)pages];
  BOOL show = self.diskCollectionScroll.hidden == NO && total > 0;
  self.diskPrevPageButton.hidden = !show; self.diskNextPageButton.hidden = !show; self.diskPageLabel.hidden = !show;
  self.diskPrevPageButton.enabled = self.diskGalleryPage > 0;
  self.diskNextPageButton.enabled = self.diskGalleryPage < pages - 1;
  self.diskPrevPageButton.alphaValue = self.diskPrevPageButton.enabled ? 1.0 : 0.4;
  self.diskNextPageButton.alphaValue = self.diskNextPageButton.enabled ? 1.0 : 0.4;
}

- (void)diskPrevGalleryPage:(id)sender {
  if (self.diskGalleryPage <= 0) return;
  self.diskGalleryPage--;
  [self applyDiskGalleryPage];
}

- (void)diskNextGalleryPage:(id)sender {
  self.diskGalleryPage++;
  [self applyDiskGalleryPage];
}

- (void)updateDiskGalleryLayout {
  if (!self.diskView || !self.diskFlowLayout || self.section != 3 || !self.diskCollectionScroll) return;
  CGFloat viewW = self.diskView.bounds.size.width;
  CGFloat cardW = MAX(620, viewW - 48);
  self.diskCard.frame = NSMakeRect(24, 64, cardW, 452);
  CGFloat scrollW = cardW - 32;
  self.diskScroll.frame = NSMakeRect(16, 40, scrollW, 360);
  self.diskCollectionScroll.frame = NSMakeRect(16, 40, scrollW, 360);
  self.diskHintLabel.frame = NSMakeRect(16, 190, scrollW, 24);
  self.diskCollection.frame = NSMakeRect(0, 0, scrollW, 360);
  NSInteger cols = scrollW < 660 ? 2 : (scrollW < 980 ? 3 : 4);
  CGFloat gap = 10;
  CGFloat itemW = floor((scrollW - 20 - gap * (cols - 1)) / cols);
  self.diskFlowLayout.itemSize = NSMakeSize(itemW, MIN(itemW, 160));
  self.diskFlowLayout.minimumInteritemSpacing = gap;
  self.diskFlowLayout.minimumLineSpacing = gap;
  [self.diskFlowLayout invalidateLayout];
  [self.diskCollection reloadData];
}

- (void)showDatePopover:(id)sender {
  if (!self.diskDatePopover) {
    self.diskDatePicker = [[NSDatePicker alloc] init];
    self.diskDatePicker.datePickerStyle = NSDatePickerStyleClockAndCalendar;
    self.diskDatePicker.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    self.diskDatePicker.dateValue = [NSDate date];
    self.diskDatePicker.translatesAutoresizingMaskIntoConstraints = NO;
    NSViewController *vc = [[NSViewController alloc] init];
    NSView *pv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 340)];
    [pv addSubview:self.diskDatePicker];
    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(diskDateCancel:)];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *ok = [NSButton buttonWithTitle:@"确定" target:self action:@selector(diskDateConfirm:)];
    ok.translatesAutoresizingMaskIntoConstraints = NO;
    [pv addSubview:cancel];
    [pv addSubview:ok];
    [NSLayoutConstraint activateConstraints:@[
      [self.diskDatePicker.topAnchor constraintEqualToAnchor:pv.topAnchor constant:8],
      [self.diskDatePicker.leadingAnchor constraintEqualToAnchor:pv.leadingAnchor constant:8],
      [self.diskDatePicker.trailingAnchor constraintEqualToAnchor:pv.trailingAnchor constant:-8],
      [cancel.bottomAnchor constraintEqualToAnchor:pv.bottomAnchor constant:-8],
      [cancel.trailingAnchor constraintEqualToAnchor:pv.trailingAnchor constant:-8],
      [cancel.widthAnchor constraintEqualToConstant:70],
      [cancel.heightAnchor constraintEqualToConstant:28],
      [ok.bottomAnchor constraintEqualToAnchor:pv.bottomAnchor constant:-8],
      [ok.trailingAnchor constraintEqualToAnchor:cancel.leadingAnchor constant:-8],
      [ok.widthAnchor constraintEqualToConstant:70],
      [ok.heightAnchor constraintEqualToConstant:28],
      [self.diskDatePicker.bottomAnchor constraintEqualToAnchor:cancel.topAnchor constant:-8]
    ]];
    vc.view = pv;
    [pv layoutSubtreeIfNeeded];
    NSSize fit = [pv fittingSize];
    if (fit.width < 280 || fit.height < 280) fit = NSMakeSize(300, 340);
    vc.preferredContentSize = fit;
    self.diskDatePopover = [[NSPopover alloc] init];
    self.diskDatePopover.contentViewController = vc;
    self.diskDatePopover.contentSize = fit;
    self.diskDatePopover.behavior = NSPopoverBehaviorTransient;
  }
  if (self.diskDatePopover.isShown) {
    [self.diskDatePopover close];
  } else {
    [self.diskDatePopover showRelativeToRect:self.diskDateButton.bounds ofView:self.diskDateButton preferredEdge:NSRectEdgeMaxY];
  }
}

- (void)diskDateCancel:(id)sender {
  [self.diskDatePopover close];
}

- (void)diskDateConfirm:(id)sender {
  NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy/MM/dd";
  self.diskDateButton.title = [df stringFromDate:self.diskDatePicker.dateValue];
  self.diskDateFilter = self.diskDatePicker.dateValue;
  self.diskTypeSegment.selectedSegment = -1;
  [self.diskDatePopover close];
  [self diskFilterChanged:nil];
}

- (void)diskClearDate:(id)sender {
  self.diskDateFilter = nil;
  self.diskDateButton.title = @"选择日期";
  [self.diskDatePopover close];
  self.diskTypeSegment.selectedSegment = -1;
  self.diskFileFiltered = @[];
  [self.diskTable reloadData];
  self.diskScroll.hidden = YES;
  self.diskCollectionScroll.hidden = YES;
  self.diskHintLabel.hidden = NO;
  self.diskHintLabel.stringValue = @"已清除日期筛选，请点击上方「文件 / 图片 / 视频」查看";
  self.diskStatus.stringValue = @"已清除日期筛选";
}

- (void)diskFilterChanged:(id)sender {
  if (!self.diskFileData.count) {
    self.diskStatus.stringValue = @"请先选择来源并点击「刷新分析」";
    return;
  }
  NSArray *base = self.diskFileData;
  if (self.diskDateFilter) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *day = self.diskDateFilter;
    NSMutableArray *byDate = [NSMutableArray array];
    for (NSDictionary *d in base) {
      NSDate *fd = d[@"date"];
      if (fd && [cal isDate:fd inSameDayAsDate:day]) [byDate addObject:d];
    }
    base = byDate;
  }
  NSInteger idx = self.diskTypeSegment.selectedSegment;
  NSMutableArray *a = [NSMutableArray array];
  if (idx == 0 || idx == 1 || idx == 2) {
    NSString *want = idx == 0 ? @"文件" : (idx == 1 ? @"图片" : @"视频");
    for (NSDictionary *d in base) if ([d[@"kind"] isEqualToString:want]) [a addObject:d];
  } else {
    [a addObjectsFromArray:base];
  }
  self.diskFileFiltered = [self diskSortedArray:a];
  if ((idx == 1 || idx == 2) && self.diskFileFiltered.count) {
    self.diskAllGalleryItems = self.diskFileFiltered;
    self.diskGalleryPage = 0;
    self.diskScroll.hidden = YES;
    self.diskCollectionScroll.hidden = NO;
    [self applyDiskGalleryPage];
    [self updateDiskGalleryLayout];
    [self.diskCollection.window makeFirstResponder:self.diskCollection];
  } else {
    self.diskScroll.hidden = NO;
    self.diskCollectionScroll.hidden = YES;
    self.diskPrevPageButton.hidden = YES;
    self.diskNextPageButton.hidden = YES;
    self.diskPageLabel.hidden = YES;
    [self.diskTable reloadData];
  }
  self.diskHintLabel.hidden = (self.diskFileFiltered.count > 0);
  if (!self.diskHintLabel.hidden) self.diskHintLabel.stringValue = @"当前筛选条件下暂无文件";
  NSString *dateText = @"";
  if (self.diskDateFilter) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy/MM/dd";
    dateText = [NSString stringWithFormat:@"%@ · ", [df stringFromDate:self.diskDateFilter]];
  }
  self.diskStatus.stringValue = [NSString stringWithFormat:@"%@%ld 个 · 按时间降序", dateText, (long)self.diskFileFiltered.count];
}

- (NSArray *)diskSortedArray:(NSArray *)arr {
  NSSortDescriptor *sd = self.diskTable.sortDescriptors.firstObject;
  if (!sd) sd = [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO];
  return [arr sortedArrayUsingDescriptors:@[sd]];
}

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
  NSIndexPath *ip = indexPaths.anyObject;
  self.diskSelectedIndex = ip ? ip.item : -1;
}
- (void)galleryItemClicked:(DiskGalleryItem *)item {
  NSInteger idx = [self.diskGalleryItems indexOfObject:item.file];
  if (idx == NSNotFound) return;
  self.diskSelectedIndex = idx;
  NSIndexPath *ip = [NSIndexPath indexPathForItem:idx inSection:0];
  [self.diskCollection selectItemsAtIndexPaths:[NSSet setWithObject:ip] scrollPosition:NSCollectionViewScrollPositionNone];
}
- (void)galleryItemDoubleClicked:(DiskGalleryItem *)item {
  NSInteger idx = [self.diskGalleryItems indexOfObject:item.file];
  if (idx == NSNotFound) return;
  self.diskSelectedIndex = idx;
  [self diskGalleryDoubleClick:nil];
}
- (void)exportAlbumAssetID:(NSString *)assetID completion:(void (^)(NSString *path))completion {
  PHAsset *asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[assetID] options:nil].firstObject;
  if (!asset) { completion(nil); return; }
  PHAssetResource *res = [PHAssetResource assetResourcesForAsset:asset].firstObject;
  if (!res) { completion(nil); return; }
  NSString *name = res.originalFilename.length ? res.originalFilename : [assetID stringByAppendingString:@".jpg"];
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DockLaunchersPreview"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
  NSURL *dst = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
  [[PHAssetResourceManager defaultManager] writeDataForAssetResource:res toFile:dst options:nil completionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(error ? nil : dst.path); });
  }];
}

- (void)previewSelectedDiskFile {
  if (self.diskSelectedIndex < 0 || self.diskSelectedIndex >= (NSInteger)self.diskGalleryItems.count) return;
  NSDictionary *item = self.diskGalleryItems[self.diskSelectedIndex];
  NSString *path = item[@"path"];
  NSString *assetID = item[@"assetID"];
  if (!path.length && assetID.length) {
    __weak typeof(self) weakSelf = self;
    [self exportAlbumAssetID:assetID completion:^(NSString *exported) {
      if (!exported.length) return;
      weakSelf.userFilesPreviewPath = exported;
      weakSelf.diskPreviewMode = NO;
      QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
      panel.dataSource = weakSelf;
      panel.delegate = weakSelf;
      [panel makeKeyAndOrderFront:nil];
      [panel reloadData];
    }];
    return;
  }
  if (!path) return;
  self.userFilesPreviewPath = path;
  self.diskPreviewMode = YES;
  QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
  panel.dataSource = self;
  panel.delegate = self;
  [panel makeKeyAndOrderFront:nil];
  [panel reloadData];
  panel.currentPreviewItemIndex = self.diskSelectedIndex;
}
- (void)diskGalleryDoubleClick:(id)sender {
  NSInteger row = self.diskSelectedIndex;
  if (row < 0 || row >= (NSInteger)self.diskGalleryItems.count) return;
  NSDictionary *item = self.diskGalleryItems[row];
  NSString *path = item[@"path"];
  NSString *assetID = item[@"assetID"];
  if (!path.length && assetID.length) {
    __weak typeof(self) weakSelf = self;
    [self exportAlbumAssetID:assetID completion:^(NSString *exported) {
      if (!exported.length) return;
      [weakSelf showOpenWithForPath:exported];
    }];
    return;
  }
  if (!path) return;
  [self showOpenWithForPath:path];
}
- (void)showOpenWithForPath:(NSString *)path {
  NSURL *url = [NSURL fileURLWithPath:path];
  NSArray *apps = CFBridgingRelease(LSCopyApplicationURLsForURL((__bridge CFURLRef)url, kLSRolesAll));
  if (!apps.count) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"没有可用于打开该文件的应用";
    [a runModal];
    return;
  }
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"选择打开方式";
  alert.informativeText = [NSString stringWithFormat:@"%@", path.lastPathComponent];
  [alert addButtonWithTitle:@"打开"];
  [alert addButtonWithTitle:@"取消"];
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 28) pullsDown:NO];
  [popup addItemWithTitle:@"请选择应用…"];
  for (NSURL *app in apps) {
    NSString *name = [[NSFileManager defaultManager] displayNameAtPath:app.path] ?: app.lastPathComponent;
    [popup addItemWithTitle:name];
    popup.lastItem.representedObject = app;
  }
  popup.frame = NSMakeRect(0, 0, 320, 28);
  alert.accessoryView = popup;
  NSModalResponse resp = [alert runModal];
  if (resp != NSAlertFirstButtonReturn || popup.indexOfSelectedItem <= 0) return;
  NSURL *appURL = popup.selectedItem.representedObject;
  if (appURL) [[NSWorkspace sharedWorkspace] openURLs:@[url] withApplicationAtURL:appURL configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}
- (void)diskRowDoubleClicked:(id)sender {
  NSInteger row = self.diskTable.clickedRow;
  if (row < 0 || row >= (NSInteger)self.diskFileFiltered.count) return;
  NSString *path = self.diskFileFiltered[row][@"path"];
  if (path) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
}

- (void)buildUninstallView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"应用卸载" size:24 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"扫描本机应用（全部应用）或仅分组内；已排除本程序自身的 Dock 分组应用" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 550, 18); [v addSubview:sub];

  self.uninstallScopeCtl = [[ScopeColorControl alloc] initWithFrame:NSMakeRect(24, 540, 180, 28)
                                                             title0:@"全部应用" color0:[NSColor systemBlueColor]
                                                             title1:@"仅分组内" color1:[NSColor systemPurpleColor]
                                                             target:self action:@selector(uninstallScopeChanged:)];
  [v addSubview:self.uninstallScopeCtl];
  self.uninstallGroupPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(210, 540, 122, 28) pullsDown:NO];
  self.uninstallGroupPopup.target = self;
  self.uninstallGroupPopup.action = @selector(uninstallGroupChanged:);
  self.uninstallGroupPopup.wantsLayer = YES;
  self.uninstallGroupPopup.layer.cornerRadius = 7;
  self.uninstallGroupPopup.layer.backgroundColor = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.16].CGColor;
  self.uninstallGroupPopup.contentTintColor = [NSColor systemOrangeColor];
  [v addSubview:self.uninstallGroupPopup];
  self.uninstallSearch = [[NSSearchField alloc] initWithFrame:NSMakeRect(340, 540, 196, 28)];
  self.uninstallSearch.placeholderString = @"搜索应用、Bundle ID 或路径";
  self.uninstallSearch.target = self;
  self.uninstallSearch.action = @selector(uninstallFilterChanged:);
  [self.uninstallSearch setContinuous:YES];
  [v addSubview:self.uninstallSearch];
  ColorHoverButton *all = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(544, 540, 50, 30)];
  all.title = @"全选"; all.hoverColor = [NSColor systemOrangeColor]; all.target = self; all.action = @selector(uninstallSelectAll:);
  [all applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:all];
  ColorHoverButton *none = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(596, 540, 56, 30)];
  none.title = @"全不选"; none.hoverColor = [NSColor systemYellowColor]; none.target = self; none.action = @selector(uninstallSelectNone:);
  [none applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:none];
  ColorHoverButton *refresh = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(656, 540, 56, 30)];
  refresh.title = @"刷新"; refresh.hoverColor = [NSColor systemGreenColor]; refresh.target = self; refresh.action = @selector(forceRefreshUninstall:);
  refresh.keyEquivalent = @"r"; refresh.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [refresh applyColor:DLButtonBackground() textColor:[NSColor labelColor]]; [v addSubview:refresh];

  self.letterIndex = [[LetterIndexView alloc] initWithFrame:NSMakeRect(18, 76, 26, 450)];
  self.letterIndex.target = self;
  self.letterIndex.action = @selector(letterIndexClicked:);
  [v addSubview:self.letterIndex];
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(48, 76, 682, 450)];
  sv.hasVerticalScroller = YES;
  sv.drawsBackground = NO;
  self.uninstallTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0,0,710,450)];
  self.uninstallTable.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
  self.uninstallTable.dataSource = self;
  self.uninstallTable.delegate = self;
  self.uninstallTable.rowHeight = 52;
  self.uninstallTable.usesAlternatingRowBackgroundColors = NO;
  NSArray *cols = @[@[@"app", @"应用", @(330)], @[@"group", @"来源", @(120)],
                    @[@"size", @"大小", @(90)], @[@"installed", @"安装日期", @(100)]];
  for (NSArray *c in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1]; col.width = [c[2] doubleValue];
    if ([c[0] isEqualToString:@"size"]) {
      col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"size" ascending:YES];
    } else if ([c[0] isEqualToString:@"app"]) {
      col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
    } else if ([c[0] isEqualToString:@"installed"]) {
      col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"installed" ascending:YES];
    }
    [self.uninstallTable addTableColumn:col];
  }
  sv.documentView = self.uninstallTable;
  [v addSubview:sv];

  self.uninstallFooter = [self label:@"" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  self.uninstallFooter.frame = NSMakeRect(24, 34, 380, 18);
  [v addSubview:self.uninstallFooter];
  ColorHoverButton *go = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(580, 26, 120, 32)];
  go.title = @"卸载所选应用"; go.hoverColor = [NSColor systemRedColor]; go.target = self; go.action = @selector(confirmUninstallApps:);
  [go applyColor:[NSColor systemRedColor] textColor:[NSColor whiteColor]];
  [v addSubview:go]; self.uninstallGo = go;
  self.uninstallView = v;
}

- (void)refreshUninstallGroupPopup {
  NSString *prev = self.uninstallGroupPopup.titleOfSelectedItem;
  [self.uninstallGroupPopup removeAllItems];
  [self.uninstallGroupPopup addItemWithTitle:@"全部分组"];
  NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:GroupDir() error:NULL];
  for (NSString *f in items) {
    if (![f hasSuffix:@".app"]) continue;
    [self.uninstallGroupPopup addItemWithTitle:[f stringByDeletingPathExtension]];
  }
  if (prev.length && [self.uninstallGroupPopup itemWithTitle:prev]) [self.uninstallGroupPopup selectItemWithTitle:prev];
  self.uninstallGroupPopup.enabled = (self.uninstallScope == 1);
  self.uninstallGroupPopup.alphaValue = (self.uninstallScope == 1) ? 1.0 : 0.45;
}

- (void)uninstallGroupChanged:(id)sender {
  [self reloadUninstallData];
}

- (unsigned long long)duSizeAtPath:(NSString *)path {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/du";
  t.arguments = @[@"-sk", path];
  NSPipe *pipe = [NSPipe pipe];
  t.standardOutput = pipe;
  t.standardError = [NSPipe pipe];
  @try { [t launch]; } @catch (NSException *e) { return 0; }
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  NSInteger kb = [[out componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] firstObject].integerValue;
  return (unsigned long long)MAX(kb, 0) * 1024ULL;
}

- (void)uninstallBlankClicked:(NSClickGestureRecognizer *)g {
  if (!self.letterFilter.length) return;
  NSPoint p = [g locationInView:self.uninstallView];
  if (self.uninstallTable.enclosingScrollView && NSPointInRect(p, self.uninstallTable.enclosingScrollView.frame)) return;
  if (NSPointInRect(p, self.letterIndex.frame)) return;
  if (p.y > 520) return;
  [self cancelLetterFilter];
}

- (void)uninstallScopeChanged:(id)sender {
  self.uninstallScope = self.uninstallScopeCtl.selectedSegment;
  self.uninstallGroupPopup.enabled = (self.uninstallScope == 1);
  self.uninstallGroupPopup.alphaValue = (self.uninstallScope == 1) ? 1.0 : 0.45;
  [self reloadUninstallData];
}

- (void)forceRefreshUninstall:(id)sender {
  [self cancelLetterFilter];
  self.uninstallSearch.stringValue = @"";
  [self.uninstallTable setSortDescriptors:@[]];
  [self.uninstallSelected removeAllObjects];
  self.uninstallFiltered = [NSMutableArray array];
  [self.uninstallTable reloadData];
  [self.uninstallFooter setStringValue:@"正在强制刷新…"];
  [self reloadUninstallData];
}

- (void)reloadUninstallData {
  [self refreshUninstallGroupPopup];
  NSFileManager *fm = [NSFileManager defaultManager];
  // 收集分组内的 target -> 分组名
  NSMutableDictionary *targetGroup = [NSMutableDictionary dictionary];
  NSArray *groupItems = [fm contentsOfDirectoryAtPath:GroupDir() error:NULL];
  for (NSString *f in groupItems) {
    if (![f hasSuffix:@".app"]) continue;
    NSString *base = [f stringByDeletingPathExtension];
    NSString *listFile = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"txt"]];
    NSString *content = [NSString stringWithContentsOfFile:listFile encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (!line.length || [line hasPrefix:@"#"]) continue;
      NSString *target = line;
      NSRange r = [line rangeOfString:@"|"];
      if (r.location != NSNotFound) target = [[line substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSString *p = ResolveAppPath(target);
      if (p) targetGroup[p] = base;
    }
  }

  NSMutableArray *paths = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  void (^addApp)(NSString *) = ^(NSString *p) {
    if (![p hasSuffix:@".app"]) return;
    NSString *real = [p stringByResolvingSymlinksInPath];
    if ([real hasPrefix:@"/System/"] || [p hasPrefix:@"/System/"]) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return;
    if ([seen containsObject:p]) return;
    [seen addObject:p];
    [paths addObject:p];
  };

  if (self.uninstallScope == 1) {
    NSString *selG = self.uninstallGroupPopup.titleOfSelectedItem ?: @"全部分组";
    for (NSString *p in targetGroup) {
      if ([selG isEqualToString:@"全部分组"] || [targetGroup[p] isEqualToString:selG]) addApp(p);
    }
  } else {
    NSArray *roots = @[@"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
    // 递归扫描（最多 2 层子目录），覆盖 Adobe、Setapp 等子文件夹
    NSMutableArray *queue = [NSMutableArray array];
    for (NSString *r in roots) [queue addObject:@{@"dir": r, @"depth": @0}];
    while (queue.count) {
      NSDictionary *item = queue.firstObject;
      [queue removeObjectAtIndex:0];
      NSString *dir = item[@"dir"];
      NSInteger depth = [item[@"depth"] integerValue];
      for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        NSString *full = [dir stringByAppendingPathComponent:f];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || !isDir) continue;
        if ([f hasSuffix:@".app"]) { addApp(full); continue; }
        if (depth < 2) [queue addObject:@{@"dir": full, @"depth": @(depth + 1)}];
      }
    }
    for (NSString *p in targetGroup) addApp(p);
  }

  NSArray *running = [[NSWorkspace sharedWorkspace] runningApplications];
  NSMutableArray *arr = [NSMutableArray array];
  for (NSString *p in paths) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *bid = info[@"CFBundleIdentifier"] ?: @"";
    // 排除本程序自身创建的 Dock 分组 / 恢复工具 / 控制台
    if ([bid hasPrefix:@"com.docklaunchers."]) continue;
    if ([p hasPrefix:GroupDir()]) continue;
    NSString *label = LocalizedAppName(p, info);
    BOOL isRunning = NO;
    for (NSRunningApplication *ra in running) if (ra.bundleURL && [[ra.bundleURL path] isEqualToString:p]) { isRunning = YES; break; }
    NSString *group = targetGroup[p];
    if (!group.length) group = @"未加入分组";
    NSDictionary *attr = [fm attributesOfItemAtPath:p error:NULL] ?: @{};
    NSMutableDictionary *d = [@{@"label": label, @"name": [[p lastPathComponent] stringByDeletingPathExtension],
                                @"path": p, @"group": group,
                                @"bid": bid,
                                @"size": @0,
                                @"installed": (InstallDateForPath(p) ?: [NSDate distantPast]),
                                @"running": @(isRunning),
                                @"target": (targetGroup[p] ? p : p)} mutableCopy];
    [arr addObject:d];
  }
  [arr sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    NSString *ka = LetterSortKey(a[@"label"] ?: @"");
    NSString *kb = LetterSortKey(b[@"label"] ?: @"");
    NSComparisonResult r = [ka compare:kb];
    if (r != NSOrderedSame) return r;
    return [(a[@"label"] ?: @"") compare:(b[@"label"] ?: @"") options:(NSCaseInsensitiveSearch|NSNumericSearch)];
  }];
  self.uninstallData = arr;
  if (getenv("DOCKLAUNCHERS_CENTER_DUMP")) {
    for (NSDictionary *d in arr) fprintf(stderr, "APP: %s\n", [d[@"path"] UTF8String]);
    exit(0);
  }
  if (!self.uninstallSelected) self.uninstallSelected = [NSMutableSet set];
  [self.uninstallSelected removeAllObjects];
  [self applyUninstallFilter];

  // 后台计算大小，完成后刷新
  NSArray *snapshot = [arr copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSInteger done = 0;
    for (NSMutableDictionary *d in snapshot) {
      d[@"size"] = @([self duSizeAtPath:d[@"path"]]);
      done++;
      if (done % 6 == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (self.uninstallData == arr) [self.uninstallTable reloadData];
        });
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.uninstallData == arr) {
        [self.uninstallTable reloadData];
        [self updateUninstallFooter];
      }
    });
  });
}

- (void)rebuildLetterIndex {
  NSMutableArray *letters = [NSMutableArray array];
  for (char c = 'A'; c <= 'Z'; c++) [letters addObject:[NSString stringWithFormat:@"%c", c]];
  [letters addObject:@"#"];
  self.letters = letters;
  self.letterIndex.letters = letters;
  self.letterIndex.hidden = NO;
}

- (void)restartLetterFilterTimer {
  [self.letterFilterTimer invalidate];
  self.letterFilterTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(cancelLetterFilter) userInfo:nil repeats:NO];
}
- (void)cancelLetterFilter {
  if (!self.letterFilter.length) return;
  self.letterFilter = nil;
  [self.letterFilterTimer invalidate];
  self.letterFilterTimer = nil;
  if (self.letterActivityMonitor) { [NSEvent removeMonitor:self.letterActivityMonitor]; self.letterActivityMonitor = nil; }
  [self applyUninstallFilter];
}
- (void)letterIndexClicked:(NSString *)letter {
  self.letterFilter = letter;
  [self applyUninstallFilter];
  [self.uninstallTable scrollRowToVisible:0];
  [self restartLetterFilterTimer];
  if (!self.letterActivityMonitor) {
    __weak typeof(self) weakSelf = self;
    self.letterActivityMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved|NSEventMaskKeyDown|NSEventMaskScrollWheel|NSEventMaskLeftMouseDown) handler:^NSEvent *(NSEvent *e) {
      if (weakSelf.letterFilter.length) {
        [weakSelf restartLetterFilterTimer];
        if (e.type == NSEventTypeLeftMouseDown && e.window == weakSelf.window) {
          NSPoint p = [weakSelf.uninstallView convertPoint:e.locationInWindow fromView:nil];
          BOOL inTable = weakSelf.uninstallTable.enclosingScrollView && NSPointInRect(p, weakSelf.uninstallTable.enclosingScrollView.frame);
          BOOL inLetters = NSPointInRect(p, weakSelf.letterIndex.frame);
          if (!inTable && !inLetters && p.y < 520) [weakSelf cancelLetterFilter];
        }
      }
      return e;
    }];
  }
}

- (void)applyUninstallFilter {
  NSString *q = [self.uninstallSearch.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *d in self.uninstallData) {
    if (self.letterFilter.length && ![LetterSortKey(d[@"label"] ?: @"") isEqualToString:self.letterFilter]) continue;
    if (q.length) {
      NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", d[@"label"], d[@"bid"], d[@"path"]];
      if ([hay rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
    }
    [out addObject:d];
  }
  self.uninstallFiltered = out;
  [self.uninstallTable reloadData];
  [self rebuildLetterIndex];
  [self updateUninstallFooter];
}

- (void)uninstallFilterChanged:(id)sender { [self applyUninstallFilter]; }

- (void)updateUninstallFooter {
  unsigned long long sel = 0;
  for (NSDictionary *d in self.uninstallData) if ([self.uninstallSelected containsObject:d[@"path"]]) sel += [d[@"size"] unsignedLongLongValue];
  self.uninstallFooter.stringValue = [NSString stringWithFormat:@"共 %ld 个应用 · 已选择 %ld 个 · 预计释放 %@", (long)self.uninstallData.count, (long)self.uninstallSelected.count, [self fmtSize:sel]];
  self.uninstallGo.enabled = (self.uninstallSelected.count > 0);
}

- (NSString *)fmtSize:(unsigned long long)bytes {
  if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
  double v = bytes; NSArray *u = @[@"KB",@"MB",@"GB",@"TB"]; NSInteger i = -1;
  do { v /= 1024.0; i++; } while (v >= 1024 && i < 3);
  return [NSString stringWithFormat:@"%.2f %@", v, u[i]];
}

- (void)uninstallSelectAll:(id)sender {
  for (NSDictionary *d in self.uninstallFiltered) [self.uninstallSelected addObject:d[@"path"]];
  [self.uninstallTable reloadData]; [self updateUninstallFooter];
}
- (void)uninstallSelectNone:(id)sender {
  [self.uninstallSelected removeAllObjects];
  [self.uninstallTable reloadData]; [self updateUninstallFooter];
}
- (void)uninstallRowToggle:(NSButton *)b {
  NSInteger row = b.tag;
  if (row < 0 || row >= (NSInteger)self.uninstallFiltered.count) return;
  NSString *p = self.uninstallFiltered[row][@"path"];
  if ([self.uninstallSelected containsObject:p]) { [self.uninstallSelected removeObject:p]; b.state = NSControlStateValueOff; }
  else { [self.uninstallSelected addObject:p]; b.state = NSControlStateValueOn; }
  [self updateUninstallFooter];
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
  if (tableView == self.diskTable) {
    self.diskFileFiltered = [self diskSortedArray:self.diskFileFiltered];
    [self.diskTable reloadData];
    if (self.diskTypeSegment.selectedSegment >= 0 && self.diskFileFiltered.count) {
      NSSortDescriptor *sd = self.diskTable.sortDescriptors.firstObject;
      self.diskStatus.stringValue = [NSString stringWithFormat:@"%ld 个 · 按%@%@排序", (long)self.diskFileFiltered.count, sd.key ?: @"大小", sd.ascending ? @"升序" : @"降序"];
    }
    return;
  }
  if (tableView != self.uninstallTable) return;
  NSSortDescriptor *sd = tableView.sortDescriptors.firstObject;
  if (!sd) return;
  BOOL asc = sd.ascending;
  NSString *key = sd.key ?: @"size";
  [self.uninstallFiltered sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    NSComparisonResult r = NSOrderedSame;
    if ([key isEqualToString:@"name"]) {
      r = [LetterSortKey(a[@"label"] ?: @"") compare:LetterSortKey(b[@"label"] ?: @"")];
      if (r == NSOrderedSame) r = [(a[@"label"] ?: @"") compare:(b[@"label"] ?: @"") options:(NSCaseInsensitiveSearch|NSNumericSearch)];
    } else if ([key isEqualToString:@"installed"]) {
      r = [(a[@"installed"] ?: [NSDate date]) compare:(b[@"installed"] ?: [NSDate date])];
    } else {
      unsigned long long sa = [a[@"size"] unsignedLongLongValue];
      unsigned long long sb = [b[@"size"] unsignedLongLongValue];
      r = (sa < sb) ? NSOrderedAscending : (sa > sb ? NSOrderedDescending : NSOrderedSame);
    }
    if (!asc) r = (r == NSOrderedAscending ? NSOrderedDescending : (r == NSOrderedDescending ? NSOrderedAscending : NSOrderedSame));
    return r;
  }];
  [tableView reloadData];
  [self rebuildLetterIndex];
}

- (CGFloat)aspectForGalleryFile:(NSDictionary *)file {
  NSString *path = file[@"path"];
  if (![file[@"kind"] isEqualToString:@"图片"]) return 16.0/9.0;
  static NSCache *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; });
  NSNumber *cached = [cache objectForKey:path];
  if (cached) return cached.doubleValue;
  CGFloat aspect = 16.0/9.0;
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (src) {
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    if (props) {
      NSDictionary *d = CFBridgingRelease(props);
      double pw = [d[(id)kCGImagePropertyPixelWidth] doubleValue];
      double ph = [d[(id)kCGImagePropertyPixelHeight] doubleValue];
      if (pw > 0 && ph > 0) aspect = pw / ph;
    }
    CFRelease(src);
  }
  aspect = MAX(0.35, MIN(3.5, aspect));
  [cache setObject:@(aspect) forKey:path];
  return aspect;
}

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
  return self.diskGalleryItems.count;
}
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
  DiskGalleryItem *item = (DiskGalleryItem *)[collectionView makeItemWithIdentifier:@"galleryItem" forIndexPath:indexPath];
  item.owner = self;
  if (indexPath.item < (NSInteger)self.diskGalleryItems.count) item.file = self.diskGalleryItems[indexPath.item];
  return item;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  if (tableView == self.aiTable) return self.aiVisibleEntries.count;
  if (tableView == self.diskTable) return self.diskFileFiltered.count;
  if (tableView == self.userFilesTable) return self.userFilesForUninstall.count;
  return self.uninstallFiltered.count;
}
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
  NSTableRowView *rv = [[NSTableRowView alloc] init];
  if ([tableView isEqual:self.aiTable] && self.aiSearchField.stringValue.length) {
    rv.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.10];
  }
  return rv;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  if (tableView == self.aiTable) {
    if (row < 0 || row >= (NSInteger)self.aiVisibleEntries.count) return nil;
    NSDictionary *e = self.aiVisibleEntries[row];
    NSString *ident = col.identifier;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,col.width,52)];
    if ([ident isEqualToString:@"sel"]) {
      NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(aiRowToggle:)];
      cb.tag = row; cb.frame = NSMakeRect(4, 17, 18, 18);
      cb.state = [self.aiSelected containsObject:e[@"name"] ?: @""] ? NSControlStateValueOn : NSControlStateValueOff;
      [v addSubview:cb];
    } else if ([ident isEqualToString:@"aiactions"]) {
      NSArray *titles = @[@"复制", @"备份", @"删除"];
      NSArray *colors = @[[NSColor systemGreenColor], [NSColor systemBlueColor], [NSColor systemRedColor]];
      NSArray *sels = @[@"aiCopyRow:", @"aiBackupRow:", @"aiDeleteRow:"];
      for (NSInteger i = 0; i < 3; i++) {
        ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(i*38, 14, 36, 26)];
        b.title = titles[i]; b.hoverColor = colors[i]; b.tag = row;
        b.target = self; b.action = NSSelectorFromString(sels[i]);
        [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
        b.font = [NSFont systemFontOfSize:9];
        [v addSubview:b];
      }
    } else {
      NSString *text = @"";
      if ([ident isEqualToString:@"ainame"]) text = e[@"name"] ?: @"";
      else if ([ident isEqualToString:@"quota"]) text = e[@"quota"] ?: @"";
      else if ([ident isEqualToString:@"endpoint"]) text = e[@"endpoint"] ?: @"";
      else if ([ident isEqualToString:@"note"]) text = e[@"note"] ?: @"";
      NSTextField *l = [self label:text size:11 bold:([ident isEqualToString:@"ainame"]) color:nil];
      l.toolTip = text;
      l.lineBreakMode = NSLineBreakByTruncatingMiddle;
      if ([ident isEqualToString:@"api"]) {
        NSString *key = e[@"api"] ?: @"";
        if (![self.aiRevealedNames containsObject:e[@"name"] ?: @""]) key = key.length ? @"••••••••" : @"";
        l.stringValue = key;
        l.frame = NSMakeRect(2, 16, col.width-34, 20);
        NSButton *eye = [[NSButton alloc] initWithFrame:NSMakeRect(col.width-30, 14, 26, 26)];
        eye.bordered = NO;
        BOOL revealed = [self.aiRevealedNames containsObject:e[@"name"] ?: @""];
        NSImage *icon = [NSImage imageWithSystemSymbolName:(revealed ? @"eye.slash" : @"eye") accessibilityDescription:@"显示 API Key"];
        eye.image = icon;
        eye.contentTintColor = [NSColor secondaryLabelColor];
        eye.toolTip = revealed ? @"隐藏 API Key" : @"显示 API Key（需要管理员密码）";
        eye.tag = row;
        eye.target = self;
        eye.action = @selector(aiToggleReveal:);
        [v addSubview:eye];
      } else {
        l.frame = NSMakeRect(2, 16, col.width-6, 20);
      }
      [self applyAISearchHighlight:l text:text baseColor:l.textColor];
      if ([ident isEqualToString:@"ainame"]) {
        NSString *url = e[@"endpoint"] ?: @"";
        if (url.length) {
          l.toolTip = @"双击打开登录 / 获取 API Key 页面";
          NSClickGestureRecognizer *g = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(aiEndpointDoubleClicked:)];
          g.numberOfClicksRequired = 2;
          [l addGestureRecognizer:g];
          objc_setAssociatedObject(l, "AILinkURL", url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
      }
      if ([ident isEqualToString:@"endpoint"]) {
        l.textColor = [NSColor controlAccentColor];
        l.toolTip = @"双击直接打开该链接";
        NSClickGestureRecognizer *g = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(aiEndpointDoubleClicked:)];
        g.numberOfClicksRequired = 2;
        [l addGestureRecognizer:g];
        objc_setAssociatedObject(l, "AILinkURL", text, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      }
      [v addSubview:l];
    }
    return v;
  }
  if (tableView == self.diskTable) {
    if (row < 0 || row >= (NSInteger)self.diskFileFiltered.count) return nil;
    NSDictionary *d = self.diskFileFiltered[row];
    NSString *ident = col.identifier;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,col.width,24)];
    NSTextField *l = nil;
    if ([ident isEqualToString:@"name"]) l = [self label:d[@"name"] size:11.5 bold:NO color:nil];
    else if ([ident isEqualToString:@"size"]) l = [self label:[self fmtSize:[d[@"size"] unsignedLongLongValue]] size:11 bold:NO color:nil];
    else if ([ident isEqualToString:@"kind"]) l = [self label:d[@"kind"] size:11 bold:NO color:[NSColor secondaryLabelColor]];
    else if ([ident isEqualToString:@"date"]) {
      NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy/MM/dd HH:mm";
      l = [self label:[df stringFromDate:d[@"date"] ?: [NSDate date]] size:10 bold:NO color:[NSColor secondaryLabelColor]];
    }
    else if ([ident isEqualToString:@"path"]) l = [self label:d[@"path"] size:9.5 bold:NO color:[NSColor tertiaryLabelColor]];
    l.frame = NSMakeRect(2, 3, col.width-6, 18);
    [v addSubview:l];
    return v;
  }
  if (tableView == self.userFilesTable) {
    if (row < 0 || row >= (NSInteger)self.userFilesForUninstall.count) return nil;
    NSDictionary *d = self.userFilesForUninstall[row];
    NSString *ident = col.identifier;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,col.width,26)];
    if ([ident isEqualToString:@"sel"]) {
      NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(userFileCheckToggled:)];
      cb.tag = row; cb.frame = NSMakeRect(2, 4, 18, 18);
      cb.state = [self.userFilesSelected containsObject:d[@"path"]] ? NSControlStateValueOn : NSControlStateValueOff;
      [v addSubview:cb];
    } else if ([ident isEqualToString:@"name"]) {
      NSTextField *l = [self label:d[@"name"] size:11.5 bold:NO color:nil];
      l.frame = NSMakeRect(2, 4, col.width-6, 17); [v addSubview:l];
    } else if ([ident isEqualToString:@"type"]) {
      NSTextField *l = [self label:d[@"type"] size:11 bold:NO color:[NSColor secondaryLabelColor]];
      l.frame = NSMakeRect(2, 4, col.width-6, 17); [v addSubview:l];
    } else if ([ident isEqualToString:@"size"]) {
      NSTextField *l = [self label:[self fmtSize:[d[@"size"] unsignedLongLongValue]] size:11 bold:NO color:nil];
      l.frame = NSMakeRect(2, 4, col.width-6, 17); [v addSubview:l];
    } else if ([ident isEqualToString:@"app"]) {
      NSTextField *l = [self label:d[@"app"] size:11 bold:NO color:[NSColor secondaryLabelColor]];
      l.frame = NSMakeRect(2, 4, col.width-6, 17); [v addSubview:l];
    } else if ([ident isEqualToString:@"path"]) {
      NSTextField *l = [self label:d[@"path"] size:10 bold:NO color:[NSColor secondaryLabelColor]];
      l.frame = NSMakeRect(2, 4, col.width-6, 17); [v addSubview:l];
    }
    return v;
  }
  if (row < 0 || row >= (NSInteger)self.uninstallFiltered.count) return nil;
  NSDictionary *d = self.uninstallFiltered[row];
  NSString *ident = col.identifier;
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,col.width,52)];
  if ([ident isEqualToString:@"app"]) {
    NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(uninstallRowToggle:)];
    cb.tag = row; cb.frame = NSMakeRect(2, 16, 18, 18);
    cb.state = [self.uninstallSelected containsObject:d[@"path"]] ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:cb];
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(24, 11, 30, 30)];
    iv.image = [[NSWorkspace sharedWorkspace] iconForFile:d[@"path"]];
    [v addSubview:iv];
    NSTextField *nm = [self label:d[@"label"] size:13 bold:YES color:nil];
    nm.frame = NSMakeRect(62, 27, 250, 17); [v addSubview:nm];
    NSTextField *bid = [self label:d[@"bid"] size:10 bold:NO color:[NSColor secondaryLabelColor]];
    bid.frame = NSMakeRect(62, 9, 250, 15); [v addSubview:bid];
  } else if ([ident isEqualToString:@"group"]) {
    NSTextField *g = [self label:d[@"group"] size:11.5 bold:NO color:[NSColor secondaryLabelColor]];
    g.frame = NSMakeRect(2, 16, col.width-6, 18); [v addSubview:g];
  } else if ([ident isEqualToString:@"size"]) {
    NSTextField *s = [self label:[self fmtSize:[d[@"size"] unsignedLongLongValue]] size:11.5 bold:NO color:nil];
    s.alignment = NSTextAlignmentRight; s.frame = NSMakeRect(2, 16, col.width-8, 18); [v addSubview:s];
  } else if ([ident isEqualToString:@"installed"]) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy/MM/dd";
    NSDate *inst = d[@"installed"];
    NSString *dateStr = (inst && [inst timeIntervalSince1970] > 946684800) ? [df stringFromDate:inst] : @"未知";
    NSTextField *s = [self label:dateStr size:11 bold:NO color:[NSColor secondaryLabelColor]];
    s.frame = NSMakeRect(2, 16, col.width-6, 18); [v addSubview:s];
  }
  return v;
}

- (NSArray<NSString *> *)relatedDataPaths:(NSDictionary *)d {
  NSString *bid = d[@"bid"] ?: @"";
  NSString *name = d[@"name"] ?: @"";
  NSString *home = NSHomeDirectory();
  NSMutableArray *out = [NSMutableArray array];
  void (^add)(NSString *) = ^(NSString *p) {
    if (p.length && [[NSFileManager defaultManager] fileExistsAtPath:p] && ![out containsObject:p]) [out addObject:p];
  };
  if (bid.length) {
    add([home stringByAppendingPathComponent:[@"Library/Application Support" stringByAppendingPathComponent:bid]]);
    add([home stringByAppendingPathComponent:[@"Library/Caches" stringByAppendingPathComponent:bid]]);
    add([home stringByAppendingPathComponent:[@"Library/Preferences" stringByAppendingPathComponent:[bid stringByAppendingPathExtension:@"plist"]]]);
    add([home stringByAppendingPathComponent:[@"Library/Saved Application State" stringByAppendingPathComponent:[bid stringByAppendingPathExtension:@"savedState"]]]);
    add([home stringByAppendingPathComponent:[@"Library/Containers" stringByAppendingPathComponent:bid]]);
    add([home stringByAppendingPathComponent:[@"Library/HTTPStorages" stringByAppendingPathComponent:bid]]);
    add([home stringByAppendingPathComponent:[@"Library/WebKit" stringByAppendingPathComponent:bid]]);
    add([home stringByAppendingPathComponent:[@"Library/Application Scripts" stringByAppendingPathComponent:bid]]);
    NSString *byHost = [home stringByAppendingPathComponent:@"Library/Preferences/ByHost"];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:byHost error:NULL]) {
      if ([f hasPrefix:bid] && [f hasSuffix:@".plist"]) add([byHost stringByAppendingPathComponent:f]);
    }
  }
  if (name.length) {
    add([home stringByAppendingPathComponent:[@"Library/Application Support" stringByAppendingPathComponent:name]]);
    add([home stringByAppendingPathComponent:[@"Library/Caches" stringByAppendingPathComponent:name]]);
    add([home stringByAppendingPathComponent:[@"Library/Logs" stringByAppendingPathComponent:name]]);
  }
  return out;
}

- (NSDictionary *)rememberedSaveDirs {
  NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"rememberedSaveDirs"];
  return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}
- (void)setRememberedSaveDirs:(NSDictionary *)d {
  [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"rememberedSaveDirs"];
}
- (void)rememberSaveDir:(NSString *)dir forApps:(NSArray<NSDictionary *> *)apps {
  if (!dir.length || !apps.count) return;
  NSMutableDictionary *all = [[self rememberedSaveDirs] mutableCopy];
  for (NSDictionary *a in apps) {
    NSString *bid = a[@"bid"];
    if (!bid.length) continue;
    NSMutableArray *arr = [all[bid] mutableCopy] ?: [NSMutableArray array];
    if (![arr containsObject:dir]) [arr addObject:dir];
    all[bid] = arr;
  }
  [self setRememberedSaveDirs:all];
}

- (void)removeRememberedDir:(NSButton *)b {
  NSInteger idx = b.tag;
  if (idx < 0 || idx >= (NSInteger)self.rememberedDirEntries.count) return;
  NSDictionary *e = self.rememberedDirEntries[idx];
  NSMutableDictionary *all = [[self rememberedSaveDirs] mutableCopy];
  NSString *bid = e[@"bid"];
  NSMutableArray *arr = [all[bid] mutableCopy];
  [arr removeObject:e[@"path"]];
  if (arr.count) all[bid] = arr; else [all removeObjectForKey:bid];
  [self setRememberedSaveDirs:all];
  [b.window orderOut:nil];
  [NSApp stopModal];
}

- (void)showRememberedSaveDirs:(id)sender {
  NSDictionary *all = [self rememberedSaveDirs];
  if (!all.count) {
    NSAlert *a = [[NSAlert alloc] init];
    a.icon = [self characterImage:64];
    a.messageText = @"没有记住的保存目录";
    a.informativeText = @"在卸载文件选择页点「添加文件夹…」时，会自动记住该应用的自定义保存目录。";
    [a runModal];
    return;
  }
  NSMutableArray *entries = [NSMutableArray array];
  for (NSString *bid in all) for (NSString *p in all[bid]) [entries addObject:@{@"bid": bid, @"path": p}];
  self.rememberedDirEntries = entries;
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = @"已记住的保存目录";
  a.informativeText = @"下次卸载对应应用时会自动扫描这些目录。";
  CGFloat h = MIN(60 + entries.count * 34, 300);
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, h)];
  CGFloat y = h - 32;
  for (NSInteger i = 0; i < (NSInteger)entries.count && i < 8; i++) {
    NSDictionary *e = entries[i];
    NSTextField *l = [self label:[NSString stringWithFormat:@"%@  ←  %@", e[@"bid"], e[@"path"]] size:11 bold:NO color:nil];
    l.frame = NSMakeRect(10, y, 520, 18); [v addSubview:l];
    NSButton *rm = [NSButton buttonWithTitle:@"移除" target:self action:@selector(removeRememberedDir:)];
    rm.tag = i; rm.frame = NSMakeRect(540, y-5, 60, 26); rm.bezelStyle = NSBezelStyleRounded;
    [v addSubview:rm];
    y -= 34;
  }
  a.accessoryView = v;
  [a addButtonWithTitle:@"关闭"];
  [a runModal];
}

- (NSString *)activityFilePath {
  return [[self backupBaseDir] stringByAppendingPathComponent:@"file_activity.json"];
}
- (void)loadActivityEntries {
  self.activityEntries = [NSMutableArray array];
  NSData *data = [NSData dataWithContentsOfFile:[self activityFilePath]];
  if (!data) return;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  if ([obj isKindOfClass:[NSArray class]]) self.activityEntries = [obj mutableCopy];
}
- (void)saveActivityEntries {
  if (!self.activityEntries) return;
  NSData *data = [NSJSONSerialization dataWithJSONObject:self.activityEntries options:0 error:NULL];
  [data writeToFile:[self activityFilePath] atomically:YES];
  self.activityDirty = NO;
}
- (void)activitySaveTick:(NSTimer *)t { if (self.activityDirty) [self saveActivityEntries]; }

- (void)startActivityRecorder {
  if (self.activityStream) return;
  [self loadActivityEntries];
  NSMutableArray *dirs = [NSMutableArray array];
  for (NSString *sub in [self scanSubdirs]) [dirs addObject:[NSHomeDirectory() stringByAppendingPathComponent:sub]];
  NSMutableArray *existing = [NSMutableArray array];
  for (NSString *d in dirs) if ([[NSFileManager defaultManager] fileExistsAtPath:d]) [existing addObject:d];
  if (!existing.count) return;
  FSEventStreamContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
  self.activityStream = FSEventStreamCreate(kCFAllocatorDefault, ActivityStreamCallback, &ctx,
      (__bridge CFArrayRef)existing, kFSEventStreamEventIdSinceNow, 0.5,
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
  if (!self.activityStream) return;
  FSEventStreamScheduleWithRunLoop(self.activityStream, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
  FSEventStreamStart(self.activityStream);
  self.activitySaveTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(activitySaveTick:) userInfo:nil repeats:YES];
}
- (void)stopActivityRecorder {
  if (self.activityStream) {
    FSEventStreamStop(self.activityStream);
    FSEventStreamInvalidate(self.activityStream);
    FSEventStreamRelease(self.activityStream);
    self.activityStream = NULL;
  }
  [self.activitySaveTimer invalidate];
  self.activitySaveTimer = nil;
  [self saveActivityEntries];
}
- (void)handleActivityPaths:(NSArray<NSString *> *)paths {
  if (!self.activityEntries) [self loadActivityEntries];
  NSString *tmp = NSTemporaryDirectory();
  NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
  NSString *bid = front.bundleIdentifier ?: @"unknown";
  NSString *appName = front.localizedName ?: @"未知应用";
  NSInteger added = 0;
  for (NSString *path in paths) {
    if (![path hasPrefix:@"/"]) continue;
    if ([path hasPrefix:tmp] || [path containsString:@"/Library/"] || [path containsString:@"/.Trash/"] || [path containsString:@"/.git/"]) continue;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
    NSNumber *ts = @([[NSDate date] timeIntervalSince1970]);
    BOOL exists = NO;
    for (NSDictionary *e in self.activityEntries) {
      if ([e[@"path"] isEqual:path] && [e[@"bid"] isEqual:bid]) { exists = YES; break; }
    }
    if (exists) continue;
    [self.activityEntries addObject:@{@"path": path, @"bid": bid, @"app": appName, @"ts": ts}];
    added++;
    if (added > 50) break;
  }
  if (added) {
    while (self.activityEntries.count > 5000) [self.activityEntries removeObjectAtIndex:0];
    self.activityDirty = YES;
  }
}
- (void)toggleActivityRecorder:(id)sender {
  BOOL on = (self.activityCheck.state == NSControlStateValueOn);
  if (on && ![self confirmPermissionAction:@"开启后会监听应用保存文件的活动，可能涉及文件访问权限。是否继续？"]) {
    self.activityCheck.state = NSControlStateValueOff; return;
  }
  [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"centerFileActivity"];
  if (on) [self startActivityRecorder]; else [self stopActivityRecorder];
  [self showToast:on ? @"已开始记录应用保存的文件" : @"已停止记录文件活动"];
}

- (NSArray<NSString *> *)recordedFilesForBids:(NSSet<NSString *> *)bids {
  if (!bids.count) return @[];
  if (!self.activityEntries) [self loadActivityEntries];
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (NSDictionary *e in self.activityEntries) {
    if (![bids containsObject:e[@"bid"] ?: @""]) continue;
    NSString *p = e[@"path"];
    if (!p.length || [seen containsObject:p]) continue;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
    [seen addObject:p];
    [out addObject:p];
  }
  return out;
}

- (NSArray<NSDictionary *> *)userSavedFilesForApps:(NSArray<NSDictionary *> *)apps {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  NSString *home = NSHomeDirectory();
  NSArray *subdirs = [self scanSubdirs];
  for (NSDictionary *d in apps) {
    NSString *name = d[@"name"] ?: @"";
    NSString *label = d[@"label"] ?: @"";
    NSString *bid = d[@"bid"] ?: @"";
    NSMutableArray *roots = [NSMutableArray array];
    for (NSString *sub in subdirs) {
      if (name.length) [roots addObject:[home stringByAppendingPathComponent:[sub stringByAppendingPathComponent:name]]];
      if (label.length && ![label isEqualToString:name]) [roots addObject:[home stringByAppendingPathComponent:[sub stringByAppendingPathComponent:label]]];
    }
    if (bid.length) {
      NSString *data = [home stringByAppendingPathComponent:[@"Library/Containers" stringByAppendingPathComponent:bid]];
      data = [data stringByAppendingPathComponent:@"Data"];
      for (NSString *sub in subdirs) [roots addObject:[data stringByAppendingPathComponent:sub]];
      for (NSString *p in [self rememberedSaveDirs][bid] ?: @[]) [roots addObject:p];
      // 尝试从应用偏好里找自定义保存路径
      NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:bid];
      NSDictionary *prefs = [ud dictionaryRepresentation];
      for (id key in prefs) {
        id val = prefs[key];
        if ([key isKindOfClass:[NSString class]] && [val isKindOfClass:[NSString class]]) {
          NSString *str = val;
          BOOL isDir = NO;
          if ([str hasPrefix:@"/"] && ![self isProtectedUserPath:str] && [[NSFileManager defaultManager] fileExistsAtPath:str isDirectory:&isDir] && isDir) {
            if ([str containsString:@"/Documents"] || [str containsString:@"/Downloads"] || [str containsString:@"/Desktop"] || [str containsString:@"/Pictures"] || [str containsString:@"/Movies"] || [str containsString:@"/Music"] || [str containsString:@"/Users/"]) {
              [roots addObject:str];
            }
          }
        }
      }
    }
    for (NSString *root in roots) {
      if ([self isProtectedUserPath:root]) continue;
      if (![fm fileExistsAtPath:root]) continue;
      NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
      for (NSString *rel in en) {
        if (out.count >= 800) break;
        NSString *full = [root stringByAppendingPathComponent:rel];
        NSDictionary *attr = [fm attributesOfItemAtPath:full error:NULL];
        if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        if ([seen containsObject:full]) continue;
        [seen addObject:full];
        NSString *ext = [full pathExtension].uppercaseString;
        [out addObject:@{@"path": full, @"name": [full lastPathComponent],
                         @"type": ext.length ? ext : @"文件",
                         @"size": attr[NSFileSize] ?: @0,
                         @"app": name.length ? name : @""}];
      }
    }
  }
  // 活动记录候选
  NSMutableSet *bids = [NSMutableSet set];
  for (NSDictionary *d in apps) if (d[@"bid"]) [bids addObject:d[@"bid"]];
  for (NSString *p in [self recordedFilesForBids:bids]) {
    if ([seen containsObject:p]) continue;
    NSDictionary *attr = [fm attributesOfItemAtPath:p error:NULL];
    if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
    [seen addObject:p];
    NSString *ext = [p pathExtension].uppercaseString;
    [out addObject:@{@"path": p, @"name": [p lastPathComponent], @"type": [@"活动记录/" stringByAppendingString:(ext.length ? ext : @"文件")], @"size": attr[NSFileSize] ?: @0, @"app": @"活动记录"}];
  }
  // 按应用声明类型 + 最近修改扫描
  NSMutableSet *exts = [NSMutableSet set];
  for (NSDictionary *d in apps) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[d[@"path"] stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    for (NSDictionary *dt in info[@"CFBundleDocumentTypes"] ?: @[]) {
      for (NSString *ext in dt[@"CFBundleTypeExtensions"] ?: @[]) if ([ext isKindOfClass:[NSString class]] && ext.length) [exts addObject:ext.lowercaseString];
    }
  }
  if (exts.count) {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-180*24*3600];
    for (NSString *sub in subdirs) {
      NSString *root = [home stringByAppendingPathComponent:sub];
      if (![fm fileExistsAtPath:root]) continue;
      NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
      for (NSString *rel in en) {
        if (out.count >= 1200) break;
        NSString *full = [root stringByAppendingPathComponent:rel];
        NSString *ext = [full pathExtension].lowercaseString;
        if (![exts containsObject:ext]) continue;
        NSDictionary *attr = [fm attributesOfItemAtPath:full error:NULL];
        if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        NSDate *mod = attr[NSFileModificationDate];
        if (mod && [mod compare:cutoff] == NSOrderedAscending) continue;
        if ([seen containsObject:full]) continue;
        [seen addObject:full];
        [out addObject:@{@"path": full, @"name": [full lastPathComponent], @"type": ext.uppercaseString, @"size": attr[NSFileSize] ?: @0, @"app": @"类型匹配"}];
      }
    }
  }
  // Spotlight 元数据候选
  for (NSDictionary *d in [self spotlightFilesForApps:apps]) {
    NSString *p = d[@"path"];
    if ([seen containsObject:p]) continue;
    [seen addObject:p];
    [out addObject:d];
  }
  return out;
}

- (NSArray<NSDictionary *> *)spotlightFilesForApps:(NSArray<NSDictionary *> *)apps {
  NSMutableSet *exts = [NSMutableSet set];
  NSMutableSet *names = [NSMutableSet set];
  for (NSDictionary *d in apps) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[d[@"path"] stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    for (NSDictionary *dt in info[@"CFBundleDocumentTypes"] ?: @[]) {
      for (NSString *ext in dt[@"CFBundleTypeExtensions"] ?: @[]) if ([ext isKindOfClass:[NSString class]] && ext.length) [exts addObject:ext.lowercaseString];
    }
    NSString *label = d[@"label"] ?: d[@"name"];
    if (label.length >= 2) [names addObject:label];
  }
  if (!exts.count && !names.count) return @[];
  NSMutableArray *terms = [NSMutableArray array];
  for (NSString *e in exts) [terms addObject:[NSString stringWithFormat:@"kMDItemFSName == \"*.%@\"c", e]];
  for (NSString *n in names) [terms addObject:[NSString stringWithFormat:@"kMDItemWhereFroms == \"*%@*\"c", n]];
  NSString *query = [NSString stringWithFormat:@"(%@)", [terms componentsJoinedByString:@" || "]];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/mdfind";
  t.arguments = @[@"-onlyin", NSHomeDirectory(), @"-0", query];
  NSPipe *pipe = [NSPipe pipe];
  t.standardOutput = pipe;
  t.standardError = [NSPipe pipe];
  @try { [t launch]; } @catch (NSException *e) { return @[]; }
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  NSMutableArray *out = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  for (NSString *p in [str componentsSeparatedByString:@"\0"]) {
    if (!p.length || out.count >= 400) continue;
    if ([p containsString:@"/Library/"] || [p containsString:@"/.Trash/"] || [p hasPrefix:NSTemporaryDirectory()]) continue;
    NSDictionary *attr = [fm attributesOfItemAtPath:p error:NULL];
    if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
    NSString *ext = [p pathExtension].uppercaseString;
    [out addObject:@{@"path": p, @"name": [p lastPathComponent], @"type": [@"Spotlight/" stringByAppendingString:(ext.length ? ext : @"文件")], @"size": attr[NSFileSize] ?: @0, @"app": @"Spotlight"}];
  }
  return out;
}

- (void)userFileCheckToggled:(NSButton *)b {
  NSInteger row = b.tag;
  if (row < 0 || row >= (NSInteger)self.userFilesForUninstall.count) return;
  NSString *p = self.userFilesForUninstall[row][@"path"];
  if (b.state == NSControlStateValueOn) [self.userFilesSelected addObject:p];
  else [self.userFilesSelected removeObject:p];
}

- (void)userFilesSelectAll:(id)sender {
  for (NSDictionary *d in self.userFilesForUninstall) [self.userFilesSelected addObject:d[@"path"]];
  [self.userFilesTable reloadData];
}
- (void)userFilesSelectNone:(id)sender {
  [self.userFilesSelected removeAllObjects];
  [self.userFilesTable reloadData];
}
- (void)userFileDoubleClick:(id)sender {
  NSInteger row = self.userFilesTable.clickedRow;
  if (row < 0 || row >= (NSInteger)self.userFilesForUninstall.count) return;
  [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.userFilesForUninstall[row][@"path"]]]];
}
- (void)previewUserFile {
  self.diskPreviewMode = NO;
  NSInteger row = self.userFilesTable.selectedRow;
  if (row < 0 || row >= (NSInteger)self.userFilesForUninstall.count) return;
  self.userFilesPreviewPath = self.userFilesForUninstall[row][@"path"];
  QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
  panel.dataSource = self;
  panel.delegate = self;
  [panel makeKeyAndOrderFront:nil];
  [panel reloadData];
}
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
  if (self.diskPreviewMode) return self.diskGalleryItems.count;
  return self.userFilesPreviewPath.length ? 1 : 0;
}
- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
  if (self.diskPreviewMode && index >= 0 && index < (NSInteger)self.diskGalleryItems.count) {
    return [NSURL fileURLWithPath:self.diskGalleryItems[index][@"path"]];
  }
  return [NSURL fileURLWithPath:self.userFilesPreviewPath ?: @"/"];
}

- (void)userFilesAddFolder:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK) return;
  NSString *root = panel.URL.path;
  NSMutableArray *add = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
  for (NSString *rel in en) {
    if (add.count >= 300) break;
    NSString *full = [root stringByAppendingPathComponent:rel];
    NSDictionary *attr = [fm attributesOfItemAtPath:full error:NULL];
    if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
    NSString *ext = [full pathExtension].uppercaseString;
    [add addObject:@{@"path": full, @"name": [full lastPathComponent],
                     @"type": ext.length ? ext : @"文件",
                     @"size": attr[NSFileSize] ?: @0,
                     @"app": @"手动选择"}];
  }
  [self rememberSaveDir:root forApps:self.userFilesApps ?: @[]];
  NSMutableArray *merged = [self.userFilesForUninstall mutableCopy] ?: [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (NSDictionary *d in merged) [seen addObject:d[@"path"]];
  for (NSDictionary *d in add) if (![seen containsObject:d[@"path"]]) [merged addObject:d];
  self.userFilesForUninstall = merged;
  [self.userFilesTable reloadData];
}

- (NSArray<NSString *> *)pickUserFilesToDelete:(NSArray<NSDictionary *> *)files apps:(NSArray<NSDictionary *> *)apps {
  self.userFilesForUninstall = files;
  self.userFilesApps = apps;
  self.userFilesSelected = [NSMutableSet set];
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = @"选择要一起删除的个人文件";
  a.informativeText = @"默认全不选；空格预览，双击在 Finder 中显示。";
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 380)];
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 50, 740, 320)];
  sv.hasVerticalScroller = YES;
  NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0,0,740,320)];
  table.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
  table.dataSource = self;
  table.delegate = self;
  table.rowHeight = 26;
  table.doubleAction = @selector(userFileDoubleClick:);
  table.target = self;
  NSArray *cols = @[@[@"sel", @"", @40], @[@"name", @"文件", @220], @[@"type", @"类型", @80], @[@"size", @"大小", @90], @[@"app", @"应用", @110], @[@"path", @"路径", @290]];
  for (NSArray *c in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1]; col.width = [c[2] doubleValue];
    [table addTableColumn:col];
  }
  sv.documentView = table;
  [v addSubview:sv];
  self.userFilesTable = table;
  NSButton *all = [NSButton buttonWithTitle:@"全选" target:self action:@selector(userFilesSelectAll:)];
  all.frame = NSMakeRect(10, 12, 70, 28); all.bezelStyle = NSBezelStyleRounded; [v addSubview:all];
  NSButton *none = [NSButton buttonWithTitle:@"全不选" target:self action:@selector(userFilesSelectNone:)];
  none.frame = NSMakeRect(88, 12, 78, 28); none.bezelStyle = NSBezelStyleRounded; [v addSubview:none];
  NSButton *addFolder = [NSButton buttonWithTitle:@"添加文件夹…" target:self action:@selector(userFilesAddFolder:)];
  addFolder.frame = NSMakeRect(174, 12, 120, 28); addFolder.bezelStyle = NSBezelStyleRounded; [v addSubview:addFolder];
  [table reloadData];
  a.accessoryView = v;
  [a addButtonWithTitle:@"确定删除所选"];
  [a addButtonWithTitle:@"取消"];
  __block id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
    if (e.window == a.window && e.keyCode == 49) { [self previewUserFile]; return nil; }
    return e;
  }];
  NSModalResponse r = [a runModal];
  [NSEvent removeMonitor:monitor];
  monitor = nil;
  if (r != NSAlertFirstButtonReturn) return nil;
  NSMutableArray *res = [NSMutableArray array];
  for (NSDictionary *d in files) if ([self.userFilesSelected containsObject:d[@"path"]]) [res addObject:d[@"path"]];
  return res;
}

- (void)showLeftoverAlert:(NSArray<NSString *> *)leftovers {
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = @"卸载完成，但有残留";
  NSMutableString *info = [NSMutableString stringWithFormat:@"检测到 %ld 项未清理：\n", (long)leftovers.count];
  NSInteger n = MIN((NSInteger)leftovers.count, 8);
  for (NSInteger i = 0; i < n; i++) [info appendFormat:@"%@\n", leftovers[i]];
  if (leftovers.count > n) [info appendString:@"…"];
  a.informativeText = info;
  [a addButtonWithTitle:@"删除残留"];
  [a addButtonWithTitle:@"在 Finder 中显示"];
  [a addButtonWithTitle:@"关闭"];
  NSModalResponse r = [a runModal];
  if (r == NSAlertFirstButtonReturn) {
    NSMutableString *body = [NSMutableString stringWithString:@"#!/bin/sh\n"];
    NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
    NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    [body appendFormat:@"mkdir -p \"%@\"\n", trash];
    NSInteger idx = 0;
    for (NSString *p in leftovers) [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/%@-%ld-%@\"\n", p, p, trash, stamp, (long)idx++, [p lastPathComponent]];
    NSString *sp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"dl-leftovers.sh"];
    [body writeToFile:sp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:sp error:NULL];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/osascript";
    t.arguments = @[@"-e", [NSString stringWithFormat:@"do shell script \"/bin/sh %@\" with administrator privileges", sp]];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    NSAlert *done = [[NSAlert alloc] init];
    done.icon = [self characterImage:64];
    done.messageText = t.terminationStatus == 0 ? @"残留已删除" : @"残留删除失败";
    [done runModal];
  } else if (r == NSAlertSecondButtonReturn) {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in leftovers) {
      NSString *parent = [p stringByDeletingLastPathComponent];
      if ([[NSFileManager defaultManager] fileExistsAtPath:parent]) [urls addObject:[NSURL fileURLWithPath:parent]];
    }
    if (urls.count) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
  }
}

- (void)confirmUninstallApps:(id)sender {
  NSMutableArray *sel = [NSMutableArray array];
  for (NSDictionary *d in self.uninstallData) if ([self.uninstallSelected containsObject:d[@"path"]]) [sel addObject:d];
  if (!sel.count) {
    NSAlert *e = [[NSAlert alloc] init];
    e.icon = [self characterImage:64];
    e.messageText = @"未选择应用";
    e.informativeText = @"请先勾选要卸载的应用。";
    [e runModal];
    return;
  }
  NSArray *userFiles = [self userSavedFilesForApps:sel];
  NSArray *pickedUserFiles = @[];
  if (userFiles.count) {
    NSAlert *p = [[NSAlert alloc] init];
    p.icon = [self characterImage:64];
    p.messageText = @"发现个人保存文件";
    p.informativeText = [NSString stringWithFormat:@"选中应用下检测到 %ld 个个人保存文件。是否一起删除？选择「否」将保留这些文件。", (long)userFiles.count];
    [p addButtonWithTitle:@"是"];
    [p addButtonWithTitle:@"否"];
    if ([p runModal] == NSAlertFirstButtonReturn) {
      NSArray *picked = [self pickUserFilesToDelete:userFiles apps:sel];
      if (!picked) return;
      pickedUserFiles = picked;
    }
  }
  // 先退出运行中的被卸载应用，避免 Dock 图标残留/继续可用
  for (NSDictionary *d in sel) {
    NSString *targetPath = d[@"path"];
    NSString *targetBid = d[@"bid"];
    for (NSRunningApplication *ra in [[NSWorkspace sharedWorkspace] runningApplications]) {
      BOOL match = NO;
      if (ra.bundleURL && [[ra.bundleURL path] isEqualToString:targetPath]) match = YES;
      if (targetBid.length && [ra.bundleIdentifier isEqualToString:targetBid]) match = YES;
      if (match) [ra forceTerminate];
    }
  }
  [NSThread sleepForTimeInterval:0.4];
  NSMutableArray *removals = [NSMutableArray array];
  for (NSDictionary *d in sel) {
    [removals addObject:d[@"path"]];
    for (NSString *dp in [self relatedDataPaths:d]) if (![removals containsObject:dp]) [removals addObject:dp];
  }
  for (NSString *p in pickedUserFiles) if (![removals containsObject:p]) [removals addObject:p];
  NSMutableString *confirm = [NSMutableString stringWithFormat:@"将卸载应用本体并清理用户数据，不可恢复。5 秒后可点击「是」。"];
  if (pickedUserFiles.count) [confirm appendFormat:@"\n同时删除 %ld 个个人文件。", (long)pickedUserFiles.count];
  NSAlert *c = [[NSAlert alloc] init];
  c.icon = [self characterImage:64];
  c.messageText = [NSString stringWithFormat:@"确认卸载 %ld 个应用？", (long)sel.count];
  c.informativeText = confirm;
  [c addButtonWithTitle:@"是（5）"];
  [c addButtonWithTitle:@"否"];
  NSButton *yes = c.buttons[0]; yes.enabled = NO;
  for (int s = 5; s >= 1; s--) {
    int remain = s - 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((5-s+1)*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (remain > 0) yes.title = [NSString stringWithFormat:@"是（%d）", remain];
      else { yes.title = @"是"; yes.enabled = YES; }
    });
  }
  if ([c runModal] != NSAlertFirstButtonReturn) return;

  NSMutableString *body = [NSMutableString stringWithString:@"#!/bin/sh\n"];
  NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
  NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
  [body appendFormat:@"mkdir -p \"%@\"\n", trash];
  NSInteger idx = 0;
  for (NSString *p in removals) [body appendFormat:@"[ -e \"%@\" ] && mv \"%@\" \"%@/%@-%ld-%@\"\n", p, p, trash, stamp, (long)idx++, [p lastPathComponent]];
  NSString *sp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"docklaunchers-center-uninstall.sh"];
  [body writeToFile:sp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:sp error:NULL];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/osascript";
  t.arguments = @[@"-e", [NSString stringWithFormat:@"do shell script \"/bin/sh %@\" with administrator privileges", sp]];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
  if (t.terminationStatus != 0) return;

  NSMutableSet *targets = [NSMutableSet set];
  NSMutableSet *removePaths = [NSMutableSet set];
  for (NSDictionary *d in sel) {
    [targets addObject:d[@"target"]];
    if (d[@"path"]) [removePaths addObject:[d[@"path"] stringByStandardizingPath]];
  }
  NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:GroupDir() error:NULL];
  for (NSString *f in items) {
    if (![f hasSuffix:@".app"]) continue;
    NSString *base = [f stringByDeletingPathExtension];
    NSString *listFile = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"txt"]];
    NSString *content = [NSString stringWithContentsOfFile:listFile encoding:NSUTF8StringEncoding error:NULL];
    if (!content) continue;
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (!line.length) continue;
      if ([line hasPrefix:@"#"]) { [keep addObject:raw]; continue; }
      NSString *target = line;
      NSRange r = [line rangeOfString:@"|"];
      if (r.location != NSNotFound) target = [[line substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      BOOL remove = [targets containsObject:target];
      if (!remove && removePaths.count) {
        NSString *resolved = ResolveAppPath(target);
        if (resolved.length && [removePaths containsObject:[resolved stringByStandardizingPath]]) remove = YES;
      }
      if (!remove) [keep addObject:raw];
    }
    [[keep componentsJoinedByString:@"\n"] writeToFile:listFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  [self reloadUninstallData];
  NSMutableArray *leftovers = [NSMutableArray array];
  for (NSString *p in removals) if ([[NSFileManager defaultManager] fileExistsAtPath:p]) [leftovers addObject:p];
  if (leftovers.count) {
    [self showLeftoverAlert:leftovers];
  } else {
    NSAlert *done = [[NSAlert alloc] init];
    done.icon = [self characterImage:64];
    done.messageText = @"卸载完成";
    done.informativeText = [NSString stringWithFormat:@"已卸载 %ld 个应用并清理 %ld 项数据%@，已验证全部清除。", (long)sel.count, (long)removals.count, pickedUserFiles.count ? [NSString stringWithFormat:@"（含 %ld 个个人文件）", (long)pickedUserFiles.count] : @""];
    [done runModal];
  }
}

// ---------------- 设置 ----------------
- (void)showToast:(NSString *)msg {
  if (!self.window.contentView) return;
  for (NSView *sv in [self.window.contentView.subviews copy]) {
    if ([sv.identifier isEqualToString:@"DLToast"]) [sv removeFromSuperview];
  }
  NSView *toast = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 36)];
  toast.identifier = @"DLToast";
  toast.wantsLayer = YES;
  toast.layer.cornerRadius = 10;
  toast.layer.backgroundColor = [[NSColor labelColor] colorWithAlphaComponent:0.86].CGColor;
  NSTextField *l = [self label:msg size:12.5 bold:YES color:[NSColor whiteColor]];
  l.alignment = NSTextAlignmentCenter;
  l.frame = NSMakeRect(8, 8, 304, 20);
  [toast addSubview:l];
  NSView *cv = self.window.contentView;
  toast.frame = NSMakeRect((cv.bounds.size.width - 320)/2.0, 22, 320, 36);
  [cv addSubview:toast];
  toast.alphaValue = 0;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
    ctx.duration = 0.18;
    toast.animator.alphaValue = 1;
  } completionHandler:^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.25;
        toast.animator.alphaValue = 0;
      } completionHandler:^{ [toast removeFromSuperview]; }];
    });
  }];
}

- (void)buildSettingsView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"设置" size:24 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"常用、同步、相册与磁盘相关选项集中管理" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 500, 18); [v addSubview:sub];

  NSView *c1 = [self cardAt:NSMakeRect(24, 430, 700, 150)]; [v addSubview:c1];
  NSTextField *t1 = [self label:@"常规" size:13 bold:YES color:nil]; t1.frame = NSMakeRect(20, 116, 200, 20); [c1 addSubview:t1];
  NSTextField *themeLabel = [self label:@"显示主题" size:12.5 bold:NO color:nil];
  themeLabel.frame = NSMakeRect(320, 116, 70, 20); [c1 addSubview:themeLabel];
  self.themePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(392, 110, 110, 28) pullsDown:NO];
  [self.themePopup addItemsWithTitles:@[@"跟随系统", @"亮色", @"暗色"]];
  NSInteger tv = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
  [self.themePopup selectItemAtIndex:(tv >= 0 && tv <= 2 ? tv : 0)];
  self.themePopup.target = self; self.themePopup.action = @selector(themeChanged:);
  self.themePopup.toolTip = @"切换控制台整体外观：跟随系统 / 亮色 / 暗色";
  [c1 addSubview:self.themePopup];
  NSTextField *zoomLabel = [self label:@"界面缩放" size:12.5 bold:NO color:nil];
  zoomLabel.frame = NSMakeRect(510, 116, 70, 20); [c1 addSubview:zoomLabel];
  NSPopUpButton *zoomPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(582, 110, 110, 28) pullsDown:NO];
  [zoomPopup addItemsWithTitles:@[@"100%", @"110%", @"120%", @"135%", @"150%", @"175%"]];
  [zoomPopup selectItemAtIndex:0];
  zoomPopup.target = self; zoomPopup.action = @selector(uiZoomChanged:);
  zoomPopup.toolTip = @"放大或缩小整个页面的文字和控件";
  [c1 addSubview:zoomPopup];
  self.menuBarCheck = [NSButton checkboxWithTitle:@"菜单栏仅显示图标（文字已移除）" target:nil action:nil];
  self.menuBarCheck.state = NSControlStateValueOff;
  self.menuBarCheck.enabled = NO;
  self.menuBarCheck.frame = NSMakeRect(20, 82, 520, 24); self.menuBarCheck.toolTip = @"菜单栏不再显示 CPU / 内存数字"; [c1 addSubview:self.menuBarCheck];
  NSTextField *il = [self label:@"采样间隔" size:12.5 bold:NO color:nil];
  il.frame = NSMakeRect(20, 44, 90, 20); [c1 addSubview:il];
  self.intervalPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(112, 38, 140, 28) pullsDown:NO];
  [self.intervalPopup addItemsWithTitles:@[@"1 秒", @"2 秒", @"5 秒", @"10 秒"]];
  NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerInterval"];
  NSArray *secs = @[@1,@2,@5,@10];
  NSInteger sel = [secs indexOfObject:@(saved)];
  [self.intervalPopup selectItemAtIndex:(sel == NSNotFound ? 1 : sel)];
  self.intervalPopup.target = self; self.intervalPopup.action = @selector(intervalChanged:); self.intervalPopup.toolTip = @"实时数据刷新间隔，越短越及时但更耗电";
  [c1 addSubview:self.intervalPopup];
  self.loginCheck = [NSButton checkboxWithTitle:@"开机自动启动控制台" target:self action:@selector(toggleLoginItem:)];
  self.loginCheck.state = [[NSFileManager defaultManager] fileExistsAtPath:[self loginPlistPath]] ? NSControlStateValueOn : NSControlStateValueOff;
  self.loginCheck.frame = NSMakeRect(20, 8, 520, 24); self.loginCheck.toolTip = @"登录 macOS 时自动启动控制台"; [c1 addSubview:self.loginCheck];

  NSView *c2 = [self cardAt:NSMakeRect(24, 270, 700, 146)]; [v addSubview:c2];
  NSTextField *t2 = [self label:@"同步与文件" size:13 bold:YES color:nil]; t2.frame = NSMakeRect(20, 112, 220, 20); [c2 addSubview:t2];
  self.autoSyncCheck = [NSButton checkboxWithTitle:@"自动同步（外部卸载应用后清理分组）" target:self action:@selector(toggleAutoSync:)];
  id autoSyncVal = [[NSUserDefaults standardUserDefaults] objectForKey:@"centerAutoSync"];
  self.autoSyncCheck.state = (autoSyncVal ? [autoSyncVal boolValue] : YES) ? NSControlStateValueOn : NSControlStateValueOff;
  self.autoSyncCheck.frame = NSMakeRect(20, 78, 560, 24); self.autoSyncCheck.toolTip = @"应用被卸载后自动清理分组中的失效条目"; [c2 addSubview:self.autoSyncCheck];
  self.activityCheck = [NSButton checkboxWithTitle:@"记录应用保存的文件（卸载候选）" target:self action:@selector(toggleActivityRecorder:)];
  self.activityCheck.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"centerFileActivity"] ? NSControlStateValueOn : NSControlStateValueOff;
  self.activityCheck.frame = NSMakeRect(20, 44, 560, 24); self.activityCheck.toolTip = @"记录应用保存文件的位置，卸载时作为清理候选"; [c2 addSubview:self.activityCheck];
  self.protectedDirsCheck = [NSButton checkboxWithTitle:@"扫描受保护目录（已禁用：避免重复授权弹窗）" target:self action:nil];
  self.protectedDirsCheck.state = NSControlStateValueOff;
  self.protectedDirsCheck.enabled = NO;
  self.protectedDirsCheck.frame = NSMakeRect(20, 10, 560, 24); self.protectedDirsCheck.toolTip = @"为彻底避免系统授权弹窗，已禁用文档 / 下载 / 桌面扫描"; [c2 addSubview:self.protectedDirsCheck];

  NSView *c3 = [self cardAt:NSMakeRect(24, 112, 700, 154)]; [v addSubview:c3];
  NSTextField *t3 = [self label:@"相册与磁盘" size:13 bold:YES color:nil]; t3.frame = NSMakeRect(20, 102, 220, 20); [c3 addSubview:t3];
  self.albumModeCheck = [NSButton checkboxWithTitle:@"相册使用完整图库（首次需授权）" target:self action:@selector(toggleAlbumMode:)];
  self.albumModeCheck.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"centerAlbumFullLibrary"] ? NSControlStateValueOn : NSControlStateValueOff;
  self.albumModeCheck.frame = NSMakeRect(20, 68, 600, 24); self.albumModeCheck.toolTip = @"使用照片图库读取全部资源，首次需授权；关闭只读本机原文件"; [c3 addSubview:self.albumModeCheck];
  self.mediaModeCheck = [NSButton checkboxWithTitle:@"包含个人媒体目录（音乐 / 影片 / 用户资源库，会授权）" target:self action:@selector(togglePersonalMedia:)];
  self.mediaModeCheck.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"centerScanPersonalMedia"] ? NSControlStateValueOn : NSControlStateValueOff;
  self.mediaModeCheck.frame = NSMakeRect(20, 34, 620, 24); self.mediaModeCheck.toolTip = @"扫描音乐 / 影片 / 用户资源库，会触发系统隐私授权"; [c3 addSubview:self.mediaModeCheck];
  NSButton *removable = [NSButton buttonWithTitle:@"可移除宗卷权限…" target:self action:@selector(showRemovableVolumeHelp:)];
  removable.frame = NSMakeRect(20, 4, 170, 24);
  removable.toolTip = @"外部磁盘扫描需要允许访问「可移除宗卷」，点击查看开启方法";
  [c3 addSubview:removable];
  ColorHoverButton *fullDisk = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(200, 4, 200, 24)];
  fullDisk.title = @"完全磁盘访问权限…"; fullDisk.hoverColor = [NSColor systemPurpleColor];
  fullDisk.target = self; fullDisk.action = @selector(showFullDiskAccessHelp:);
  fullDisk.toolTip = @"最高权限读取本机存储，需要到系统设置的「完全磁盘访问权限」中手动开启";
  [fullDisk applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [c3 addSubview:fullDisk];

  ColorHoverButton *about = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(24, 24, 90, 32)];
  about.title = @"关于"; about.hoverColor = [NSColor systemGreenColor];
  about.target = self; about.action = @selector(showAbout:);
  about.toolTip = @"查看版本和项目信息"; [v addSubview:about];

  ColorHoverButton *openGrp = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(161, 24, 150, 32)];
  openGrp.title = @"打开分组文件夹"; openGrp.hoverColor = [NSColor systemBlueColor];
  openGrp.target = self; openGrp.action = @selector(openGroupsFolder:);
  openGrp.toolTip = @"在 Finder 中打开分组 App 所在的文件夹"; [v addSubview:openGrp];

  ColorHoverButton *remember = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(357, 24, 210, 32)];
  remember.title = @"管理已记住的保存目录…"; remember.hoverColor = [NSColor systemYellowColor];
  remember.target = self; remember.action = @selector(showRememberedSaveDirs:);
  remember.toolTip = @"管理卸载时记住的应用保存目录"; [v addSubview:remember];

  ColorHoverButton *quit = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(614, 24, 110, 32)];
  quit.title = @"退出控制台"; quit.hoverColor = [NSColor systemRedColor];
  quit.target = self; quit.action = @selector(quitApp:);
  quit.toolTip = @"退出控制台，不会删除分组和数据"; [v addSubview:quit];
  [about applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [openGrp applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [remember applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [quit applyColor:DLButtonBackground() textColor:[NSColor labelColor]];

  self.settingsView = v;
}
- (void)applyAppearanceRecursively:(NSView *)view appearance:(NSAppearance *)ap {
  if (!view) return;
  if ([view.identifier isEqualToString:@"MetricCard"]) {
    view.layer.backgroundColor = CardBackgroundForAppearance(ap).CGColor;
    view.layer.borderColor = CardBorderForAppearance(ap).CGColor;
  }
  if ([view.identifier isEqualToString:@"DLCard"]) {
    view.layer.backgroundColor = CardBackgroundForAppearance(ap).CGColor;
    view.layer.borderColor = CardBorderForAppearance(ap).CGColor;
  }
  view.needsDisplay = YES;
  for (NSView *sub in view.subviews) [self applyAppearanceRecursively:sub appearance:ap];
}

- (void)applyThemeFromDefaults {
  NSInteger tv = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerTheme"];
  NSAppearance *ap = nil;
  if (tv == 1) ap = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  else if (tv == 2) ap = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  NSApp.appearance = ap;
  self.window.appearance = ap;
  [self applyAppearanceRecursively:self.window.contentView appearance:ap];
  if (self.popover.contentViewController.view) [self applyAppearanceRecursively:self.popover.contentViewController.view appearance:ap];
  [self refreshThemeColors];
}

- (void)refreshThemeColors {
  self.window.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
  if (self.contentScroll) self.contentScroll.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
  if (self.content) self.content.layer.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance).CGColor;
  if (self.sideView) self.sideView.layer.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance).CGColor;
  if (self.statusItem.button) self.statusItem.button.contentTintColor = [NSColor labelColor];
}

- (void)uiZoomChanged:(NSPopUpButton *)sender {
  NSArray *vals = @[@1.0, @1.1, @1.2, @1.35, @1.5, @1.75];
  NSInteger idx = sender.indexOfSelectedItem;
  self.uiZoom = idx >= 0 && idx < (NSInteger)vals.count ? [vals[idx] doubleValue] : 1.2;
  [self layoutPageView:self.content.subviews.firstObject];
  [self showToast:[NSString stringWithFormat:@"界面缩放：%@", sender.titleOfSelectedItem]];
}

- (void)themeChanged:(id)sender {
  NSInteger tv = self.themePopup.indexOfSelectedItem;
  [[NSUserDefaults standardUserDefaults] setInteger:tv forKey:@"centerTheme"];
  [self applyThemeFromDefaults];
  [self showSection:self.section];
  NSArray *names = @[@"跟随系统", @"亮色", @"暗色"];
  [self showToast:[NSString stringWithFormat:@"显示主题：%@", names[tv]]];
}

- (void)toggleMenuBarText:(id)sender {
  BOOL on = (self.menuBarCheck.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"centerMenuText"];
  [self sample];
  [self showToast:on ? @"菜单栏数字已开启" : @"菜单栏数字已隐藏"];
}

- (void)intervalChanged:(id)sender {
  NSArray *secs = @[@1,@2,@5,@10];
  NSInteger s = [secs[self.intervalPopup.indexOfSelectedItem] integerValue];
  self.sampleSeconds = s;
  [[NSUserDefaults standardUserDefaults] setInteger:s forKey:@"centerInterval"];
  [self.timer invalidate];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:s target:self selector:@selector(sample) userInfo:nil repeats:YES];
  [self showToast:[NSString stringWithFormat:@"采样间隔已设为 %ld 秒", (long)s]];
}

- (NSString *)loginPlistPath { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.docklaunchers.center.plist"]; }

- (void)unloadLoginAgent {
  NSString *p = [self loginPlistPath];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/bin/launchctl";
  t.arguments = @[@"unload", p];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
}

- (void)toggleLoginItem:(id)sender {
  NSString *path = [self loginPlistPath];
  if (self.loginCheck.state == NSControlStateValueOn) {
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *exe = [[NSBundle mainBundle] executablePath];
    NSDictionary *pl = @{@"Label": @"com.docklaunchers.center",
                         @"ProgramArguments": @[exe],
                         @"RunAtLoad": @YES,
                         @"KeepAlive": @NO};
    [pl writeToFile:path atomically:YES];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/launchctl";
    t.arguments = @[@"load", path];
    @try { [t launch]; } @catch (NSException *e) {}
  } else {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/launchctl";
    t.arguments = @[@"unload", path];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
  }
  [self showToast:(self.loginCheck.state == NSControlStateValueOn ? @"已开启开机自启" : @"已关闭开机自启")];
}

- (void)quitApp:(id)sender { [self unloadLoginAgent]; [NSApp terminate:nil]; }

- (void)buildPopover {
  NSPopover *pop = [[NSPopover alloc] init];
  pop.behavior = NSPopoverBehaviorTransient;
  self.popover = pop;
  NSViewController *vc = [[NSViewController alloc] init];
  NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,420,620)];
  vc.view = root;

  self.quickTabs = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(12, 574, 300, 28)];
  self.quickTabs.segmentCount = 4;
  NSArray *tabs = @[@"概览", @"分组", @"AI", @"工具"];
  for (NSInteger i = 0; i < tabs.count; i++) [self.quickTabs setLabel:tabs[i] forSegment:i];
  self.quickTabs.controlSize = NSControlSizeSmall;
  self.quickTabs.trackingMode = NSSegmentSwitchTrackingSelectOne;
  self.quickTabs.selectedSegment = 0;
  self.quickTabs.target = self;
  self.quickTabs.action = @selector(quickTabChanged:);
  [root addSubview:self.quickTabs];

  NSView *ov = [[NSView alloc] initWithFrame:NSMakeRect(0, 40, 420, 526)];
  self.quickOverview = ov;
  [root addSubview:ov];

  NSArray *ctitles = @[@"CPU", @"GPU", @"内存", @"磁盘", @"网络", @"电源"];
  NSArray *ccolors = @[[NSColor systemOrangeColor], [NSColor systemTealColor], [NSColor systemGreenColor], [NSColor systemBlueColor], [NSColor systemMintColor], [NSColor systemPinkColor]];
  CGFloat cw = 126, ch = 250, cgap = 8;
  for (NSInteger i = 0; i < 6; i++) {
    CGFloat x = 12 + (i % 3) * (cw + cgap);
    CGFloat y = (i < 3) ? 264 : 6;
    NSView *card = [self cardAt:NSMakeRect(x, y, cw, ch)];
    [ov addSubview:card];
    NSTextField *t = [self label:ctitles[i] size:11 bold:YES color:ccolors[i]];
    t.frame = NSMakeRect(10, ch - 26, cw - 20, 16); [card addSubview:t];
    NSTextField *val = [self label:@"--" size:19 bold:NO color:nil];
    val.frame = NSMakeRect(10, ch - 58, cw - 20, 28); [card addSubview:val];
    NSTextField *sub = [self label:@"" size:8.5 bold:NO color:[NSColor secondaryLabelColor]];
    sub.maximumNumberOfLines = 3;
    sub.lineBreakMode = NSLineBreakByWordWrapping;
    sub.frame = NSMakeRect(10, 8, cw - 20, 36); [card addSubview:sub];
    if (i == 0) { self.quickCPU = val; self.quickCPUSub = sub; self.quickCPUBar = [[QuickBarView alloc] initWithFrame:NSMakeRect(10, 70, cw - 20, 8)]; self.quickCPUBar.barColor = ccolors[i]; [card addSubview:self.quickCPUBar]; }
    else if (i == 1) { self.quickGPU = val; self.quickGPUSub = sub; self.quickGPUBar = [[QuickBarView alloc] initWithFrame:NSMakeRect(10, 70, cw - 20, 8)]; self.quickGPUBar.barColor = ccolors[i]; [card addSubview:self.quickGPUBar]; }
    else if (i == 2) { self.quickMem = val; self.quickMemSub = sub; self.quickMemBar = [[QuickBarView alloc] initWithFrame:NSMakeRect(10, 70, cw - 20, 8)]; self.quickMemBar.barColor = ccolors[i]; [card addSubview:self.quickMemBar]; }
    else if (i == 3) { self.quickDisk = val; self.quickDiskSub = sub; self.quickDiskBar = [[QuickBarView alloc] initWithFrame:NSMakeRect(10, 70, cw - 20, 8)]; self.quickDiskBar.barColor = ccolors[i]; [card addSubview:self.quickDiskBar]; }
    else if (i == 4) { self.quickNet = val; val.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]; val.maximumNumberOfLines = 2; val.lineBreakMode = NSLineBreakByWordWrapping; self.quickNetSub = sub; self.quickNetSpark = [[Sparkline alloc] initWithFrame:NSMakeRect(10, 50, cw - 20, 110)]; self.quickNetSpark.lineColor = ccolors[i]; [card addSubview:self.quickNetSpark]; }
    else { self.quickBat = val; self.quickPowerSub = sub; }
  }

  NSView *toolsPage = [[NSView alloc] initWithFrame:NSMakeRect(0, 40, 420, 526)];
  toolsPage.hidden = YES; self.quickToolsPage = toolsPage; [root addSubview:toolsPage];
  NSTextField *tt = [self label:@"工具" size:18 bold:YES color:nil];
  tt.frame = NSMakeRect(16, 480, 250, 26); [toolsPage addSubview:tt];
  NSTextField *ts = [self label:@"选择工具，打开独立窗口；可钉住置顶" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
  ts.frame = NSMakeRect(16, 456, 388, 18); [toolsPage addSubview:ts];
  ColorHoverButton *transBtn = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(70, 296, 132, 140)];
  transBtn.title = @"AI 翻译";
  transBtn.image = ToolIconImage(@"character.bubble.fill", [NSColor systemTealColor]);
  transBtn.imagePosition = NSImageAbove;
  transBtn.imageScaling = NSImageScaleProportionallyUpOrDown;
  transBtn.hoverColor = [NSColor systemTealColor];
  transBtn.target = self; transBtn.action = @selector(openTranslationToolFromPopover:);
  transBtn.hoverTitle = @"AI 翻译";
  transBtn.hoverDetail = @"截图 OCR、划词、文档/图片翻译，自动识别语言";
  [transBtn applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  NSMutableParagraphStyle *tps = [[NSMutableParagraphStyle alloc] init]; tps.alignment = NSTextAlignmentCenter;
  transBtn.attributedTitle = [[NSAttributedString alloc] initWithString:@"AI 翻译" attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:[NSColor labelColor], NSParagraphStyleAttributeName:tps}];
  transBtn.layer.borderWidth = 0.6;
  [toolsPage addSubview:transBtn];

  ColorHoverButton *zipBtn = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(218, 296, 132, 140)];
  zipBtn.title = @"压缩 / 解压";
  zipBtn.image = ToolIconImage(@"archivebox.fill", [NSColor systemOrangeColor]);
  zipBtn.imagePosition = NSImageAbove;
  zipBtn.imageScaling = NSImageScaleProportionallyUpOrDown;
  zipBtn.hoverColor = [NSColor systemOrangeColor];
  zipBtn.target = self; zipBtn.action = @selector(openCompressToolFromPopover:);
  zipBtn.hoverTitle = @"压缩 / 解压";
  zipBtn.hoverDetail = @"ZIP / TAR.GZ，本地处理，解压前做路径安全校验";
  [zipBtn applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  zipBtn.attributedTitle = [[NSAttributedString alloc] initWithString:@"压缩 / 解压" attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:[NSColor labelColor], NSParagraphStyleAttributeName:tps}];
  zipBtn.layer.borderWidth = 0.6;
  [toolsPage addSubview:zipBtn];

  NSTextField *tip = [self label:@"悬停查看用途，点击打开工具" size:10 bold:NO color:[NSColor tertiaryLabelColor]];
  tip.alignment = NSTextAlignmentCenter;
  tip.frame = NSMakeRect(16, 250, 388, 16); [toolsPage addSubview:tip];

  NSView *groupPage = [[NSView alloc] initWithFrame:NSMakeRect(0, 40, 420, 526)];
  groupPage.hidden = YES; self.quickGroupPage = groupPage; [root addSubview:groupPage];
  NSTextField *gtitle = [self label:@"Dock 栏分组" size:18 bold:YES color:nil];
  gtitle.frame = NSMakeRect(16, 480, 250, 26); [groupPage addSubview:gtitle];
  self.quickGroupContainer = [[NSView alloc] initWithFrame:NSMakeRect(10, 10, 400, 462)];
  [groupPage addSubview:self.quickGroupContainer];

  NSView *aiPage = [[NSView alloc] initWithFrame:NSMakeRect(0, 40, 420, 526)];
  aiPage.hidden = YES; self.quickAIPage = aiPage; [root addSubview:aiPage];
  NSTextField *atitle = [self label:@"AI 管理" size:18 bold:YES color:nil];
  atitle.frame = NSMakeRect(16, 480, 250, 26); [aiPage addSubview:atitle];
  NSTextField *aempty = [self label:@"AI 管理暂未开放" size:13 bold:NO color:[NSColor tertiaryLabelColor]];
  aempty.alignment = NSTextAlignmentCenter;
  aempty.frame = NSMakeRect(16, 240, 388, 24); [aiPage addSubview:aempty];

  NSView *detail = [[NSView alloc] initWithFrame:NSMakeRect(0, 40, 420, 526)];
  detail.hidden = YES; self.quickDetail = detail; [root addSubview:detail];
  self.quickDetailTitle = [self label:@"" size:18 bold:YES color:nil];
  self.quickDetailTitle.frame = NSMakeRect(24, 430, 370, 30); [detail addSubview:self.quickDetailTitle];
  self.quickDetailValue = [self label:@"" size:44 bold:YES color:[NSColor systemOrangeColor]];
  self.quickDetailValue.frame = NSMakeRect(24, 350, 370, 60); [detail addSubview:self.quickDetailValue];
  self.quickDetailSub = [self label:@"" size:12 bold:NO color:[NSColor secondaryLabelColor]];
  self.quickDetailSub.frame = NSMakeRect(24, 318, 370, 20); [detail addSubview:self.quickDetailSub];
  self.quickDetailChart = [[Sparkline alloc] initWithFrame:NSMakeRect(24, 150, 372, 140)];
  self.quickDetailChart.lineColor = [NSColor systemOrangeColor]; [detail addSubview:self.quickDetailChart];
  self.quickDetailBar = [[QuickBarView alloc] initWithFrame:NSMakeRect(24, 130, 372, 10)];
  self.quickDetailBar.barColor = [NSColor systemOrangeColor]; [detail addSubview:self.quickDetailBar];
  self.quickDetailExtra = [self label:@"" size:12 bold:NO color:[NSColor secondaryLabelColor]];
  self.quickDetailExtra.maximumNumberOfLines = 5;
  self.quickDetailExtra.frame = NSMakeRect(24, 30, 372, 88); [detail addSubview:self.quickDetailExtra];

  ColorHoverButton *settings = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(12, 6, 70, 28)];
  settings.title = @"退出"; settings.hoverColor = [NSColor systemGreenColor];
  settings.target = self; settings.action = @selector(closePopover:);
  settings.toolTip = @"关闭菜单栏面板，不退出应用";
  [settings applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [root addSubview:settings];
  ColorHoverButton *open = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(146, 6, 128, 28)];
  open.title = @"打开控制台"; open.hoverColor = [NSColor systemGreenColor];
  open.target = self; open.action = @selector(openConsoleFromPopover:);
  [open applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [root addSubview:open];
  ColorHoverButton *quit = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(338, 6, 70, 28)];
  quit.title = @"刷新"; quit.hoverColor = [NSColor systemGreenColor];
  quit.target = self; quit.action = @selector(refreshPopover:);
  quit.toolTip = @"刷新菜单栏数据";
  [quit applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [root addSubview:quit];

  pop.contentViewController = vc;
  pop.contentSize = NSMakeSize(420, 620);
}

- (void)syncAIQuotaAtIndex:(NSInteger)idx completion:(void (^)(NSString *quota))completion {
  if (idx < 0 || idx >= (NSInteger)self.aiEntries.count) { if (completion) completion(nil); return; }
  NSDictionary *e = self.aiEntries[idx];
  NSString *provider = [self quotaProviderKeyForEntry:e];
  NSString *apiKey = e[@"api"] ?: @"";
  if (!provider || !apiKey.length) { if (completion) completion(nil); return; }
  NSString *url = nil;
  if ([provider isEqualToString:@"deepseek"]) url = @"https://api.deepseek.com/user/balance";
  else if ([provider isEqualToString:@"kimi"]) url = @"https://api.moonshot.cn/v1/users/me/balance";
  else if ([provider isEqualToString:@"siliconflow"]) url = @"https://api.siliconflow.cn/v1/user/info";
  else if ([provider isEqualToString:@"openrouter"]) url = @"https://api.openrouter.ai/api/v1/credits";
  if ([provider isEqualToString:@"openrouter"]) url = @"https://openrouter.ai/api/v1/credits";
  if (!url) { if (completion) completion(nil); return; }
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
    NSString *quota = nil;
    if (data.length && !err) {
      id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
      if ([provider isEqualToString:@"deepseek"] && [obj isKindOfClass:[NSDictionary class]]) {
        NSArray *infos = obj[@"balance_infos"];
        if ([infos isKindOfClass:[NSArray class]] && infos.count) {
          NSDictionary *b = infos.firstObject;
          quota = [NSString stringWithFormat:@"%@ %@", b[@"total_balance"] ?: @"", b[@"currency"] ?: @""];
        }
      } else if ([provider isEqualToString:@"kimi"] && [obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj[@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) quota = [NSString stringWithFormat:@"¥%@", d[@"available_balance"] ?: @"?"];
      } else if ([provider isEqualToString:@"siliconflow"] && [obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj[@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) quota = [NSString stringWithFormat:@"¥%@", d[@"balance"] ?: d[@"chargeBalance"] ?: @"?"];
      } else if ([provider isEqualToString:@"openrouter"] && [obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj[@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) {
          double credits = [d[@"total_credits"] doubleValue];
          double usage = [d[@"total_usage"] doubleValue];
          quota = [NSString stringWithFormat:@"$%.2f", MAX(0, credits - usage)];
        }
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (quota.length && idx < (NSInteger)self.aiEntries.count) {
        NSMutableDictionary *m = [self.aiEntries[idx] mutableCopy];
        m[@"quota"] = quota;
        self.aiEntries[idx] = m;
        [self saveAIEntries];
      }
      if (completion) completion(quota);
    });
  }] resume];
}

- (void)quickAIRowClicked:(NSClickGestureRecognizer *)g {
  NSNumber *idxNum = objc_getAssociatedObject(g.view, "QuickAIRowIndex");
  self.quickAISelectedRow = idxNum ? idxNum.integerValue : -1;
  for (NSInteger i = 0; i < (NSInteger)self.quickAIRowViews.count; i++) {
    NSView *row = self.quickAIRowViews[i];
    row.layer.backgroundColor = (i == self.quickAISelectedRow) ? [[NSColor systemGreenColor] colorWithAlphaComponent:0.16].CGColor : [NSColor clearColor].CGColor;
  }
}

- (void)quickAIBalanceClicked:(NSButton *)b {
  NSInteger idx = b.tag;
  if (idx < 0 || idx >= (NSInteger)self.aiEntries.count) return;
  self.quickAISelectedRow = idx;
  for (NSInteger i = 0; i < (NSInteger)self.quickAIRowViews.count; i++) {
    NSView *row = self.quickAIRowViews[i];
    row.layer.backgroundColor = (i == idx) ? [[NSColor systemGreenColor] colorWithAlphaComponent:0.16].CGColor : [NSColor clearColor].CGColor;
  }
  b.enabled = NO;
  b.image = nil;
  b.title = @"同步中…";
  __weak typeof(self) weakSelf = self;
  __weak NSButton *weakBtn = b;
  [self syncAIQuotaAtIndex:idx completion:^(NSString *quota) {
    dispatch_async(dispatch_get_main_queue(), ^{
      weakBtn.enabled = YES;
      if (quota.length) {
        weakBtn.image = nil; weakBtn.title = quota; weakBtn.imagePosition = NSNoImage;
      } else {
        weakBtn.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"无余额数据"];
        weakBtn.imagePosition = NSImageOnly; weakBtn.title = @"";
        weakBtn.toolTip = @"该服务不支持自动查询，或未填写 API Key";
      }
      [weakSelf.aiTable reloadData];
    });
  }];
}

- (void)rebuildQuickAITab {
  NSView *page = self.quickAIPage;
  if (!page) return;
  for (NSView *sub in [page.subviews copy]) [sub removeFromSuperview];
  NSTextField *title = [self label:@"AI 管理" size:18 bold:YES color:nil];
  title.frame = NSMakeRect(16, 480, 250, 26); [page addSubview:title];
  NSTextField *sub = [self label:@"点击眼睛图标同步并显示实时余量" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(16, 456, 388, 18); [page addSubview:sub];
  NSTextField *hName = [self label:@"名称" size:12 bold:YES color:nil];
  hName.frame = NSMakeRect(22, 428, 220, 18); [page addSubview:hName];
  NSTextField *hQuota = [self label:@"余量" size:12 bold:YES color:nil];
  hQuota.alignment = NSTextAlignmentRight;
  hQuota.frame = NSMakeRect(312, 428, 80, 18); [page addSubview:hQuota];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 16, 396, 400)];
  sv.hasVerticalScroller = YES; sv.drawsBackground = NO;
  CGFloat rowH = 44;
  CGFloat docH = MAX(400, self.aiEntries.count * rowH);
  NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, docH)];
  NSInteger n = self.aiEntries.count;
  self.quickAIRowViews = [NSMutableArray array];
  for (NSInteger i = 0; i < n; i++) {
    NSDictionary *e = self.aiEntries[i];
    CGFloat y = docH - (i + 1) * rowH;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(4, y, 372, rowH)];
    row.wantsLayer = YES;
    row.layer.cornerRadius = 8;
    BOOL sel = (i == self.quickAISelectedRow);
    row.layer.backgroundColor = sel ? [[NSColor systemGreenColor] colorWithAlphaComponent:0.16].CGColor : [NSColor clearColor].CGColor;
    NSClickGestureRecognizer *g = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(quickAIRowClicked:)];
    objc_setAssociatedObject(row, "QuickAIRowIndex", @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    g.numberOfClicksRequired = 1;
    [row addGestureRecognizer:g];
    [doc addSubview:row];
    [self.quickAIRowViews addObject:row];
    NSTextField *nm = [self label:e[@"name"] ?: @"" size:12 bold:YES color:nil];
    nm.lineBreakMode = NSLineBreakByTruncatingTail;
    nm.frame = NSMakeRect(8, 13, 260, 18); [row addSubview:nm];
    NSButton *qb = [[NSButton alloc] initWithFrame:NSMakeRect(274, 8, 94, 26)];
    qb.tag = i;
    qb.bordered = NO;
    qb.alignment = NSTextAlignmentRight;
    qb.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightBold];
    qb.contentTintColor = [NSColor controlAccentColor];
    qb.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"显示余额"];
    qb.imagePosition = NSImageOnly;
    qb.target = self; qb.action = @selector(quickAIBalanceClicked:);
    qb.toolTip = @"点击眼睛图标同步余额";
    [row addSubview:qb];
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(8, 0, 356, 1)];
    line.boxType = NSBoxSeparator; [row addSubview:line];
  }
  sv.documentView = doc;
  [page addSubview:sv];
  if (!n) {
    NSTextField *empty = [self label:@"暂无 AI 服务，请先在控制台添加" size:11.5 bold:NO color:[NSColor tertiaryLabelColor]];
    empty.alignment = NSTextAlignmentCenter;
    empty.frame = NSMakeRect(16, 240, 388, 20); [page addSubview:empty];
  }
}

- (void)quickTabChanged:(id)sender {
  NSInteger idx = self.quickTabs.selectedSegment;
  self.quickOverview.hidden = (idx != 0);
  if (self.quickDetail) self.quickDetail.hidden = YES;
  if (self.quickGroupPage) self.quickGroupPage.hidden = (idx != 1);
  if (self.quickAIPage) self.quickAIPage.hidden = (idx != 2);
  if (self.quickToolsPage) self.quickToolsPage.hidden = (idx != 3);
  if (idx == 1) [self rebuildQuickGroupTab];
  else if (idx == 2) [self rebuildQuickAITab];
}

- (void)rebuildQuickGroupTab {
  if (!self.quickGroupContainer) return;
  for (NSView *v in [self.quickGroupContainer.subviews copy]) [v removeFromSuperview];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *items = [[fm contentsOfDirectoryAtPath:GroupDir() error:NULL] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return [[a description] compare:[b description] options:NSCaseInsensitiveSearch]; }];
  NSMutableArray *apps = [NSMutableArray array];
  for (NSString *f in items) if ([f hasSuffix:@".app"]) [apps addObject:f];
  CGFloat width = 400, gap = 10;
  NSInteger cols = 3;
  CGFloat bw = (width - gap * (cols - 1)) / cols;
  CGFloat bh = 132;
  CGFloat y = 462 - bh;
  NSInteger col = 0;
  for (NSString *f in apps) {
    NSString *path = [GroupDir() stringByAppendingPathComponent:f];
    NSString *name = [f stringByDeletingPathExtension];
    name = [name stringByReplacingOccurrencesOfString:@"DockLaunchers" withString:@""];
    NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(col * (bw + gap), y, bw, bh)];
    cell.wantsLayer = YES;
    cell.layer.cornerRadius = 12;
    cell.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;
    cell.layer.borderWidth = 1;
    cell.layer.borderColor = [NSColor separatorColor].CGColor;
    cell.toolTip = path;
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Resources/AppIcon.icns"]];
    if (!icon) icon = [[NSImage alloc] initWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Resources/AppIcon2.icns"]];
    if (!icon) icon = [NSImage imageNamed:NSImageNameApplicationIcon];
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect((bw - 56)/2, 54, 56, 56)];
    iv.image = icon; iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    [cell addSubview:iv];
    NSTextField *lb = [NSTextField labelWithString:name];
    lb.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    lb.alignment = NSTextAlignmentCenter;
    lb.lineBreakMode = NSLineBreakByTruncatingTail;
    lb.frame = NSMakeRect(6, 22, bw - 12, 20);
    [cell addSubview:lb];
    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(openGroupFromMenuBarGesture:)];
    [cell addGestureRecognizer:click];
    [self.quickGroupContainer addSubview:cell];
    col++;
    if (col % cols == 0) { col = 0; y -= bh + gap; }
  }
}

- (void)openGroupFromMenuBarGesture:(NSClickGestureRecognizer *)g {
  NSString *path = g.view.toolTip;
  if (path) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
  [self.popover performClose:nil];
}

- (void)openGroupFromMenuBar:(NSButton *)sender {
  NSString *path = sender.toolTip;
  if (path) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
  [self.popover performClose:nil];
}

- (void)rebuildQuickGroups {
  for (NSView *v in [self.quickGroups.subviews copy]) [v removeFromSuperview];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *items = [[fm contentsOfDirectoryAtPath:GroupDir() error:NULL] sortedArrayUsingSelector:@selector(localizedCompare:)];
  CGFloat x = 6, y = 190, bw = 104, bh = 82;
  NSInteger col = 0;
  for (NSString *f in items) {
    if (![f hasSuffix:@".app"]) continue;
    NSString *path = [GroupDir() stringByAppendingPathComponent:f];
    NSString *name = [f stringByDeletingPathExtension];
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, bw, bh)];
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Resources/AppIcon.icns"]];
    if (!icon) icon = [[NSImage alloc] initWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Resources/AppIcon2.icns"]];
    if (!icon) icon = [NSImage imageNamed:NSImageNameApplicationIcon];
    b.image = icon;
    b.imageScaling = NSImageScaleProportionallyUpOrDown;
    b.imagePosition = NSImageAbove;
    b.title = name;
    b.font = [NSFont systemFontOfSize:10.5];
    b.bordered = NO;
    b.tag = 0;
    b.toolTip = path;
    b.target = self;
    b.action = @selector(openQuickGroup:);
    [self.quickGroups addSubview:b];
    col++;
    if (col % 3 == 0) { col = 0; x = 6; y -= 88; } else x += 112;
  }
}

- (void)togglePopover:(id)sender {
  if (self.popover.isShown) { [self.popover performClose:nil]; return; }
  [self rebuildQuickGroups];
  [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
}

- (void)openQuickGroup:(NSButton *)b {
  if (b.toolTip) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:b.toolTip]];
  [self.popover performClose:nil];
}

- (NSDictionary *)translationAPIConfigForEntry:(NSDictionary *)e {
  NSString *name = [(e[@"name"] ?: @"") lowercaseString];
  NSString *base = nil, *model = nil;
  if ([name containsString:@"deepseek"] || [name containsString:@"深度求索"]) { base = @"https://api.deepseek.com/v1"; model = @"deepseek-chat"; }
  else if ([name containsString:@"openai"] || [name containsString:@"chatgpt"]) { base = @"https://api.openai.com/v1"; model = @"gpt-4o-mini"; }
  else if ([name containsString:@"gemini"] || [name containsString:@"谷歌"]) { base = @"https://generativelanguage.googleapis.com/v1beta/openai"; model = @"gemini-1.5-flash"; }
  else if ([name containsString:@"grok"] || [name containsString:@"xai"]) { base = @"https://api.x.ai/v1"; model = @"grok-2-latest"; }
  else if ([name containsString:@"mistral"]) { base = @"https://api.mistral.ai/v1"; model = @"mistral-small-latest"; }
  else if ([name containsString:@"kimi"] || [name containsString:@"moonshot"] || [name containsString:@"月之暗面"]) { base = @"https://api.moonshot.cn/v1"; model = @"moonshot-v1-8k"; }
  else if ([name containsString:@"智谱"] || [name containsString:@"glm"]) { base = @"https://open.bigmodel.cn/api/paas/v4"; model = @"glm-4-flash"; }
  else if ([name containsString:@"千问"] || [name containsString:@"qwen"] || [name containsString:@"通义"] || [name containsString:@"百炼"]) { base = @"https://dashscope.aliyuncs.com/compatible-mode/v1"; model = @"qwen-plus"; }
  else if ([name containsString:@"文心"] || [name containsString:@"千帆"] || [name containsString:@"ernie"]) { base = @"https://qianfan.baidubce.com/v2"; model = @"ernie-4.0-8k"; }
  else if ([name containsString:@"豆包"] || [name containsString:@"方舟"] || [name containsString:@"doubao"] || [name containsString:@"volcengine"]) { base = @"https://ark.cn-beijing.volces.com/api/v3"; model = @"doubao-pro-32k"; }
  else if ([name containsString:@"混元"] || [name containsString:@"hunyuan"]) { base = @"https://api.hunyuan.cloud.tencent.com/v1"; model = @"hunyuan-lite"; }
  else if ([name containsString:@"minimax"] || [name containsString:@"海螺"]) { base = @"https://api.minimaxi.com/v1"; model = @"abab6.5s-chat"; }
  else if ([name containsString:@"百川"] || [name containsString:@"baichuan"]) { base = @"https://api.baichuan-ai.com/v1"; model = @"Baichuan4"; }
  else if ([name containsString:@"零一"] || [name containsString:@"yi"] || [name containsString:@"lingyiwanwu"]) { base = @"https://api.lingyiwanwu.com/v1"; model = @"yi-lightning"; }
  else if ([name containsString:@"阶跃"] || [name containsString:@"stepfun"]) { base = @"https://api.stepfun.com/v1"; model = @"step-1-8k"; }
  else if ([name containsString:@"硅基流动"] || [name containsString:@"siliconflow"]) { base = @"https://api.siliconflow.cn/v1"; model = @"Qwen/Qwen2.5-7B-Instruct"; }
  else if ([name containsString:@"openrouter"]) { base = @"https://openrouter.ai/api/v1"; model = @"openai/gpt-4o-mini"; }
  else if ([name containsString:@"groq"]) { base = @"https://api.groq.com/openai/v1"; model = @"llama-3.1-8b-instant"; }
  else if ([name containsString:@"together"]) { base = @"https://api.together.xyz/v1"; model = @"meta-llama/Llama-3.1-8B-Instruct-Turbo"; }
  else if ([name containsString:@"fireworks"]) { base = @"https://api.fireworks.ai/inference/v1"; model = @"accounts/fireworks/models/llama-v3p1-8b-instruct"; }
  // 优先使用备注里的 API 地址
  NSString *note = e[@"note"] ?: @"";
  NSRange r = [note rangeOfString:@"API 地址："];
  if (r.location != NSNotFound) {
    NSString *tail = [note substringFromIndex:NSMaxRange(r)];
    NSRange sp = [tail rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (sp.location != NSNotFound) tail = [tail substringToIndex:sp.location];
    tail = [tail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([tail hasSuffix:@"/"]) tail = [tail substringToIndex:tail.length - 1];
    if (tail.length) base = tail;
  }
  if (!base.length) return nil;
  return @{@"base": base, @"model": model ?: @""};
}

- (void)reloadTranslationProviders {
  if (!self.translationProviderPopup) return;
  [self loadAIEntries];
  [self.translationProviderPopup removeAllItems];
  NSMutableArray *valid = [NSMutableArray array];
  for (NSDictionary *e in self.aiEntries) if ([e[@"api"] length]) [valid addObject:e];
  if (!valid.count) {
    [self.translationProviderPopup addItemWithTitle:@"请先在 AI 管理中添加服务"];
    self.translationProviderPopup.enabled = NO;
    self.translationStatus.stringValue = @"没有可用的 AI 服务，请先在 AI 管理中填写 API Key";
    return;
  }
  self.translationProviderPopup.enabled = YES;
  for (NSDictionary *e in valid) {
    [self.translationProviderPopup addItemWithTitle:e[@"name"] ?: @"AI 服务"];
    self.translationProviderPopup.lastItem.representedObject = e;
  }
  [self translationProviderChanged:nil];
}

- (void)fetchTranslationModels:(id)sender {
  NSDictionary *e = self.translationProviderPopup.selectedItem.representedObject;
  if (!e) return;
  NSDictionary *cfg = [self translationAPIConfigForEntry:e];
  NSString *key = e[@"api"] ?: @"";
  if (!cfg || !key.length) { self.translationStatus.stringValue = @"缺少 API 地址或 Key"; return; }
  self.translationStatus.stringValue = @"正在获取模型列表…";
  NSString *url = [cfg[@"base"] stringByAppendingString:@"/models"];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
  req.timeoutInterval = 20;
  __weak typeof(self) weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
    NSMutableArray *models = [NSMutableArray array];
    if (data.length) {
      id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
      id list = [obj isKindOfClass:[NSDictionary class]] ? obj[@"data"] : nil;
      if ([list isKindOfClass:[NSArray class]]) {
        for (id m in list) {
          NSString *mid = [m isKindOfClass:[NSDictionary class]] ? m[@"id"] : nil;
          if (mid.length) [models addObject:mid];
        }
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!models.count) { weakSelf.translationStatus.stringValue = @"未获取到模型列表，可直接手动输入模型名"; return; }
      [models sortUsingSelector:@selector(localizedStandardCompare:)];
      NSString *current = weakSelf.translationModelField.stringValue;
      [weakSelf.translationModelField removeAllItems];
      [weakSelf.translationModelField addItemsWithObjectValues:models];
      if (current.length && [models containsObject:current]) weakSelf.translationModelField.stringValue = current;
      else weakSelf.translationModelField.stringValue = models.firstObject;
      weakSelf.translationStatus.stringValue = [NSString stringWithFormat:@"已获取 %ld 个模型", (long)models.count];
    });
  }] resume];
}

- (void)translationProviderChanged:(id)sender {
  NSDictionary *e = self.translationProviderPopup.selectedItem.representedObject;
  if (!e) return;
  NSDictionary *cfg = [self translationAPIConfigForEntry:e];
  self.translationModelField.stringValue = cfg[@"model"] ?: @"";
  if (!cfg) self.translationStatus.stringValue = @"该服务暂无可用 API 地址，可在备注中写「API 地址：https://…」";
  else {
    self.translationStatus.stringValue = @"";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self fetchTranslationModels:nil];
    });
  }
}

- (NSTextView *)translationTextViewAtFrame:(NSRect)frame {
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:frame];
  sv.hasVerticalScroller = YES;
  sv.borderType = NSBezelBorder;
  NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.contentView.bounds];
  tv.font = [NSFont systemFontOfSize:12];
  tv.richText = NO;
  tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  sv.documentView = tv;
  [self.translationWindow.contentView addSubview:sv];
  return tv;
}

- (void)openTranslationToolFromPopover:(id)sender {
  [self.popover performClose:nil];
  [self showTranslationWindow:sender];
}
- (void)openCompressToolFromPopover:(id)sender {
  [self.popover performClose:nil];
  [self showCompressWindow:sender];
}

- (void)applyPinLook:(NSButton *)b pinned:(BOOL)pinned {
  b.state = pinned ? NSControlStateValueOn : NSControlStateValueOff;
  b.image = [NSImage imageWithSystemSymbolName:(pinned ? @"pin.fill" : @"pin") accessibilityDescription:@"钉住"];
  b.contentTintColor = pinned ? [NSColor systemOrangeColor] : [NSColor secondaryLabelColor];
  b.toolTip = pinned ? @"取消钉住（不再置顶）" : @"钉住窗口（始终置顶）";
}

- (void)toggleToolPin:(NSButton *)b {
  NSWindow *w = b.tag == 0 ? self.compressWindow : self.translationWindow;
  if (!w) return;
  BOOL pinned = (w.level != NSFloatingWindowLevel);
  w.level = pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
  [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:(b.tag == 0 ? @"centerCompressPinned" : @"centerTranslatePinned")];
  [self applyPinLook:b pinned:pinned];
}

- (void)showTranslationWindow:(id)sender {
  if (!self.translationWindow) {
    self.translationWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,820,560) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
    self.translationWindow.title = @"AI 翻译";
    self.translationWindow.releasedWhenClosed = NO;
    self.translationWindow.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
    NSView *cv = self.translationWindow.contentView;
    NSTextField *title = [self label:@"AI 翻译" size:20 bold:YES color:nil];
    title.frame = NSMakeRect(24, 516, 300, 26); [cv addSubview:title];
    NSTextField *sub = [self label:@"选择 AI 服务；支持截图 OCR、拖入英文文档翻译" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
    sub.frame = NSMakeRect(24, 494, 500, 18); [cv addSubview:sub];

    self.translationProviderPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(96, 458, 220, 28) pullsDown:NO];
    self.translationProviderPopup.target = self; self.translationProviderPopup.action = @selector(translationProviderChanged:);
    [cv addSubview:self.translationProviderPopup];
    NSTextField *pl = [self label:@"AI 服务" size:11 bold:NO color:[NSColor secondaryLabelColor]];
    pl.frame = NSMakeRect(24, 464, 70, 18); [cv addSubview:pl];
    NSTextField *ml = [self label:@"模型" size:11 bold:NO color:[NSColor secondaryLabelColor]];
    ml.frame = NSMakeRect(330, 464, 40, 18); [cv addSubview:ml];
    self.translationModelField = [[NSComboBox alloc] initWithFrame:NSMakeRect(374, 458, 140, 28)];
    self.translationModelField.placeholderString = @"模型";
    self.translationModelField.editable = YES;
    [cv addSubview:self.translationModelField];
    ColorHoverButton *fetchModels = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(520, 458, 64, 28)];
    fetchModels.title = @"获取模型"; fetchModels.hoverColor = [NSColor systemBlueColor];
    fetchModels.target = self; fetchModels.action = @selector(fetchTranslationModels:);
    fetchModels.toolTip = @"从服务商 /models 接口获取最新模型";
    [fetchModels applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
    [cv addSubview:fetchModels];
    NSTextField *tl = [self label:@"目标语言" size:11 bold:NO color:[NSColor secondaryLabelColor]];
    tl.frame = NSMakeRect(594, 464, 60, 18); [cv addSubview:tl];
    self.translationTargetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(660, 458, 146, 28) pullsDown:NO];
    [self.translationTargetPopup addItemsWithTitles:@[@"中文（简体）", @"English", @"日本語", @"한국어", @"Français", @"Deutsch", @"Español", @"Русский"]];
    [cv addSubview:self.translationTargetPopup];

    NSTextField *sl = [self label:@"原文" size:11 bold:YES color:nil];
    sl.frame = NSMakeRect(24, 426, 100, 18); [cv addSubview:sl];
    NSTextField *rl = [self label:@"译文" size:11 bold:YES color:nil];
    rl.frame = NSMakeRect(424, 426, 100, 18); [cv addSubview:rl];
    self.translationSourceView = [self translationTextViewAtFrame:NSMakeRect(24, 140, 370, 276)];
    self.translationSourceView.delegate = self;
    self.translationResultView = [self translationTextViewAtFrame:NSMakeRect(424, 140, 372, 276)];

    NSArray *symbols = @[@"doc.badge.plus", @"doc.on.doc", @"square.and.arrow.down", @"keyboard"];
    NSArray *tips = @[@"选择文档", @"复制译文", @"保存译文", @"快捷键设置"];
    NSArray *details = @[@"支持 txt / md / pdf / docx / 图片", @"复制右侧译文到剪贴板", @"保存译文为 txt 文件", @"设置截图、划词、翻译的快捷键"];
    NSArray *tSels = @[@"translationChooseDocument:", @"translationCopy:", @"translationSave:", @"openShortcutSettings:"];
    CGFloat txs[4] = {560, 604, 648, 692};
    for (NSInteger i = 0; i < 4; i++) {
      ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(txs[i], 512, 38, 34)];
      b.title = @"";
      b.image = [NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:tips[i]];
      b.imagePosition = NSImageOnly;
      b.hoverColor = [NSColor systemTealColor];
      b.target = self; b.action = NSSelectorFromString(tSels[i]);
      b.hoverTitle = tips[i]; b.hoverDetail = details[i];
      [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
      [cv addSubview:b];
    }
    CompressDropView *drop = [[CompressDropView alloc] initWithFrame:NSMakeRect(24, 34, 772, 50)];
    drop.dropTarget = self; drop.dropAction = @selector(translationFilesDropped:);
    [cv addSubview:drop];
    NSTextField *dh = [self label:@"拖入英文文档 / PDF / 图片到这里" size:11 bold:NO color:[NSColor tertiaryLabelColor]];
    dh.alignment = NSTextAlignmentCenter;
    dh.frame = NSMakeRect(24, 49, 772, 18); [cv addSubview:dh];
    self.translationStatus = [self label:@"" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
    self.translationStatus.frame = NSMakeRect(24, 10, 772, 18); [cv addSubview:self.translationStatus];
    self.translationPinButton = [[NSButton alloc] initWithFrame:NSMakeRect(768, 516, 30, 26)];
    self.translationPinButton.bordered = NO;
    self.translationPinButton.target = self;
    self.translationPinButton.action = @selector(toggleToolPin:);
    self.translationPinButton.tag = 1;
    [cv addSubview:self.translationPinButton];
    [self.translationWindow center];
  }
  [self reloadTranslationProviders];
  BOOL pinned = [[NSUserDefaults standardUserDefaults] boolForKey:@"centerTranslatePinned"];
  self.translationWindow.level = pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
  [self applyPinLook:self.translationPinButton pinned:pinned];
  [NSApp activateIgnoringOtherApps:YES];
  [self.translationWindow makeKeyAndOrderFront:nil];
  [self.translationWindow orderFrontRegardless];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (self.translationWindow.isVisible) [self.translationWindow orderFrontRegardless];
  });
}

- (void)translationOCRImage:(NSString *)path completion:(void (^)(NSString *))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (!img) { if (src) CFRelease(src); dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(@""); }); return; }
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"en-US", @"zh-Hans", @"ja-JP", @"ko-KR"];
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
    [h performRequests:@[req] error:NULL];
    NSMutableArray *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *obs in req.results) {
      VNRecognizedText *t = [obs topCandidates:1].firstObject;
      if (t.string.length) [lines addObject:t.string];
    }
    CGImageRelease(img); CFRelease(src);
    NSString *text = [lines componentsJoinedByString:@"\n"];
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(text); });
  });
}

- (void)translationExtractTextFromURL:(NSURL *)url completion:(void (^)(NSString *))completion {
  NSString *ext = url.pathExtension.lowercaseString;
  if ([@[@"png",@"jpg",@"jpeg",@"tiff",@"heic",@"webp"] containsObject:ext]) {
    [self translationOCRImage:url.path completion:completion];
    return;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *text = nil;
    if ([ext isEqualToString:@"pdf"]) {
      PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
      text = doc.string;
    } else if ([@[@"doc",@"docx",@"rtf",@"rtfd",@"html",@"htm",@"odt"] containsObject:ext]) {
      NSTask *t = [[NSTask alloc] init];
      t.launchPath = @"/usr/bin/textutil";
      t.arguments = @[@"-convert", @"txt", @"-stdout", url.path];
      NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSPipe pipe];
      @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
      text = [[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    } else {
      text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(text ?: @""); });
  });
}

- (void)translationSetSource:(NSString *)text status:(NSString *)status {
  if (text.length) self.translationSourceView.string = text;
  self.translationStatus.stringValue = status ?: @"";
  [self scheduleAutoTranslate];
}

- (NSString *)translationDetectedLanguage:(NSString *)text {
  NLLanguageRecognizer *r = [[NLLanguageRecognizer alloc] init];
  [r processString:text ?: @""];
  NSString *lang = r.dominantLanguage ?: @"";
  NSDictionary *names = @{@"en": @"英语", @"zh": @"中文", @"ja": @"日语", @"ko": @"韩语", @"fr": @"法语", @"de": @"德语", @"es": @"西班牙语", @"ru": @"俄语"};
  return names[lang] ?: (lang.length ? lang.uppercaseString : @"未知语言");
}

- (void)scheduleAutoTranslate {
  [self.translationAutoTimer invalidate];
  self.translationAutoTimer = nil;
  NSString *text = self.translationSourceView.string;
  if (!text.length || self.translationBusy || !self.translationWindow.isVisible) return;
  NSString *detected = [self translationDetectedLanguage:text];
  self.translationStatus.stringValue = [NSString stringWithFormat:@"检测到 %@，准备自动翻译…", detected];
  __weak typeof(self) weakSelf = self;
  self.translationAutoTimer = [NSTimer scheduledTimerWithTimeInterval:0.9 repeats:NO block:^(NSTimer *timer) {
    if (weakSelf.translationSourceView.string.length && !weakSelf.translationBusy) {
      [weakSelf translationTranslate:nil];
    }
  }];
}

- (void)textDidChange:(NSNotification *)notification {
  if (notification.object == self.translationSourceView) [self scheduleAutoTranslate];
}

- (NSString *)selectedTextFromFocusedApplication {
  if (!AXIsProcessTrusted()) {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
    return nil;
  }
  AXUIElementRef sys = AXUIElementCreateSystemWide();
  CFTypeRef focused = NULL;
  NSString *result = @"";
  if (AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess && focused) {
    CFTypeRef sel = NULL;
    if (AXUIElementCopyAttributeValue((AXUIElementRef)focused, kAXSelectedTextAttribute, &sel) == kAXErrorSuccess && sel) {
      if (CFGetTypeID(sel) == CFStringGetTypeID()) result = [NSString stringWithString:(__bridge NSString *)sel];
      CFRelease(sel);
    }
    CFRelease(focused);
  }
  CFRelease(sys);
  return result;
}

- (BOOL)showTranslateConfirmWindow:(NSString *)text origin:(NSString *)origin {
  NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,480,220) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  w.title = @"翻译确认";
  w.level = NSFloatingWindowLevel;
  w.releasedWhenClosed = NO;
  self.translateConfirmWindow = w;
  self.translateConfirmYes = NO;
  NSView *cv = w.contentView;
  NSTextField *title = [self label:[NSString stringWithFormat:@"是否翻译%@？", origin ?: @"这段文字"] size:15 bold:YES color:nil];
  title.frame = NSMakeRect(24, 172, 430, 24); [cv addSubview:title];
  NSTextField *preview = [self label:(text.length > 160 ? [[text substringToIndex:160] stringByAppendingString:@"…"] : text) size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
  preview.maximumNumberOfLines = 4;
  preview.lineBreakMode = NSLineBreakByTruncatingTail;
  preview.frame = NSMakeRect(24, 70, 430, 82); [cv addSubview:preview];
  ColorHoverButton *no = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(300, 28, 70, 32)];
  no.title = @"取消"; no.hoverColor = [NSColor systemGrayColor]; no.tag = 0;
  no.frame = NSMakeRect(300, 18, 70, 32);
  no.target = self; no.action = @selector(translateConfirmButton:);
  [no applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
  [cv addSubview:no];
  ColorHoverButton *yes = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(378, 28, 78, 32)];
  yes.title = @"翻译"; yes.hoverColor = [NSColor systemTealColor]; yes.tag = 1;
  yes.frame = NSMakeRect(378, 18, 78, 32);
  yes.target = self; yes.action = @selector(translateConfirmButton:);
  [yes applyColor:[NSColor controlAccentColor] textColor:[NSColor whiteColor]];
  [cv addSubview:yes];
  [w center];
  [NSApp activateIgnoringOtherApps:YES];
  [w makeKeyAndOrderFront:nil];
  [w orderFrontRegardless];
  [NSApp runModalForWindow:w];
  [w orderOut:nil];
  return self.translateConfirmYes;
}

- (void)translateConfirmButton:(NSButton *)b {
  self.translateConfirmYes = (b.tag == 1);
  [NSApp stopModal];
}

- (void)confirmTranslateText:(NSString *)text origin:(NSString *)origin {
  if (!text.length) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"%@没有可翻译的文字", origin ?: @""];
    [a addButtonWithTitle:@"好"];
    a.window.level = NSFloatingWindowLevel;
    [NSApp activateIgnoringOtherApps:YES];
    [a runModal];
    return;
  }
  if (![self showTranslateConfirmWindow:text origin:origin]) return;
  [self showTranslationWindow:nil];
  [self translationSetSource:text status:@"已获取文字，正在自动翻译…"];
}

- (void)translateSelectedText {
  NSString *text = [self selectedTextFromFocusedApplication];
  if (!text) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"需要辅助功能权限";
    a.informativeText = @"划词翻译需要读取其他应用中的选中文本。请在系统设置 → 隐私与安全性 → 辅助功能中允许 DockLaunchers 控制台。";
    [a addButtonWithTitle:@"打开系统设置"];
    [a addButtonWithTitle:@"取消"];
    a.window.level = NSFloatingWindowLevel;
    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] == NSAlertFirstButtonReturn) {
      [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    }
    return;
  }
  [self confirmTranslateText:text origin:@"选中内容"];
}

- (void)translateCurrentText {
  [self showTranslationWindow:nil];
  if (!self.translationSourceView.string.length) {
    self.translationStatus.stringValue = @"文本框为空，可先粘贴或拖入文本";
    return;
  }
  [self translationTranslate:nil];
}

- (void)openShortcutSettings:(id)sender {
  if (!self.shortcutSettingsWindow) {
    self.shortcutSettingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,480,300) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    self.shortcutSettingsWindow.title = @"快捷键设置";
    self.shortcutSettingsWindow.releasedWhenClosed = NO;
    self.shortcutSettingsWindow.level = NSFloatingWindowLevel;
    NSView *cv = self.shortcutSettingsWindow.contentView;
    NSTextField *t = [self label:@"快捷键设置" size:18 bold:YES color:nil];
    t.frame = NSMakeRect(24, 254, 300, 24); [cv addSubview:t];
    NSTextField *h = [self label:@"点击右侧快捷键，然后按下新的组合键；Esc 取消" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
    h.frame = NSMakeRect(24, 232, 430, 18); [cv addSubview:h];
    NSArray *names = @[@"截图翻译", @"划词翻译", @"翻译当前文本"];
    self.shortcutButtons = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
      NSTextField *l = [self label:names[i] size:13 bold:YES color:nil];
      l.frame = NSMakeRect(28, 175 - i * 52, 160, 22); [cv addSubview:l];
      ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(190, 170 - i * 52, 240, 32)];
      b.tag = i;
      b.title = [self shortcutDisplayForAction:i];
      b.hoverColor = [NSColor systemTealColor];
      b.target = self; b.action = @selector(recordShortcutForAction:);
      [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
      [cv addSubview:b];
      [self.shortcutButtons addObject:b];
    }
    self.shortcutStatusLabel = [self label:@"点击右侧快捷键开始录制；Esc 取消" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
    self.shortcutStatusLabel.frame = NSMakeRect(24, 18, 430, 18); [cv addSubview:self.shortcutStatusLabel];
    [self.shortcutSettingsWindow center];
  }
  [self stopShortcutRecording];
  [self refreshShortcutButtons];
  [NSApp activateIgnoringOtherApps:YES];
  [self.shortcutSettingsWindow makeKeyAndOrderFront:nil];
  [self.shortcutSettingsWindow orderFrontRegardless];
}

- (void)stopShortcutRecording {
  if (self.shortcutRecordingMonitor) {
    [NSEvent removeMonitor:self.shortcutRecordingMonitor];
    self.shortcutRecordingMonitor = nil;
  }
  self.shortcutRecordingAction = -1;
  [self refreshShortcutButtons];
  if (self.shortcutStatusLabel) self.shortcutStatusLabel.stringValue = @"点击右侧快捷键开始录制；Esc 取消";
}

- (void)recordShortcutForAction:(ColorHoverButton *)sender {
  [self stopShortcutRecording];
  self.shortcutRecordingAction = sender.tag;
  sender.title = @"请按新组合键…";
  if (self.shortcutStatusLabel) self.shortcutStatusLabel.stringValue = @"录制中：按下组合键，Esc 取消";
  __weak typeof(self) weakSelf = self;
  self.shortcutRecordingMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
    NSInteger action = weakSelf.shortcutRecordingAction;
    if (action < 0) return e;
    if (e.keyCode == 53) { [weakSelf stopShortcutRecording]; return nil; }
    NSEventModifierFlags f = e.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift);
    if (!(f & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))) {
      weakSelf.shortcutStatusLabel.stringValue = @"请至少使用 Command / Control / Option 之一";
      return nil;
    }
    UInt32 mods = 0;
    if (f & NSEventModifierFlagControl) mods |= controlKey;
    if (f & NSEventModifierFlagOption) mods |= optionKey;
    if (f & NSEventModifierFlagShift) mods |= shiftKey;
    if (f & NSEventModifierFlagCommand) mods |= cmdKey;
    NSString *key = e.charactersIgnoringModifiers.uppercaseString;
    if (!key.length) key = [NSString stringWithFormat:@"Key%u", (unsigned)e.keyCode];
    if (e.keyCode == kVK_Return) key = @"↩";
    else if (e.keyCode == kVK_Space) key = @"Space";
    else if (e.keyCode == kVK_Tab) key = @"⇥";
    NSMutableString *disp = [NSMutableString string];
    if (mods & controlKey) [disp appendString:@"⌃"];
    if (mods & optionKey) [disp appendString:@"⌥"];
    if (mods & shiftKey) [disp appendString:@"⇧"];
    if (mods & cmdKey) [disp appendString:@"⌘"];
    [disp appendString:key];
    UInt32 oldCode = action == 0 ? weakSelf.shotKeyCode : (action == 1 ? weakSelf.selectionKeyCode : weakSelf.translateKeyCode);
    UInt32 oldMods = action == 0 ? weakSelf.shotModifiers : (action == 1 ? weakSelf.selectionModifiers : weakSelf.translateModifiers);
    NSString *oldDisp = [weakSelf shortcutDisplayForAction:action];
    if (![weakSelf registerHotKeyForAction:action code:(UInt32)e.keyCode modifiers:mods display:disp]) {
      [weakSelf registerHotKeyForAction:action code:oldCode modifiers:oldMods display:oldDisp];
      weakSelf.shortcutStatusLabel.stringValue = @"该快捷键被占用，请换一个";
      return nil;
    }
    [weakSelf stopShortcutRecording];
    weakSelf.shortcutStatusLabel.stringValue = @"已保存，立即生效";
    return nil;
  }];
}

- (void)beginScreenshotTranslation {
  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"dl-translate-shot.png"];
  [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/screencapture";
    t.arguments = @[@"-i", @"-x", tmp];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    if (![[NSFileManager defaultManager] fileExistsAtPath:tmp]) return;
    [self translationOCRImage:tmp completion:^(NSString *text) {
      [self confirmTranslateText:text origin:@"截图"];
    }];
  });
}

- (void)translationChooseDocument:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
  if ([p runModal] != NSModalResponseOK) return;
  [self translationExtractTextFromURL:p.URL completion:^(NSString *text) {
    [self translationSetSource:text status:text.length ? @"文档读取完成，请点击翻译" : @"没有读取到文本"];
  }];
}

- (void)translationFilesDropped:(NSArray<NSURL *> *)urls {
  if (!urls.count) return;
  [self translationExtractTextFromURL:urls.firstObject completion:^(NSString *text) {
    [self translationSetSource:text status:text.length ? [NSString stringWithFormat:@"已读取 %@", urls.firstObject.lastPathComponent] : @"没有读取到文本"];
  }];
}

- (NSArray<NSString *> *)translationChunks:(NSString *)text {
  NSMutableArray *chunks = [NSMutableArray array];
  NSArray *paras = [text componentsSeparatedByString:@"\n\n"];
  NSMutableString *cur = [NSMutableString string];
  for (NSString *p in paras) {
    if (cur.length + p.length > 2800) {
      if (cur.length) [chunks addObject:cur.copy];
      [cur setString:@""];
      if (p.length > 2800) {
        for (NSUInteger i = 0; i < p.length; i += 2800) {
          [chunks addObject:[p substringWithRange:NSMakeRange(i, MIN(2800, p.length - i))]];
        }
        continue;
      }
    }
    if (cur.length) [cur appendString:@"\n\n"];
    [cur appendString:p];
  }
  if (cur.length) [chunks addObject:cur.copy];
  return chunks;
}

- (void)translateChunks:(NSArray<NSString *> *)chunks index:(NSInteger)idx output:(NSMutableString *)output base:(NSString *)base model:(NSString *)model key:(NSString *)key target:(NSString *)target {
  if (idx >= (NSInteger)chunks.count) {
    self.translationResultView.string = output;
    self.translationStatus.stringValue = @"翻译完成";
    self.translationBusy = NO;
    return;
  }
  self.translationStatus.stringValue = [NSString stringWithFormat:@"正在翻译 %ld/%ld…", (long)(idx+1), (long)chunks.count];
  NSDictionary *body = @{@"model": model, @"temperature": @0.2, @"messages": @[
    @{@"role": @"system", @"content": [NSString stringWithFormat:@"You are a professional translator. Translate the user's text into %@. Preserve Markdown, line breaks and formatting. Output only the translation.", target]},
    @{@"role": @"user", @"content": chunks[idx]}]};
  NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]]];
  req.HTTPMethod = @"POST";
  [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = json;
  req.timeoutInterval = 120;
  [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
    NSString *content = nil; NSString *errMsg = nil;
    if (data.length) {
      id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
      if ([obj isKindOfClass:[NSDictionary class]]) {
        id choices = obj[@"choices"];
        if ([choices isKindOfClass:[NSArray class]] && [choices count]) {
          id msg = choices[0][@"message"];
          id c = msg[@"content"];
          if ([c isKindOfClass:[NSString class]]) content = c;
          else if ([c isKindOfClass:[NSArray class]]) {
            NSMutableString *m = [NSMutableString string];
            for (id part in c) if ([part isKindOfClass:[NSDictionary class]] && [part[@"text"] isKindOfClass:[NSString class]]) [m appendString:part[@"text"]];
            content = m;
          }
        }
        if (!content) errMsg = obj[@"error"][@"message"] ?: @"API 返回格式异常";
      }
    }
    if (!content.length) errMsg = errMsg ?: (err.localizedDescription ?: @"翻译请求失败");
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!content.length) {
        self.translationStatus.stringValue = errMsg;
        self.translationBusy = NO;
      } else {
        [output appendString:content];
        if (idx + 1 < (NSInteger)chunks.count) [output appendString:@"\n\n"];
        [self translateChunks:chunks index:idx+1 output:output base:base model:model key:key target:target];
      }
    });
  }] resume];
}

- (void)translationTranslate:(id)sender {
  if (self.translationBusy) return;
  NSString *text = self.translationSourceView.string;
  if (!text.length) { self.translationStatus.stringValue = @"请先输入、截图或拖入要翻译的内容"; return; }
  NSDictionary *e = self.translationProviderPopup.selectedItem.representedObject;
  if (!e) { self.translationStatus.stringValue = @"请选择 AI 服务"; return; }
  NSDictionary *cfg = [self translationAPIConfigForEntry:e];
  NSString *model = [self.translationModelField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!cfg) { self.translationStatus.stringValue = @"该服务没有可用 API 地址，请在备注中写「API 地址：…」"; return; }
  if (!model.length) { self.translationStatus.stringValue = @"请填写模型名称"; return; }
  NSString *key = e[@"api"] ?: @"";
  if (!key.length) { self.translationStatus.stringValue = @"该服务没有 API Key"; return; }
  NSArray *names = @[@"中文（简体）", @"English", @"日本語", @"한국어", @"Français", @"Deutsch", @"Español", @"Русский"];
  NSInteger ti = MAX(0, self.translationTargetPopup.indexOfSelectedItem);
  NSString *target = names[MIN(ti, (NSInteger)names.count - 1)];
  NSArray *chunks = [self translationChunks:text];
  if (!chunks.count) return;
  self.translationBusy = YES;
  self.translationResultView.string = @"";
  [self translateChunks:chunks index:0 output:[NSMutableString string] base:cfg[@"base"] model:model key:key target:target];
}

- (void)translationCopy:(id)sender {
  NSString *text = self.translationResultView.string;
  if (!text.length) return;
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
  self.translationStatus.stringValue = @"译文已复制";
}

- (void)translationSave:(id)sender {
  NSString *text = self.translationResultView.string;
  if (!text.length) return;
  NSSavePanel *p = [NSSavePanel savePanel];
  p.nameFieldStringValue = @"translation.txt";
  if ([p runModal] != NSModalResponseOK) return;
  [text writeToFile:p.URL.path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  self.translationStatus.stringValue = @"译文已保存";
}

- (void)showCompressWindow:(id)sender {
  if (!self.compressWindow) {
    NSRect frame = NSMakeRect(0, 0, 620, 470);
    self.compressWindow = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    self.compressWindow.title = @"压缩 / 解压";
    self.compressWindow.releasedWhenClosed = NO;
    self.compressWindow.backgroundColor = PageBackgroundForAppearance(NSApp.effectiveAppearance);
    NSView *cv = self.compressWindow.contentView;
    NSTextField *title = [self label:@"压缩 / 解压" size:20 bold:YES color:nil];
    title.frame = NSMakeRect(24, 418, 300, 26); [cv addSubview:title];
    NSTextField *sub = [self label:@"拖入文件或文件夹，支持 ZIP 与 TAR.GZ；不会修改原文件" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
    sub.frame = NSMakeRect(24, 396, 560, 18); [cv addSubview:sub];

    CompressDropView *drop = [[CompressDropView alloc] initWithFrame:NSMakeRect(20, 190, 580, 190)];
    drop.dropTarget = self; drop.dropAction = @selector(compressDropped:);
    [cv addSubview:drop];
    NSTextField *dhint = [self label:@"拖入文件 / 文件夹" size:13 bold:NO color:[NSColor tertiaryLabelColor]];
    dhint.alignment = NSTextAlignmentCenter;
    dhint.frame = NSMakeRect(20, 270, 580, 22); [cv addSubview:dhint];

    self.compressListLabel = [self label:@"尚未选择项目" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
    self.compressListLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.compressListLabel.frame = NSMakeRect(20, 166, 580, 18); [cv addSubview:self.compressListLabel];

    NSArray *symbols = @[@"doc.badge.plus", @"folder.badge.plus", @"trash", @"doc.zipper", @"archivebox", @"shippingbox.and.arrow.backward"];
    NSArray *tips = @[@"添加文件", @"添加文件夹", @"清空", @"压缩为 ZIP", @"压缩为 TAR.GZ", @"解压"];
    NSArray *details = @[@"选择一个或多个文件", @"选择一个或多个文件夹", @"移除已选项目", @"压缩为 ZIP 压缩包", @"压缩为 TAR.GZ 压缩包", @"解压 ZIP / TAR.GZ"];
    NSArray *sels = @[@"compressAddFiles:", @"compressAddFolder:", @"compressClear:", @"compressZip:", @"compressTar:", @"extractArchive:"];
    CGFloat xs[6] = {300, 344, 388, 432, 476, 520};
    for (NSInteger i = 0; i < 6; i++) {
      ColorHoverButton *b = [[ColorHoverButton alloc] initWithFrame:NSMakeRect(xs[i], 414, 40, 34)];
      b.title = @"";
      b.image = [NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:tips[i]];
      b.imagePosition = NSImageOnly;
      b.hoverColor = (i < 3) ? [NSColor systemGrayColor] : [NSColor systemOrangeColor];
      b.target = self; b.action = NSSelectorFromString(sels[i]);
      b.hoverTitle = tips[i]; b.hoverDetail = details[i];
      [b applyColor:DLButtonBackground() textColor:[NSColor labelColor]];
      [cv addSubview:b];
    }
    self.compressSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 30, 18, 18)];
    self.compressSpinner.style = NSProgressIndicatorStyleSpinning;
    self.compressSpinner.displayedWhenStopped = NO;
    [cv addSubview:self.compressSpinner];
    self.compressStatus = [self label:@"" size:10.5 bold:NO color:[NSColor secondaryLabelColor]];
    self.compressStatus.frame = NSMakeRect(50, 30, 540, 18); [cv addSubview:self.compressStatus];
    self.compressPinButton = [[NSButton alloc] initWithFrame:NSMakeRect(572, 418, 30, 26)];
    self.compressPinButton.bordered = NO;
    self.compressPinButton.target = self;
    self.compressPinButton.action = @selector(toggleToolPin:);
    self.compressPinButton.tag = 0;
    [cv addSubview:self.compressPinButton];
    self.compressPaths = [NSMutableArray array];
    [self.compressWindow center];
  }
  BOOL cpinned = [[NSUserDefaults standardUserDefaults] boolForKey:@"centerCompressPinned"];
  self.compressWindow.level = cpinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
  [self applyPinLook:self.compressPinButton pinned:cpinned];
  [NSApp activateIgnoringOtherApps:YES];
  [self.compressWindow makeKeyAndOrderFront:nil];
  [self.compressWindow orderFrontRegardless];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (self.compressWindow.isVisible) [self.compressWindow orderFrontRegardless];
  });
}

- (void)compressAddFiles:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = YES;
  if ([p runModal] != NSModalResponseOK) return;
  [self addCompressURLs:p.URLs];
}
- (void)compressAddFolder:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = NO; p.canChooseDirectories = YES; p.allowsMultipleSelection = YES;
  if ([p runModal] != NSModalResponseOK) return;
  [self addCompressURLs:p.URLs];
}
- (void)compressDropped:(NSArray<NSURL *> *)urls { [self addCompressURLs:urls]; }
- (void)addCompressURLs:(NSArray<NSURL *> *)urls {
  if (!self.compressPaths) self.compressPaths = [NSMutableArray array];
  for (NSURL *u in urls) {
    NSString *p = u.path.stringByStandardizingPath;
    if (!p.length || [self.compressPaths containsObject:p]) continue;
    [self.compressPaths addObject:p];
  }
  NSMutableArray *names = [NSMutableArray array];
  for (NSString *p in self.compressPaths) [names addObject:p.lastPathComponent];
  self.compressListLabel.stringValue = names.count ? [names componentsJoinedByString:@"  ·  "] : @"尚未选择项目";
}
- (void)compressClear:(id)sender {
  [self.compressPaths removeAllObjects];
  self.compressListLabel.stringValue = @"尚未选择项目";
  self.compressStatus.stringValue = @"";
}
- (NSString *)commonParentForPaths:(NSArray<NSString *> *)paths {
  if (!paths.count) return nil;
  NSArray *first = [paths.firstObject pathComponents];
  NSInteger n = first.count - 1;
  for (NSString *p in paths) {
    NSArray *c = p.pathComponents;
    NSInteger m = MIN(n, (NSInteger)c.count - 1);
    NSInteger k = 0;
    while (k < m && [c[k] isEqualToString:first[k]]) k++;
    n = k;
  }
  NSArray *prefix = [first subarrayWithRange:NSMakeRange(0, n)];
  if (!prefix.count) return nil;
  return [NSString pathWithComponents:prefix];
}

- (void)runCompressTask:(NSString *)launch args:(NSArray<NSString *> *)args currentDir:(NSString *)dir completion:(void (^)(BOOL, NSString *))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = launch;
    t.arguments = args;
    if (dir) t.currentDirectoryURL = [NSURL fileURLWithPath:dir];
    NSPipe *err = [NSPipe pipe];
    t.standardError = err;
    t.standardOutput = [NSPipe pipe];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {
      dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, e.reason ?: @"启动失败"); });
      return;
    }
    NSData *ed = [err.fileHandleForReading readDataToEndOfFile];
    NSString *msg = [[NSString alloc] initWithData:ed encoding:NSUTF8StringEncoding] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(t.terminationStatus == 0, msg); });
  });
}

- (void)compressZip:(id)sender {
  if (!self.compressPaths.count) { self.compressStatus.stringValue = @"请先添加文件或文件夹"; return; }
  NSString *parent = [self commonParentForPaths:self.compressPaths];
  if (!parent) { self.compressStatus.stringValue = @"请选择同一目录下的项目"; return; }
  NSSavePanel *p = [NSSavePanel savePanel];
  p.nameFieldStringValue = [((NSString *)self.compressPaths.firstObject).lastPathComponent stringByAppendingString:@".zip"];
  p.allowedFileTypes = @[@"zip"];
  if ([p runModal] != NSModalResponseOK) return;
  NSString *archive = p.URL.path;
  [[NSFileManager defaultManager] removeItemAtPath:archive error:NULL];
  NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-r", @"-y", archive, nil];
  for (NSString *path in self.compressPaths) [args addObject:path.lastPathComponent];
  [self.compressSpinner startAnimation:nil];
  self.compressStatus.stringValue = @"正在压缩 ZIP…";
  [self runCompressTask:@"/usr/bin/zip" args:args currentDir:parent completion:^(BOOL ok, NSString *msg) {
    [self.compressSpinner stopAnimation:nil];
    self.compressStatus.stringValue = ok ? @"ZIP 压缩完成" : msg;
  }];
}

- (void)compressTar:(id)sender {
  if (!self.compressPaths.count) { self.compressStatus.stringValue = @"请先添加文件或文件夹"; return; }
  NSString *parent = [self commonParentForPaths:self.compressPaths];
  if (!parent) { self.compressStatus.stringValue = @"请选择同一目录下的项目"; return; }
  NSSavePanel *p = [NSSavePanel savePanel];
  p.nameFieldStringValue = [((NSString *)self.compressPaths.firstObject).lastPathComponent stringByAppendingString:@".tar.gz"];
  p.allowedFileTypes = @[@"gz"];
  if ([p runModal] != NSModalResponseOK) return;
  NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-czf", p.URL.path, @"-C", parent, nil];
  for (NSString *path in self.compressPaths) [args addObject:path.lastPathComponent];
  [self.compressSpinner startAnimation:nil];
  self.compressStatus.stringValue = @"正在压缩 TAR.GZ…";
  [self runCompressTask:@"/usr/bin/tar" args:args currentDir:nil completion:^(BOOL ok, NSString *msg) {
    [self.compressSpinner stopAnimation:nil];
    self.compressStatus.stringValue = ok ? @"TAR.GZ 压缩完成" : msg;
  }];
}

- (BOOL)isSafeArchiveEntry:(NSString *)entry {
  if (!entry.length || [entry hasPrefix:@"/"]) return NO;
  for (NSString *part in [entry pathComponents]) if ([part isEqualToString:@".."]) return NO;
  return YES;
}

- (BOOL)archiveListSafe:(NSString *)archive tar:(BOOL)tar {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = tar ? @"/usr/bin/tar" : @"/usr/bin/unzip";
  t.arguments = tar ? @[@"-tzf", archive] : @[@"-Z1", archive];
  NSPipe *out = [NSPipe pipe];
  t.standardOutput = out;
  t.standardError = [NSPipe pipe];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return NO; }
  if (t.terminationStatus != 0) return NO;
  NSString *s = [[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
  for (NSString *line in [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    if (line.length && ![self isSafeArchiveEntry:line]) return NO;
  }
  return YES;
}

- (void)extractArchive:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
  p.allowedFileTypes = @[@"zip", @"gz", @"tgz", @"tar"];
  p.message = @"选择要解压的 ZIP / TAR.GZ";
  if ([p runModal] != NSModalResponseOK) return;
  NSString *archive = p.URL.path;
  BOOL isTar = [archive.pathExtension.lowercaseString isEqualToString:@"gz"] || [archive.pathExtension.lowercaseString isEqualToString:@"tgz"] || [archive.pathExtension.lowercaseString isEqualToString:@"tar"];
  NSOpenPanel *dp = [NSOpenPanel openPanel];
  dp.canChooseFiles = NO; dp.canChooseDirectories = YES; dp.allowsMultipleSelection = NO;
  dp.message = @"选择解压目标文件夹";
  if ([dp runModal] != NSModalResponseOK) return;
  NSString *dest = [dp.URL.path stringByAppendingPathComponent:archive.lastPathComponent.stringByDeletingPathExtension];
  [[NSFileManager defaultManager] createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:NULL];
  [self.compressSpinner startAnimation:nil];
  self.compressStatus.stringValue = @"正在检查压缩包…";
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    BOOL safe = [self archiveListSafe:archive tar:isTar];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!safe) {
        [self.compressSpinner stopAnimation:nil];
        self.compressStatus.stringValue = @"压缩包包含不安全路径，已拒绝解压";
        return;
      }
      self.compressStatus.stringValue = @"正在解压…";
      NSArray *args = isTar ? @[@"-xzf", archive, @"-C", dest] : @[@"-x", @"-k", archive, dest];
      NSString *launch = isTar ? @"/usr/bin/tar" : @"/usr/bin/ditto";
      [self runCompressTask:launch args:args currentDir:nil completion:^(BOOL ok, NSString *msg) {
        [self.compressSpinner stopAnimation:nil];
        self.compressStatus.stringValue = ok ? [NSString stringWithFormat:@"已解压到 %@", dest] : msg;
      }];
    });
  });
}

- (void)openConsoleFromPopover:(id)sender {
  [self.popover performClose:nil];
  [self showWindow:nil];
}

- (void)closePopover:(id)sender {
  [self.popover performClose:nil];
}

- (void)refreshPopover:(id)sender {
  [self sample];
  [self refreshExternalVolumes];
  if (self.quickTabs.selectedSegment == 1) [self rebuildQuickGroupTab];
  if (self.quickTabs.selectedSegment == 2) [self rebuildQuickAITab];
  [self showToast:@"菜单栏数据已刷新"];
}

- (NSString *)batteryText {
  CFTypeRef blob = IOPSCopyPowerSourcesInfo();
  if (!blob) return @"电池 --";
  CFArrayRef list = IOPSCopyPowerSourcesList(blob);
  NSString *result = @"电池 --";
  if (list) {
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
      CFTypeRef src = CFArrayGetValueAtIndex(list, i);
      NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(blob, src);
      if (![d isKindOfClass:[NSDictionary class]]) continue;
      NSNumber *cur = d[@kIOPSCurrentCapacityKey];
      NSNumber *max = d[@kIOPSMaxCapacityKey];
      NSNumber *charging = d[@kIOPSIsChargingKey];
      if (![cur isKindOfClass:[NSNumber class]] || ![max isKindOfClass:[NSNumber class]] || max.doubleValue <= 0) continue;
      double pct = cur.doubleValue / max.doubleValue * 100.0;
      if ([charging boolValue]) result = [NSString stringWithFormat:@"电池 %.0f%% · 充电中", pct];
      else {
        NSNumber *mins = d[@kIOPSTimeToEmptyKey];
        if ([mins isKindOfClass:[NSNumber class]] && mins.intValue > 0)
          result = [NSString stringWithFormat:@"电池 %.0f%% · 剩 %d:%02d", pct, mins.intValue/60, mins.intValue%60];
        else result = [NSString stringWithFormat:@"电池 %.0f%%", pct];
      }
      break;
    }
    CFRelease(list);
  }
  CFRelease(blob);
  return result;
}

- (NSString *)thermalText {
  NSProcessInfoThermalState st = [[NSProcessInfo processInfo] thermalState];
  NSString *s = @"热状态 正常";
  if (st == NSProcessInfoThermalStateFair) s = @"热状态 偏热";
  else if (st == NSProcessInfoThermalStateSerious) s = @"热状态 严重";
  else if (st == NSProcessInfoThermalStateCritical) s = @"热状态 过热";
  int level = 0; size_t sz = sizeof(level);
  if (sysctlbyname("machdep.xcpm.cpu_thermal_level", &level, &sz, NULL, 0) == 0 && level > 0) {
    s = [s stringByAppendingFormat:@" · CPU 热档 %d", level];
  }
  return s;
}

- (NSString *)processTopText {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/bin/ps";
  t.arguments = @[@"-Ao", @"pcpu=,pmem=,comm=", @"-r"];
  NSPipe *pipe = [NSPipe pipe];
  t.standardOutput = pipe;
  t.standardError = [NSPipe pipe];
  @try { [t launch]; } @catch (NSException *e) { return @"进程信息不可用"; }
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  NSMutableArray *lines = [NSMutableArray array];
  for (NSString *line in [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!trim.length) continue;
    NSArray *parts = [trim componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (parts.count < 3) continue;
    NSString *cpu = parts[0], *mem = parts[1];
    NSString *name = [[parts subarrayWithRange:NSMakeRange(2, parts.count-2)] componentsJoinedByString:@" "];
    if ([name containsString:@"/"]) name = [name lastPathComponent];
    [lines addObject:[NSString stringWithFormat:@"%5.1f%%  %5.1f%%   %@", cpu.doubleValue, mem.doubleValue, name]];
    if (lines.count >= 5) break;
  }
  return [lines componentsJoinedByString:@"\n"];
}

// ---------------- 采样 ----------------
- (BOOL)scanProtectedDirsEnabled {
  id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"centerScanProtectedDirs"];
  return v ? [v boolValue] : NO;
}
- (BOOL)isProtectedUserPath:(NSString *)path {
  NSString *home = NSHomeDirectory();
  NSString *p = path.stringByStandardizingPath;
  for (NSString *sub in @[@"Desktop", @"Documents", @"Downloads"]) {
    NSString *dir = [[home stringByAppendingPathComponent:sub] stringByStandardizingPath];
    if ([p isEqualToString:dir] || [p hasPrefix:[dir stringByAppendingString:@"/"]]) return YES;
  }
  return NO;
}

- (NSArray<NSString *> *)scanSubdirs {
  // 为避免重复触发系统隐私授权，默认永不扫描受保护目录
  return @[@"Movies", @"Music"];
}
- (void)requestProtectedDirsAccess {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *n in @[@"Documents", @"Downloads", @"Desktop"]) {
      [fm contentsOfDirectoryAtPath:[NSHomeDirectory() stringByAppendingPathComponent:n] error:NULL];
    }
  });
}

- (void)requestMediaDirsAccess {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *n in @[@"Music", @"Movies", @"Library"]) {
      [fm contentsOfDirectoryAtPath:[NSHomeDirectory() stringByAppendingPathComponent:n] error:NULL];
    }
  });
}

- (void)requestRemovableVolumeAccess {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *vols = [fm contentsOfDirectoryAtPath:@"/Volumes" error:NULL] ?: @[];
    for (NSString *v in vols) {
      [fm contentsOfDirectoryAtPath:[@"/Volumes" stringByAppendingPathComponent:v] error:NULL];
    }
  });
}

- (void)requestPhotoLibraryAccess {
  [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
        [self showToast:@"照片图库已授权"];
      } else {
        self.albumModeCheck.state = NSControlStateValueOff;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"centerAlbumFullLibrary"];
        [self showToast:@"未授权照片图库，已切回本机原文件"];
      }
    });
  }];
}

- (BOOL)confirmPermissionAction:(NSString *)message {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"需要系统授权";
  a.informativeText = message;
  [a addButtonWithTitle:@"继续"];
  [a addButtonWithTitle:@"取消"];
  return [a runModal] == NSAlertFirstButtonReturn;
}

- (void)showFullDiskAccessHelp:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"完全磁盘访问权限（最高权限）";
  a.informativeText = @"开启后控制台可读取本机所有存储位置，包括其他应用的数据和受保护目录。\n\n开启方法：\n系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 点「+」添加 DockLaunchers 控制台，然后重新启动控制台。\n\n这是 macOS 最高级别文件权限，请确认后再开启。";
  [a addButtonWithTitle:@"打开系统设置"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] == NSAlertFirstButtonReturn) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
  }
}

- (void)showRemovableVolumeHelp:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"可移除宗卷访问权限";
  a.informativeText = @"扫描外部磁盘需要允许本应用访问「可移除宗卷」。\n\n打开：系统设置 → 隐私与安全性 → 文件与文件夹，找到 DockLaunchers 控制台，勾选「可移除宗卷」。\n\n如果列表里没有本应用，先在「文件管理」中选择外部磁盘并刷新一次，触发授权请求后再回来开启。";
  [a addButtonWithTitle:@"请求访问"];
  [a addButtonWithTitle:@"打开系统设置"];
  [a addButtonWithTitle:@"取消"];
  NSModalResponse r = [a runModal];
  if (r == NSAlertFirstButtonReturn) {
    [self requestRemovableVolumeAccess];
    [self showToast:@"已请求可移除宗卷访问权限"];
  } else if (r == NSAlertSecondButtonReturn) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"]];
  }
}

- (void)showAbout:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"DockLaunchers 控制台";
  NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0";
  a.informativeText = [NSString stringWithFormat:@"版本 %@\n\nDock 分组启动器与卸载管理工具\n菜单栏常驻 · 实时状态 · 文件管理\n\n所有数据保存在本机，不上传云端。", ver];
  [a addButtonWithTitle:@"好"];
  [a runModal];
}

- (void)togglePersonalMedia:(id)sender {
  BOOL on = (self.mediaModeCheck.state == NSControlStateValueOn);
  if (on && ![self confirmPermissionAction:@"开启后控制台会扫描音乐 / 影片 / 用户资源库，可能触发系统隐私授权。是否继续？"]) {
    self.mediaModeCheck.state = NSControlStateValueOff; return;
  }
  [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"centerScanPersonalMedia"];
  if (on) [self requestMediaDirsAccess];
  [self showToast:on ? @"已请求媒体目录访问权限" : @"已排除个人媒体目录"];
}

- (void)toggleAlbumMode:(id)sender {
  BOOL on = (self.albumModeCheck.state == NSControlStateValueOn);
  if (on && ![self confirmPermissionAction:@"完整图库模式会请求访问照片图库，以显示包含 iCloud 在内的全部照片和视频。是否继续？"]) {
    self.albumModeCheck.state = NSControlStateValueOff; return;
  }
  [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"centerAlbumFullLibrary"];
  if (on) [self requestPhotoLibraryAccess];
  [self showToast:on ? @"正在请求照片图库权限…" : @"相册已切换为本机原文件"];
}

- (void)toggleProtectedDirs:(id)sender {
  [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"centerScanProtectedDirs"];
  self.protectedDirsCheck.state = NSControlStateValueOff;
  [self showToast:@"受保护目录扫描已禁用，避免系统授权弹窗"];
}

- (void)probeBatteryFromProfiler {
  if (self.batteryProbeRunning) return;
  self.batteryProbeRunning = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/system_profiler";
    t.arguments = @[@"SPPowerDataType"];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (NSException *e) { weakSelf.batteryProbeRunning = NO; weakSelf.lastBatteryProbe = [NSDate timeIntervalSinceReferenceDate]; return; }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSInteger health = 0, cycles = 0;
    NSString *condition = @"";
    for (NSString *line in [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSString *lower = trim.lowercaseString;
      NSString *value = @"";
      NSRange colon = [trim rangeOfString:@":"];
      if (colon.location != NSNotFound) value = [[trim substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([lower containsString:@"maximum capacity"] || [trim containsString:@"最大容量"]) {
        health = [[value componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""].integerValue;
      } else if ([lower containsString:@"cycle count"] || [trim containsString:@"循环次数"]) {
        cycles = value.integerValue;
      } else if ([lower containsString:@"condition"] || [trim containsString:@"状态"]) {
        if (value.length) condition = value;
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (health > 0) weakSelf.batteryHealthFromProfiler = health;
      if (cycles > 0) weakSelf.batteryCyclesFromProfiler = cycles;
      if (condition.length) weakSelf.batteryConditionText = condition;
      weakSelf.lastBatteryProbe = [NSDate timeIntervalSinceReferenceDate];
      weakSelf.batteryProbeRunning = NO;
    });
  });
}

- (double)gpuUsagePercent {
  double best = 0;
  for (NSString *cls in @[@"IOAccelerator", @"AGXAccelerator"]) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls.UTF8String), &it) != KERN_SUCCESS) continue;
    io_object_t svc;
    while ((svc = IOIteratorNext(it))) {
      CFMutableDictionaryRef props = NULL;
      if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        NSDictionary *dict = CFBridgingRelease(props);
        NSDictionary *perf = dict[@"PerformanceStatistics"];
        if ([perf isKindOfClass:[NSDictionary class]]) {
          for (NSString *k in @[@"Device Utilization %", @"GPU Activity(%)", @"gpu_busy", @"GPU Busy"]) {
            id v = perf[k];
            if ([v isKindOfClass:[NSNumber class]]) best = MAX(best, [v doubleValue]);
          }
        }
      }
      IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (best > 0) break;
  }
  return best;
}

- (NSDictionary *)batteryInfo {
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
  if (!svc) return nil;
  CFMutableDictionaryRef props = NULL;
  NSDictionary *dict = nil;
  if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) dict = CFBridgingRelease(props);
  IOObjectRelease(svc);
  return dict;
}

- (NSString *)gbString:(unsigned long long)bytes {
  return [NSString stringWithFormat:@"%.1f GB", bytes / 1073741824.0];
}

- (void)sample {
  host_cpu_load_info_data_t cpu;
  mach_msg_type_number_t ccount = HOST_CPU_LOAD_INFO_COUNT;
  double cpuPct = 0;
  if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &ccount) == KERN_SUCCESS) {
    double busy = cpu.cpu_ticks[CPU_STATE_USER] + cpu.cpu_ticks[CPU_STATE_SYSTEM] + cpu.cpu_ticks[CPU_STATE_NICE];
    double total = busy + cpu.cpu_ticks[CPU_STATE_IDLE];
    double db = busy - gPrevCPUBusy, dt = total - gPrevCPUTotal;
    if (dt > 0) cpuPct = MAX(0, MIN(100, db/dt*100.0));
    gPrevCPUBusy = busy; gPrevCPUTotal = total;
  }
  unsigned long long memTotal = 0; size_t sz = sizeof(memTotal);
  sysctlbyname("hw.memsize", &memTotal, &sz, NULL, 0);
  vm_statistics64_data_t vm; mach_msg_type_number_t vcount = HOST_VM_INFO64_COUNT;
  double memPct = 0;
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &vcount) == KERN_SUCCESS) {
    unsigned long long used = ((unsigned long long)vm.active_count + vm.wire_count + vm.compressor_page_count) * vm_page_size;
    if (memTotal) memPct = MIN(100.0, (double)used/(double)memTotal*100.0);
  }
  struct statfs fs; double diskPct = 0;
  if (statfs("/", &fs) == 0) {
    unsigned long long total = (unsigned long long)fs.f_blocks * fs.f_bsize;
    unsigned long long avail = (unsigned long long)fs.f_bavail * fs.f_bsize;
    if (total) diskPct = (double)(total-avail)/(double)total*100.0;
  }
  unsigned long long inB = 0, outB = 0;
  struct ifaddrs *ifa = NULL;
  if (getifaddrs(&ifa) == 0) {
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
      if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
      if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
      struct if_data *d = (struct if_data *)p->ifa_data;
      if (!d) continue;
      inB += d->ifi_ibytes; outB += d->ifi_obytes;
    }
    freeifaddrs(ifa);
  }
  double now = [NSDate timeIntervalSinceReferenceDate];
  double inRate = 0, outRate = 0;
  if (gLastNetTime > 0 && now > gLastNetTime) {
    double dt = now - gLastNetTime;
    inRate = (inB >= gPrevNetIn ? inB-gPrevNetIn : 0)/dt;
    outRate = (outB >= gPrevNetOut ? outB-gPrevNetOut : 0)/dt;
  }
  gPrevNetIn = inB; gPrevNetOut = outB; gLastNetTime = now;

  unsigned long long memUsed = 0;
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &vcount) == KERN_SUCCESS) {
    memUsed = ((unsigned long long)vm.active_count + vm.wire_count + vm.compressor_page_count) * vm_page_size;
  }
  struct statfs fs2; unsigned long long diskTotal = 0, diskFree = 0;
  if (statfs("/", &fs2) == 0) {
    diskTotal = (unsigned long long)fs2.f_blocks * fs2.f_bsize;
    diskFree = (unsigned long long)fs2.f_bavail * fs2.f_bsize;
  }
  if (self.metricColumns.count >= 6) {
    MetricColumnView *memCol = self.metricColumns[0];
    [memCol setValueText:[NSString stringWithFormat:@"%.0f%%", memPct]
                  detail:[NSString stringWithFormat:@"%@ / %@", [self gbString:memUsed], [self gbString:memTotal]]
                     bar:memPct];
    MetricColumnView *diskCol = self.metricColumns[1];
    [diskCol setValueText:[NSString stringWithFormat:@"%.0f%%", diskPct]
                   detail:[NSString stringWithFormat:@"已用 %@\n可用 %@", [self gbString:diskTotal-diskFree], [self gbString:diskFree]]
                      bar:diskPct];
    MetricColumnView *cpuCol = self.metricColumns[2];
    [cpuCol setValueText:[NSString stringWithFormat:@"%.0f%%", cpuPct] detail:@"实时处理器占用" bar:cpuPct];
    self.gpuPercent = [self gpuUsagePercent];
    MetricColumnView *gpuCol = self.metricColumns[3];
    [gpuCol setValueText:(self.gpuPercent > 0 ? [NSString stringWithFormat:@"%.0f%%", self.gpuPercent] : @"--") detail:@"图形处理器占用" bar:self.gpuPercent];
    if ([NSDate timeIntervalSinceReferenceDate] - self.lastBatteryProbe > 60) [self probeBatteryFromProfiler];
    NSDictionary *bat = [self batteryInfo];
    MetricColumnView *pwrCol = self.metricColumns[4];
    if (bat) {
      NSDictionary *bd = [bat[@"BatteryData"] isKindOfClass:[NSDictionary class]] ? bat[@"BatteryData"] : @{};
      double cur = [bat[@"CurrentCapacity"] doubleValue];
      double maxc = [bat[@"MaxCapacity"] doubleValue] ?: 100;
      double pct = (maxc <= 100) ? cur : (maxc > 0 ? cur / maxc * 100.0 : 0);
      double rawMax = [bd[@"AppleRawMaxCapacity"] doubleValue];
      double design = [bd[@"DesignCapacity"] doubleValue];
      if (design <= 0) design = [bat[@"DesignCapacity"] doubleValue];
      double health = (design > 0 && rawMax > 0) ? rawMax / design * 100.0 : 0;
      if (self.batteryHealthFromProfiler > 0) health = self.batteryHealthFromProfiler;
      NSInteger cycles = self.batteryCyclesFromProfiler > 0 ? self.batteryCyclesFromProfiler : [bat[@"CycleCount"] integerValue];
      NSString *state = [bat[@"ExternalConnected"] boolValue] ? ([bat[@"IsCharging"] boolValue] ? @"充电中" : @"已接通电源") : @"使用电池";
      self.quickBatteryCycles = cycles;
      self.quickBatteryHealth = health;
      self.quickBatteryState = state;
      self.quickBat.stringValue = [NSString stringWithFormat:@"%.0f%%", pct];
      self.quickPowerSub.stringValue = [NSString stringWithFormat:@"循环 %ld 次 · 健康 %.0f%%", (long)cycles, health];
      [pwrCol setValueText:[NSString stringWithFormat:@"%.0f%%", pct]
                    detail:[NSString stringWithFormat:@"%@\n循环 %ld 次\n健康 %.0f%%", state, (long)cycles, health]
                       bar:pct];
    } else {
      [pwrCol setValueText:@"--" detail:@"未检测到电池" bar:0];
    }
    MetricColumnView *netCol = self.metricColumns[5];
    double rateKB = (inRate + outRate) / 1024.0;
    [netCol setValueFontSize:15];
    [netCol setValueText:[NSString stringWithFormat:@"%.0f KB/s", rateKB]
                  detail:[NSString stringWithFormat:@"↓ %@/s\n↑ %@/s", [self rate:inRate], [self rate:outRate]]
                     bar:MIN(100.0, rateKB * 2.0)];
  }
  [self updateExternalColumnDisplay];
  self.uptimeLabel.stringValue = [NSString stringWithFormat:@"系统启动 %@", [self uptimeString]];
  if (self.popover.isShown) {
    self.quickCPU.stringValue = [NSString stringWithFormat:@"%.0f%%", cpuPct];
    self.quickGPU.stringValue = self.gpuPercent > 0 ? [NSString stringWithFormat:@"%.0f%%", self.gpuPercent] : @"--";
    self.quickMem.stringValue = [NSString stringWithFormat:@"%.0f%%", memPct];
    self.quickDisk.stringValue = [NSString stringWithFormat:@"%.0f%%", diskPct];
    self.quickNet.stringValue = [NSString stringWithFormat:@"↑ %@/s   ↓ %@/s", [self rate:outRate], [self rate:inRate]];
    [self.quickCPUSpark addValue:cpuPct];
    [self.quickGPUSpark addValue:self.gpuPercent];
    [self.quickNetSpark addValue:MIN(100.0, (inRate+outRate)/1024.0/10.24)];
    self.quickMemBar.value = memPct;
    self.quickDiskBar.value = diskPct;
    self.quickCPUSub.stringValue = @"实时处理器占用";
    self.quickGPUSub.stringValue = @"图形处理器";
    self.quickCPUBar.value = cpuPct;
    self.quickGPUBar.value = self.gpuPercent;
    self.quickMemSub.stringValue = [NSString stringWithFormat:@"%@ / %@ · 压力正常", [self gbString:memUsed], [self gbString:memTotal]];
    self.quickDiskSub.stringValue = [NSString stringWithFormat:@"可用 %@ / 总计 %@", [self gbString:diskFree], [self gbString:diskTotal]];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TRACE")) fprintf(stderr, "TRACE cpu=%.0f mem=%.0f cols=%ld\n", cpuPct, memPct, (long)self.metricColumns.count);
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  self.statusItem.button.title = @"";
}

- (NSString *)rate:(double)bps {
  if (bps < 1024) return [NSString stringWithFormat:@"%.0f B", bps];
  if (bps < 1048576) return [NSString stringWithFormat:@"%.1f KB", bps/1024.0];
  return [NSString stringWithFormat:@"%.1f MB", bps/1048576.0];
}

- (NSString *)uptimeString {
  struct timeval boot; size_t sz = sizeof(boot);
  if (sysctl((int[]){CTL_KERN, KERN_BOOTTIME}, 2, &boot, &sz, NULL, 0) != 0) return @"--";
  NSTimeInterval up = [[NSDate date] timeIntervalSince1970] - boot.tv_sec;
  NSInteger d = (NSInteger)up/86400, h = ((NSInteger)up%86400)/3600, m = ((NSInteger)up%3600)/60;
  return [NSString stringWithFormat:@"%ld 天 %ld 小时 %ld 分", (long)d, (long)h, (long)m];
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    Controller *c = [[Controller alloc] init];
    NSApp.delegate = c;
    [NSApp run];
  }
  return 0;
}
