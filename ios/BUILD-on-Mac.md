# 在 Mac 上编译（两个 App）

本工程用 XcodeGen 生成 .xcodeproj，用 CocoaPods 引入高德 SDK（仅仪表版用到）。

## 一次性准备
```bash
brew install xcodegen cocoapods     # 已装可跳过
```

## 生成工程并安装依赖
```bash
cd ios
# 若从 git 克隆而非本压缩包：先 cp Shared/ZeehoSecrets.swift.example Shared/ZeehoSecrets.swift 并填入常量
xcodegen generate
pod install
open ZeehoBridge.xcworkspace        # 注意是 .xcworkspace，不是 .xcodeproj
```

## 两个 Target / Scheme
- **ZeehoBridge**（极核仪表，com.zeeho.bridge）：仪表投屏 + 3D 地图 + 速度弧 + 媒体卡 + 自动连热点 + 高德常规导航 + 原生车辆页。自用。
- **ZeehoPanel**（极核面板，com.zeeho.panel）：只有原生车辆页（登录 + 车况 + 基础车控），不含高德，可分发。

在 Xcode 左上角选 Scheme，连真机，设好你的签名团队（79ECZZR225），Run 即可。
命令行归档：
```bash
xcodebuild -workspace ZeehoBridge.xcworkspace -scheme ZeehoPanel -configuration Release -sdk iphoneos archive -archivePath build/ZeehoPanel.xcarchive DEVELOPMENT_TEAM=79ECZZR225
```

## 高德 Key（仅仪表版）
`ios/Secrets.xcconfig` 里的 `AMAP_IOS_KEY` 会注入仪表版 Info.plist。面板版用不到。

## 原生对接说明
- 车辆页为纯原生（不再嵌网页），通过还原的签名算法直接调极核接口（见 `dist/recon/zeeho-api-spec.md`）。
- 登录/车控的请求体字段按还原结果实现；若真机上登录或某个车控报错，把接口返回发给开发者微调即可。
