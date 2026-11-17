# 水印工坊 BatchMark · README（工程与装机说明）

> iOS 17+ · SwiftUI · Swift 6（strict concurrency）· 零第三方依赖 · 纯本地不联网 · 中文界面 / 深色优先
> 编译环境：**Mac + Xcode 16**（Windows 仅能查看/编辑源码，无法编译）
> 块C 交付：四页签 UI + 设置/调试面板 + 工程文件（project.pbxproj / Info.plist / Assets）+ 本 README

---

## 一、5 分钟跑起来

1. 把整个 `WatermarkBatch/` 目录（含 `WatermarkBatch.xcodeproj`）拷到 Mac；
2. 双击 `WatermarkBatch.xcodeproj` 用 Xcode 16 打开；
3. TARGETS → WatermarkBatch → Signing & Capabilities：勾选 **Automatically manage signing**，选择你的 Team（个人免费 Apple ID 即可）；
4. 顶部设备栏选你的 iPhone（真机）或任一 iOS 17+ 模拟器 → **Cmd+R**；
5. （可选）**Cmd+U** 运行 `WatermarkBatchTests`：内含源码守卫用例（源码扫描断言「导出链路禁止缩略图解码 / 尺寸上限」，见 `Tests/SourceGuardTests.swift`）。测试 target 由同目录 `project.yml` 声明，挂在共享 scheme `WatermarkBatch` 的 Test 动作上，无需手动添加。

> 真机首次运行：系统会弹相册权限（文案见下），选「允许完全访问」才能批量读取；「仅添加」权限只能写不能读，App 内会有明确引导。

### 工程文件是生成的，不要手改 `project.pbxproj`

`WatermarkBatch.xcodeproj/project.pbxproj` 是**生成物**，唯一真相来源是仓库根目录的 `project.yml`（XcodeGen 描述文件）。

```bash
brew install xcodegen
xcodegen generate            # 覆盖生成 WatermarkBatch.xcodeproj
```

- **加 / 删 / 移动 `.swift` 文件不用改工程**：`sources` 按目录递归收集，重新生成一次即可；
- 改 Bundle ID、部署版本、编译开关：改 `project.yml` 的 `settings`。在 Xcode UI 里改的构建设置下次生成会被覆盖，别在 UI 里改；
- 包内仍附一份**语法校验通过**的 `WatermarkBatch.xcodeproj`，没装 xcodegen 也能直接双击打开；但它随时可能被重新生成覆盖，不作为权威；
- 校验工具：`python3 Tools/verify/validate_pbxproj.py WatermarkBatch.xcodeproj/project.pbxproj`（OpenStep plist 语法 + 悬空 UUID 引用，退出码非 0 即不合法）。CI 在生成后会跑这一条。

> 为什么不用手写：pbxproj 的合法性由 OpenStep plist 语法管（每条 `key = value` 必须 `;` 结尾、裸字符串不得含逗号/括号/中文），而 `xcodebuild` 只有解析成功之后才轮到编译报错——手写期间它一直处在「没有任何检查」的状态。

---

## 二、权限配置（Info.plist 已内置，无需手改）

| 键 | 值 | 用途 |
|---|---|---|
| `NSPhotoLibraryUsageDescription` | 水印工坊需要访问你的相册，用于选取要加水印的照片和视频。所有处理均在你的设备本地完成，不会上传或修改你的原片。 | 读取素材（批量导入必需完全访问） |
| `NSPhotoLibraryAddUsageDescription` | 水印工坊需要将加好水印的照片和视频保存到你的相册。你也可以仅授予添加权限，本功能即可正常使用。 | 写回副本 |
| `BGTaskSchedulerPermittedIdentifiers` | `["com.watermarkbatch.export"]` | BGProcessingTask 后台续跑（块B `BGTaskCoordinator.taskIdentifier` 与此一致，改包名时两处同步） |
| `UIBackgroundModes` | `["processing"]` | 后台处理 |
| `UIUserInterfaceStyle` | `Dark` | 深色优先 |

**不声明任何网络/定位权限**；App 无网络请求（缩略图在 iCloud 未下载时由 PhotoKit 系统行为拉取，属系统进程行为，App 本身零联网代码）。

