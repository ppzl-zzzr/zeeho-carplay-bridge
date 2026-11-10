import Foundation
import UIKit
import VideoToolbox
import CoreMedia
import CoreLocation

// MARK: - 帧队列：满了整体清空并等下一个关键帧，绝不单独丢 P 帧

final class FrameQueue {
    private var items: [Data] = []
    private var waitKey = true
    private let lock = NSLock()
    private let capacity = 8

    /// 返回 false 表示需要立刻要一个关键帧
    func push(_ d: Data, key: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if waitKey && !key { return true }
        if key { waitKey = false }
        if items.count >= capacity {
            items.removeAll()
            if !key { waitKey = true; return false }
        }
        items.append(d)
        return true
    }

    func pop() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    func reset() {
        lock.lock(); items.removeAll(); waitKey = true; lock.unlock()
    }
}

// MARK: - H.264 编码（VideoToolbox，Baseline，关键帧带 SPS/PPS）

final class H264Encoder {
    let queue = FrameQueue()
    private let width: Int, height: Int, fps: Int, bitrate: Int
    private let log: (String) -> Void
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var forceKey = true
    private var lastCreate = Date.distantPast
    private var failures = 0

    init(width: Int, height: Int, fps: Int, bitrate: Int, log: @escaping (String) -> Void) {
        self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate; self.log = log
    }

    func start() { createSession() }

    func stop() {
        lock.lock(); let s = session; session = nil; lock.unlock()
        if let s = s { VTCompressionSessionInvalidate(s) }
        queue.reset()
    }

    func requestKeyFrame() {
        queue.reset()
        lock.lock(); forceKey = true; lock.unlock()
    }

    private func createSession() {
        lastCreate = Date()
        var out: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &out)
        guard st == noErr, let s = out else { log("[enc] 创建编码器失败 \(st)"); return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.0))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(s)
        lock.lock(); session = s; forceKey = true; lock.unlock()
        log("[enc] 编码器就绪 \(width)x\(height) \(fps)fps \(bitrate / 1000)kbps")
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        lock.lock(); let s = session; let fk = forceKey; forceKey = false; lock.unlock()
        guard let sess = s else {
            // 锁屏/后台时系统会收回硬件编码器，每 2 秒尝试重建一次
            if Date().timeIntervalSince(lastCreate) > 2 { createSession() }
            return
        }
        let props: CFDictionary? = fk ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary) : nil
        let st = VTCompressionSessionEncodeFrame(sess, imageBuffer: pb, presentationTimeStamp: pts,
                                                 duration: .invalid, frameProperties: props,
                                                 infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb = sb else { return }
            self?.output(sb)
        }
        if st != noErr {
            failures += 1
            if failures == 1 || failures % 120 == 0 {
                log("[enc] 编码失败 \(st)（锁屏或切到后台时 iOS 会收回硬件编码器）")
            }
            lock.lock(); forceKey = true; lock.unlock()
            if st == kVTInvalidSessionErr {
                lock.lock(); session = nil; lock.unlock()
                VTCompressionSessionInvalidate(sess)
            }
        } else if failures > 0 {
            log("[enc] 编码恢复（之前失败 \(failures) 次）")
            failures = 0
        }
    }

    private func output(_ sb: CMSampleBuffer) {
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as NSArray?,
           let first = arr.firstObject as? NSDictionary,
           let notSync = first.object(forKey: kCMSampleAttachmentKey_NotSync) as? Bool {
            isKey = !notSync
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        let len = CMBlockBufferGetDataLength(bb)
        var avcc = Data(count: len)
        let copied = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: raw.baseAddress!)
        }
        guard copied == noErr else { return }

        var out = Data()
        let startCode = Data([0, 0, 0, 1])
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
                    out.append(startCode)
                    out.append(p, count: size)
                }
            }
        }
        // AVCC（4 字节长度前缀）→ Annex-B（起始码）
        var i = 0
        while i + 4 <= avcc.count {
            let n = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            i += 4
            guard n > 0, i + n <= avcc.count else { break }
            out.append(startCode)
            out.append(avcc[i..<(i + n)])
            i += n
        }
        if !queue.push(out, key: isKey) {
            lock.lock(); forceKey = true; lock.unlock()
        }
    }
}

