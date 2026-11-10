import Foundation
import Combine

/// 车况快照（仪表界面读取）。由 ZeehoAccount 调接口后写入。
final class VehicleStore: ObservableObject {
    static let shared = VehicleStore()

    struct Snapshot {
        var soc: Int?
        var rangeKm: Int?
        var charging = false
        var voltage: Double?
        var updatedAt: Date?
    }

    private let lock = NSLock()
    private var snap = Snapshot()

    /// 演示模式 / 接口写入都走这里
    var override: Snapshot? {
        get { lock.lock(); defer { lock.unlock() }; return _override }
        set { lock.lock(); _override = newValue; lock.unlock(); DispatchQueue.main.async { self.objectWillChange.send() } }
    }
    private var _override: Snapshot?

    /// 渲染线程调用
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return _override ?? snap
    }
}
