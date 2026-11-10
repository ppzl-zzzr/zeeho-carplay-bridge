# 极核仪表（Zeeho Bridge）

自己的极核电动车仪表 App：在手机上渲染仪表画面（悬浮车速、地图、车况、时间），按 MotoPlay（Carbit EasyConn / PXC）协议推到极核仪表；
内嵌 [Zeeho Unlocker](https://lswlc33.github.io/zeeho-3d-models/) 车辆面板，车况数据同步到仪表画面。

| 目录 | 内容 |
|---|---|
| `ios/` | **iOS App（主线）**，Swift + SwiftUI，XcodeGen 生成工程 |
| `dashlink/`、`app/` | Android 版（投屏协议库 + 调试 App） |
| `.github/workflows/ios.yml` | GitHub 云端 Mac 编译，产出未签名 IPA |

## iOS App（v1）

两个页面：

- **仪表**：仪表画面实时预览、开始/停止投屏、骑行模式（屏幕常亮）、握手包名、仪表 IP、日志。
- **车辆**：嵌入 Zeeho Unlocker 网页面板（登录、车况、车控、充电记录、主题等全部功能）。
  App 只读监听面板拿到的极核接口响应，取出电量、续航、充电状态显示到仪表画面上。

| 文件 | 说明 |
|---|---|
| `ios/ZeehoBridge/App.swift` | 入口、两个页面、状态管理 |
| `ios/ZeehoBridge/DashLink.swift` | 仪表投屏协议：探测、握手、心跳、画布协商、逐帧发送 |
| `ios/ZeehoBridge/Video.swift` | 仪表画面渲染、VideoToolbox H.264 编码、GPS 车速 |
| `ios/ZeehoBridge/VehiclePanel.swift` | Unlocker 面板容器 + 车况采集 |
| `ios/project.yml` | XcodeGen 工程描述（权限说明、后台定位等） |

### 没有 Mac 怎么编译和安装

1. 在 GitHub 新建一个仓库，把本文件夹推上去（公开仓库的 macOS 编译分钟数不限，私有仓库每月有额度）。
2. 推送后 GitHub 会自动运行 **iOS build**（也可在 Actions 页手动点 Run workflow），约 5–10 分钟。
3. 在该次运行页面底部下载 **ZeehoBridge-ipa**（解压得到 `ZeehoBridge-unsigned.ipa`）。
   编译失败时下载 **build-log** 发给我。
4. Windows 上用 **Sideloadly**（需先装苹果官网版 iTunes 和 iCloud）：连上 iPhone，拖入 IPA，填 Apple ID，Start。
5. iPhone：设置 → 隐私与安全性 → 开发者模式 打开；设置 → 通用 → VPN 与设备管理 → 信任。
   免费 Apple ID 签名 7 天有效，到期用 Sideloadly 重签即可（数据不丢）。

### 车上使用

1. 车辆设置里打开「投屏（MotoPlay）」，仪表切到投屏页。
2. iPhone 在系统设置里连上仪表热点（WiFi 直连一般叫 `DIRECT-…`）。
3. 打开 App →「开始投屏」，允许「本地网络」和「定位」权限。
4. 日志里看到 `仪表信息 CLIENT_INFO`、`仪表请求画布`、`已发送第 N 帧` 就说明通了；请把 CLIENT_INFO 那段保存下来。

### 已知限制

- iOS 锁屏/切后台时会收回硬件编码器，仪表画面可能停住（日志会提示“编码失败”，回到前台自动恢复）。骑行时开着 App、打开骑行模式。
- 地图目前是占位动画，下一版接入高德地图。
- Unlocker 里依赖 Android 外壳的功能（VPN 抓 token、root 保活、桌面小组件、后台自动任务）在 iOS 上不可用；登录请用短信验证码或粘贴 token。

## Android 版

见 `dashlink/`、`app/`，用 Android Studio 打开即可编译（需要 JDK 17+）。

## 参考

- 投屏协议：[zanderp/open-cfmoto](https://github.com/zanderp/open-cfmoto)（AGPL-3.0）的逆向文档，本工程为独立实现。
- 车辆面板：[lswlc33/zeeho-3d-models](https://github.com/lswlc33/zeeho-3d-models)（Zeeho Unlocker），在 App 内以网页方式加载。
