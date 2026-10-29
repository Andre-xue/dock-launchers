#import <Cocoa/Cocoa.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

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
  [[NSColor colorWithCalibratedWhite:0.965 alpha:1.0] setFill];
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

@interface Controller : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSWindow *window;
@property (strong) NSView *content;
@property (strong) NSButton *sideLive, *sideGroups, *sideUninstall, *sideSettings;
@property NSInteger section;
@property (strong) NSView *liveView, *groupsView, *uninstallView, *settingsView;
@property (strong) NSTextField *cpuLabel, *memLabel, *diskLabel, *netLabel, *uptimeLabel;
@property (strong) Sparkline *cpuSpark, *memSpark;
@property (strong) NSTimer *timer;
@property NSInteger sampleSeconds;
@property (strong) NSButton *menuBarCheck;
@property (strong) NSPopUpButton *intervalPopup;
@property (strong) NSButton *loginCheck;
// groups
@property (strong) NSMutableArray<NSDictionary *> *groups;
@property (strong) NSMutableSet<NSString *> *selectedGroups;
@property (strong) NSView *groupsList;
@property (strong) NSScrollView *groupsScroll;
// uninstall
@property (strong) NSMutableArray<NSDictionary *> *uninstallData;
@property (strong) NSMutableArray<NSDictionary *> *uninstallFiltered;
@property (strong) NSMutableSet<NSString *> *uninstallSelected;
@property (strong) NSTableView *uninstallTable;
@property (strong) NSSearchField *uninstallSearch;
@property (strong) NSTextField *uninstallFooter;
@property (strong) NSSegmentedControl *uninstallScopeCtl;
@property (strong) NSPopUpButton *uninstallGroupPopup;
@property NSInteger uninstallScope;
@property (strong) NSButton *uninstallGo;
- (void)unloadLoginAgent;
@property (strong) NSPopover *popover;
@property (strong) NSView *quickGroups;
@property (strong) NSTextField *quickCPU, *quickMem, *quickBat;
@property (strong) NSTextField *batteryLabel, *thermalLabel, *processLabel;
@end

@implementation Controller

- (NSImage *)characterImage:(CGFloat)size {
  NSString *p = [[NSBundle mainBundle] pathForResource:@"menubar" ofType:@"png"];
  NSImage *img = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
  if (!img) {
    p = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    img = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
  }
  if (!img) img = [NSImage imageNamed:NSImageNameApplicationIcon];
  img.size = NSMakeSize(size, size);
  img.template = NO;
  return img;
}

- (NSTextField *)label:(NSString *)s size:(CGFloat)sz bold:(BOOL)b color:(NSColor *)c {
  NSTextField *l = [NSTextField labelWithString:s];
  l.font = b ? [NSFont systemFontOfSize:sz weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:sz];
  if (c) l.textColor = c;
  return l;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
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
  self.statusItem.button.title = @" --%";
  self.statusItem.button.target = self;
  self.statusItem.button.action = @selector(togglePopover:);
  [self buildWindow];
  [self buildPopover];
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) {
    [self deleteGroupNames:@[[NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")]]];
    exit(0);
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
  [self showWindow:nil];
  if (getenv("DOCKLAUNCHERS_CENTER_SECTION")) {
    [self showSection:atoi(getenv("DOCKLAUNCHERS_CENTER_SECTION"))];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_SEARCH")) {
    [self showSection:2];
    self.uninstallSearch.stringValue = [NSString stringWithUTF8String:getenv("DOCKLAUNCHERS_CENTER_SEARCH")];
    [self reloadUninstallData];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_GROUP")) {
    [self showSection:2];
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

- (void)buildWindow {
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,960,660)
                                            styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable)
                                              backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"DockLaunchers 控制台";
  self.window.minSize = NSMakeSize(820, 540);
  self.window.releasedWhenClosed = NO;
  self.window.titlebarAppearsTransparent = YES;
  NSView *root = self.window.contentView;

  // 侧边栏
  NSView *side = [[NSView alloc] initWithFrame:NSMakeRect(0,0,210,660)];
  side.wantsLayer = YES;
  side.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.96 alpha:1.0].CGColor;
  side.autoresizingMask = NSViewHeightSizable;
  [root addSubview:side];
  NSImageView *avatar = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 590, 44, 44)];
  avatar.image = [self characterImage:44];
  [side addSubview:avatar];
  NSTextField *title = [self label:@"DockLaunchers" size:15 bold:YES color:nil];
  title.frame = NSMakeRect(74, 608, 130, 20); [side addSubview:title];
  NSTextField *subtitle = [self label:@"控制台" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  subtitle.frame = NSMakeRect(74, 590, 130, 16); [side addSubview:subtitle];

  NSArray *titles = @[@"实时数据", @"Dock 分组", @"应用卸载", @"设置"];
  NSArray *symbols = @[@"gauge", @"square.grid.2x2", @"trash", @"gearshape"];
  CGFloat y = 540;
  NSMutableArray *btns = [NSMutableArray array];
  for (NSInteger i = 0; i < titles.count; i++) {
    NSButton *b = [NSButton buttonWithTitle:titles[i] target:self action:@selector(sideClicked:)];
    b.tag = i;
    b.frame = NSMakeRect(14, y, 182, 38);
    b.bordered = NO;
    b.alignment = NSTextAlignmentLeft;
    b.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightMedium];
    b.image = [NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:titles[i]];
    b.imagePosition = NSImageLeft;
    b.contentTintColor = [NSColor secondaryLabelColor];
    b.wantsLayer = YES;
    b.layer.cornerRadius = 8;
    [side addSubview:b];
    [btns addObject:b];
    y -= 46;
  }
  self.sideLive = btns[0]; self.sideGroups = btns[1]; self.sideUninstall = btns[2]; self.sideSettings = btns[3];

  NSTextField *ver = [self label:@"v1.0 · 菜单栏常驻" size:10 bold:NO color:[NSColor tertiaryLabelColor]];
  ver.frame = NSMakeRect(20, 20, 170, 16);
  [side addSubview:ver];

  self.content = [[NSView alloc] initWithFrame:NSMakeRect(210, 0, 750, 660)];
  self.content.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
  [root addSubview:self.content];

  [self buildLiveView];
  [self buildGroupsView];
  [self buildUninstallView];
  [self buildSettingsView];
  [self showSection:0];
}