// MARK: - 仪表画面渲染（CPU 绘制，锁屏时也能画）

final class LegacyDashRenderer {
    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "HH:mm"; return f
    }()
    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE"; return f
    }()
    private let cs = CGColorSpaceCreateDeviceRGB()

    /// ctx 必须是 UIKit 坐标（左上角原点），且已 UIGraphicsPushContext。
    func draw(in ctx: CGContext, size: CGSize, now: Date) {
        let w = size.width, h = size.height, s = min(w, h)

        // 背景
        let bg = CGGradient(colorsSpace: cs, colors: [rgb(10, 16, 28), rgb(18, 26, 40)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: w, y: h), options: [])

        // 占位“地图”：缓慢移动的道路（下一版换成高德地图）
        let shift = CGFloat((now.timeIntervalSinceReferenceDate / 12).truncatingRemainder(dividingBy: 1))
        UIColor(cgColor: rgb(46, 58, 78)).setStroke()
        for i in -1...4 {
            let y = h * (CGFloat(i) + shift) / 3.5
            let p = UIBezierPath()
            p.move(to: CGPoint(x: -50, y: y))
            p.addCurve(to: CGPoint(x: w + 50, y: y),
                       controlPoint1: CGPoint(x: w * 0.3, y: y - h * 0.15),
                       controlPoint2: CGPoint(x: w * 0.6, y: y + h * 0.15))
            p.lineWidth = s * 0.05; p.lineCapStyle = .round; p.stroke()
        }
        let route = UIBezierPath()
        route.move(to: CGPoint(x: w * 0.55, y: h + 20))
        route.addCurve(to: CGPoint(x: w * 0.68, y: h * 0.1),
                       controlPoint1: CGPoint(x: w * 0.5, y: h * 0.7),
                       controlPoint2: CGPoint(x: w * 0.75, y: h * 0.45))
        UIColor(cgColor: rgb(64, 156, 255)).setStroke()
        route.lineWidth = s * 0.035; route.lineCapStyle = .round; route.stroke()

        // 四周暗角，让悬浮元素和地图融为一体
        let vg = CGGradient(colorsSpace: cs, colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.85)] as CFArray,
                            locations: [0, 0.55, 1])!
        let mid = CGPoint(x: w / 2, y: h / 2)
        ctx.drawRadialGradient(vg, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: max(w, h) * 0.75,
                               options: [.drawsAfterEndLocation])

        // 悬浮车速：无边框，底下一团柔和暗区
        let c = CGPoint(x: w * 0.22, y: h * 0.5)
        let sg = CGGradient(colorsSpace: cs, colors: [rgb(0, 0, 0, 0.65), rgb(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(sg, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.42, options: [])
        let speed = LocationService.shared.speedKmh.map { String(Int($0.rounded())) } ?? "--"
        text(speed, CGPoint(x: c.x, y: c.y - s * 0.04), .center, .systemFont(ofSize: s * 0.40, weight: .bold), .white)
        text("km/h", CGPoint(x: c.x, y: c.y + s * 0.2), .center, .systemFont(ofSize: s * 0.08), UIColor(white: 1, alpha: 0.7))

        // 时间日期
        text(timeFmt.string(from: now), CGPoint(x: w - s * 0.06, y: s * 0.13), .right,
             .monospacedDigitSystemFont(ofSize: s * 0.15, weight: .bold), .white)
        text(dateFmt.string(from: now), CGPoint(x: w - s * 0.06, y: s * 0.27), .right,
             .systemFont(ofSize: s * 0.06), UIColor(white: 1, alpha: 0.75))

        // 车况卡片：半透明 + 外发光阴影，边缘融进背景
        let v = VehicleStore.shared.snapshot()
        let r = CGRect(x: w * 0.52, y: h - s * 0.42, width: w * 0.48 - s * 0.05, height: s * 0.34)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.08, color: rgb(0, 0, 0, 0.7))
        UIColor(cgColor: rgb(30, 41, 59, 0.6)).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: s * 0.05).fill()
        ctx.restoreGState()

        let socText = v.soc.map { "\($0)%" } ?? "--%"
        let rangeText = v.rangeKm.map { "\($0) km" } ?? "-- km"
        text(socText, CGPoint(x: r.minX + s * 0.05, y: r.minY + s * 0.1), .left,
             .monospacedDigitSystemFont(ofSize: s * 0.1, weight: .bold), .white)
        text(v.charging ? "充电中" : "续航 \(rangeText)", CGPoint(x: r.maxX - s * 0.05, y: r.minY + s * 0.1), .right,
             .systemFont(ofSize: s * 0.06), UIColor(white: 1, alpha: 0.8))
        let barBg = CGRect(x: r.minX + s * 0.05, y: r.maxY - s * 0.1, width: r.width - s * 0.1, height: s * 0.025)
        UIColor(white: 1, alpha: 0.15).setFill()
        UIBezierPath(roundedRect: barBg, cornerRadius: barBg.height / 2).fill()
        let pct = CGFloat(min(max(v.soc ?? 0, 0), 100)) / 100
        let bar = CGRect(x: barBg.minX, y: barBg.minY, width: barBg.width * pct, height: barBg.height)
        let low = (v.soc ?? 100) <= 20
        UIColor(cgColor: low ? rgb(255, 99, 71) : rgb(52, 211, 153)).setFill()
        UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2).fill()
        if v.soc == nil {
            text("在「车辆」页登录后显示车况", CGPoint(x: r.minX + s * 0.05, y: r.minY + s * 0.2), .left,
                 .systemFont(ofSize: s * 0.045), UIColor(white: 1, alpha: 0.55))
        }
    }

    private enum Align { case left, center, right }

    /// 以 point 为文字的垂直中心绘制
    private func text(_ str: String, _ point: CGPoint, _ align: Align, _ font: UIFont, _ color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (str as NSString).size(withAttributes: attrs)
        var x = point.x
        switch align {
        case .left: break
        case .center: x -= size.width / 2
        case .right: x -= size.width
        }
        (str as NSString).draw(at: CGPoint(x: x, y: point.y - size.height / 2), withAttributes: attrs)
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a).cgColor
    }

    /// App 内预览用
    func previewImage(size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            draw(in: ctx.cgContext, size: size, now: Date())
        }
    }
}