权限差异须知：**完全访问**才能读取既有相册做批量导入；**仅添加**权限只覆盖「写入」路径，App 内以引导卡片明示该差异，不静默失败。

---

## 三、文件结构

```
WatermarkBatch/
├── WatermarkBatch.xcodeproj/          工程文件（objectVersion 56，Xcode 16 打开）
├── Info.plist                          权限文案 / BGTask / 后台模式
├── README.md                           本文件
├── Assets.xcassets/                    AppIcon（1024 占位图）+ AccentColor
│
├── App/                                块C · 应用层
│   ├── WatermarkBatchApp.swift         @main 入口（环境注入 / 深色 / 中文）
│   ├── RootTabView.swift               四页签 + 轻提示 + 空态 + 权限引导
│   ├── AppModel.swift                  @MainActor @Observable 全局状态
│   ├── BatchController.swift           批量状态机（消费块B BatchQueue / ExportService）
│   ├── ProcessingPolicy.swift          处理策略 UI 外壳（包装块B ProcessingSettings，单一事实源）+ 预估耗时
│   └── NotificationManager.swift       完成本地通知（点按跳记录页 → 相册）
│
├── Models/                             块A · 模型层（WatermarkConfig / LibraryAsset / WatermarkError / 模板仓库）
├── PhotoLibrary/                       块A · PhotoKit 层（权限 / 取数 / 日期分组 / 缩略图缓存 / iCloud 下载 / 相簿写入）
├── Rendering/                          块A · 渲染层（WatermarkCompositor 共享 CIContext+Metal；CoreText 文字层）
│
├── Support/                            块B · 参数与日志（ProcessingSettings 单一事实源 / 批量日志 / 失败清单导出 / 内存监控）
├── Processing/                         块B · 四处理器 + 队列
│   ├── PhotoProcessor.swift            照片/RAW（原编码器写回 + RAW→HEIC 门禁）
│   ├── LivePhotoProcessor.swift        Live Photo（still+MOV 拆解/重配对）
│   ├── AnimatedImageProcessor.swift    GIF/WebP 逐帧（调色板/延时/循环保留）
│   ├── VideoProcessor.swift            AVAssetReader→合成→AVAssetWriter 硬编（音频直通）
│   └── BatchQueue.swift                分槽并发（默认 2 照片/1 视频；速度档 3-4 自适应）
├── Export/                             块B · ExportService（分块 8 个一次 performChanges）+ ExportRecordStore
├── Background/                         块B · BGTaskCoordinator（后台续跑）
│
├── Tests/                              验收测试（挂 WatermarkBatchTests target）
│   ├── SourceGuardTests.swift          源码守卫：导出链路禁用缩略图解码等 5 组断言（Cmd+U 首跑）
│   └── AcceptanceTests.swift           真机四项：Live 可组装 / 动图多帧 / 视频色彩标签 / 音频非 PCM
├── Tools/verify/verify_media.sh        Mac 文件级验收：配对键 / GIF 逐帧延时 / HDR 标签 / 音频 md5 / PSNR-SSIM
│
└── UI/                                 块C · 界面
    ├── Common/UIHelpers.swift          颜色/格式化/内存采样/降采样解码/文本导出
    ├── AlbumPicker/                    Tab1 相册选择（日期分组吸顶 / 混合多选 / 类型角标 / iCloud 进度与重试）
    ├── Editor/                         Tab2 水印编辑（文字 8 参数 / PNG Logo / 九宫格+手势+数值微调 / 平铺 / 模板 / 参数 JSON）
    ├── Preview/                        照片·视频时间轴·Live 双预览位·GIF 帧预览（全部走 compositedFrame 同管线）
    ├── Batch/                          Tab3 批量任务（二次确认+预估耗时 / 逐任务进度 / 取消 / 失败清单导出与重跑）
    ├── Records/                        Tab4 导出记录（批次历史 / 输出容器标签 outputUTI / 失败原因展开 / 跳相册）
    └── Settings/                       设置（策略二选一二次确认 / 跳过已加水印 / PNG 无损 / 日志导出 / 长按标题解锁调试面板）
```