- (void)sideClicked:(NSButton *)b { [self showSection:b.tag]; }

- (void)showSection:(NSInteger)idx {
  self.section = idx;
  for (NSView *v in self.content.subviews) [v removeFromSuperview];
  NSArray *btns = @[self.sideLive, self.sideGroups, self.sideUninstall, self.sideSettings];
  for (NSInteger i = 0; i < btns.count; i++) {
    NSButton *b = btns[i];
    BOOL on = (i == idx);
    b.layer.backgroundColor = on ? [NSColor colorWithCalibratedRed:0.04 green:0.52 blue:1.0 alpha:0.14].CGColor : [NSColor clearColor].CGColor;
    b.contentTintColor = on ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
  }
  NSView *v = @[self.liveView, self.groupsView, self.uninstallView, self.settingsView][idx];
  v.frame = self.content.bounds;
  v.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
  [self.content addSubview:v];
  if (idx == 1) [self refreshGroups];
  if (idx == 2) [self reloadUninstallData];
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
  NSTextField *h = [self label:@"本机实时状态" size:22 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"每 2 秒采样 · 菜单栏同步显示 CPU / 内存" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 400, 18); [v addSubview:sub];
  self.batteryLabel = [self label:@"电池 --" size:12 bold:NO color:nil];
  self.batteryLabel.alignment = NSTextAlignmentRight;
  self.batteryLabel.frame = NSMakeRect(470, 608, 250, 20); [v addSubview:self.batteryLabel];
  self.thermalLabel = [self label:@"热状态 --" size:12 bold:NO color:[NSColor secondaryLabelColor]];
  self.thermalLabel.alignment = NSTextAlignmentRight;
  self.thermalLabel.frame = NSMakeRect(470, 588, 250, 18); [v addSubview:self.thermalLabel];

  NSView *card1 = [self cardAt:NSMakeRect(24, 430, 340, 150)];
  [v addSubview:card1];
  self.cpuLabel = [self label:@"CPU  --" size:18 bold:YES color:nil];
  self.cpuLabel.frame = NSMakeRect(16, 118, 200, 24); [card1 addSubview:self.cpuLabel];
  self.cpuSpark = [[Sparkline alloc] initWithFrame:NSMakeRect(16, 18, 308, 88)];
  self.cpuSpark.lineColor = [NSColor systemBlueColor];
  [card1 addSubview:self.cpuSpark];

  NSView *card2 = [self cardAt:NSMakeRect(384, 430, 340, 150)];
  [v addSubview:card2];
  self.memLabel = [self label:@"内存  --" size:18 bold:YES color:nil];
  self.memLabel.frame = NSMakeRect(16, 118, 200, 24); [card2 addSubview:self.memLabel];
  self.memSpark = [[Sparkline alloc] initWithFrame:NSMakeRect(16, 18, 308, 88)];
  self.memSpark.lineColor = [NSColor systemGreenColor];
  [card2 addSubview:self.memSpark];

  NSView *card3 = [self cardAt:NSMakeRect(24, 300, 340, 110)];
  [v addSubview:card3];
  NSTextField *dl = [self label:@"磁盘" size:12 bold:YES color:nil]; dl.frame = NSMakeRect(16, 84, 100, 18); [card3 addSubview:dl];
  self.diskLabel = [self label:@"已用 --" size:18 bold:NO color:nil]; self.diskLabel.frame = NSMakeRect(16, 44, 300, 24); [card3 addSubview:self.diskLabel];
  NSTextField *dt = [self label:@"系统启动磁盘" size:10 bold:NO color:[NSColor secondaryLabelColor]]; dt.frame = NSMakeRect(16, 20, 260, 16); [card3 addSubview:dt];

  NSView *card4 = [self cardAt:NSMakeRect(384, 300, 340, 110)];
  [v addSubview:card4];
  NSTextField *nl = [self label:@"网络" size:12 bold:YES color:nil]; nl.frame = NSMakeRect(16, 84, 100, 18); [card4 addSubview:nl];
  self.netLabel = [self label:@"↓ --   ↑ --" size:16 bold:NO color:nil]; self.netLabel.frame = NSMakeRect(16, 44, 310, 24); [card4 addSubview:self.netLabel];
  NSTextField *nt = [self label:@"实时上下行速率" size:10 bold:NO color:[NSColor secondaryLabelColor]]; nt.frame = NSMakeRect(16, 20, 260, 16); [card4 addSubview:nt];

  NSView *card5 = [self cardAt:NSMakeRect(24, 120, 700, 165)];
  [v addSubview:card5];
  NSTextField *pt = [self label:@"进程 TOP 5（按 CPU）" size:12 bold:YES color:nil];
  pt.frame = NSMakeRect(16, 136, 300, 18); [card5 addSubview:pt];
  self.processLabel = [self label:@"" size:11.5 bold:NO color:[NSColor labelColor]];
  self.processLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
  self.processLabel.frame = NSMakeRect(16, 14, 670, 118);
  self.processLabel.maximumNumberOfLines = 6;
  [card5 addSubview:self.processLabel];

  self.uptimeLabel = [self label:@"" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  self.uptimeLabel.frame = NSMakeRect(24, 92, 700, 18);
  [v addSubview:self.uptimeLabel];

  NSButton *folder = [NSButton buttonWithTitle:@"打开分组文件夹" target:self action:@selector(openGroupsFolder:)];
  folder.frame = NSMakeRect(24, 42, 160, 32); folder.bezelStyle = NSBezelStyleRounded; [v addSubview:folder];
  NSButton *hide = [NSButton buttonWithTitle:@"隐藏主窗口" target:self action:@selector(hideWindow:)];
  hide.frame = NSMakeRect(196, 42, 140, 32); hide.bezelStyle = NSBezelStyleRounded; [v addSubview:hide];
  self.liveView = v;
}

- (NSView *)cardAt:(NSRect)r {
  NSView *c = [[NSView alloc] initWithFrame:r];
  c.wantsLayer = YES;
  c.layer.backgroundColor = [NSColor whiteColor].CGColor;
  c.layer.cornerRadius = 14;
  c.layer.borderColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1.0].CGColor;
  c.layer.borderWidth = 1;
  return c;
}

