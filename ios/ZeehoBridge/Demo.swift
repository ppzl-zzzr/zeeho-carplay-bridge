import Foundation
import CoreLocation
import UIKit

/// 演示模式（启动参数 -demo）：用假数据驱动仪表，并把 2048×960 仪表画面导出成 PNG，
/// 供云端模拟器截图检查真实渲染效果。正常使用时不生效。
enum Demo {
    static let on = ProcessInfo.processInfo.arguments.contains("-demo")
    static let start = Date()

    static let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 30.2590, longitude: 120.1650),
                                     altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5,
                                     course: 35, speed: 13.6, timestamp: Date())

    static var nowPlaying: NowPlayingInfo {
        NowPlayingInfo(title: "示例歌曲（演示）", artist: "演示歌手", album: "演示专辑", duration: 188,
                       elapsed: 72, rate: 1, timestamp: start, artwork: artwork, source: "正在播放")
    }

    /// 演示用歌词（自拟文字）
    static let lyrics: [LyricLine] = [
        "清晨的风吹过湖面", "车轮压过安静的街", "仪表上的数字在跳动", "这一段路只属于我",
        "红灯亮起又再熄灭", "导航说前方右转", "音乐刚好放到副歌", "把油门拧得更坚定",
        "城市在后视镜里变小", "晚霞落在头盔上",
    ].enumerated().map { LyricLine(time: Double($0.offset) * 9 + 40, text: $0.element) }

    static let artwork: UIImage = {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: fmt).image { c in
            let colors = [UIColor(red: 1, green: 0.56, blue: 0.69, alpha: 1).cgColor,
                          UIColor(red: 0.48, green: 0.36, blue: 1, alpha: 1).cgColor,
                          UIColor(red: 0.18, green: 0.49, blue: 0.96, alpha: 1).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
            c.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 300, y: 300), options: [])
        }
    }()

    /// 等地图快照就绪（最多约 60 秒）再导出
    static func export(log: @escaping (String) -> Void, waited: Int = 0) {
        if MapBackdrop.shared.blurred == nil && waited < 60 {
            _ = MapBackdrop.shared.current(for: CGSize(width: 2048, height: 960))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { export(log: log, waited: waited + 1) }
            return
        }
        exportNow(log: log, mapReady: MapBackdrop.shared.blurred != nil)
    }

    /// 把三套字体的 2048×960 仪表画面写到 Documents/dash-*.png
    private static func exportNow(log: @escaping (String) -> Void, mapReady: Bool) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let renderer = DashRenderer()
        let saved = UserDefaults.standard.integer(forKey: "dashFont")
        for f in DashFont.allCases {
            UserDefaults.standard.set(f.rawValue, forKey: "dashFont")
            let img = renderer.previewImage(size: CGSize(width: 2048, height: 960))
            if let data = img.pngData() {
                try? data.write(to: dir.appendingPathComponent("dash-\(f.rawValue)-\(["barlow", "saira", "rajdhani"][f.rawValue]).png"))
            }
        }
        UserDefaults.standard.set(saved, forKey: "dashFont")
        try? "done map=\(mapReady)".write(to: dir.appendingPathComponent("export-done.txt"), atomically: true, encoding: .utf8)
        log("[演示] 已导出仪表截图到 \(dir.path)")
    }
}
