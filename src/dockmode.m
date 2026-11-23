// dockmode.m — DockLaunchers 启动器：Dock 单图标 ⇄ 分组图标切换
// 用法: dockmode [--expand | --collapse]
//   无参数（点击启动器图标，仅收起态可见）= 展开全部分组，启动器自身隐藏
//   --collapse: 收起全部分组图标，把自己固定进 Dock（收起态；分组 App 右键「收起分组图标」也走这里）
//   --expand:   展开全部分组图标并隐藏自己（展开态）
//   状态写入 com.docklaunchers.center 的 centerDockLauncherExpanded，控制台据此尊重当前排布
#import <Foundation/Foundation.h>

static NSString *GroupDir(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DockLaunchers.noindex"]; }

// 启动器只在 Dock 里，dockmode 跑完就退出；把自己的 LS 记录注销，避免出现在「应用程序」窗口。
static void UnregisterPathFromLaunchServices(NSString *path) {
  if (!path.length) return;
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
  t.arguments = @[@"-u", path];
  t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
  t.standardError = [NSFileHandle fileHandleWithNullDevice];
  @try { [t launch]; } @catch (NSException *e) {}
}

static NSString *DockURLForPath(NSString *path) {
  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
  NSString *raw = isDir ? [path stringByAppendingString:@"/"] : path;
  NSString *enc = [raw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
  return [NSString stringWithFormat:@"file://%@", enc];
}

static NSString *GroupSuiteName(NSString *name) {
  const char *s = name.UTF8String ?: "";
  uint64_t h = 1469598103934665603ULL;
  while (*s) { h ^= (unsigned char)*s++; h *= 1099511628211ULL; }
  return [NSString stringWithFormat:@"com.docklaunchers.group.%016llx", (unsigned long long)h];
}

static NSString *GroupLabel(NSString *name) {
  NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GroupSuiteName(name)];
  NSString *v = [d stringForKey:@"displayNameOverride"];
  return v.length ? v : name;
}

static NSString *EntryPath(NSString *u) {
  if (![u isKindOfClass:[NSString class]]) return @"";
  NSString *p = u;
  if ([p hasPrefix:@"file://"]) p = [[p substringFromIndex:7] stringByRemovingPercentEncoding] ?: p;
  while ([p hasSuffix:@"/"] && p.length > 1) p = [p substringToIndex:p.length - 1];
  return [p stringByStandardizingPath];
}

static NSMutableArray *DockApps(void) {
  CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
  return raw ? [CFBridgingRelease(raw) mutableCopy] : [NSMutableArray array];
}

static void SaveDockApps(NSArray *apps) {
  CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFPropertyListRef)apps, CFSTR("com.apple.dock"));
  CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  NSTask *k = [[NSTask alloc] init];
  k.launchPath = @"/usr/bin/killall";
  k.arguments = @[@"-KILL", @"Dock"];
  @try { [k launch]; [k waitUntilExit]; } @catch (NSException *e) {}
}

// GroupDir 下分组入口：优先 .dockgroup 文件，旧 .app 仅在没有同名文件时兼容
static NSArray *GroupAppPaths(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  NSArray *files = [fm contentsOfDirectoryAtPath:GroupDir() error:NULL] ?: @[];
  for (NSString *f in files) {
    if (![f.pathExtension.lowercaseString isEqualToString:@"dockgroup"]) continue;
    NSString *key = f.stringByDeletingPathExtension;
    [seen addObject:key];
    [out addObject:[GroupDir() stringByAppendingPathComponent:f]];
  }
  for (NSString *f in files) {
    if (![f.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
    NSString *key = f.stringByDeletingPathExtension;
    if ([seen containsObject:key]) continue;
    NSString *p = [GroupDir() stringByAppendingPathComponent:f];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *bid = info[@"CFBundleIdentifier"] ?: @"";
    if (![bid hasPrefix:@"com.docklaunchers."] || [bid isEqualToString:@"com.docklaunchers.center"] || [bid isEqualToString:@"com.docklaunchers.launcher"]) continue;
    [out addObject:p];
  }
  return [out sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a compare:b]; }];
}