- (void)hideWindow:(id)sender { [self.window orderOut:nil]; }
- (void)openGroupsFolder:(id)sender { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:GroupDir()]]; }

// ---------------- Dock 分组 ----------------
- (NSString *)backupBaseDir {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DockLaunchers/backup"];
}
- (NSString *)groupBackupRoot {
  return [[self backupBaseDir] stringByAppendingPathComponent:@"groups"];
}
- (NSString *)deletedManifestPath {
  return [[self backupBaseDir] stringByAppendingPathComponent:@"deleted.plist"];
}

- (NSMutableArray<NSString *> *)deletedGroupNames {
  NSArray *a = [NSArray arrayWithContentsOfFile:[self deletedManifestPath]];
  return a ? [a mutableCopy] : [NSMutableArray array];
}
- (void)saveDeletedGroupNames:(NSArray *)names {
  [[NSFileManager defaultManager] createDirectoryAtPath:[self backupBaseDir] withIntermediateDirectories:YES attributes:nil error:NULL];
  [names writeToFile:[self deletedManifestPath] atomically:YES];
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
  if (!names.count) return;
  [self backupGroupNames:names];
}

- (void)deleteGroupsClicked:(id)sender {
  NSArray *names = [self targetGroupNamesFromSelection];
  if (!names.count) return;
  [self deleteGroupNames:names];
}

