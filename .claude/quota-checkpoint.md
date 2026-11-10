# 任务检查点
- 状态：进行中（15:03 已恢复）
- [x] 高德 iOS Key 已创建（应用 ZEEHO Dashboard，Key 名 ZeehoBridge-iOS，Bundle ID com.zeeho.bridge），保存在 ios/Secrets.xcconfig（已 gitignore，未提交）
- [x] DashRenderer.swift 新版（高级车机风格）+ MapBackdrop.swift（MapKit 暗色 3D 快照铺底，无需 Key）；旧渲染器改名 LegacyDashRenderer；LocationService 增加 lastLocation；已推送 746c16d
- quota-guard 停止线已按用户要求改为剩 2%（~/.claude/quota-guard/config.json）
- 恢复后第一件事改为：等 Codemagic（用户注册+API token）→ 编译修错；然后接高德 SDK（Key 已有，CI 里用环境变量 AMAP_IOS_KEY 注入）、媒体卡私有 MediaRemote 试验
- [x] Codemagic 应用已添加（appId 6af2b483be978b0d13be98c3）；API token 存在 ~/.zeeho-bridge/codemagic_token（appId 在 codemagic_app）；首次编译 buildId 6af2b4a00c41a3c63ce2bd04 已启动
  - 查状态：curl -H "x-auth-token: $(cat ~/.zeeho-bridge/codemagic_token)" https://api.codemagic.io/builds/<buildId>（看 build.status 与 buildActions[].logUrl / artefacts）
  - 下一步：读编译结果，按错误修 Swift 代码 → push 自动触发 → 拿 IPA 下载链接给用户
- （已完成，保留记录）原第一件事：用户新要求（完全授权）——在 Chrome 打开高德开放平台 https://console.amap.com/dev/key/app ，用户负责登录，我负责创建应用和 iOS Key（平台选 iOS，Bundle ID 填 com.zeeho.bridge），拿到 Key 写进 iOS 工程（不要提交到公开仓库：仓库已公开，Key 放 ios/Secrets.xcconfig 并加入 .gitignore，CI 用环境变量注入）。注意：上次 Chrome 扩展未连接，若仍连不上就提示用户安装/登录 Claude in Chrome 扩展
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

## 15:03 恢复后进展
- [x] 首次 Codemagic 编译成功（746c16d），IPA 在 dist/ZeehoBridge-unsigned.ipa（dist/ 已 gitignore）
- [x] mockup v4：三套字体 + 大号媒体卡/歌词
- [x] 代码：Fonts/（Barlow/Saira/Rajdhani，OFL）+ UIAppFonts；NowPlaying.swift（MediaRemote dlopen + Apple Music 兜底 + CoverTint）；Lyrics.swift（LRCLIB → 网易云）；DashRenderer 重写（DashFont 可切换、行程栏、大号媒体卡：模糊地图+封面染色+羽化遮罩+歌词滚动）；MapBackdrop 增加模糊版；LocationService 增加 trip；App 字体切换
- [x] 第二次编译成功（179f037），IPA 717KB 含 6 个字体
- [x] 演示模式 Demo.swift（-demo 启动参数：假车速/电量/播放/歌词，导出 2048×960 PNG）+ Codemagic 工作流 ios-screenshot（模拟器运行导出截图）
  - 触发脚本：python -I ~/.zeeho-bridge/cmrun.py <workflowId> <输出目录>（ios-unsigned 出 IPA，ios-screenshot 出截图）；push 不会自动触发，需用 API
  - 第一轮截图：渲染正常，但导出时地图未就绪（黑底）；手机预览里 MapKit 暗色 3D 地图已正常（模拟器英文路名）→ 已改为等地图就绪再导出，正在重跑
  - 第三轮截图（commit 隐藏 POI/加强模糊羽化/中文 locale）效果良好，已用 SendUserFile 发给用户三套字体截图（dist/shots/ios/shots/）；等用户选字体和反馈
  - 已用最新代码重编 IPA（724KB）→ dist/ZeehoBridge-unsigned.ipa
  - 用户选定字体 A Barlow（本来就是默认值 0，无需改代码）
  - 用户嫌“太素”→ docs/speed-styles.html 四种车速样式，用户选 C 速度弧线；已实现 speedGauge（270° 弧、青→紫渐变+发光、刻度、0/120、Barlow-ExtraBoldItalic 数字；电量/行程数字 Barlow-SemiBoldItalic），截图已发用户；IPA 已重编（838KB，dist/）
  - 下一步：等用户装机实测（MediaRemote 能否读到酷狗等、实车投屏）及界面反馈
- [x] 用户已用爱思助手装上 App；反馈：手机号登录报“取图形验证码失败 Load failed（CORS）”、扫“我的”二维码只拿到账号 id 无车况 → 新增 FetchProxy（WKScriptMessageHandlerWithReply，JS 接管 fetch，*.zeehoev.com 走原生 URLSession，UA 缺省 okhttp/4.12.0），IPA 已重编（845KB，dist/）待用户重签实测
- 用户说“没啥大问题，继续开发”；我开始做高德导航，用户叫停：免费版不能做摩托车/电动车专用导航，导航先不加（未改任何代码）。写 Codemagic 密钥变量被自动审核拦下（需用户本人操作）
- 后续可做：显式 App ID com.zeeho.bridge + Hotspot Configuration 能力，App 自动连仪表热点（通配描述文件不支持该能力）
- [x] 签名材料（用户付费开发者账号，团队 79ECZZR225）：Apple Development 证书 VDK498DD86（到 2027-11-10）；P12 = dist/signing/ZeehoBridge-dev.p12（密码在同目录 p12-password.txt，3DES/SHA1 兼容爱思助手）；描述文件 dist/signing/ZeehoBridge_Dev_Wildcard.mobileprovision（通配 79ECZZR225.*，含设备 Joker 00008150-000130CA149A401C，到 2027-11-10）。私钥原件在 ~/.zeeho-bridge/signing/。用户用爱思助手自签

## 用户最新界面要求（15:03 恢复后编译跑通再做）
1. 字体太丑要换：车速改 DIN Alternate Bold / DIN Condensed（iOS 自带），不用 ultraLight；中文 PingFang SC；先在 mockup 里出 2~3 个字体方案给用户选
2. 骑行模式 ECO/STREET/SPORT 是效果图里的假数据，App 里已去掉；如要显示需找数据源（云端车况接口/仪表协议都未见当前档位字段），已如实告知用户
3. 媒体卡：明显加大（约占右侧 40% 宽、60% 高）；背景用地图快照对应区域做 CIGaussianBlur 真模糊 + 半透明暗色；四边羽化渐隐（遮罩渐变）；封面取色；支持歌词滚动（LRCLIB 免费歌词库按歌名+歌手查，备用网易云搜索接口；按播放进度高亮当前行、上下两行渐隐）。播放信息来源依赖私有 MediaRemote 实验，Apple Music 可用 systemMusicPlayer

## 下一步（从这里继续）
1. 解决 Actions startup_failure → 看 Actions 结果；编译错误按 build-log 修
2. Sideloadly 安装，实车测：CLIENT_INFO、画布尺寸、出画面、锁屏表现
3. v1.1：实现 ZeehoShell 原生接口（store*/insets/setDark/setWidgetStats/GPS），接高德地图（AMap iOS SDK，需 key），媒体卡片（systemMusicPlayer）

## 注意事项
- Swift 代码未经编译器验证（本地无 Mac），首次 CI 很可能有小错误
- 握手包名默认 com.cfmoto（极核官方 App）
- Unlocker 网页由 App 远程加载，未打包进 App
