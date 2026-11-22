// dockmode.m — DockLaunchers 启动器：Dock 单图标 ⇄ 分组图标切换
// 用法: dockmode [--expand | --collapse]
//   无参数（双击启动器 App）= 展开：把 ~/Applications/DockLaunchers 下的分组 App 固定进 Dock，自己从 Dock 消失
//   --collapse: 收起全部分组图标，把自己固定进 Dock（控制台「Dock 外观」开关调用）
#import <Foundation/Foundation.h>

static NSString *GroupDir(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DockLaunchers"]; }

static NSString *DockURLForPath(NSString *path) {
  NSString *enc = [[path stringByAppendingString:@"/"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
  return [NSString stringWithFormat:@"file://%@", enc];
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

// GroupDir 下全部有效分组 App（bundle id 前缀 com.docklaunchers.，排除控制台本体），按路径排序保证顺序稳定
static NSArray *GroupAppPaths(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *f in ([fm contentsOfDirectoryAtPath:GroupDir() error:NULL] ?: @[])) {
    if (![f hasSuffix:@".app"]) continue;
    NSString *p = [GroupDir() stringByAppendingPathComponent:f];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
    NSString *bid = info[@"CFBundleIdentifier"] ?: @"";
    if (![bid hasPrefix:@"com.docklaunchers."] || [bid isEqualToString:@"com.docklaunchers.center"]) continue;
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
  [apps addObject:@{@"tile-data": @{@"file-data": @{@"_CFURLString": DockURLForPath(path), @"_CFURLStringType": @15},
                                                    @"file-label": label ?: @"", @"file-type": @41,
                                                    @"bundle-identifier": bid ?: @"", @"dock-extra": @NO},
                    @"tile-type": @"file-tile"}];
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

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"--expand";
    NSString *selfPath = [[NSBundle mainBundle] bundlePath] ?: @"";
    NSString *label = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"DockLaunchers";
    NSString *bid = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"] ?: @"com.docklaunchers.launcher";
    NSMutableArray *apps = DockApps();
    if ([mode isEqualToString:@"--collapse"]) {
      RemoveGroupEntries(apps);
      AddEntry(apps, selfPath, label, bid);
    } else {
      for (NSString *p in GroupAppPaths()) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]] ?: @{};
        NSString *l = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: [[p lastPathComponent] stringByDeletingPathExtension];
        AddEntry(apps, p, l, info[@"CFBundleIdentifier"] ?: l);
      }
      if (selfPath.length) RemoveEntry(apps, selfPath);
    }
    SaveDockApps(apps);
    return 0;
  }
}
