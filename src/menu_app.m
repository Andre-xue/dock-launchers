#import <Cocoa/Cocoa.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>

static double gPrevCPUBusy = 0, gPrevCPUTotal = 0;
static unsigned long long gPrevNetIn = 0, gPrevNetOut = 0;
static double gLastNetTime = 0;

@interface Sparkline : NSView
@property (strong) NSMutableArray<NSNumber *> *values;
@property (strong) NSColor *lineColor;
@property CGFloat maxValue;
@end

@implementation Sparkline
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) { _values = [NSMutableArray array]; _lineColor = [NSColor systemBlueColor]; _maxValue = 100; }
  return self;
}
- (void)addValue:(double)v {
  [self.values addObject:@(v)];
  while (self.values.count > 60) [self.values removeObjectAtIndex:0];
  [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor colorWithCalibratedWhite:0.96 alpha:1.0] setFill];
  NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
  [bg fill];
  if (self.values.count < 2) return;
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  CGFloat step = w / 59.0;
  NSBezierPath *p = [NSBezierPath bezierPath];
  for (NSInteger i = 0; i < (NSInteger)self.values.count; i++) {
    double v = [self.values[i] doubleValue];
    CGFloat y = MAX(2, MIN(h - 2, h * (v / MAX(self.maxValue, 1.0))));
    NSPoint pt = NSMakePoint(i * step + 2, y);
    if (i == 0) [p moveToPoint:pt]; else [p lineToPoint:pt];
  }
  [self.lineColor setStroke];
  p.lineWidth = 1.6;
  [p stroke];
}
@end

@interface Controller : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover *popover;
@property (strong) NSTimer *timer;
@property (strong) NSTextField *cpuLabel, *memLabel, *diskLabel, *netLabel;
@property (strong) Sparkline *cpuSpark, *memSpark;
@property (strong) NSButton *menuBarCheck;
@property (strong) NSPopUpButton *intervalPopup;
@property NSInteger sampleSeconds;
@end

@implementation Controller

- (NSImage *)statusImage {
  NSString *p = [[NSBundle mainBundle] pathForResource:@"menubar" ofType:@"png"];
  NSImage *img = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
  if (!img) {
    p = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    img = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
  }
  if (!img) img = [NSImage imageWithSystemSymbolName:@"gauge" accessibilityDescription:@"DockLaunchers"];
  img.size = NSMakeSize(18, 18);
  img.template = NO;
  return img;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  self.sampleSeconds = 2;
  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  self.statusItem.button.image = [self statusImage];
  self.statusItem.button.imagePosition = NSImageLeft;
  self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
  self.statusItem.button.title = @" --%";
  self.statusItem.button.target = self;
  self.statusItem.button.action = @selector(togglePopover:);
  [self buildPopover];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:self.sampleSeconds target:self selector:@selector(sample) userInfo:nil repeats:YES];
  [self sample];
  if (getenv("DOCKLAUNCHERS_CENTER_SHOW")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self togglePopover:nil];
    });
  }
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
  NSTextField *l = [NSTextField labelWithString:text];
  l.font = bold ? [NSFont systemFontOfSize:size weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:size];
  return l;
}