**预览与导出同管线**：预览（含视频逐帧）全部调用 `WatermarkCompositor.compositedFrame(base:config:outputPixelSize:seconds:)`，UI 不自绘水印；pt↔px 一律用 `WatermarkCompositor.pixelsPerPoint(for:) / canvasReferenceWidthPoints(390)`，无第二基准。

---

## 四、已知边界（如实告知，非缺陷即边界）

| # | 边界 | 说明 |
|---|---|---|
| 1 | **RAW/DNG → HEIC** | iOS 无法以原 RAW 格式写回加过水印的版本；RAW 素材经用户显式确认后以 HEIC（最高质量）保存为新副本，原 RAW 文件不变，导出后逐条告知。 |
| 2 | **视频为「视觉无损」，非数学无损** | 目标 PSNR ≥42dB / SSIM ≥0.98（水印区域外逐帧最小值），分辨率/帧率/时长/HDR 色彩/音频直通保持不变；不是逐比特相同的数学无损。 |
| 3 | **HEIC 二次编码轻微损失** | HEIC 源加水印后必须重编码。设置页提供**「输出 PNG 无损」**勾选项（默认**关**，已生效）：开启后 **HEIC/HEIF 静态照片**输出为 PNG（无损、保 alpha、位深不降 16bpc），代价是容器改变、12MP 约 25-35MB/张（HEIC q1.0 约 3-5MB，增大 6-10 倍）、部分 EXIF/GPS 字段可能无法承载（缺失分组写入日志与导出记录），且批次更慢（内存压力下照片并发自动降到 1）。RAW、GIF/WebP、Live Photo 静帧不受该开关影响。 |
| 4 | **GIF/WebP 调色板 ≤256 色** | GIF/WebP 调色板 ≤256 色，叠加水印后必须量化（优先保留原调色板+预留水印色，超限中位切分、关闭抖动），平滑渐变可能出现色带，属格式物理约束；帧数/延时/循环次数/透明区域原样保留。 |
| 5 | **视频预览为降采样合成** | 预览合成长边 ≤1280px（§六.5 允许），导出仍为原分辨率；水印几何为归一化坐标，预览与导出一致。预览静音，导出保留原音轨。 |
| 6 | **仅添加权限** | 只能写、不能读既有相册；批量导入需完全访问，App 内引导卡片明示。 |
| 7 | **模拟器** | BGTaskScheduler 提交在模拟器会失败（正常），仅影响后台续跑，不影响前台批处理。 |
| 8 | **临时文件策略** | 视频与 Live Photo 配对 MOV 的中间产物一律落在 `FileManager.temporaryDirectory`（系统可回收）；写回相册按分块（每块 8 个）`performChanges` 返回后**立即清理成功项**，失败项保留到用户放弃重试，并由启动时陈旧文件清扫（`ProcessingTempFile.sweepStaleFiles`，>1h 未处理）兜底回收，不会无限堆积。块C 不再额外调 `cleanupTemporaryFiles`，避免两处都以为对方负责。 |

---

## 五、默认参数表（画质优先档 = 出厂默认，全部常量）

> 单一事实源：`Support/ProcessingSettings.swift`（块B）。UI 展示值经 `App/ProcessingPolicy.swift` 从同一份常量派生，**不存在「UI 显示 1.0 而代码写 0.95」的第二套口径**。

| 参数 | 画质优先（默认） | 优先速度（默认关，切换需二次确认） |
|---|---|---|
| 视频码率 | max(源码率 × **1.3**, 平台推荐值) | max(源码率 × **1.0**, 平台推荐值) |
| JPEG 质量 | **1.0** | **0.95** |
| HEIC 质量 | **1.0**（两档恒同，位深红线） | **1.0** |
| PNG（仅「输出 PNG 无损」开启时的 HEIC/HEIF 源） | 无损保 alpha、位深不降 | 同左 |
| 照片并发 | **2** | **3**（物理内存 ≤4GB）/ **4**（>4GB） |
| 视频并发 | **1**（同一时刻最多一条视频在编码） | **1** |
| 内存策略 | 峰值目标 <200MB；超限**降并发不降画质** | 同左 |
| 缩放 | 一律不缩放像素尺寸（`allowsDownscaling = false` 写死） | 同左 |
| 音频 | passthrough 直通不重编码 | 同左 |
| 安全区吸附阈值 | 0.03（`WatermarkConfig.safeMarginNormalized`） | 同左 |
| 平铺 | 关（间距 0.5 × 水印长边，倾角 -30°） | 同左 |
| 默认文字水印 | PingFangSC-Semibold 24pt 白 #FFFFFF | 同左 |