- (void)deleteGroupNames:(NSArray<NSString *> *)names {
  if (!getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) {
    NSAlert *bk = [[NSAlert alloc] init];
    bk.icon = [self characterImage:64];
    bk.messageText = @"删除前必须先备份";
    bk.informativeText = [NSString stringWithFormat:@"将先备份 %ld 个分组，然后再执行删除。是否继续？", (long)names.count];
    [bk addButtonWithTitle:@"备份并删除"];
    [bk addButtonWithTitle:@"取消"];
    if ([bk runModal] != NSAlertFirstButtonReturn) return;
  }
  for (NSString *n in names) [self backupGroupNamed:n];
  if (!getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) {
  NSAlert *c = [[NSAlert alloc] init];
  c.icon = [self characterImage:64];
  c.messageText = [NSString stringWithFormat:@"确认删除 %ld 个分组？", (long)names.count];
  c.informativeText = @"只会删除 Dock 分组本身（App 与列表移到废纸篓），不会卸载分组里的应用。5 秒后可点击「是」。";
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
  }

  NSMutableArray *trashPaths = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *apps = [NSMutableArray array];
  for (NSString *n in names) {
    NSString *app = [[GroupDir() stringByAppendingPathComponent:n] stringByAppendingPathExtension:@"app"];
    NSString *list = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"txt"]];
    if ([fm fileExistsAtPath:app]) { [apps addObject:app]; [trashPaths addObject:app]; }
    if ([fm fileExistsAtPath:list]) [trashPaths addObject:list];
    [self removeDockEntry:app];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) {
    for (NSString *n in names) {
      NSString *app = [[GroupDir() stringByAppendingPathComponent:n] stringByAppendingPathExtension:@"app"];
      NSString *list = [[GroupDir() stringByAppendingPathComponent:@"lists"] stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"txt"]];
      [fm trashItemAtURL:[NSURL fileURLWithPath:app] resultingItemURL:nil error:NULL];
      if ([fm fileExistsAtPath:list]) [fm trashItemAtURL:[NSURL fileURLWithPath:list] resultingItemURL:nil error:NULL];
    }
  } else {
    [self runAdminTrashPaths:trashPaths];
  }
  NSMutableArray *deleted = [self deletedGroupNames];
  NSMutableArray *failed = [NSMutableArray array];
  for (NSString *n in names) {
    NSString *app = [[GroupDir() stringByAppendingPathComponent:n] stringByAppendingPathExtension:@"app"];
    if ([fm fileExistsAtPath:app]) { [failed addObject:n]; continue; }
    if (![deleted containsObject:n]) [deleted addObject:n];
  }
  [self saveDeletedGroupNames:deleted];
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];
  if (failed.count && !getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) {
    NSAlert *f = [[NSAlert alloc] init];
    f.icon = [self characterImage:64];
    f.messageText = @"部分分组未删除";
    f.informativeText = [NSString stringWithFormat:@"%@ 删除失败（可能取消了管理员授权），未删除的分组不会进入恢复列表。", [failed componentsJoinedByString:@"、"]];
    [f runModal];
  }
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_DELETE")) fprintf(stderr, "DELETE_TEST remaining=%ld\n", (long)failed.count);
}

- (void)restoreGroupsClicked:(id)sender {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *root = [self groupBackupRoot];
  NSArray *dirs = [fm contentsOfDirectoryAtPath:root error:NULL];
  NSMutableArray *restored = [NSMutableArray array];
  NSMutableArray *deleted = [self deletedGroupNames];
  for (NSString *n in dirs) {
    NSString *appBackup = [[root stringByAppendingPathComponent:n] stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"app"]];
    if (![fm fileExistsAtPath:appBackup]) continue;
    NSString *installed = [[GroupDir() stringByAppendingPathComponent:n] stringByAppendingPathExtension:@"app"];
    if ([fm fileExistsAtPath:installed]) continue;   // 未删除的跳过
    if (![fm copyItemAtPath:appBackup toPath:installed error:NULL]) continue;
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
    [self addDockEntry:installed label:n];
    [deleted removeObject:n];
    [restored addObject:n];
  }
  [self saveDeletedGroupNames:deleted];
  [self killDock];
  [self refreshGroups];
  if (self.popover.isShown) [self rebuildQuickGroups];
  if (getenv("DOCKLAUNCHERS_CENTER_TEST_SILENT")) { fprintf(stderr, "RESTORE_TEST count=%ld\n", (long)restored.count); return; }
  NSAlert *a = [[NSAlert alloc] init];
  a.icon = [self characterImage:64];
  a.messageText = restored.count ? @"恢复完成" : @"没有需要恢复的分组";
  a.informativeText = restored.count ? [NSString stringWithFormat:@"已恢复：%@", [restored componentsJoinedByString:@"、"]] : @"所有备份的分组都已经安装。";
  [a runModal];
}

- (void)buildGroupsView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"Dock 分组" size:22 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"管理已安装的分组；新建/删除会同步 Dock 图标" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 500, 18); [v addSubview:sub];

  NSButton *create = [NSButton buttonWithTitle:@"新建分组…" target:self action:@selector(createGroup:)];
  create.frame = NSMakeRect(24, 540, 120, 32); create.bezelStyle = NSBezelStyleRounded; [v addSubview:create];
  NSButton *refresh = [NSButton buttonWithTitle:@"刷新" target:self action:@selector(refreshGroups)];
  refresh.frame = NSMakeRect(152, 540, 80, 32); refresh.bezelStyle = NSBezelStyleRounded; [v addSubview:refresh];
  NSButton *folder = [NSButton buttonWithTitle:@"打开文件夹" target:self action:@selector(openGroupsFolder:)];
  folder.frame = NSMakeRect(240, 540, 110, 32); folder.bezelStyle = NSBezelStyleRounded; [v addSubview:folder];
  NSButton *backupAll = [NSButton buttonWithTitle:@"一键备份" target:self action:@selector(backupGroupsClicked:)];
  backupAll.frame = NSMakeRect(360, 540, 100, 32); backupAll.bezelStyle = NSBezelStyleRounded; [v addSubview:backupAll];
  NSButton *delAll = [NSButton buttonWithTitle:@"一键删除" target:self action:@selector(deleteGroupsClicked:)];
  delAll.frame = NSMakeRect(468, 540, 100, 32); delAll.bezelStyle = NSBezelStyleRounded; [v addSubview:delAll];
  NSButton *restoreAll = [NSButton buttonWithTitle:@"一键恢复" target:self action:@selector(restoreGroupsClicked:)];
  restoreAll.frame = NSMakeRect(576, 540, 100, 32); restoreAll.bezelStyle = NSBezelStyleRounded; [v addSubview:restoreAll];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 710, 500)];
  sv.hasVerticalScroller = YES;
  sv.drawsBackground = NO;
  self.groupsList = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,690,10)];
  sv.documentView = self.groupsList;
  self.groupsScroll = sv;
  [v addSubview:sv];
  self.groupsView = v;
}

