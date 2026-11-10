import UIKit

/// 仪表画面（高级车机风格，对应 docs/dash-mockup.html 第三版）。
/// 设计基准 1024×480，按画布高度等比缩放；2048×960 仪表正好是 2 倍。
final class DashRenderer {
    private let accent = UIColor(red: 98 / 255, green: 214 / 255, blue: 236 / 255, alpha: 1)
    private let text2 = UIColor(red: 235 / 255, green: 242 / 255, blue: 1, alpha: 0.6)
    private let cs = CGColorSpaceCreateDeviceRGB()
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M/d EEE"; return f
    }()
    var modelName = "AE6  ULTRA"

    /// ctx 为 UIKit 坐标（左上原点）且已 UIGraphicsPushContext
    func draw(in ctx: CGContext, size: CGSize, now: Date) {
        let w = size.width, h = size.height, k = h / 480

        // 底色 + 3D 暗色地图
        UIColor(red: 7 / 255, green: 11 / 255, blue: 18 / 255, alpha: 1).setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        if let map = MapBackdrop.shared.current(for: size) {
            let s = max(w / map.size.width, h / map.size.height)
            let dw = map.size.width * s, dh = map.size.height * s
            map.draw(in: CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh), blendMode: .normal, alpha: 0.95)
        }
        // 雾化：顶部、左侧压暗，四周暗角——让悬浮信息和地图自然融合
        linear(ctx, [rgba(7, 11, 18, 1), rgba(7, 11, 18, 0.9), rgba(7, 11, 18, 0.25), rgba(7, 11, 18, 0)],
               [0, 0.14, 0.42, 0.6], CGPoint(x: 0, y: 0), CGPoint(x: 0, y: h))
        linear(ctx, [rgba(5, 8, 14, 0.92), rgba(5, 8, 14, 0.55), rgba(5, 8, 14, 0)],
               [0, 0.26, 0.46], CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0))
        let vc = CGPoint(x: w * 0.62, y: h * 0.85)
        radial(ctx, [rgba(4, 7, 12, 0), rgba(4, 7, 12, 0.75)], [0.35, 1], vc, max(w, h) * 0.75)

        // 车标
        let pc = CGPoint(x: w * 0.6, y: h * 0.69)
        radial(ctx, [accent.withAlphaComponent(0.35).cgColor, accent.withAlphaComponent(0).cgColor], [0, 1], pc, 70 * k)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8 * k), blur: 14 * k, color: rgba(0, 0, 0, 0.7))
        let ring = UIBezierPath(ovalIn: CGRect(x: pc.x - 25 * k, y: pc.y - 25 * k, width: 50 * k, height: 50 * k))
        UIColor(red: 8 / 255, green: 14 / 255, blue: 22 / 255, alpha: 0.88).setFill(); ring.fill()
        ctx.restoreGState()
        accent.setStroke(); ring.lineWidth = 2 * k; ring.stroke()
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: pc.x, y: pc.y - 16 * k))
        arrow.addLine(to: CGPoint(x: pc.x + 12 * k, y: pc.y + 12 * k))
        arrow.addLine(to: CGPoint(x: pc.x, y: pc.y + 6 * k))
        arrow.addLine(to: CGPoint(x: pc.x - 12 * k, y: pc.y + 12 * k))
        arrow.close(); UIColor.white.setFill(); arrow.fill()

        // 顶栏
        let top = 38 * k
        let brandFont: UIFont = {
            let base = UIFont.systemFont(ofSize: 20 * k, weight: .black)
            if let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) { return UIFont(descriptor: d, size: 20 * k) }
            return base
        }()
        let bw = text("ZEEHO", CGPoint(x: 40 * k, y: top), .left, brandFont, .white, kern: 3 * k)
        let mx = 40 * k + bw + 12 * k
        UIColor(white: 1, alpha: 0.22).setFill()
        ctx.fill(CGRect(x: mx, y: top - 8 * k, width: 1 * k, height: 16 * k))
        text(modelName, CGPoint(x: mx + 12 * k, y: top), .left, .systemFont(ofSize: 12 * k, weight: .medium), text2, kern: 3 * k)

        let clock = timeFmt.string(from: now)
        let cw = width(clock, .monospacedDigitSystemFont(ofSize: 22 * k, weight: .medium))
        let date = dateFmt.string(from: now)
        let dw = width(date, .systemFont(ofSize: 13 * k))
        let cx = w / 2 - (cw + 10 * k + dw) / 2
        text(clock, CGPoint(x: cx, y: top), .left, .monospacedDigitSystemFont(ofSize: 22 * k, weight: .medium), .white)
        text(date, CGPoint(x: cx + cw + 10 * k, y: top + 1 * k), .left, .systemFont(ofSize: 13 * k), text2)

        let v = VehicleStore.shared.snapshot()
        var rx = w - 40 * k
        let rangeStr = v.rangeKm.map { "\($0) km" } ?? "-- km"
        rx -= text(rangeStr, CGPoint(x: rx, y: top), .right, .systemFont(ofSize: 14 * k), text2) + 14 * k
        rx -= text(v.soc.map { "\($0)%" } ?? "--%", CGPoint(x: rx, y: top), .right,
                   .monospacedDigitSystemFont(ofSize: 14 * k, weight: .semibold), .white) + 8 * k
        battery(ctx, CGRect(x: rx - 26 * k, y: top - 6 * k, width: 26 * k, height: 12 * k), soc: v.soc, charging: v.charging, k: k)

        // 悬浮车速：细字重 + 投影
        let speed = LocationService.shared.speedKmh.map { String(Int($0.rounded())) } ?? "--"
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10 * k), blur: 30 * k, color: rgba(0, 0, 0, 0.65))
        text(speed, CGPoint(x: 36 * k, y: 176 * k), .left, .systemFont(ofSize: 170 * k, weight: .ultraLight), .white, kern: -8 * k)
        ctx.restoreGState()
        text("KM/H", CGPoint(x: 42 * k, y: 268 * k), .left, .systemFont(ofSize: 15 * k, weight: .medium), text2, kern: 4 * k)
        let gps = LocationService.shared.speedKmh != nil
        text(gps ? "GPS" : "等待 GPS", CGPoint(x: 42 * k, y: 300 * k), .left, .systemFont(ofSize: 13 * k, weight: .semibold),
             gps ? accent : UIColor(white: 1, alpha: 0.35), kern: 1 * k)

        // 左下：电量卡（玻璃）
        let card = CGRect(x: 40 * k, y: h - 34 * k - 86 * k, width: 300 * k, height: 86 * k)
        glass(ctx, card, k: k)
        text(v.soc.map { "\($0)%" } ?? "--%", CGPoint(x: card.minX + 20 * k, y: card.minY + 32 * k), .left,
             .monospacedDigitSystemFont(ofSize: 28 * k, weight: .semibold), .white)
        text(v.charging ? "充电中" : "续航 \(rangeStr)", CGPoint(x: card.maxX - 20 * k, y: card.minY + 32 * k), .right,
             .systemFont(ofSize: 13 * k), text2)
        let track = CGRect(x: card.minX + 20 * k, y: card.maxY - 24 * k, width: card.width - 40 * k, height: 5 * k)
        UIColor(white: 1, alpha: 0.14).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: track.height / 2).fill()
        let pct = CGFloat(min(max(v.soc ?? 0, 0), 100)) / 100
        if pct > 0 {
            let fill = CGRect(x: track.minX, y: track.minY, width: track.width * pct, height: track.height)
            ((v.soc ?? 100) <= 20 ? UIColor(red: 1, green: 0.4, blue: 0.3, alpha: 1)
                                   : UIColor(red: 62 / 255, green: 224 / 255, blue: 143 / 255, alpha: 1)).setFill()
            UIBezierPath(roundedRect: fill, cornerRadius: track.height / 2).fill()
        }

        // 右下：媒体卡（v1.1 接入正在播放）
        let media = CGRect(x: w - 40 * k - 330 * k, y: h - 34 * k - 96 * k, width: 330 * k, height: 96 * k)
        glass(ctx, media, k: k)
        let cover = CGRect(x: media.minX + 14 * k, y: media.minY + 14 * k, width: 68 * k, height: 68 * k)
        linear(ctx, [rgba(42, 63, 82, 1), rgba(25, 50, 62, 1)], [0, 1], cover.origin,
               CGPoint(x: cover.maxX, y: cover.maxY), clip: UIBezierPath(roundedRect: cover, cornerRadius: 12 * k))
        text("♪", CGPoint(x: cover.midX, y: cover.midY), .center, .systemFont(ofSize: 30 * k, weight: .bold), accent)
        text("媒体", CGPoint(x: cover.maxX + 14 * k, y: media.minY + 30 * k), .left, .systemFont(ofSize: 11 * k), text2)
        text("未在播放", CGPoint(x: cover.maxX + 14 * k, y: media.minY + 52 * k), .left,
             .systemFont(ofSize: 18 * k, weight: .semibold), .white)
    }

    // MARK: - 绘制工具

    private func glass(_ ctx: CGContext, _ r: CGRect, k: CGFloat) {
        let path = UIBezierPath(roundedRect: r, cornerRadius: 20 * k)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 18 * k), blur: 50 * k, color: rgba(0, 0, 0, 0.45))
        UIColor(red: 22 / 255, green: 30 / 255, blue: 44 / 255, alpha: 0.62).setFill()
        path.fill()
        ctx.restoreGState()
        linear(ctx, [rgba(255, 255, 255, 0.07), rgba(255, 255, 255, 0)], [0, 1], r.origin,
               CGPoint(x: r.minX, y: r.maxY), clip: path)
        UIColor(white: 1, alpha: 0.08).setStroke()
        path.lineWidth = 1 * k; path.stroke()
    }

    private func battery(_ ctx: CGContext, _ r: CGRect, soc: Int?, charging: Bool, k: CGFloat) {
        let body = UIBezierPath(roundedRect: r, cornerRadius: 3 * k)
        UIColor(white: 1, alpha: 0.7).setStroke(); body.lineWidth = 1.5 * k; body.stroke()
        let inner = r.insetBy(dx: 2.5 * k, dy: 2.5 * k)
        let pct = CGFloat(min(max(soc ?? 0, 0), 100)) / 100
        (charging ? accent : UIColor(red: 62 / 255, green: 224 / 255, blue: 143 / 255, alpha: 1)).setFill()
        UIBezierPath(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: inner.width * pct, height: inner.height),
                     cornerRadius: 1.5 * k).fill()
    }

    private enum Align { case left, center, right }

    /// 以 point.y 为垂直中心绘制，返回文字宽度
    @discardableResult
    private func text(_ s: String, _ p: CGPoint, _ align: Align, _ font: UIFont, _ color: UIColor, kern: CGFloat = 0) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let size = (s as NSString).size(withAttributes: attrs)
        var x = p.x
        if align == .center { x -= size.width / 2 } else if align == .right { x -= size.width }
        (s as NSString).draw(at: CGPoint(x: x, y: p.y - size.height / 2), withAttributes: attrs)
        return size.width
    }

    private func width(_ s: String, _ font: UIFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a).cgColor
    }

    private func linear(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], _ a: CGPoint, _ b: CGPoint,
                        clip: UIBezierPath? = nil) {
        guard let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) else { return }
        ctx.saveGState()
        if let clip = clip { clip.addClip() }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
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