// MARK: - 渲染 → 编码的视频源（自己的定时器驱动，不依赖屏幕刷新）

final class RenderSource: FrameSource {
    private let width: Int, height: Int, fps: Int
    private let encoder: H264Encoder
    private let renderer = DashRenderer()
    private let q = DispatchQueue(label: "dash.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameNo: Int64 = 0

    init(width: Int, height: Int, fps: Int, bitrate: Int, log: @escaping (String) -> Void) {
        self.width = width; self.height = height; self.fps = fps
        encoder = H264Encoder(width: width, height: height, fps: fps, bitrate: bitrate, log: log)
    }

    func start() {
        encoder.start()
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        encoder.stop()
    }

    func requestKeyFrame() { encoder.requestKeyFrame() }

    func popFrame() -> Data? { encoder.queue.pop() }

    private func tick() {
        guard let pool = pool else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            renderer.draw(in: ctx, size: CGSize(width: width, height: height), now: Date())
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        frameNo += 1
        encoder.encode(pb, pts: CMTime(value: frameNo, timescale: CMTimeScale(fps)))
    }
}

// MARK: - GPS 车速（开了后台定位，锁屏后进程也能继续跑）

final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var speed: Double = -1
    private var at = Date.distantPast
    private var _last: CLLocation?

    var lastLocation: CLLocation? { lock.lock(); defer { lock.unlock() }; return _last }

    var speedKmh: Double? {
        lock.lock(); defer { lock.unlock() }
        return (speed >= 0 && Date().timeIntervalSince(at) < 5) ? speed : nil
    }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.requestWhenInUseAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        lock.lock()
        speed = l.speed >= 0 ? l.speed * 3.6 : -1
        at = Date()
        _last = l
        lock.unlock()
    }
}