- (void)pruneStaleDockEntries {
  @try {
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!raw) return;
    NSArray *apps = CFBridgingRelease(raw);
    NSMutableArray *keep = [NSMutableArray array];
    BOOL changed = NO;
    NSString *gd = [GroupDir() stringByAppendingString:@"/"];
    for (id item in apps) {
      NSString *u = nil, *bid = nil;
      @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; bid = item[@"tile-data"][@"bundle-identifier"]; } @catch (NSException *e) {}
      NSString *path = [u hasPrefix:@"file://"] ? [[u substringFromIndex:7] stringByRemovingPercentEncoding] : u;
      BOOL missing = (path.length && [path hasPrefix:@"/"] && ![[NSFileManager defaultManager] fileExistsAtPath:path]);
      if (missing && ([path hasPrefix:gd] || [bid hasPrefix:@"com.docklaunchers."])) { changed = YES; continue; }
      [keep addObject:item];
    }
    if (changed) {
      CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)keep, CFSTR("com.apple.dock"));
      CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
      [self killDock];
    }
  } @catch (NSException *e) {}
}

- (void)refreshGroups {
  [self pruneStaleDockEntries];
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
  for (NSView *x in [self.groupsList.subviews copy]) [x removeFromSuperview];
  CGFloat y = 10;
  NSInteger idx = 0;
  for (NSDictionary *g in gs) {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(6, y, 670, 58)];
    row.wantsLayer = YES;
    row.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.975 alpha:1.0].CGColor;
    row.layer.cornerRadius = 10;
    if (!self.selectedGroups) self.selectedGroups = [NSMutableSet set];
    NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleGroupSelection:)];
    cb.frame = NSMakeRect(8, 18, 18, 18);
    cb.tag = idx;
    cb.state = [self.selectedGroups containsObject:g[@"name"]] ? NSControlStateValueOn : NSControlStateValueOff;
    [row addSubview:cb];
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(32, 9, 40, 40)];
    icon.image = [[NSWorkspace sharedWorkspace] iconForFile:g[@"path"]];
    [row addSubview:icon];
    NSTextField *nm = [self label:g[@"display"] size:14 bold:YES color:nil];
    nm.frame = NSMakeRect(84, 30, 240, 18); [row addSubview:nm];
    NSTextField *pt = [self label:g[@"path"] size:10 bold:NO color:[NSColor secondaryLabelColor]];
    pt.frame = NSMakeRect(84, 10, 300, 16); [row addSubview:pt];
    NSButton *open = [NSButton buttonWithTitle:@"打开" target:self action:@selector(openGroupRow:)];
    open.frame = NSMakeRect(406, 14, 62, 30); open.bezelStyle = NSBezelStyleRounded; open.tag = idx;
    [row addSubview:open];
    NSButton *bk = [NSButton buttonWithTitle:@"备份" target:self action:@selector(backupGroupRow:)];
    bk.frame = NSMakeRect(474, 14, 62, 30); bk.bezelStyle = NSBezelStyleRounded; bk.tag = idx;
    [row addSubview:bk];
    NSButton *del = [NSButton buttonWithTitle:@"删除" target:self action:@selector(deleteGroupRow:)];
    del.frame = NSMakeRect(542, 14, 62, 30); del.bezelStyle = NSBezelStyleRounded; del.tag = idx;
    [row addSubview:del];
    [self.groupsList addSubview:row];
    y += 66;
    idx++;
  }
  self.groupsList.frame = NSMakeRect(0,0,690,MAX(y+10,10));
  [self.groupsScroll.contentView scrollToPoint:NSMakePoint(0, 0)];
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