---

## 六、性能实测数据表（Mac + Xcode 16 + iPhone 12 真机实测后填写）

> **口径（v1.1 最高裁决）**：「优先速度」档为发布门禁（30 张 ≤8s 等）；**默认画质优先档如实实测**，
> 预期区间：**30 张 10-12s / 1080p30 60s 视频 30-40s / 4K30 60s 视频 60-80s**。
> 实测达不到预期区间时**如实填写实测值并上报风险，禁止改目标值凑数**。每项 5 轮取中位数。

| 指标 | 门禁值（优先速度档） | 保守档预期（默认画质优先） | 实测（速度档） | 实测（默认档） | 机型/iOS |
|---|---|---|---|---|---|
| 30 × 4000×3000 JPEG 端到端 | ≤8.0s | 10-12s | 待测 | 待测 | 待测 |
| 1min 1080p30 视频导出 | ≤30s | 30-40s | 待测 | 待测 | 待测 |
| 1min 4K30 视频导出 | ≤60s | 60-80s | 待测 | 待测 | 待测 |
| 4K 批量内存峰值 | <250MB | <200MB（超限降并发不降画质） | 待测 | 待测 | 待测 |
| 预览拖动帧率 | ≥55fps | 同左 | 待测 | 待测 | 待测 |
| 点水印到画面（P95） | <100ms | 同左 | 待测 | 待测 | 待测 |
| 冷启动 | ≤3s | 同左 | 待测 | 待测 | 待测 |
| 视觉无损 PSNR（水印区外，逐帧最小） | ≥42dB | 同左 | 待测 | 待测 | 待测 |
| 视觉无损 SSIM（同上） | ≥0.98 | 同左 | 待测 | 待测 | 待测 |
| 音频 passthrough（原/新 md5） | 一致 | 同左 | 待测 | 待测 | 待测 |

App 内置的「隐藏调试面板」（设置页**长按标题 2 秒**解锁）提供：单任务耗时（平均/最长）、批量总耗时、内存峰值、视频编码参数（码率系数/编码器/profile 口径）、当前并发数，可截图对照本表。

---

## 七、与块B 的对齐点（当前状态）

1. **「输出 PNG 无损」开关**：字段由块C 扩展 `ProcessingSettings.outputLosslessPNG`（UserDefaults 持久化）承载，**已生效**——块B `Processing/PhotoProcessor.swift` 消费该字段（仅 heic/heif 静态照片改 `public.png`，10bit 拓宽 16bpc；RAW 仍 HEIC，Live Photo 静帧不变）。代价见设置页文案与 §四 边界 3（容器改变、体积增大 6-10 倍、部分 EXIF/GPS 可能无法承载），默认关。
   - 导出记录页每条记录右侧展示块B 写入的 `ExportRecord.outputUTI`（`public.png` → 「PNG（无损）」、`public.heic` → 「HEIC」、`public.jpeg` → 「JPEG」、其余显示 UTI 末段、nil 留空），并在有 `outputNote` 时原样展示 PNG 取舍说明。块C 只显示，不推导容器。
2. 处理器构造：块C `ProcessorFactory.make(for:policy:rawConsent:)` 委托块B `AssetProcessorFactory.processor(for:settings:)`，与后台续跑同路径；BatchQueue 与处理器收到同一份 `ProcessingSettings.withRawConsent(...)`。
3. 其余契约调用（`BatchQueue.run/cancel/outputs`、`ExportService.saveToLibrary`、`BatchProgress` 字段）均已按块B 落盘实现核对一致。

> 若后续新增/改名 Swift 文件：直接在 Xcode 里把文件拖入对应 Group 即可（工程为显式文件引用，不会自动收录新文件）。

---

## 八、签名与装机（个人自用，不上架）

### 方案 A：免费 Apple ID（7 天有效，推荐开发验证期）

**前置**：任意 Apple ID、Mac + Xcode 16、USB 线、iPhone。

