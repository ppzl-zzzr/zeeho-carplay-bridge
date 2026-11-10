import Foundation
import CoreImage
import MapKit
import UIKit

/// 仪表底图：用 MapKit 的暗色 3D 快照（国内 MapKit 的数据来自高德，不需要 Key）。
/// 每隔几秒按当前 GPS 位置和朝向重新拍一张，渲染线程直接取最新一张铺底。
/// 以后接入高德 SDK 时，只要替换这里即可。
final class MapBackdrop {
    static let shared = MapBackdrop()

    private let lock = NSLock()
    private var image: UIImage?
    private var size = CGSize(width: 1024, height: 480)
    private var busy = false
    private var lastCenter: CLLocationCoordinate2D?
    private var lastHeading: CLLocationDirection = 0
    private var lastShot = Date.distantPast

    /// 渲染线程调用：返回最新底图（可能为空）
    func current(for canvas: CGSize) -> UIImage? {
        lock.lock()
        // 快照按画布一半分辨率拍，省电；绘制时拉伸
        // 只在画布变大时才换尺寸，避免预览和投屏两种尺寸来回切换导致反复重拍
        let want = CGSize(width: max(canvas.width / 2, 512), height: max(canvas.height / 2, 240))
        if want.width > size.width + 1 { size = want; lastShot = .distantPast }
        let img = image
        lock.unlock()
        refreshIfNeeded()
        return img
    }

    private func refreshIfNeeded() {
        guard let loc = LocationService.shared.lastLocation else { return }
        lock.lock()
        let moved = lastCenter.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc) } ?? .infinity
        let heading = loc.course >= 0 ? loc.course : lastHeading
        let turned = abs(heading - lastHeading) > 8
        let stale = Date().timeIntervalSince(lastShot) > 6
        guard !busy, moved > 25 || turned || stale else { lock.unlock(); return }
        busy = true
        lastShot = Date()
        let shotSize = size
        lock.unlock()

        DispatchQueue.main.async {
            let opts = MKMapSnapshotter.Options()
            opts.size = shotSize
            opts.scale = 1
            opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            opts.pointOfInterestFilter = .excludingAll
            let conf = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            conf.pointOfInterestFilter = .excludingAll   // 不要商家/酒店等 POI，画面更干净
            conf.showsTraffic = false
            opts.preferredConfiguration = conf
            // 车在画面偏下方，前方路况看得更远
            opts.camera = MKMapCamera(lookingAtCenter: Self.ahead(of: loc.coordinate, heading: heading, meters: 140),
                                      fromDistance: 650, pitch: 62, heading: heading)
            MKMapSnapshotter(options: opts).start(with: .global(qos: .utility)) { [weak self] snap, _ in
                guard let self = self else { return }
                let blurred = snap.flatMap { Self.blur($0.image) }
                self.lock.lock()
                if let img = snap?.image { self.image = img }
                if let b = blurred { self.blurredImage = b }
                self.lastCenter = loc.coordinate
                self.lastHeading = heading
                self.busy = false
                self.lock.unlock()
            }
        }
    }

    private var blurredImage: UIImage?
    /// 同一张地图的高斯模糊版（媒体卡的毛玻璃背景用）
    var blurred: UIImage? { lock.lock(); defer { lock.unlock() }; return blurredImage }

    /// 软件渲染，锁屏/后台也能用
    static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    private static func blur(_ img: UIImage) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(26, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage?.cropped(to: input.extent),
              let res = ciContext.createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: res)
    }

    /// 地图按“铺满画布”方式绘制时所占的矩形
    static func fillRect(image: CGSize, canvas: CGSize) -> CGRect {
        let s = max(canvas.width / image.width, canvas.height / image.height)
        let w = image.width * s, h = image.height * s
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    private static func ahead(of c: CLLocationCoordinate2D, heading: CLLocationDirection, meters: Double) -> CLLocationCoordinate2D {
        let r = heading * .pi / 180
        let dLat = meters * cos(r) / 111_000
        let dLon = meters * sin(r) / (111_000 * max(cos(c.latitude * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}