static BOOL DockHasEntry(NSArray *apps, NSString *path) {
  NSString *std = [path stringByStandardizingPath];
  for (id item in apps) {
    NSString *u = nil;
    @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
    if (u && [EntryPath(u) isEqualToString:std]) return YES;
  }
  return NO;
}

static void AddEntry(NSMutableArray *apps, NSString *path, NSString *label, NSString *bid) {
  if (!path.length || DockHasEntry(apps, path)) return;
  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
  NSMutableDictionary *td = [@{@"file-data": @{@"_CFURLString": DockURLForPath(path), @"_CFURLStringType": @15},
                               @"file-label": label ?: @"", @"file-type": @41, @"dock-extra": @NO} mutableCopy];
  if (isDir) td[@"bundle-identifier"] = bid ?: @"";
  [apps addObject:@{@"tile-data": td, @"tile-type": @"file-tile"}];
}

static void RemoveEntry(NSMutableArray *apps, NSString *path) {
  NSString *std = [path stringByStandardizingPath];
  NSMutableArray *keep = [NSMutableArray array];
  for (id item in apps) {
    NSString *u = nil;
    @try { u = item[@"tile-data"][@"file-data"][@"_CFURLString"]; } @catch (NSException *e) {}
    if (u && [EntryPath(u) isEqualToString:std]) continue;
    [keep addObject:item];
  }
  [apps setArray:keep];
}

static void RemoveGroupEntries(NSMutableArray *apps) {
  for (NSString *p in GroupAppPaths()) RemoveEntry(apps, p);
}

static void AddGroupEntries(NSMutableArray *apps) {
  for (NSString *p in GroupAppPaths()) {
    NSString *key = [[p lastPathComponent] stringByDeletingPathExtension];
    if ([p.pathExtension.lowercaseString isEqualToString:@"dockgroup"]) {
      AddEntry(apps, p, GroupLabel(key), @"");
      continue;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *l = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: key;
    AddEntry(apps, p, l, info[@"CFBundleIdentifier"] ?: l);
  }
}

// 展开态标记：YES=分组全排列+启动器隐藏；NO=收起态只留启动器。控制台跨进程读取
static void SetExpanded(BOOL on) {
  CFPreferencesSetAppValue(CFSTR("centerDockLauncherExpanded"), (__bridge CFPropertyListRef)@(on), CFSTR("com.docklaunchers.center"));
  CFPreferencesAppSynchronize(CFSTR("com.docklaunchers.center"));
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"--click";
    NSString *selfPath = [[NSBundle mainBundle] bundlePath] ?: @"";
    UnregisterPathFromLaunchServices(selfPath);
    NSString *label = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"DockLaunchers";
    NSString *bid = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"] ?: @"com.docklaunchers.launcher";
    NSMutableArray *apps = DockApps();
    if ([mode isEqualToString:@"--collapse"]) {
      // 收起：移除全部分组，保留启动器
      RemoveGroupEntries(apps);
      AddEntry(apps, selfPath, label, bid);
      SetExpanded(NO);
    } else if ([mode isEqualToString:@"--expand"]) {
      // 展开态：分组全排列，启动器隐藏
      AddGroupEntries(apps);
      if (selfPath.length) RemoveEntry(apps, selfPath);
      SetExpanded(YES);
    } else {
      // 点击启动器（仅收起态可见）：展开分组，启动器自身也隐藏
      AddGroupEntries(apps);
      if (selfPath.length) RemoveEntry(apps, selfPath);
      SetExpanded(YES);
    }
    SaveDockApps(apps);
    // Dock 重启后会重新登记 wrapper；等 Dock 起来再注销，避免「应用程序」窗口出现启动器图标
    sleep(3);
    UnregisterPathFromLaunchServices(selfPath);
    return 0;
  }
}