- (void)createGroup:(id)sender {
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"新建分组";
  a.informativeText = @"输入分组名（如 设计）。会复制现有分组作为模板并加入 Dock。";
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
  a.accessoryView = tf;
  [a addButtonWithTitle:@"创建"];
  [a addButtonWithTitle:@"取消"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *name = [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  while ([name hasSuffix:@"组"] && name.length > 1) name = [name substringToIndex:name.length-1];
  if (!name.length) return;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *items = [fm contentsOfDirectoryAtPath:GroupDir() error:NULL];
  NSString *tpl = nil;
  for (NSString *f in items) if ([f hasSuffix:@".app"]) { tpl = [GroupDir() stringByAppendingPathComponent:f]; break; }
  if (!tpl) { NSBeep(); return; }
  NSString *dst = [GroupDir() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
  if ([fm fileExistsAtPath:dst]) {
    NSAlert *e = [[NSAlert alloc] init]; e.messageText = @"同名分组已存在"; [e runModal]; return;
  }
  if (![fm copyItemAtPath:tpl toPath:dst error:NULL]) return;
  NSString *plist = [dst stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:plist] mutableCopy];
  info[@"CFBundleName"] = name;
  info[@"CFBundleDisplayName"] = name;
  info[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.docklaunchers.g%lu", (unsigned long)([[NSDate date] timeIntervalSince1970]*1000)];
  [info writeToFile:plist atomically:YES];
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
}

// ---------------- Dock 条目 ----------------
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
      if (u && [u containsString:enc]) return;
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
      if (u && [u containsString:enc]) continue;
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
- (void)buildUninstallView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"应用卸载" size:22 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];
  NSTextField *sub = [self label:@"扫描本机应用（全部应用）或仅分组内；已排除本程序自身的 Dock 分组应用" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  sub.frame = NSMakeRect(24, 584, 550, 18); [v addSubview:sub];

  self.uninstallScopeCtl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(24, 540, 180, 28)];
  [self.uninstallScopeCtl setSegmentCount:2];
  [self.uninstallScopeCtl setLabel:@"全部应用" forSegment:0];
  [self.uninstallScopeCtl setLabel:@"仅分组内" forSegment:1];
  self.uninstallScopeCtl.selectedSegment = 0;
  self.uninstallScopeCtl.target = self;
  self.uninstallScopeCtl.action = @selector(uninstallScopeChanged:);
  [v addSubview:self.uninstallScopeCtl];
  self.uninstallGroupPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(210, 540, 122, 28) pullsDown:NO];
  self.uninstallGroupPopup.target = self;
  self.uninstallGroupPopup.action = @selector(uninstallGroupChanged:);
  [v addSubview:self.uninstallGroupPopup];
  self.uninstallSearch = [[NSSearchField alloc] initWithFrame:NSMakeRect(340, 540, 196, 28)];
  self.uninstallSearch.placeholderString = @"搜索应用、Bundle ID 或路径";
  self.uninstallSearch.target = self;
  self.uninstallSearch.action = @selector(uninstallFilterChanged:);
  [self.uninstallSearch setContinuous:YES];
  [v addSubview:self.uninstallSearch];
  NSButton *all = [NSButton buttonWithTitle:@"全选" target:self action:@selector(uninstallSelectAll:)];
  all.frame = NSMakeRect(544, 540, 50, 30); all.bezelStyle = NSBezelStyleRounded; [v addSubview:all];
  NSButton *none = [NSButton buttonWithTitle:@"全不选" target:self action:@selector(uninstallSelectNone:)];
  none.frame = NSMakeRect(596, 540, 56, 30); none.bezelStyle = NSBezelStyleRounded; [v addSubview:none];
  NSButton *refresh = [NSButton buttonWithTitle:@"刷新" target:self action:@selector(reloadUninstallData)];
  refresh.frame = NSMakeRect(656, 540, 56, 30); refresh.bezelStyle = NSBezelStyleRounded; [v addSubview:refresh];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 76, 710, 450)];
  sv.hasVerticalScroller = YES;
  sv.drawsBackground = NO;
  self.uninstallTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0,0,710,450)];
  self.uninstallTable.dataSource = self;
  self.uninstallTable.delegate = self;
  self.uninstallTable.rowHeight = 52;
  self.uninstallTable.usesAlternatingRowBackgroundColors = YES;
  NSArray *cols = @[@[@"app", @"应用", @(330)], @[@"group", @"来源", @(120)],
                    @[@"size", @"大小", @(90)], @[@"installed", @"安装日期", @(100)]];
  for (NSArray *c in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1]; col.width = [c[2] doubleValue];
    [self.uninstallTable addTableColumn:col];
  }
  sv.documentView = self.uninstallTable;
  [v addSubview:sv];

  self.uninstallFooter = [self label:@"" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  self.uninstallFooter.frame = NSMakeRect(24, 34, 380, 18);
  [v addSubview:self.uninstallFooter];
  self.uninstallGo = [NSButton buttonWithTitle:@"卸载所选应用" target:self action:@selector(confirmUninstallApps:)];
  self.uninstallGo.frame = NSMakeRect(580, 26, 120, 32); self.uninstallGo.bezelStyle = NSBezelStyleRounded; [v addSubview:self.uninstallGo];
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

- (void)uninstallScopeChanged:(id)sender {
  self.uninstallScope = self.uninstallScopeCtl.selectedSegment;
  self.uninstallGroupPopup.enabled = (self.uninstallScope == 1);
  self.uninstallGroupPopup.alphaValue = (self.uninstallScope == 1) ? 1.0 : 0.45;
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
                                @"installed": attr[NSFileCreationDate] ?: [NSDate date],
                                @"running": @(isRunning),
                                @"target": (targetGroup[p] ? p : p)} mutableCopy];
    [arr addObject:d];
  }
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

