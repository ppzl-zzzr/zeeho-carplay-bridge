# 任务检查点
- 状态：暂停中（额度用尽，预约 2026-11-10 15:03 自动恢复）
- 恢复后第一件事：用户新要求（完全授权）——在 Chrome 打开高德开放平台 https://console.amap.com/dev/key/app ，用户负责登录，我负责创建应用和 iOS Key（平台选 iOS，Bundle ID 填 com.zeeho.bridge），拿到 Key 写进 iOS 工程（不要提交到公开仓库：仓库已公开，Key 放 ios/Secrets.xcconfig 并加入 .gitignore，CI 用环境变量注入）。注意：上次 Chrome 扩展未连接，若仍连不上就提示用户安装/登录 Claude in Chrome 扩展
- 其次：等用户 Codemagic 注册+API token；DashRenderer 按 mockup v3（高级车机感）重写；v1.1 媒体卡（尝试私有 MediaRemote）
- 更新时间：2026-11-10 13:55
- 会话 id：（未记录）
- 预约恢复：无

## 原始任务
用户要自己的 iOS App（用户设计、我实现、用户自签名安装，无 Mac）：
1. 仪表界面：悬浮车速/地图/媒体/天气/时间，投屏到极核仪表（MotoPlay/Carbit PXC，WiFi 直连）。
2. 把 Zeeho Unlocker（https://lswlc33.github.io/zeeho-3d-models/ ）做成 iOS 版嵌进 App，车况进仪表界面。

## 已完成
- [x] Android 版 dashlink + app（未编译，本机无 JDK）
- [x] iOS v1：ios/project.yml、ios/ZeehoBridge/{App,DashLink,Video,VehiclePanel}.swift
  - 仪表页：预览 + 投屏 + 设置 + 日志；车辆页：WKWebView 加载 Unlocker，注入只读 hook 把 zeehoev.com 响应转给 VehicleStore（字段 bmssoc/hmiRidableMile/whetherChargeState）
  - 投屏：Network.framework 监听 10920-22，探测 :10930，VideoToolbox Baseline，CPU 渲染 24fps
- [x] .github/workflows/ios.yml：macos-15 + XcodeGen + xcodebuild -target，产出未签名 IPA 和 build-log
- [x] README 更新

## 进展（13:50 后）
- [x] GitHub 已登录（GCM，账号 ppzl-zzzr），私有仓库 ppzl-zzzr/zeeho-carplay-bridge 已推送 main
- [!] 首次 Actions 运行 42763985676 = startup_failure（0 个 job，workflow 文件本身合法）→ 疑似私有仓库计费/账号限制，等用户决定改公开或去网页看原因
- [x] 效果图 docs/dash-mockup.html（导航卡、悬浮车速、时间天气、电量卡、媒体卡；玻璃模糊+边缘羽化）
- 用户新需求 v1.1：媒体卡片要显示任何 App 正在播放的内容（酷狗/网易云/抖音）。iOS 公开 API 做不到；计划试私有 MediaRemote（自签名可尝试，不保证）
- CI 等待脚本：scratchpad 里的 waitci.sh（参数：commit sha、输出目录）

- [x] 已恢复 Git 证书校验：删除 ~/.gitconfig 的 http.sslverify=false（备份在 scratchpad/gitconfig.bak），经 127.0.0.1:7890 代理访问 GitHub 正常
- [!] 私有仓库再次 workflow_dispatch 仍 startup_failure（run 42764375580）；改公开被自动审核拦下，需用户明确同意
- 用户告知：仪表分辨率 2048×960（以仪表握手上报为准；Baseline AutoLevel 可覆盖；CPU 绘制 2048×960 可能偏重，必要时内部降采样）

- [x] 用户同意，仓库已改为公开；run 42764550144 失败，注解原文：“The job was not started because your account is locked due to a billing issue.” → GitHub 账号因计费问题被锁，公开/私有都跑不了，需用户去 https://github.com/settings/billing 处理；备选 Codemagic（用户自己注册，免费 macOS 分钟）

- [x] 改用 Codemagic：codemagic.yaml 已推送（workflow ios-unsigned，push main 触发，产物 ios/ZeehoBridge-unsigned.ipa + ios/build.log）。等用户在 codemagic.io 用 GitHub 登录并添加仓库；要读编译日志需用户提供 Codemagic API token
- [x] 设计风格以用户上一版为准（截图：横屏，ZEEHO 斜体 logo + 车型「AE6 ULTRA」，顶部居中时间日期，左侧超大车速+km/h+青色短线标签，左下行程/时长/均速/最高，右侧无框悬浮媒体（标题「媒体」+封面+大字歌名），地图标路名，中间圆形箭头定位标，强调色青 #5fd3e8）；docs/dash-mockup.html 已按此重做（2048×960 比例）。仪表画面只放信息，按钮留在手机
- 用户反馈“仍不好看”：问题=地图太假太平、整体没质感；选定方向=高级车机感（特斯拉/小米 SU7 类）
- [x] docs/dash-mockup.html 第三版：高德瓦片暗色处理（invert+hue-rotate）+ 3D 倾斜（rotateX 58°）、青色发光路线、圆形车标光晕、细字重渐变大车速、驾驶模式、ETA、玻璃导航卡、封面取色模糊媒体卡。等用户确认
- App 实现方向：高德 iOS 地图 SDK（MAMapView 自定义暗色样式 + 3D 俯仰 cameraDegree）离屏截图作底图，或 MapKit 暗色 3D（无需 key）先顶上；悬浮层用 CoreGraphics 画
- 下一步要把 Video.swift 的 DashRenderer 改成这个布局

## 下一步（从这里继续）
1. 解决 Actions startup_failure → 看 Actions 结果；编译错误按 build-log 修
2. Sideloadly 安装，实车测：CLIENT_INFO、画布尺寸、出画面、锁屏表现
3. v1.1：实现 ZeehoShell 原生接口（store*/insets/setDark/setWidgetStats/GPS），接高德地图（AMap iOS SDK，需 key），媒体卡片（systemMusicPlayer）

## 注意事项
- Swift 代码未经编译器验证（本地无 Mac），首次 CI 很可能有小错误
- 握手包名默认 com.cfmoto（极核官方 App）
- Unlocker 网页由 App 远程加载，未打包进 App
