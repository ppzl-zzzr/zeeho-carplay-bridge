import Foundation
import CryptoKit

// MARK: - 签名（纯原生复刻，已对照开源 JS 与 Node/Python 验证一致）

enum ZeehoSign {
    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 参数序列化：去空 → key 升序 → "k=v"（值不转义）→ "&" 连接
    static func toQuery(_ params: [String: String]) -> String {
        params.filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }

    static func nonce() -> String {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var r = ""
        for _ in 0..<16 { r.append(ZeehoSecrets.nonceCharset.randomElement()!) }
        return "\(ts)\(r)"
    }

    struct Signed { let param: String; let sign: String }

    /// query：GET 查询串（已 toQuery）；body：POST 原始 JSON 串
    static func make(query: String, body: String, nonce: String, ts: Int64) -> Signed {
        let param = "appId=\(ZeehoSecrets.appId)&nonce=\(nonce)&timestamp=\(ts)"
        let source = query + body + param + ZeehoSecrets.appSecret
        return Signed(param: param, sign: md5Hex(sha1Hex(source)))
    }
}

// MARK: - 模型

struct ZeehoVehicle: Identifiable, Codable {
    let vin: String
    var name: String
    var id: String { vin }
}

struct ZeehoStatus {
    var soc: Int?
    var rangeKm: Int?
    var voltage: Double?
    var charging = false
    var locked: Bool?
    var online: Bool?
    var totalMileage: Double?
    var latitude: Double?
    var longitude: Double?
    var updatedAt: Date?
    /// 投屏资料（vehicleHomePageV2 的 encryptInfo，用于免扫码连接仪表）
    var castSSID: String?
    var castPassword: String?
}

enum ZeehoError: LocalizedError {
    case http(Int, String)
    case message(String)
    case notLoggedIn
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "HTTP \(c) \(m)"
        case .message(let m): return m
        case .notLoggedIn: return "未登录"
        }
    }
}

// MARK: - 账号 / 接口客户端

@MainActor
final class ZeehoAccount: ObservableObject {
    static let shared = ZeehoAccount()

    @Published var token: String? = UserDefaults.standard.string(forKey: "zeehoToken")
    @Published var vehicles: [ZeehoVehicle] = []
    @Published var currentVin: String? = UserDefaults.standard.string(forKey: "zeehoVin")
    @Published var status = ZeehoStatus()
    @Published var busy = false
    @Published var lastError: String?

    var isLoggedIn: Bool { token?.isEmpty == false }
    var log: (String) -> Void = { _ in }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: 请求底座

    private func request(path: String, method: String = "GET",
                         query: [String: String] = [:], bodyObject: [String: Any]? = nil,
                         authed: Bool = true) async throws -> [String: Any] {
        var urlStr = ZeehoSecrets.base + path
        let q = ZeehoSign.toQuery(query)
        if method == "GET", !q.isEmpty { urlStr += "?" + q }
        guard let url = URL(string: urlStr) else { throw ZeehoError.message("URL 无效") }

        var bodyStr = ""
        if let obj = bodyObject {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [])
            bodyStr = String(data: data, encoding: .utf8) ?? ""
        }
        let nonce = ZeehoSign.nonce()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        // GET 的签名 payload 用查询串；POST 用请求体
        let signed = ZeehoSign.make(query: method == "GET" ? q : "", body: bodyStr, nonce: nonce, ts: ts)

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        req.setValue("2", forHTTPHeaderField: "interfaceversion")
        req.setValue(signed.param, forHTTPHeaderField: "cfmoto-x-param")
        req.setValue(signed.sign, forHTTPHeaderField: "cfmoto-x-sign")
        req.setValue("0", forHTTPHeaderField: "cfmoto-x-sign-type")
        req.setValue(ZeehoSecrets.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(ZeehoSecrets.appInfo, forHTTPHeaderField: "x-app-info")
        if authed, let t = token, !t.isEmpty {
            req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(ZeehoSecrets.basicAuth, forHTTPHeaderField: "Authorization")
        }
        if !bodyStr.isEmpty { req.httpBody = Data(bodyStr.utf8) }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard code == 200 else { throw ZeehoError.http(code, String(text.prefix(200))) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ZeehoError.message("返回不是 JSON")
        }
        // 极核统一响应：{ code/respCode, msg, data/result }
        let biz = (json["code"] as? Int) ?? (json["respCode"] as? Int) ?? Int(json["code"] as? String ?? "0") ?? 0
        if biz != 0 && biz != 200 {
            let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? "业务失败(\(biz))"
            throw ZeehoError.message(msg)
        }
        return json
    }

    private func dataDict(_ json: [String: Any]) -> [String: Any] {
        (json["data"] as? [String: Any]) ?? (json["result"] as? [String: Any]) ?? json
    }

    // MARK: 登录

    func sendCode(phone: String, areaCode: String = "86") async -> Bool {
        await run {
            _ = try await self.request(path: "/v1.0/mine/cfmotoservermine/authCode/V2",
                                       query: ["phone": phone, "areaCode": areaCode], authed: false)
            self.log("[账号] 验证码已发送到 \(phone)")
        }
    }

