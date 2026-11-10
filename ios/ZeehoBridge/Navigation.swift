import AMapFoundationKit
import AMapNaviKit
import AMapSearchKit
import CoreLocation
import Foundation

/// 常规（汽车）导航：高德搜索 + 驾车算路 + 逐向导航 + 内置语音。仅仪表版使用。
final class NavService: NSObject, ObservableObject {
    static let shared = NavService()

    struct Place: Identifiable {
        let id = UUID()
        let name: String
        let address: String
        let lat: Double
        let lon: Double
        let distance: Int
    }

    /// 渲染线程读取的导航快照
    struct Snapshot {
        var active = false
        var icon = 0
        var segmentDistance = 0
        var nextRoad = ""
        var remainDistance = 0
        var remainTime = 0
        var route: [CLLocationCoordinate2D] = []   // GCJ-02
    }

    @Published var results: [Place] = []
    @Published var searching = false
    @Published var active = false
    @Published var status = ""

    var log: (String) -> Void = { _ in }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var search: AMapSearchAPI?
    private var pendingEmulate = false
    private var configured = false

    func snapshot() -> Snapshot { lock.withLock { snap } }

    /// 设置 Key 和隐私合规（高德要求先声明已展示并同意隐私政策）
    private func configure() -> Bool {
        if configured { return true }
        let key = (Bundle.main.object(forInfoDictionaryKey: "AMapApiKey") as? String) ?? ""
        guard !key.isEmpty, !key.hasPrefix("$(") else {
            setStatus("没有高德 Key，导航不可用")
            return false
        }
        AMapServices.shared().apiKey = key
        AMapServices.shared().enableHTTPS = true
        AMapNaviManagerConfig.shared().updatePrivacyShow(.didShow, privacyInfo: .didContain)
        AMapNaviManagerConfig.shared().updatePrivacyAgree(.didAgree)
        AMapSearchAPI.updatePrivacyShow(.didShow, privacyInfo: .didContain)
        AMapSearchAPI.updatePrivacyAgree(.didAgree)
        let s = AMapSearchAPI()
        s?.delegate = self
        search = s
        let d = AMapNaviDriveManager.sharedInstance()
        d.delegate = self
        d.addDataRepresentative(self)
        d.allowsBackgroundLocationUpdates = true
        d.pausesLocationUpdatesAutomatically = false
        d.isUseInternalTTS = true
        configured = true
        return true
    }

    // MARK: 搜索

    func searchPlaces(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, configure(), let s = search else { return }
        let req = AMapPOIKeywordsSearchRequest()
        req.keywords = kw
        req.offset = 15
        if let loc = LocationService.shared.lastLocation {
            let g = Geo.wgs84ToGcj02(loc.coordinate)
            req.location = AMapGeoPoint.location(withLatitude: CGFloat(g.latitude), longitude: CGFloat(g.longitude))
            req.sortrule = 0
        }
        searching = true
        setStatus("正在搜索「\(kw)」…")
        s.aMapPOIKeywordsSearch(req)
    }

    // MARK: 导航

    func navigate(to p: Place, emulate: Bool) {
        guard configure() else { return }
        pendingEmulate = emulate
        setStatus("正在规划路线到「\(p.name)」…")
        let end: AMapNaviPoint = AMapNaviPoint.location(withLatitude: CGFloat(p.lat), longitude: CGFloat(p.lon))
        let ok = AMapNaviDriveManager.sharedInstance().calculateDriveRoute(withEnd: [end], wayPoints: nil,
                                                                          drivingStrategy: .singleDefault)
        if !ok { setStatus("算路请求失败") }
    }

    func stop() {
        AMapNaviDriveManager.sharedInstance().stopNavi()
        lock.withLock { snap = Snapshot() }
        DispatchQueue.main.async { self.active = false }
        setStatus("导航已结束")
    }

    private func setStatus(_ s: String) {
        log("[导航] \(s)")
        DispatchQueue.main.async { self.status = s }
    }

    private func updateRoute(_ d: AMapNaviDriveManager) {
        let pts = (d.naviRoute?.routeCoordinates ?? []).map {
            CLLocationCoordinate2D(latitude: Double($0.latitude), longitude: Double($0.longitude))
        }
        lock.withLock { snap.route = pts }
    }
}