- (void)buildPopover {
  NSPopover *pop = [[NSPopover alloc] init];
  pop.behavior = NSPopoverBehaviorTransient;
  self.popover = pop;
  NSViewController *vc = [[NSViewController alloc] init];
  NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,420,520)];
  vc.view = root;

  NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(10, 10, 400, 500)];
  [root addSubview:tabs];

  // ===== 实时数据 =====
  NSTabViewItem *live = [[NSTabViewItem alloc] initWithIdentifier:@"live"];
  live.label = @"实时数据";
  NSView *lv = [[NSView alloc] initWithFrame:NSMakeRect(0,0,390,470)];
  NSTextField *h = [self label:@"本机实时状态" size:17 bold:YES];
  h.frame = NSMakeRect(14, 430, 300, 24); [lv addSubview:h];

  self.cpuLabel = [self label:@"CPU  --" size:15 bold:YES];
  self.cpuLabel.frame = NSMakeRect(14, 392, 360, 20); [lv addSubview:self.cpuLabel];
  self.cpuSpark = [[Sparkline alloc] initWithFrame:NSMakeRect(14, 320, 360, 62)];
  self.cpuSpark.lineColor = [NSColor systemBlueColor];
  [lv addSubview:self.cpuSpark];

  self.memLabel = [self label:@"内存  --" size:15 bold:YES];
  self.memLabel.frame = NSMakeRect(14, 286, 360, 20); [lv addSubview:self.memLabel];
  self.memSpark = [[Sparkline alloc] initWithFrame:NSMakeRect(14, 214, 360, 62)];
  self.memSpark.lineColor = [NSColor systemGreenColor];
  [lv addSubview:self.memSpark];

  self.diskLabel = [self label:@"磁盘  --" size:14 bold:NO];
  self.diskLabel.frame = NSMakeRect(14, 176, 360, 20); [lv addSubview:self.diskLabel];
  self.netLabel = [self label:@"网络  --" size:14 bold:NO];
  self.netLabel.frame = NSMakeRect(14, 150, 360, 20); [lv addSubview:self.netLabel];

  NSButton *openFolder = [NSButton buttonWithTitle:@"打开分组文件夹" target:self action:@selector(openGroupsFolder:)];
  openFolder.frame = NSMakeRect(14, 24, 170, 30);
  openFolder.bezelStyle = NSBezelStyleRounded;
  [lv addSubview:openFolder];
  NSButton *quit = [NSButton buttonWithTitle:@"退出控制台" target:self action:@selector(quitApp:)];
  quit.frame = NSMakeRect(200, 24, 160, 30);
  quit.bezelStyle = NSBezelStyleRounded;
  [lv addSubview:quit];
  live.view = lv;
  [tabs addTabViewItem:live];

  // ===== Dock 分组 =====
  NSTabViewItem *groups = [[NSTabViewItem alloc] initWithIdentifier:@"groups"];
  groups.label = @"Dock 分组";
  NSView *gv = [[NSView alloc] initWithFrame:NSMakeRect(0,0,390,470)];
  NSTextField *gh = [self label:@"Dock 分组" size:17 bold:YES];
  gh.frame = NSMakeRect(14, 430, 300, 24); [gv addSubview:gh];
  NSTextField *gt = [self label:@"点击分组可直接打开；新建/删除请在分组窗口的 🎨 设置中操作。" size:11 bold:NO];
  gt.frame = NSMakeRect(14, 406, 360, 18);
  gt.textColor = [NSColor secondaryLabelColor];
  [gv addSubview:gt];
  CGFloat y = 370;
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DockLaunchers"];
  NSArray *apps = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(localizedCompare:)];
  for (NSString *f in apps) {
    if (![f hasSuffix:@".app"]) continue;
    NSButton *b = [NSButton buttonWithTitle:[f stringByDeletingPathExtension] target:self action:@selector(openGroup:)];
    b.frame = NSMakeRect(14, y, 360, 34);
    b.bezelStyle = NSBezelStyleRounded;
    b.alignment = NSTextAlignmentLeft;
    b.tag = y;
    b.toolTip = [dir stringByAppendingPathComponent:f];
    [gv addSubview:b];
    y -= 40;
    if (y < 30) break;
  }
  groups.view = gv;
  [tabs addTabViewItem:groups];

  // ===== 卸载应用 =====
  NSTabViewItem *uninstall = [[NSTabViewItem alloc] initWithIdentifier:@"uninstall"];
  uninstall.label = @"应用卸载";
  NSView *uv = [[NSView alloc] initWithFrame:NSMakeRect(0,0,390,470)];
  NSTextField *uh = [self label:@"应用卸载" size:17 bold:YES];
  uh.frame = NSMakeRect(14, 430, 300, 24); [uv addSubview:uh];
  NSTextField *ut = [self label:@"应用卸载会清理应用本体、配置、缓存与容器。\n目前入口在任意分组窗口的 🎨 →「应用卸载」中。" size:12 bold:NO];
  ut.frame = NSMakeRect(14, 350, 360, 60);
  ut.textColor = [NSColor secondaryLabelColor];
  [uv addSubview:ut];
  NSButton *openGroupForUninstall = [NSButton buttonWithTitle:@"打开分组并进入应用卸载" target:self action:@selector(openGroupForUninstall:)];
  openGroupForUninstall.frame = NSMakeRect(14, 300, 240, 32);
  openGroupForUninstall.bezelStyle = NSBezelStyleRounded;
  [uv addSubview:openGroupForUninstall];
  uninstall.view = uv;
  [tabs addTabViewItem:uninstall];

  // ===== 设置 =====
  NSTabViewItem *settings = [[NSTabViewItem alloc] initWithIdentifier:@"settings"];
  settings.label = @"设置";
  NSView *sv = [[NSView alloc] initWithFrame:NSMakeRect(0,0,390,470)];
  NSTextField *sh = [self label:@"控制台设置" size:17 bold:YES];
  sh.frame = NSMakeRect(14, 430, 300, 24); [sv addSubview:sh];
  self.menuBarCheck = [NSButton checkboxWithTitle:@"在菜单栏显示 CPU / 内存数字" target:self action:@selector(toggleMenuBarText:)];
  self.menuBarCheck.state = NSControlStateValueOn;
  self.menuBarCheck.frame = NSMakeRect(14, 390, 340, 24);
  [sv addSubview:self.menuBarCheck];
  NSTextField *il = [self label:@"采样间隔" size:13 bold:NO];
  il.frame = NSMakeRect(14, 352, 80, 20); [sv addSubview:il];
  self.intervalPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(100, 346, 120, 28) pullsDown:NO];
  [self.intervalPopup addItemsWithTitles:@[@"1 秒", @"2 秒", @"5 秒", @"10 秒"]];
  [self.intervalPopup selectItemAtIndex:1];
  self.intervalPopup.target = self;
  self.intervalPopup.action = @selector(intervalChanged:);
  [sv addSubview:self.intervalPopup];
  settings.view = sv;
  [tabs addTabViewItem:settings];

  pop.contentViewController = vc;
}

