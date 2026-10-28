# Dock 分组启动器（DockLaunchers）

把常用的 App 按场景分组，在程序坞里放一个图标，点开就是一个原生应用列表——工作、聊天、外网、影音、AI、Docker、工具，一组一个图标，支持皮肤、多列布局、自定义图标。

纯原生 Objective-C / AppKit 实现，无 Electron、无 Python、无 Tk，单进程、启动快、关窗即退出。

![分组图标预览](docs/icons-preview.png)

## 特性

- **7 个独立 App**：工作组 / 聊天组 / 外网组 / 影音组 / Ai组 / Docker组 / 工具组，各自维护应用列表
- **原生列表窗口**：图标 + 名称，官方 App 图标（NSWorkspace），固定列对齐
- **＋ / −**：添加应用（NSOpenPanel 选择）、移除选中项（只改列表文件，不动应用本身，带确认弹窗）
- **🎨 皮肤**：纯白 / 纯黑 / 质感玻璃（实时透明度滑杆）/ 自定义图片（可拖动 + 缩放裁剪）
- **多列布局**：默认单列；点绿灯放大自动三列；Option+点绿灯四列居中最大化；也可在 🎨 菜单里切换
- **自定义图标**：右键 Dock 图标 →「更换图标」，人物图等比缩放填入圆角图标，右上角 emoji 角标悬浮保留
- **Spotlight**：⌘Space 搜「工作 / 聊天 / 外网 / 影音 / Ai / Docker / 工具」直接打开对应分组
- **键盘 / 鼠标**：←→↑↓ 选择、Enter 打开、⌫ 移除、Esc 取消；鼠标点击选中、双击打开
- **单实例 + 关窗退出**：同一时间只有一个启动器窗口，关窗即释放内存

## 快速开始

### 方式一：使用发布包（推荐）

1. 下载 `DockLaunchers-portable.zip`（Releases 页面）
2. 解压后双击 `install.command`
   - 提示「无法验证开发者」时：右键 → 打开 → 仍要打开
   - 或终端执行：`bash 路径/DockLaunchers/install.command`
3. 脚本会自动完成：复制到 `~/Applications/DockLaunchers/`、去隔离、ad-hoc 重签、Spotlight 建索引、加入程序坞、重启 Dock

### 方式二：从源码构建

```bash
git clone https://github.com/<你的用户名>/dock-launchers.git
cd dock-launchers
bash build.sh        # 需要 Xcode Command Line Tools
bash install.command
```

## 使用说明

| 操作 | 说明 |
|---|---|
| ＋ | 添加应用到当前分组（写入 `lists/<组名>.txt`） |
| − | 移除选中项（确认后仅删除列表行） |
| 🎨 | 皮肤 / 布局 / 更换图标 / 恢复默认 |
| 红灯 | 关闭并退出 |
| 黄灯 | 最小化到程序坞 |
| 绿灯 | 点击放大（三列）/ Option+点击四列 |
| ⌘Space 搜组名 | Spotlight 直接打开分组 |

分组内容文件：`~/Applications/DockLaunchers/lists/<组名>.txt`，格式 `显示名称|应用名称或完整路径`，`#` 开头为注释。

## 目录结构

```
dock-launchers/
├── src/launcher.m          # 全部 UI / 交互 / 皮肤 / 图标逻辑（单文件原生 ObjC）
├── resources/icons/        # 7 个分组的默认 .icns 图标
├── lists/                  # 默认分组列表
├── build.sh                # 编译通用二进制并打包 7 个 .app
├── install.command         # 安装到 ~/Applications 并加入程序坞
├── tools/bench.sh          # 启动速度 / 内存 / 存储 基准测试
├── docs/icons-preview.png  # 图标预览
└── README.md
```

## 启动速度优化

主要瓶颈不是界面本身（构建窗口约 55–65ms），而是两类「看不见的工作」：**每次启动同步重建自定义图标**、以及把一次性工作放在启动关键路径上。优化点如下。

### 1. 自定义图标不再每次启动同步重建

存储里记录「已应用的图片路径」，并用 `getxattr` 检查 App 包是否仍带自定义图标标记；只有图片变化或图标丢失时才异步重建：

