# 任务检查点
- 状态：进行中（iOS v1 代码已写完，等用户推到 GitHub 云编译）
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

## 下一步（从这里继续）
1. 用户建 GitHub 仓库并推送 → 看 Actions 结果；编译错误按 build-log 修
2. Sideloadly 安装，实车测：CLIENT_INFO、画布尺寸、出画面、锁屏表现
3. v1.1：实现 ZeehoShell 原生接口（store*/insets/setDark/setWidgetStats/GPS），接高德地图（AMap iOS SDK，需 key），媒体卡片（systemMusicPlayer）

## 注意事项
- Swift 代码未经编译器验证（本地无 Mac），首次 CI 很可能有小错误
- 握手包名默认 com.cfmoto（极核官方 App）
- Unlocker 网页由 App 远程加载，未打包进 App
