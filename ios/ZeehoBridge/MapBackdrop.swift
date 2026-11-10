import Foundation
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
        let want = CGSize(width: max(canvas.width / 2, 320), height: max(canvas.height / 2, 160))
        if want != size { size = want; lastShot = .distantPast }
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
            opts.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            // 车在画面偏下方，前方路况看得更远
            opts.camera = MKMapCamera(lookingAtCenter: Self.ahead(of: loc.coordinate, heading: heading, meters: 140),
                                      fromDistance: 650, pitch: 62, heading: heading)
            MKMapSnapshotter(options: opts).start(with: .global(qos: .utility)) { [weak self] snap, _ in
                guard let self = self else { return }
                self.lock.lock()
                if let img = snap?.image { self.image = img }
                self.lastCenter = loc.coordinate
                self.lastHeading = heading
                self.busy = false
                self.lock.unlock()
            }
        }
    }

    private static func ahead(of c: CLLocationCoordinate2D, heading: CLLocationDirection, meters: Double) -> CLLocationCoordinate2D {
        let r = heading * .pi / 180
        let dLat = meters * cos(r) / 111_000
        let dLon = meters * sin(r) / (111_000 * max(cos(c.latitude * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}