- (void)applyUninstallFilter {
  NSString *q = [self.uninstallSearch.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *d in self.uninstallData) {
    if (q.length) {
      NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", d[@"label"], d[@"bid"], d[@"path"]];
      if ([hay rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
    }
    [out addObject:d];
  }
  self.uninstallFiltered = out;
  [self.uninstallTable reloadData];
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

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.uninstallFiltered.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
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
    NSTextField *s = [self label:[df stringFromDate:d[@"installed"]] size:11 bold:NO color:[NSColor secondaryLabelColor]];
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
  NSAlert *c = [[NSAlert alloc] init];
  c.icon = [self characterImage:64];
  c.messageText = [NSString stringWithFormat:@"确认卸载 %ld 个应用？", (long)sel.count];
  c.informativeText = @"将卸载应用本体并清理用户数据，不可恢复。5 秒后可点击「是」。";
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

  NSMutableArray *removals = [NSMutableArray array];
  for (NSDictionary *d in sel) {
    [removals addObject:d[@"path"]];
    for (NSString *dp in [self relatedDataPaths:d]) if (![removals containsObject:dp]) [removals addObject:dp];
  }
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
  for (NSDictionary *d in sel) [targets addObject:d[@"target"]];
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
      if (![targets containsObject:target]) [keep addObject:raw];
    }
    [[keep componentsJoinedByString:@"\n"] writeToFile:listFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  [self reloadUninstallData];
  NSAlert *done = [[NSAlert alloc] init];
  done.icon = [self characterImage:64];
  done.messageText = @"卸载完成";
  NSInteger left = 0;
  for (NSString *p in removals) if ([[NSFileManager defaultManager] fileExistsAtPath:p]) left++;
  done.informativeText = left == 0 ? [NSString stringWithFormat:@"已卸载 %ld 个应用并清理 %ld 项数据，已验证全部清除。", (long)sel.count, (long)removals.count] : [NSString stringWithFormat:@"已卸载 %ld 个应用，检测到 %ld 项残留。", (long)sel.count, (long)left];
  [done runModal];
}

// ---------------- 设置 ----------------
- (void)buildSettingsView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,750,660)];
  NSTextField *h = [self label:@"设置" size:22 bold:YES color:nil];
  h.frame = NSMakeRect(24, 606, 300, 30); [v addSubview:h];

  NSView *card = [self cardAt:NSMakeRect(24, 380, 700, 200)];
  [v addSubview:card];
  self.menuBarCheck = [NSButton checkboxWithTitle:@"在菜单栏显示 CPU / 内存数字" target:self action:@selector(toggleMenuBarText:)];
  self.menuBarCheck.state = [[NSUserDefaults standardUserDefaults] objectForKey:@"centerMenuText"] ? ([[NSUserDefaults standardUserDefaults] boolForKey:@"centerMenuText"] ? NSControlStateValueOn : NSControlStateValueOff) : NSControlStateValueOn;
  self.menuBarCheck.frame = NSMakeRect(20, 150, 400, 24); [card addSubview:self.menuBarCheck];
  NSTextField *il = [self label:@"采样间隔" size:13 bold:NO color:nil];
  il.frame = NSMakeRect(20, 108, 100, 20); [card addSubview:il];
  self.intervalPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, 102, 140, 28) pullsDown:NO];
  [self.intervalPopup addItemsWithTitles:@[@"1 秒", @"2 秒", @"5 秒", @"10 秒"]];
  NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:@"centerInterval"];
  NSArray *secs = @[@1,@2,@5,@10];
  NSInteger sel = [secs indexOfObject:@(saved)];
  [self.intervalPopup selectItemAtIndex:(sel == NSNotFound ? 1 : sel)];
  self.intervalPopup.target = self; self.intervalPopup.action = @selector(intervalChanged:);
  [card addSubview:self.intervalPopup];

  self.loginCheck = [NSButton checkboxWithTitle:@"开机自动启动控制台" target:self action:@selector(toggleLoginItem:)];
  self.loginCheck.state = [[NSFileManager defaultManager] fileExistsAtPath:[self loginPlistPath]] ? NSControlStateValueOn : NSControlStateValueOff;
  self.loginCheck.frame = NSMakeRect(20, 66, 400, 24); [card addSubview:self.loginCheck];

  NSButton *openGrp = [NSButton buttonWithTitle:@"打开分组文件夹" target:self action:@selector(openGroupsFolder:)];
  openGrp.frame = NSMakeRect(24, 300, 160, 34); openGrp.bezelStyle = NSBezelStyleRounded; [v addSubview:openGrp];
  NSButton *quit = [NSButton buttonWithTitle:@"退出控制台" target:self action:@selector(quitApp:)];
  quit.frame = NSMakeRect(196, 300, 140, 34); quit.bezelStyle = NSBezelStyleRounded; [v addSubview:quit];

  NSTextField *about = [self label:@"DockLaunchers 控制台 · 菜单栏常驻\nDock 分组启动器与卸载管理" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  about.frame = NSMakeRect(24, 120, 600, 40); about.maximumNumberOfLines = 2;
  [v addSubview:about];
  self.settingsView = v;
}