    func login(phone: String, code: String, areaCode: String = "86") async -> Bool {
        await run {
            let json = try await self.request(path: "/v1.0/mine/cfmotoservermine/user/loginByPhone",
                                              method: "POST",
                                              bodyObject: ["phone": phone, "areaCode": areaCode, "authCode": code],
                                              authed: false)
            let d = self.dataDict(json)
            guard let t = (d["token"] as? String) ?? (d["accessToken"] as? String), !t.isEmpty else {
                throw ZeehoError.message("登录返回里没有 token")
            }
            self.token = t
            UserDefaults.standard.set(t, forKey: "zeehoToken")
            self.log("[账号] 登录成功")
            try await self.loadVehicles()
        }
    }

    func loginWithToken(_ t: String) async -> Bool {
        token = t.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(token, forKey: "zeehoToken")
        return await run { try await self.loadVehicles() }
    }

    func logout() {
        token = nil; vehicles = []; currentVin = nil; status = ZeehoStatus()
        UserDefaults.standard.removeObject(forKey: "zeehoToken")
        UserDefaults.standard.removeObject(forKey: "zeehoVin")
    }

    // MARK: 车辆 / 车况

    func loadVehicles() async throws {
        let json = try await request(path: "/v1.0/app/cfmotoserverapp/vehicle/list")
        let arr = (json["data"] as? [[String: Any]]) ?? (dataDict(json)["list"] as? [[String: Any]]) ?? []
        vehicles = arr.compactMap { v in
            guard let vin = (v["vin"] as? String) ?? (v["vinNo"] as? String) else { return nil }
            let name = (v["vehicleName"] as? String) ?? (v["name"] as? String) ?? (v["modelName"] as? String) ?? vin
            return ZeehoVehicle(vin: vin, name: name)
        }
        if currentVin == nil || !vehicles.contains(where: { $0.vin == currentVin }) {
            currentVin = vehicles.first?.vin
        }
        UserDefaults.standard.set(currentVin, forKey: "zeehoVin")
        if currentVin != nil { try await refreshStatus() }
    }

    func selectVehicle(_ vin: String) {
        currentVin = vin
        UserDefaults.standard.set(vin, forKey: "zeehoVin")
        Task { _ = await run { try await self.refreshStatus() } }
    }

    func refreshStatus() async throws {
        guard let vin = currentVin else { return }
        var st = status
        // 首页（含投屏资料）
        if let json = try? await request(path: "/v1.0/app/cfmotoserverapp/vehicleHomePageV2/\(vin)") {
            let d = dataDict(json)
            st.online = (d["onlineStatus"] as? Int).map { $0 == 1 } ?? (d["online"] as? Bool)
            st.totalMileage = doubleOf(d["totalMileage"] ?? d["mileage"])
            if let lock = d["lockStatus"] ?? d["vcuLockStatus"] { st.locked = intOf(lock).map { $0 == 1 } }
            if let lat = doubleOf(d["latitude"]), let lon = doubleOf(d["longitude"]) { st.latitude = lat; st.longitude = lon }
            // 投屏资料 encryptInfo
            if let enc = d["encryptInfo"] as? [String: Any] {
                st.castSSID = enc["ssid"] as? String ?? enc["wifiName"] as? String
                st.castPassword = enc["pwd"] as? String ?? enc["password"] as? String
            }
        }
        // 电池
        if let json = try? await request(path: "/v1.0/app/cfmotoserverapp/batteryInfo/\(vin)") {
            let d = dataDict(json)
            st.soc = intOf(d["bmssoc"] ?? d["batteryLevel"] ?? d["soc"])
            st.rangeKm = intOf(d["hmiRidableMile"] ?? d["ridableMile"] ?? d["remainMileage"])
            st.voltage = doubleOf(d["voltage"] ?? d["bmsVoltage"])
            st.charging = (intOf(d["chargeState"]) ?? 0) != 0 || (d["whetherChargeState"] as? Bool ?? false)
        }
        st.updatedAt = Date()
        status = st
        // 同步到仪表界面
        VehicleStore.shared.override = VehicleStore.Snapshot(
            soc: st.soc, rangeKm: st.rangeKm, charging: st.charging, voltage: st.voltage, updatedAt: st.updatedAt)
    }

    // MARK: 车控

    /// 高声寻车
    func findVehicle() async -> Bool { await control(["command": "lightAndWhistleHigh"]) }
    /// 打开坐垫
    func openSeat() async -> Bool { await control(["command": "openSaddle"]) }
    /// 开/关锁（关锁 lockFlag=0；开锁 lockFlag=1，部分车型开锁还需云解锁，一次成功不保证）
    func setLock(_ locked: Bool) async -> Bool {
        await control(["command": "ON_AND_OFF", "lockFlag": locked ? 0 : 1])
    }

    private func control(_ body: [String: Any]) async -> Bool {
        guard let vin = currentVin else { lastError = "未选择车辆"; return false }
        var b = body; b["vin"] = vin
        return await run {
            _ = try await self.request(path: "/v1.0/app/cfmotoserverapp/vehicleInfo/controlV2",
                                       method: "POST", bodyObject: b)
            self.log("[车控] 指令已发送：\(body["command"] ?? "")")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? await self.refreshStatus()
        }
    }

    // MARK: 工具

    @discardableResult
    private func run(_ op: @escaping () async throws -> Void) async -> Bool {
        busy = true; lastError = nil
        defer { busy = false }
        do { try await op(); return true }
        catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = msg; log("[账号] 失败：\(msg)")
            if case ZeehoError.http(401, _) = error { logout() }
            return false
        }
    }

    private func intOf(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(Double(s) ?? .nan) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
    private func doubleOf(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