// MARK: - 搜索回调

extension NavService: AMapSearchDelegate {
    func onPOISearchDone(_ request: AMapPOISearchBaseRequest!, response: AMapPOISearchResponse!) {
        let pois = response?.pois ?? []
        let list = pois.compactMap { p -> Place? in
            guard let loc = p.location else { return nil }
            return Place(name: p.name ?? "", address: p.address ?? "", lat: Double(loc.latitude),
                         lon: Double(loc.longitude), distance: p.distance)
        }
        DispatchQueue.main.async {
            self.results = list
            self.searching = false
        }
        setStatus(list.isEmpty ? "没有搜到结果" : "找到 \(list.count) 个地点")
    }

    func aMapSearchRequest(_ request: Any!, didFailWithError error: Error!) {
        DispatchQueue.main.async { self.searching = false }
        setStatus("搜索失败：\(error?.localizedDescription ?? "未知错误")")
    }
}

// MARK: - 导航回调

extension NavService: AMapNaviDriveManagerDelegate, AMapNaviDriveDataRepresentable {
    func driveManager(onCalculateRouteSuccess driveManager: AMapNaviDriveManager) {
        routeReady(driveManager)
    }

    func driveManager(_ driveManager: AMapNaviDriveManager, onCalculateRouteSuccessWith type: AMapNaviRoutePlanType) {
        routeReady(driveManager)
    }

    private func routeReady(_ d: AMapNaviDriveManager) {
        guard !lock.withLock({ snap.active }) else { return }
        updateRoute(d)
        lock.withLock { snap.active = true }
        DispatchQueue.main.async { self.active = true }
        let ok = pendingEmulate ? d.startEmulatorNavi() : d.startGPSNavi()
        setStatus(ok ? (pendingEmulate ? "模拟导航中" : "导航中") : "启动导航失败")
    }

    func driveManager(_ driveManager: AMapNaviDriveManager, onCalculateRouteFailure error: Error) {
        setStatus("路线规划失败：\(error.localizedDescription)")
    }

    func driveManager(_ driveManager: AMapNaviDriveManager, update naviInfo: AMapNaviInfo?) {
        guard let i = naviInfo else { return }
        lock.withLock {
            snap.icon = i.iconType.rawValue
            snap.segmentDistance = i.segmentRemainDistance
            snap.nextRoad = i.nextRoadName ?? ""
            snap.remainDistance = i.routeRemainDistance
            snap.remainTime = i.routeRemainTime
        }
    }

    func driveManager(_ driveManager: AMapNaviDriveManager, update naviRoute: AMapNaviRoute?) {
        updateRoute(driveManager)
    }

    func driveManager(_ driveManager: AMapNaviDriveManager, playNaviSound soundString: String?,
                      soundStringType: AMapNaviSoundType) {}

    func driveManagerIsNaviSoundPlaying(_ driveManager: AMapNaviDriveManager) -> Bool { false }

    func driveManager(onArrivedDestination driveManager: AMapNaviDriveManager) {
        setStatus("已到达目的地")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.stop() }
    }
}

// MARK: - 坐标转换

enum Geo {
    /// GPS（WGS-84）→ 国测局（GCJ-02）。国内 MapKit 和高德都用 GCJ-02。
    static func wgs84ToGcj02(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = c.latitude, lon = c.longitude
        guard lon > 72.004, lon < 137.8347, lat > 0.8293, lat < 55.8271 else { return c }
        let a = 6378245.0, ee = 0.00669342162296594323
        func tLat(_ x: Double, _ y: Double) -> Double {
            var r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
            r += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
            r += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
            r += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
            return r
        }
        func tLon(_ x: Double, _ y: Double) -> Double {
            var r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
            r += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
            r += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
            r += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
            return r
        }
        var dLat = tLat(lon - 105.0, lat - 35.0), dLon = tLon(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat); magic = 1 - ee * magic * magic
        let sq = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sq) * .pi)
        dLon = (dLon * 180.0) / (a / sq * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon)
    }
}
