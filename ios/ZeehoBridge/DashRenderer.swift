import UIKit
import CoreImage

/// 仪表数字/英文字体（三套开源字体，在 App 设置里切换；中文统一用苹方）
enum DashFont: Int, CaseIterable {
    case barlow = 0, saira, rajdhani

    var title: String {
        switch self {
        case .barlow: return "A · Barlow"
        case .saira: return "B · Saira"
        case .rajdhani: return "C · Rajdhani"
        }
    }

    private var family: String {
        switch self {
        case .barlow: return "Barlow"
        case .saira: return "SairaSemiCondensed"
        case .rajdhani: return "Rajdhani"
        }
    }

    /// 窄体字号放大一点，视觉大小一致
    var scale: CGFloat { self == .rajdhani ? 1.12 : 1 }

    static var current: DashFont { DashFont(rawValue: UserDefaults.standard.integer(forKey: "dashFont")) ?? .barlow }

    /// 车速大数字：Barlow 用超粗斜体
    func display(_ size: CGFloat) -> UIFont {
        if self == .barlow, let f = UIFont(name: "Barlow-ExtraBoldItalic", size: size) { return f }
        return font(size)
    }

    /// 次要数字（电量、行程）：Barlow 用粗斜体
    func italic(_ size: CGFloat) -> UIFont {
        if self == .barlow, let f = UIFont(name: "Barlow-SemiBoldItalic", size: size) { return f }
        return font(size)
    }

    func font(_ size: CGFloat, bold: Bool = true) -> UIFont {
        let s = size * scale
        return UIFont(name: "\(family)-\(bold ? "SemiBold" : "Medium")", size: s)
            ?? .monospacedDigitSystemFont(ofSize: s, weight: bold ? .semibold : .medium)
    }
}