- (void)toggleMenuBarText:(id)sender {
  [[NSUserDefaults standardUserDefaults] setBool:(self.menuBarCheck.state == NSControlStateValueOn) forKey:@"centerMenuText"];
  [self sample];
}

- (void)intervalChanged:(id)sender {
  NSArray *secs = @[@1,@2,@5,@10];
  NSInteger s = [secs[self.intervalPopup.indexOfSelectedItem] integerValue];
  self.sampleSeconds = s;
  [[NSUserDefaults standardUserDefaults] setInteger:s forKey:@"centerInterval"];
  [self.timer invalidate];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:s target:self selector:@selector(sample) userInfo:nil repeats:YES];
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
                         @"KeepAlive": @YES};
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
}

- (void)quitApp:(id)sender { [self unloadLoginAgent]; [NSApp terminate:nil]; }

- (void)buildPopover {
  NSPopover *pop = [[NSPopover alloc] init];
  pop.behavior = NSPopoverBehaviorTransient;
  self.popover = pop;
  NSViewController *vc = [[NSViewController alloc] init];
  NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,360,460)];
  vc.view = root;

  NSTextField *title = [self label:@"DockLaunchers" size:15 bold:YES color:nil];
  title.frame = NSMakeRect(16, 424, 200, 20); [root addSubview:title];
  self.quickCPU = [self label:@"CPU --" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  self.quickCPU.frame = NSMakeRect(16, 400, 100, 18); [root addSubview:self.quickCPU];
  self.quickMem = [self label:@"内存 --" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  self.quickMem.frame = NSMakeRect(130, 400, 100, 18); [root addSubview:self.quickMem];
  self.quickBat = [self label:@"电池 --" size:11 bold:NO color:[NSColor secondaryLabelColor]];
  self.quickBat.frame = NSMakeRect(244, 400, 110, 18); [root addSubview:self.quickBat];

  NSTextField *gl = [self label:@"分组快捷启动" size:11 bold:YES color:nil];
  gl.frame = NSMakeRect(16, 372, 200, 18); [root addSubview:gl];
  self.quickGroups = [[NSView alloc] initWithFrame:NSMakeRect(10, 110, 340, 258)];
  [root addSubview:self.quickGroups];

  NSButton *open = [NSButton buttonWithTitle:@"打开控制台" target:self action:@selector(openConsoleFromPopover:)];
  open.frame = NSMakeRect(16, 60, 150, 32); open.bezelStyle = NSBezelStyleRounded; [root addSubview:open];
  NSButton *quit = [NSButton buttonWithTitle:@"退出" target:self action:@selector(quitFromPopover:)];
  quit.frame = NSMakeRect(270, 60, 74, 32); quit.bezelStyle = NSBezelStyleRounded; [root addSubview:quit];

  pop.contentViewController = vc;
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
    b.image = [[NSWorkspace sharedWorkspace] iconForFile:path];
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

- (void)openConsoleFromPopover:(id)sender {
  [self.popover performClose:nil];
  [self showWindow:nil];
}

- (void)quitFromPopover:(id)sender { [self unloadLoginAgent]; [NSApp terminate:nil]; }

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

  self.cpuLabel.stringValue = [NSString stringWithFormat:@"CPU  %.0f%%", cpuPct];
  self.memLabel.stringValue = [NSString stringWithFormat:@"内存  %.0f%%", memPct];
  self.diskLabel.stringValue = [NSString stringWithFormat:@"已用 %.0f%%", diskPct];
  self.netLabel.stringValue = [NSString stringWithFormat:@"↓ %@/s   ↑ %@/s", [self rate:inRate], [self rate:outRate]];
  [self.cpuSpark addValue:cpuPct];
  [self.memSpark addValue:memPct];
  self.uptimeLabel.stringValue = [NSString stringWithFormat:@"系统启动：%@", [self uptimeString]];
  self.batteryLabel.stringValue = [self batteryText];
  self.thermalLabel.stringValue = [self thermalText];
  self.processLabel.stringValue = [self processTopText];
  if (self.popover.isShown) {
    self.quickCPU.stringValue = [NSString stringWithFormat:@"CPU %.0f%%", cpuPct];
    self.quickMem.stringValue = [NSString stringWithFormat:@"内存 %.0f%%", memPct];
    self.quickBat.stringValue = [self batteryText];
  }
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  id mt = [ud objectForKey:@"centerMenuText"];
  BOOL showText = mt ? [mt boolValue] : YES;
  self.statusItem.button.title = showText ? [NSString stringWithFormat:@" %.0f%% · %.0f%%", cpuPct, memPct] : @"";
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