1. iPhone USB 连 Mac，手机上点「信任此电脑」；
2. Xcode → TARGETS → Signing & Capabilities → Team 选你的 Apple ID（Personal Team）→ 自动管理签名；Bundle Identifier 保持 `com.watermarkbatch`（首次会自动注册 App ID）；
3. Xcode 顶部设备栏选你的 iPhone → **Cmd+R** → 自动生成 7 天描述文件并安装；
4. 首次启动：设置 → 隐私与安全性 → 已验证（若提示未受信任的开发者，去设置信任）；
5. **7 天到期**：图标还在，点开提示「无法验证」/闪退——**这是正常现象，不是故障**。重连 Mac 再按一次 Cmd+R（覆盖安装）即恢复；模板与导出记录**不会丢**（数据在 App 沙盒 Documents，覆盖安装只替换二进制）。

免费账号三条硬限制：最多注册 10 个 App ID / 7 天；同账号最多 3 个自签 App 在装机名单；签名仅对登录该 Apple ID 的设备有效。

### 方案 B：付费个人开发者账号（1 年有效）

1. Xcode → Signing & Capabilities → Team 选付费 Team（不再是 Personal Team）→ 自动管理签名；
2. 日常：**Cmd+R 直装**，开发签名同样 1 年有效，最省事；
3. 归档分发（给多台设备装）：Product → Archive → Organizer → Distribute App → Custom → **Ad Hoc**（勾选包含你设备 UDID 的 profile）→ 导出 `.ipa`；
4. 安装 `.ipa`：Mac 端 Apple Configurator 2 / iMazing 拖入，或走下文 Windows 路径。

### Windows 侧载（只有 `.ipa`，无 Mac）：Sideloadly / AltStore

**Sideloadly（推荐，免费/付费均可）**

1. 下载安装 Sideloadly（sideloadly.io，Windows 版），安装 iTunes 相关驱动（官方指引）；
2. iPhone USB 连电脑，解锁并信任；
3. 把 `.ipa` 拖入 Sideloadly → 登录 Apple ID：免费账号自动申请 7 天描述文件重签；付费账号可走 Advanced 导入 `.p12` 证书 + `.mobileprovision`（1 年有效）；
4. Advanced 里可改 Bundle Identifier（见下方纪律）；
5. 开始 → 完成后 iPhone 上 设置 → 通用 → VPN 与设备管理 → 信任对应证书；
6. **免费账号每周维护**：到期重复第 3-5 步（同 Bundle ID 覆盖安装，数据保留，约 2 分钟）。

**AltStore（免费签名自动续命）**

1. Windows 装 AltServer 并设为开机自启，登录 Apple ID；
2. iPhone USB 连接 → 托盘 AltServer → Install AltStore → 选你的 iPhone（AltStore 本身占用免费 3 App 限额之一）；
3. 侧载水印工坊：「文件」App 中找到 `.ipa` → 分享 → 用 AltStore 打开 → 安装；
4. iPhone 与 Windows 同一 Wi-Fi 且 AltServer 运行时，**7 天有效期后台自动续签，无感维持**；付费账号侧载有效期 1 年。

### Bundle ID 纪律

- **可随意改**（个人自用不上架）：`com.local.watermark`、`com.watermarkbatch` 等均合法；
- **权限文案不需要重配**：四个 Info.plist 键是打包进 App 的静态文案，与 Bundle ID 零耦合，改包名后原样生效；
- 但换 Bundle ID 后 iOS 视为**全新 App**：相册权限重新弹窗、沙盒数据为空（旧数据不可见）；
- 联动项（建议）：改包名时把 `BGTaskSchedulerPermittedIdentifiers` 从 `com.watermarkbatch.export` 同步改为 `<新包名>.export`（非强绑定，仅为一致）；
- **一旦产生真实使用数据（模板/导出记录），不要再改 Bundle ID**。

### 签名过期 FAQ

- 图标在、点开闪退/提示「无法验证」→ 签名过期，**正常现象**；任一方式重签覆盖安装（Xcode Cmd+R / Sideloadly / AltStore 自动刷新）即可，2-5 分钟；
- 数据（模板、导出记录、设置）存在 App 沙盒 Documents/UserDefaults，**覆盖安装不丢**；换 Bundle ID 才会视为新 App 数据不可见。