/// 仪表画面（高级车机风格，对应 docs/dash-mockup.html）。
/// 设计基准 1024×480，按画布高度等比缩放；2048×960 仪表正好是 2 倍。
final class DashRenderer {
    private let accent = UIColor(red: 98 / 255, green: 214 / 255, blue: 236 / 255, alpha: 1)
    private let text2 = UIColor(red: 235 / 255, green: 242 / 255, blue: 1, alpha: 0.62)
    private let cs = CGColorSpaceCreateDeviceRGB()
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M/d EEE"; return f
    }()
    var modelName = "AE6 ULTRA"

    // 媒体卡缓存（每秒约 12 次重绘，省电）
    private var cardImage: UIImage?
    private var cardAt = Date.distantPast
    private var maskImage: CGImage?
    private var maskSize = CGSize.zero

    /// ctx 为 UIKit 坐标（左上原点）且已 UIGraphicsPushContext
    func draw(in ctx: CGContext, size: CGSize, now: Date) {
        let w = size.width, h = size.height, k = h / 480
        let F = DashFont.current

        // 底色 + 3D 暗色地图
        UIColor(red: 7 / 255, green: 11 / 255, blue: 18 / 255, alpha: 1).setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        var mapRect = CGRect.zero
        if let map = MapBackdrop.shared.current(for: size) {
            mapRect = MapBackdrop.fillRect(image: map.size, canvas: size)
            map.draw(in: mapRect, blendMode: .normal, alpha: 0.95)
        }
        // 雾化：顶部、左侧压暗，四周暗角
        linear(ctx, [rgba(7, 11, 18, 1), rgba(7, 11, 18, 0.9), rgba(7, 11, 18, 0.2), rgba(7, 11, 18, 0)],
               [0, 0.13, 0.4, 0.58], .zero, CGPoint(x: 0, y: h))
        linear(ctx, [rgba(5, 8, 14, 0.9), rgba(5, 8, 14, 0.5), rgba(5, 8, 14, 0)],
               [0, 0.24, 0.4], .zero, CGPoint(x: w, y: 0))
        radial(ctx, [rgba(4, 7, 12, 0), rgba(4, 7, 12, 0.75)], [0.35, 1], CGPoint(x: w * 0.45, y: h * 0.85), max(w, h) * 0.75)

        puck(ctx, CGPoint(x: w * 0.42, y: h * 0.73), k: k)

        // 顶栏
        let top = 36 * k
        let brandW = text("ZEEHO", CGPoint(x: 40 * k, y: top), .left, F.font(20 * k), .white, kern: 3 * k, oblique: 0.22)
        let mx = 40 * k + brandW + 12 * k
        UIColor(white: 1, alpha: 0.22).setFill()
        ctx.fill(CGRect(x: mx, y: top - 8 * k, width: max(1, k), height: 16 * k))
        text(modelName, CGPoint(x: mx + 12 * k, y: top), .left, F.font(12 * k), text2, kern: 3 * k)

        let clock = timeFmt.string(from: now), date = dateFmt.string(from: now)
        let cf = F.font(24 * k), df = UIFont.systemFont(ofSize: 13 * k)
        let cw = width(clock, cf), dw = width(date, df)
        let cx = w / 2 - (cw + 10 * k + dw) / 2
        text(clock, CGPoint(x: cx, y: top), .left, cf, .white)
        text(date, CGPoint(x: cx + cw + 10 * k, y: top + 1 * k), .left, df, text2)

        let v = VehicleStore.shared.snapshot()
        var rx = w - 40 * k
        rx -= text(v.rangeKm.map { "\($0) km" } ?? "-- km", CGPoint(x: rx, y: top), .right, F.font(15 * k, bold: false), text2) + 14 * k
        rx -= text(v.soc.map { "\($0)%" } ?? "--%", CGPoint(x: rx, y: top), .right, F.italic(16 * k), .white) + 8 * k
        battery(ctx, CGRect(x: rx - 26 * k, y: top - 6 * k, width: 26 * k, height: 12 * k), soc: v.soc, charging: v.charging, k: k)

        // 车速：速度弧线 + 超粗斜体数字
        speedGauge(ctx, center: CGPoint(x: 165 * k, y: 226 * k), radius: 118 * k, k: k, font: F,
                   speed: LocationService.shared.speedKmh)

        let nav = NavService.shared.snapshot()
        if nav.active {
            // 导航中：左下转向卡 + 右上到达信息
            navCard(ctx, CGRect(x: 40 * k, y: h - 34 * k - 96 * k, width: 330 * k, height: 96 * k), nav, k: k, font: F)
            let eta = Date().addingTimeInterval(TimeInterval(nav.remainTime))
            let etaStr = "\(timeFmt.string(from: eta)) 到达"
            let remain = nav.remainDistance >= 1000 ? String(format: "%.1f km", Double(nav.remainDistance) / 1000)
                                                     : "\(nav.remainDistance) m"
            text(etaStr, CGPoint(x: w - 40 * k, y: 70 * k), .right, F.italic(17 * k), .white)
            text("剩余 \(remain) · \(max(nav.remainTime / 60, 1)) 分钟", CGPoint(x: w - 40 * k, y: 92 * k), .right,
                 .systemFont(ofSize: 12 * k), text2)
        } else {
            // 左下：本次行程
            let t = LocationService.shared.trip
            var tx = 40 * k
            let by = h - 38 * k
            for (label, value) in [("行程", String(format: "%.1f km", t.km)),
                                   ("时长", String(format: "%02d:%02d", Int(t.seconds) / 3600, Int(t.seconds) / 60 % 60)),
                                   ("最高", String(Int(t.maxKmh.rounded())))] {
                tx += text(label, CGPoint(x: tx, y: by), .left, .systemFont(ofSize: 13 * k), text2) + 6 * k
                tx += text(value, CGPoint(x: tx, y: by), .left, F.italic(18 * k), .white) + 22 * k
            }
        }

        // 右侧：大号媒体卡
        let card = CGRect(x: w - 36 * k - 452 * k, y: 78 * k, width: 452 * k, height: 372 * k)
        if cardImage == nil || now.timeIntervalSince(cardAt) > 1.0 / 12 {
            cardImage = renderCard(card, mapRect: mapRect, k: k, font: F)
            cardAt = now
        }
        if let img = cardImage, let mask = feather(card.size, k: k) {
            ctx.saveGState()
            ctx.clip(to: card, mask: mask)
            img.draw(in: card)
            ctx.restoreGState()
        }
    }

    // MARK: - 媒体卡

    private func renderCard(_ r: CGRect, mapRect: CGRect, k: CGFloat, font F: DashFont) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let np = NowPlaying.shared.current
        let tint = CoverTint.shared.current
        return UIGraphicsImageRenderer(size: r.size, format: fmt).image { c in
            let g = c.cgContext
            let W = r.width, H = r.height
            // 毛玻璃：卡片背后那块地图的模糊版 + 暗色 + 封面主色
            if let blur = MapBackdrop.shared.blurred, mapRect.width > 0 {
                blur.draw(in: mapRect.offsetBy(dx: -r.minX, dy: -r.minY))
            } else {
                UIColor(red: 0.08, green: 0.1, blue: 0.16, alpha: 1).setFill(); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
            }
            linear(g, [tint.withAlphaComponent(0.45).cgColor, rgba(18, 24, 40, 0.68), rgba(10, 14, 24, 0.8)],
                   [0, 0.55, 1], .zero, CGPoint(x: W, y: H))
            radial(g, [tint.withAlphaComponent(0.45).cgColor, tint.withAlphaComponent(0).cgColor], [0, 1],
                   CGPoint(x: W * 0.18, y: H * 0.16), W * 0.6)
            UIColor(white: 1, alpha: 0.06).setFill()
            g.fill(CGRect(x: 0, y: 0, width: W, height: 1.5 * k))

            let pad = 34 * k
            // 封面
            let cover = CGRect(x: pad, y: 30 * k, width: 92 * k, height: 92 * k)
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: 12 * k), blur: 30 * k, color: rgba(0, 0, 0, 0.45))
            let cp = UIBezierPath(roundedRect: cover, cornerRadius: 16 * k)
            UIColor(red: 0.16, green: 0.24, blue: 0.32, alpha: 1).setFill(); cp.fill()
            g.restoreGState()
            if let art = np?.artwork {
                g.saveGState(); cp.addClip(); art.draw(in: cover); g.restoreGState()
            } else {
                text("♪", CGPoint(x: cover.midX, y: cover.midY), .center, .systemFont(ofSize: 40 * k, weight: .bold), accent)
            }

            let tx = cover.maxX + 18 * k, tw = W - tx - pad
            if let np = np {
                dot(g, CGPoint(x: tx + 3.5 * k, y: 52 * k), 3.5 * k, np.rate > 0 ? accent : UIColor(white: 1, alpha: 0.4))
                text(np.source, CGPoint(x: tx + 12 * k, y: 52 * k), .left, .systemFont(ofSize: 12 * k), text2)
                line(np.title, CGRect(x: tx, y: 62 * k, width: tw, height: 34 * k), .systemFont(ofSize: 26 * k, weight: .bold), .white)
                line(np.artist, CGRect(x: tx, y: 97 * k, width: tw, height: 20 * k), .systemFont(ofSize: 14 * k), text2)
                lyrics(np, CGRect(x: pad, y: 140 * k, width: W - pad * 2, height: H - 140 * k - 62 * k), k: k)
                // 进度
                let py = H - 36 * k
                let cur = mmss(np.position), tot = mmss(np.duration)
                let lw = text(cur, CGPoint(x: pad, y: py), .left, F.font(12 * k, bold: false), text2)
                let rw = width(tot, F.font(12 * k, bold: false))
                text(tot, CGPoint(x: W - pad, y: py), .right, F.font(12 * k, bold: false), text2)
                let bar = CGRect(x: pad + lw + 12 * k, y: py - 2 * k, width: W - pad * 2 - lw - rw - 24 * k, height: 4 * k)
                UIColor(white: 1, alpha: 0.16).setFill()
                UIBezierPath(roundedRect: bar, cornerRadius: 2 * k).fill()
                let pct = np.duration > 0 ? CGFloat(np.position / np.duration) : 0
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * pct, height: bar.height),
                             cornerRadius: 2 * k).fill()
            } else {
                text("媒体", CGPoint(x: tx, y: 52 * k), .left, .systemFont(ofSize: 12 * k), text2)
                line("未在播放", CGRect(x: tx, y: 62 * k, width: tw, height: 34 * k), .systemFont(ofSize: 26 * k, weight: .bold), .white)
                line("手机播放音乐后自动显示", CGRect(x: tx, y: 97 * k, width: tw, height: 20 * k), .systemFont(ofSize: 14 * k), text2)
            }
        }
    }

    /// 歌词：当前句高亮放大，上下各两句渐隐；临近换行时平滑上移
    private func lyrics(_ np: NowPlayingInfo, _ area: CGRect, k: CGFloat) {
        let snap = Lyrics.shared.snapshot()
        guard !snap.lines.isEmpty else {
            text(snap.state.isEmpty ? "暂无歌词" : snap.state, CGPoint(x: area.minX, y: area.midY), .left,
                 .systemFont(ofSize: 16 * k), UIColor(white: 1, alpha: 0.4))
            return
        }
        let cur = Lyrics.cursor(snap.lines, at: np.position)
        let lineH = 40 * k
        let ease = cur.frac > 0.82 ? (cur.frac - 0.82) / 0.18 : 0
        let shift = CGFloat(ease * ease * (3 - 2 * ease)) * lineH
        let center = max(cur.index, 0)
        for d in -3...3 {
            let i = center + d
            guard i >= 0, i < snap.lines.count else { continue }
            let y = area.midY + CGFloat(d) * lineH - (cur.index >= 0 ? shift : 0)
            guard y > area.minY - lineH / 2, y < area.maxY + lineH / 2 else { continue }
            let dist = abs(y - area.midY) / lineH
            let isNow = d == 0 && cur.index >= 0 && ease < 0.5
            let alpha = isNow ? 1 : max(0.12, 0.5 - 0.17 * dist)
            let f: UIFont = isNow ? .systemFont(ofSize: 23 * k, weight: .bold) : .systemFont(ofSize: 16 * k, weight: .medium)
            line(snap.lines[i].text, CGRect(x: area.minX, y: y - lineH / 2, width: area.width, height: lineH), f,
                 UIColor(white: 1, alpha: alpha), centerY: true)
        }
    }

    /// 四边羽化遮罩（灰度：白=显示），按尺寸缓存
    private func feather(_ size: CGSize, k: CGFloat) -> CGImage? {
        if let m = maskImage, maskSize == size { return m }
        let W = Int(size.width), H = Int(size.height)
        guard W > 0, H > 0, let g = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let edge = 40 * k
        g.setFillColor(gray: 0, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        g.setFillColor(gray: 1, alpha: 1)
        g.addPath(UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: edge, dy: edge),
                               cornerRadius: 30 * k).cgPath)
        g.fillPath()
        guard let hard = g.makeImage(), let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        let input = CIImage(cgImage: hard)
        f.setValue(input, forKey: kCIInputImageKey)   // 不 clamp：四周按黑色淡出，边缘更柔
        f.setValue(edge * 0.6, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage?.cropped(to: input.extent),
              let img = MapBackdrop.ciContext.createCGImage(out, from: input.extent, format: .L8,
                                                            colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        maskImage = img; maskSize = size
        return img
    }

    // MARK: - 小部件

    /// 导航转向卡：转向图标 + 距离 + 下一条路
    private func navCard(_ ctx: CGContext, _ r: CGRect, _ nav: NavService.Snapshot, k: CGFloat, font F: DashFont) {
        let path = UIBezierPath(roundedRect: r, cornerRadius: 20 * k)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14 * k), blur: 40 * k, color: rgba(0, 0, 0, 0.5))
        UIColor(red: 18 / 255, green: 26 / 255, blue: 40 / 255, alpha: 0.72).setFill(); path.fill()
        ctx.restoreGState()
        UIColor(white: 1, alpha: 0.08).setStroke(); path.lineWidth = 1 * k; path.stroke()

        let ic = CGRect(x: r.minX + 16 * k, y: r.midY - 30 * k, width: 60 * k, height: 60 * k)
        let icp = UIBezierPath(roundedRect: ic, cornerRadius: 16 * k)
        ctx.saveGState(); icp.addClip()
        linear(ctx, [UIColor(red: 0.44, green: 0.88, blue: 0.95, alpha: 1).cgColor,
                     UIColor(red: 0.16, green: 0.65, blue: 0.79, alpha: 1).cgColor], [0, 1],
               ic.origin, CGPoint(x: ic.maxX, y: ic.maxY))
        ctx.restoreGState()
        let cfg = UIImage.SymbolConfiguration(pointSize: 30 * k, weight: .heavy)
        if let sym = UIImage(systemName: Self.turnSymbol(nav.icon), withConfiguration: cfg)?
            .withTintColor(UIColor(red: 0.02, green: 0.13, blue: 0.16, alpha: 1), renderingMode: .alwaysOriginal) {
            let s = sym.size
            sym.draw(in: CGRect(x: ic.midX - s.width / 2, y: ic.midY - s.height / 2, width: s.width, height: s.height))
        }

        let tx = ic.maxX + 16 * k
        let d = nav.segmentDistance
        let num = d >= 1000 ? String(format: "%.1f", Double(d) / 1000) : "\(d)"
        let nw = text(num, CGPoint(x: tx, y: r.midY - 14 * k), .left, F.display(34 * k), .white)
        text(d >= 1000 ? "公里" : "米", CGPoint(x: tx + nw + 6 * k, y: r.midY - 10 * k), .left, .systemFont(ofSize: 14 * k), text2)
        line(nav.nextRoad.isEmpty ? "沿当前道路行驶" : "进入 \(nav.nextRoad)",
             CGRect(x: tx, y: r.midY + 10 * k, width: r.maxX - tx - 16 * k, height: 22 * k),
             .systemFont(ofSize: 15 * k, weight: .medium), text2)
    }

    /// 高德转向图标编号 → SF Symbols
    private static func turnSymbol(_ icon: Int) -> String {
        switch icon {
        case 2: return "arrow.turn.up.left"
        case 3: return "arrow.turn.up.right"
        case 4: return "arrow.up.left"
        case 5: return "arrow.up.right"
        case 6: return "arrow.down.left"
        case 7: return "arrow.down.right"
        case 8: return "arrow.uturn.down"
        case 10: return "mappin.circle"
        case 11, 12: return "arrow.triangle.turn.up.right.circle"
        case 15: return "flag.checkered"
        default: return "arrow.up"
        }
    }

    /// 270° 速度弧：底部开口，青→紫渐变 + 发光；满刻度 120 km/h
    private func speedGauge(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, k: CGFloat, font F: DashFont, speed: Double?) {
        let maxKmh = 120.0
        let start = CGFloat.pi * 0.75, sweep = CGFloat.pi * 1.5
        let frac = CGFloat(min(max((speed ?? 0) / maxKmh, 0), 1))
        let lw = 10 * k

        // 底部压暗，让弧线和数字从地图上浮出来
        radial(ctx, [rgba(0, 0, 0, 0.55), rgba(0, 0, 0, 0)], [0, 1], c, r * 1.35)

        let track = UIBezierPath(arcCenter: c, radius: r, startAngle: start, endAngle: start + sweep, clockwise: true)
        track.lineWidth = lw; track.lineCapStyle = .round
        UIColor(white: 1, alpha: 0.08).setStroke(); track.stroke()

        // 刻度点
        for i in 0...12 {
            let a = start + sweep * CGFloat(i) / 12
            let p = CGPoint(x: c.x + cos(a) * (r - 18 * k), y: c.y + sin(a) * (r - 18 * k))
            UIColor(white: 1, alpha: i % 3 == 0 ? 0.35 : 0.14).setFill()
            let d = (i % 3 == 0 ? 3.2 : 2.2) * k
            UIBezierPath(ovalIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).fill()
        }

        if frac > 0.002 {
            let arc = UIBezierPath(arcCenter: c, radius: r, startAngle: start, endAngle: start + sweep * frac, clockwise: true)
            // 发光层
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 18 * k, color: accent.withAlphaComponent(0.8).cgColor)
            arc.lineWidth = lw; arc.lineCapStyle = .round
            accent.withAlphaComponent(0.6).setStroke(); arc.stroke()
            ctx.restoreGState()
            // 渐变层：把弧线描边当作裁剪区，再铺横向渐变
            ctx.saveGState()
            ctx.addPath(arc.cgPath)
            ctx.setLineWidth(lw); ctx.setLineCap(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            linear(ctx, [accent.cgColor, rgba(155, 123, 255, 1)], [0, 1],
                   CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x + r, y: c.y))
            ctx.restoreGState()
            // 弧线端点亮点
            let ea = start + sweep * frac
            let ep = CGPoint(x: c.x + cos(ea) * r, y: c.y + sin(ea) * r)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: ep.x - 4 * k, y: ep.y - 4 * k, width: 8 * k, height: 8 * k)).fill()
        }

        let ly = c.y + sin(start) * r + 22 * k
        text("0", CGPoint(x: c.x + cos(start) * r, y: ly), .center, F.font(12 * k), UIColor(white: 1, alpha: 0.35))
        text("\(Int(maxKmh))", CGPoint(x: c.x - cos(start) * r, y: ly), .center, F.font(12 * k), UIColor(white: 1, alpha: 0.35))

        // 数字
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8 * k), blur: 26 * k, color: rgba(0, 0, 0, 0.7))
        text(speed.map { String(Int($0.rounded())) } ?? "--", CGPoint(x: c.x + 4 * k, y: c.y - 6 * k), .center,
             F.display(118 * k), .white, kern: -3 * k)
        ctx.restoreGState()
        text("KM/H", CGPoint(x: c.x + 2 * k, y: c.y + 58 * k), .center, F.font(15 * k), text2, kern: 4 * k)
        let gps = speed != nil
        text(gps ? "GPS" : "等待 GPS", CGPoint(x: c.x, y: c.y + 96 * k), .center, F.font(12 * k),
             gps ? accent : UIColor(white: 1, alpha: 0.35), kern: 2 * k)
    }

    private func puck(_ ctx: CGContext, _ pc: CGPoint, k: CGFloat) {
        radial(ctx, [accent.withAlphaComponent(0.35).cgColor, accent.withAlphaComponent(0).cgColor], [0, 1], pc, 66 * k)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8 * k), blur: 14 * k, color: rgba(0, 0, 0, 0.7))
        let ring = UIBezierPath(ovalIn: CGRect(x: pc.x - 25 * k, y: pc.y - 25 * k, width: 50 * k, height: 50 * k))
        UIColor(red: 8 / 255, green: 14 / 255, blue: 22 / 255, alpha: 0.88).setFill(); ring.fill()
        ctx.restoreGState()
        accent.setStroke(); ring.lineWidth = 2 * k; ring.stroke()
        let a = UIBezierPath()
        a.move(to: CGPoint(x: pc.x, y: pc.y - 16 * k))
        a.addLine(to: CGPoint(x: pc.x + 12 * k, y: pc.y + 12 * k))
        a.addLine(to: CGPoint(x: pc.x, y: pc.y + 6 * k))
        a.addLine(to: CGPoint(x: pc.x - 12 * k, y: pc.y + 12 * k))
        a.close(); UIColor.white.setFill(); a.fill()
    }

    private func battery(_ ctx: CGContext, _ r: CGRect, soc: Int?, charging: Bool, k: CGFloat) {
        let body = UIBezierPath(roundedRect: r, cornerRadius: 3 * k)
        UIColor(white: 1, alpha: 0.7).setStroke(); body.lineWidth = 1.5 * k; body.stroke()
        let inner = r.insetBy(dx: 2.5 * k, dy: 2.5 * k)
        let pct = CGFloat(min(max(soc ?? 0, 0), 100)) / 100
        let low = (soc ?? 100) <= 20
        (charging ? accent : low ? UIColor(red: 1, green: 0.4, blue: 0.3, alpha: 1)
                                 : UIColor(red: 62 / 255, green: 224 / 255, blue: 143 / 255, alpha: 1)).setFill()
        UIBezierPath(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: inner.width * pct, height: inner.height),
                     cornerRadius: 1.5 * k).fill()
    }

    private func dot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: UIColor) {
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }

    private func mmss(_ t: Double) -> String {
        let s = max(Int(t.rounded()), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - 文字与渐变

    private enum Align { case left, center, right }

    /// 以 p.y 为垂直中心绘制，返回文字宽度
    @discardableResult
    private func text(_ s: String, _ p: CGPoint, _ align: Align, _ font: UIFont, _ color: UIColor,
                      kern: CGFloat = 0, oblique: CGFloat = 0) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        if oblique != 0 { attrs[.obliqueness] = oblique }
        let size = (s as NSString).size(withAttributes: attrs)
        var x = p.x
        if align == .center { x -= size.width / 2 } else if align == .right { x -= size.width }
        (s as NSString).draw(at: CGPoint(x: x, y: p.y - size.height / 2), withAttributes: attrs)
        return size.width
    }

    /// 单行、超出截断
    private func line(_ s: String, _ r: CGRect, _ font: UIFont, _ color: UIColor, centerY: Bool = false) {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
        var rect = r
        if centerY {
            let hgt = font.lineHeight
            rect = CGRect(x: r.minX, y: r.midY - hgt / 2, width: r.width, height: hgt + 2)
        }
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs, context: nil)
    }

    private func width(_ s: String, _ font: UIFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a).cgColor
    }

    private func linear(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], _ a: CGPoint, _ b: CGPoint) {
        guard let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func radial(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], _ c: CGPoint, _ r: CGFloat) {
        guard let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
    }

    /// App 内预览
    func previewImage(size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { c in
            draw(in: c.cgContext, size: size, now: Date())
        }
    }
}