- (void)togglePopover:(id)sender {
  if (self.popover.isShown) { [self.popover performClose:nil]; return; }
  [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
}

- (void)openGroup:(NSButton *)b {
  NSString *path = b.toolTip;
  if (path) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
  [self.popover performClose:nil];
}

- (void)openGroupsFolder:(id)sender {
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DockLaunchers"];
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
}

- (void)openGroupForUninstall:(id)sender {
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DockLaunchers/聊天.app"];
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
  [self.popover performClose:nil];
}

- (void)quitApp:(id)sender { [NSApp terminate:nil]; }

- (void)toggleMenuBarText:(id)sender {
  self.statusItem.button.title = self.menuBarCheck.state == NSControlStateValueOn ? @" --%" : @"";
}

- (void)intervalChanged:(id)sender {
  NSInteger idx = self.intervalPopup.indexOfSelectedItem;
  NSArray *secs = @[@1, @2, @5, @10];
  self.sampleSeconds = [secs[idx] integerValue];
  [self.timer invalidate];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:self.sampleSeconds target:self selector:@selector(sample) userInfo:nil repeats:YES];
}

- (void)sample {
  // CPU
  host_cpu_load_info_data_t cpu;
  mach_msg_type_number_t ccount = HOST_CPU_LOAD_INFO_COUNT;
  double cpuPct = 0;
  if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &ccount) == KERN_SUCCESS) {
    double busy = cpu.cpu_ticks[CPU_STATE_USER] + cpu.cpu_ticks[CPU_STATE_SYSTEM] + cpu.cpu_ticks[CPU_STATE_NICE];
    double total = busy + cpu.cpu_ticks[CPU_STATE_IDLE];
    double db = busy - gPrevCPUBusy, dt = total - gPrevCPUTotal;
    if (dt > 0) cpuPct = MAX(0, MIN(100, db / dt * 100.0));
    gPrevCPUBusy = busy; gPrevCPUTotal = total;
  }
  // Memory
  double memPct = 0; unsigned long long memUsed = 0, memTotal = 0;
  size_t sz = sizeof(memTotal);
  sysctlbyname("hw.memsize", &memTotal, &sz, NULL, 0);
  vm_statistics64_data_t vm;
  mach_msg_type_number_t vcount = HOST_VM_INFO64_COUNT;
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &vcount) == KERN_SUCCESS) {
    unsigned long long page = vm_page_size;
    memUsed = ((unsigned long long)vm.active_count + vm.wire_count + vm.compressor_page_count) * page;
    if (memTotal > 0) memPct = MIN(100.0, (double)memUsed / (double)memTotal * 100.0);
  }
  // Disk
  struct statfs fs;
  double diskPct = 0;
  if (statfs("/", &fs) == 0) {
    unsigned long long total = (unsigned long long)fs.f_blocks * fs.f_bsize;
    unsigned long long avail = (unsigned long long)fs.f_bavail * fs.f_bsize;
    if (total > 0) diskPct = (double)(total - avail) / (double)total * 100.0;
  }
  // Network
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
  double netInRate = 0, netOutRate = 0;
  if (gLastNetTime > 0 && now > gLastNetTime) {
    double dt = now - gLastNetTime;
    netInRate = (inB >= gPrevNetIn ? inB - gPrevNetIn : 0) / dt;
    netOutRate = (outB >= gPrevNetOut ? outB - gPrevNetOut : 0) / dt;
  }
  gPrevNetIn = inB; gPrevNetOut = outB; gLastNetTime = now;

  self.cpuLabel.stringValue = [NSString stringWithFormat:@"CPU  %.0f%%", cpuPct];
  self.memLabel.stringValue = [NSString stringWithFormat:@"内存  %.0f%%", memPct];
  self.diskLabel.stringValue = [NSString stringWithFormat:@"磁盘  已用 %.0f%%", diskPct];
  self.netLabel.stringValue = [NSString stringWithFormat:@"网络  ↓ %@/s   ↑ %@/s", [self fmtRate:netInRate], [self fmtRate:netOutRate]];
  [self.cpuSpark addValue:cpuPct];
  [self.memSpark addValue:memPct];
  if (self.menuBarCheck.state == NSControlStateValueOn) {
    self.statusItem.button.title = [NSString stringWithFormat:@" %.0f%% · %.0f%%", cpuPct, memPct];
  }
}

- (NSString *)fmtRate:(double)bps {
  if (bps < 1024) return [NSString stringWithFormat:@"%.0f B", bps];
  if (bps < 1024*1024) return [NSString stringWithFormat:@"%.1f KB", bps/1024.0];
  return [NSString stringWithFormat:@"%.1f MB", bps/1048576.0];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  if (!self.popover.isShown) [self togglePopover:nil];
  return YES;
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