---

## 九、验收提醒（Mac 落地后）

- 按《04-测试保障方案》跑 TC-AC-001~010 + 异常流 TC-EX-001~012；
- 权限文案与 PRD §7.1 逐字一致（已在 Info.plist 固化）；
- 性能表（§六）实测后回填，禁止改目标值；
- 本工程所有 Swift 代码在 Windows 环境产出、**未经编译验证**（状态：代码侧待编译）。首编译如有类型/并发标注错误属预期，按 Xcode 报错逐条修复即可（架构与契约已按 Swift 6 strict concurrency 书写）。

### 四项真机验收：现成脚本，直接跑

> 以下命令均在**仓库根**执行（与 `WatermarkBatch.xcodeproj` 同级，不是 `WatermarkBatch/` 源码目录里）。

**① 源码守卫（模拟器即可，第一条要绿的测试）**
```bash
xcodebuild test -project WatermarkBatch.xcodeproj -scheme WatermarkBatch \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:WatermarkBatchTests/SourceGuardTests
```

**② 设备级四项（要真机 + 相册里已有一批导出结果）**
```bash
# 带闸门跑（推荐）：SKIPPED≠0 或 VERIFIED=0 直接判未通过
bash Tools/verify/acceptance_gate.sh <设备UDID>
bash Tools/verify/acceptance_gate.sh --all <设备UDID>     # 连守卫测试与限流器单测一起
bash Tools/verify/acceptance_gate.sh --log run.log        # 离线复判已有日志

# 不用闸门时至少看这一行输出
xcodebuild test -project WatermarkBatch.xcodeproj -scheme WatermarkBatch \
  -destination "platform=iOS,id=<设备UDID>" \
  -only-testing:WatermarkBatchTests/AcceptanceTests
```
- `testLivePhotoIsPlayable`：用 `PHLivePhoto.request` 问系统要 Live Photo，断言非降级 + 有配对视频（= 长按会播放）；
- `testAnimatedExportIsStillAnimated`：断言导出后仍多帧、逐帧延时非零、每帧可解；
- `testVideoColorTagsAndAudioTrack`：打印色彩标签/位深/旋转矩阵，断言音频轨不是 PCM（PCM 即被重编码）。
- **跳过不算通过**：每个用例结束都会打 `[Acceptance] <测试名> SKIPPED=0 VERIFIED=n`；闸门脚本按这行 + xcodebuild 的 passed/failed/skipped 统计，打印 `[GATE] SKIPPED=N PASSED=M FAILED=K`，SKIPPED≠0 就退出 1。相册里没有对应素材时会 SKIP——那不是通过，是「没验」。

**③ 文件级四项（Mac，需 `brew install ffmpeg exiftool`，GIF 精确延时另需 `pip install pillow`）**
```bash
cd WatermarkBatch/Tools/verify

# 0. 先反向自测：造已知不合格样本，确认脚本会红（不跑这步，后面的 PASS 不算数）
bash selftest_verify_media.sh      # 期望「自测通过」，退出码 0

# Live Photo 配对键：静帧 MakerApple key17 必须等于 MOV content identifier
bash verify_media.sh live  ~/Desktop/out.HEIC ~/Desktop/out.MOV

# GIF 帧数 / 逐帧延时 / 循环次数 / 透明色
bash verify_media.sh gif   ~/Desktop/orig.gif ~/Desktop/out.gif

# 4K HDR：codec/profile/pix_fmt/color_primaries/transfer/matrix/位深 + 音频 md5 逐字节一致
bash verify_media.sh video ~/Desktop/orig.mov ~/Desktop/out.mov --factor 1.3

# 画质定量（裁掉水印区域后应 ≥42dB / 0.98）
bash verify_media.sh psnr  ~/Desktop/orig.mov ~/Desktop/out.mov --crop 3840:1620:0:0
```
批量：写一份 TSV（`类型<TAB>原文件<TAB>导出文件`，类型取 live/gif/video/psnr），`bash verify_media.sh all manifest.tsv`。

脚本判定是 PASS/FAIL/WARN 三档并给退出码（0 全过 / 1 有失败），输出里每条都带「为什么这条重要」，不静默跳过。