```objc
NSString *savedIcon   = [[NSUserDefaults standardUserDefaults] stringForKey:@"customIconPath"];
NSString *appliedIcon = [[NSUserDefaults standardUserDefaults] stringForKey:@"customIconApplied"];
BOOL bundleHasCustomIcon =
    (getxattr([bundlePath fileSystemRepresentation],
              "com.apple.FinderInfo", NULL, 0, 0, 0) > 0);

if (savedIcon.length > 0 &&
    (![savedIcon isEqualToString:(appliedIcon ?: @"")] || !bundleHasCustomIcon)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [c applyCustomIconAtPath:savedIcon];   // 窗口显示后再做
    });
}
```

> 这一项把启动前段从 **445ms 降到 70–97ms**（见下方数据）。

### 2. 背景层按需创建

默认纯白皮肤不再创建 `NSVisualEffectView` 和图片层，只有选择玻璃 / 自定义图片时才懒创建：

```objc
if (gTheme == 2 && !self.vibrancy) {
    self.vibrancy = [[NSVisualEffectView alloc] initWithFrame:cv.bounds];
    self.vibrancy.material = NSVisualEffectMaterialUnderWindowBackground;
    self.vibrancy.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    [cv addSubview:self.vibrancy positioned:NSWindowBelow relativeTo:nil];
}
```

### 3. 图标异步加载，窗口先出现

窗口和列表先构建，图标按 3 个一批在后续 runloop 补齐：

```objc
- (void)loadIconsFrom:(NSInteger)start {
  NSInteger end = MIN(start + 3, (NSInteger)self.items.count);
  for (NSInteger i = start; i < end; i++) { /* NSWorkspace iconForFile */ }
  if (end < total) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self loadIconsFrom:end]; });
  }
}
```

### 4. 单实例检查移出启动关键路径

原来启动时同步遍历所有运行中的 App，现改为窗口显示 0.6 秒后异步清理其他实例。

### 5. 只在尺寸变化时重建列表

窗口构建阶段只布局一次；`windowDidResize` 才重新计算网格行，避免重复 reload。

## 性能测试数据

测试环境：Apple M1 / 8GB / macOS（通用二进制 arm64 构建），测量通过程序内置的 `DOCKLAUNCHER_BENCH` / `DOCKLAUNCHER_MEM` 钩子读取进程内时间戳与 RSS。

### 启动速度（14 个应用的影音组，5 次）

| 指标 | 优化前 | 优化后 |
|---|---|---|
| 进程启动 → 开始构建界面 | ~445 ms | **70–100 ms** |
| 界面构建（窗口/按钮/列表） | 55–65 ms | 55–85 ms |
| 窗口上屏 | 1–2 ms | 1–2 ms |
| **进程启动 → 窗口可见** | ~500+ ms | **130–200 ms** |
| 加上 Dock / LaunchServices 调度 | — | **约 100 ms** |
| **点图标到看见窗口** | — | **约 0.25 秒** |

### 选中应用 → 应用启动

| 项目 | 耗时 |
|---|---|
| 启动器调用 `open` | **1.5–2 ms** |
| 计算器（小应用） | 约 110 ms |
| 微信 / Chrome / 网易云等大应用 | 1–2 秒（应用自身启动） |

### 内存

| 状态 | RSS |
|---|---|
| 窗口打开（14 个应用） | **约 96 MB** |
| 关闭窗口 / 选完应用后 | **0（进程退出）** |

不常驻后台，无定时任务、无网络请求。

### 存储

| 项目 | 占用 |
|---|---|
| 7 个 App | **12–14 MB**（每个约 1.7–2 MB，含 icns 与通用二进制） |
| 列表文件 | 28 KB |
| 偏好设置（皮肤/图标/列数） | 约 4.5 KB |

### 复现测量

```bash
bash tools/bench.sh
```

## 兼容性

- macOS 12+，Intel 与 Apple Silicon 通用二进制
- 构建需要 Xcode Command Line Tools：`xcode-select --install`

## 已知限制

- **Dock 图标双击**无法被 App 可靠捕获（macOS 不派发该事件），因此换图标入口放在「右键 Dock 图标」和 🎨 菜单里
- 系统绿灯的悬停平铺菜单由 macOS 控制，App 无法改变其显示时长
- 自定义皮肤引用的是图片路径，图片移动/删除后需重新选择
- 皮肤、自定义图标等偏好按机器独立保存，不随安装包迁移

## 素材说明

代码以 MIT 协议开源；`resources/icons` 中的角色图标素材来自项目作者本地使用的角色图，如需商用/再分发请自行确认素材版权，可替换为自己的图片后重新打包。

## License

MIT
