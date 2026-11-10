import Foundation
import Network
import Security
import UIKit

// MARK: - 配置与接口

struct DashConfig {
    /// 握手时报给仪表的“官方 App 包名”。极核官方 App 是 com.cfmoto。
    var spoofPackage = "com.cfmoto"
    var phoneType = "Android"
    var versionCode = 126
    var bluetoothName = "ZeehoBridge"
    var bitrate = 2_000_000
    var fps = 24
}

/// 视频来源：输出 H.264 Annex-B 访问单元，关键帧前带 SPS/PPS。
protocol FrameSource: AnyObject {
    func start()
    func stop()
    func requestKeyFrame()
    func popFrame() -> Data?
}

enum DashError: Error, CustomStringConvertible {
    case closed, timeout, bad(String)
    var description: String {
        switch self {
        case .closed: return "连接已关闭"
        case .timeout: return "超时"
        case .bad(let s): return s
        }
    }
}

// MARK: - 字节工具（协议全部小端）

extension Data {
    func le16(_ o: Int) -> Int {
        Int(self[startIndex + o]) | (Int(self[startIndex + o + 1]) << 8)
    }
    func le32(_ o: Int) -> Int32 {
        var u: UInt32 = 0
        for i in 0..<4 { u |= UInt32(self[startIndex + o + i]) << (8 * UInt32(i)) }
        return Int32(bitPattern: u)
    }
    mutating func putLE16(_ v: Int) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func putLE32(_ v: Int32) {
        let u = UInt32(bitPattern: v)
        for i in 0..<4 { append(UInt8(truncatingIfNeeded: u >> (8 * UInt32(i)))) }
    }
    var utf8Text: String { String(data: self, encoding: .utf8) ?? "" }
}

enum Cmd {
    static let chCarCtrl: Int32 = 0x10000
    static let chCarData: Int32 = 0x20000
    static let mdnsRespond: Int32 = 0x70000010
    static let mdnsRespondAck: Int32 = 0x70000011
    static let heartbeat: Int32 = 0x70000000
    static let heartbeatAck: Int32 = 0x70000001
    static let clientInfo: Int32 = 0x10010
    static let clientInfoRly: Int32 = 0x10011
    static let checkSn: Int32 = 0x103e0
    static let checkSnResult: Int32 = 0x201c0
    static let huTimeSync: Int32 = 0x10600
}

/// 控制面帧：cmd | totalLen | cmd^totalLen | 0 | payload
func ctrlFrame(_ cmd: Int32, _ payload: Data = Data()) -> Data {
    let total = Int32(16 + payload.count)
    var d = Data()
    d.putLE32(cmd); d.putLE32(total); d.putLE32(cmd ^ total); d.putLE32(0)
    d.append(payload)
    return d
}

/// 媒体面帧：cmdType(16) | len(16) | token(32) | body
func mediaFrame(_ type: Int, _ body: Data = Data()) -> Data {
    var d = Data()
    d.putLE16(type); d.putLE16(body.count); d.putLE32(0)
    d.append(body)
    return d
}

func hex(_ v: Int32) -> String { "0x" + String(UInt32(bitPattern: v), radix: 16) }

// MARK: - TCP 连接封装

final class Conn {
    let nw: NWConnection
    private let lock = NSLock()
    private var _alive = true
    var alive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _alive }
        set { lock.lock(); _alive = newValue; lock.unlock() }
    }

    init(_ nw: NWConnection) { self.nw = nw }

    func send(_ d: Data) {
        nw.send(content: d, completion: .contentProcessed { _ in })
    }

    func read(_ n: Int) async throws -> Data {
        var buf = Data()
        while buf.count < n {
            let want = n - buf.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                nw.receive(minimumIncompleteLength: 1, maximumLength: want) { data, _, done, err in
                    if let err = err {
                        cont.resume(throwing: err)
                    } else if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if done {
                        cont.resume(throwing: DashError.closed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            buf.append(chunk)
        }
        return buf
    }

    func readCtrl() async throws -> (cmd: Int32, payload: Data) {
        let h = try await read(16)
        let cmd = h.le32(0), total = h.le32(4), magic = h.le32(8)
        guard (cmd ^ total) == magic else { throw DashError.bad("控制帧校验失败 \(hex(cmd))") }
        let len = max(0, Int(total) - 16)
        guard len < 4_000_000 else { throw DashError.bad("控制帧过大") }
        var payload = Data()
        if len > 0 { payload = try await read(len) }
        return (cmd, payload)
    }

    func readMedia() async throws -> (type: Int, body: Data) {
        let h = try await read(8)
        let type = Int(Int16(truncatingIfNeeded: h.le16(0)))
        let len = h.le16(2)
        var body = Data()
        if len > 0 { body = try await read(len) }
        return (type, body)
    }
}

final class Once {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; f() }
    }
}

// MARK: - RSA 身份（公钥放进 CLIENT_INFO，HUID 用私钥签名）

enum RsaIdentity {
    static let privateKey: SecKey? = {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        return SecKeyCreateRandomKey(attrs as CFDictionary, nil)
    }()

    /// X.509 SubjectPublicKeyInfo（与 Java 的 publicKey.encoded 相同格式）
    static let publicKeyBase64: String = {
        guard let priv = privateKey, let pub = SecKeyCopyPublicKey(priv),
              let raw = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { return "" }
        let header: [UInt8] = [0x30, 0x81, 0x9F, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7,
                               0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x81, 0x8D, 0x00]
        return (Data(header) + raw).base64EncodedString()
    }()

    static func signHuid(_ huid: String) -> String {
        guard let priv = privateKey,
              let sig = SecKeyCreateSignature(priv, .rsaSignatureDigestPKCS1v15Raw, Data(huid.utf8) as CFData, nil) as Data?
        else { return "" }
        return sig.base64EncodedString()
    }
}

// MARK: - 网络工具

enum NetUtil {
    /// WiFi（en0）的 IPv4 地址与掩码（主机字节序）
    static func wifiIPv4() -> (ip: UInt32, mask: UInt32)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == "en0", let nm = ifa.ifa_netmask {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                return (ip, mask)
            }
            p = ifa.ifa_next
        }
        return nil
    }

    static func str(_ v: UInt32) -> String {
        "\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }

    static func localIP() -> String? { wifiIPv4().map { str($0.ip) } }

    /// 仪表热点里网关一般是子网第一个地址（AP 模式 192.168.0.1，WiFi 直连 192.168.49.1）
    static func gateway() -> String? {
        guard let a = wifiIPv4() else { return nil }
        return str((a.ip & a.mask) &+ 1)
    }
}

// MARK: - 投屏会话

/// 与 MotoPlay（Carbit EasyConn / PXC）仪表的一次投屏会话。
/// 手机先在系统设置里连上仪表热点；本机在 10920/10921/10922 监听（手机是服务端），
/// 探测仪表 :10930 后仪表回连，10922 握手，10921 协商画布，10920 由仪表逐帧拉取 H.264。
final class DashSession {
    var onLog: (String) -> Void = { _ in }
    var onState: (String) -> Void = { _ in }
    var onCanvas: (Int, Int) -> Void = { _, _ in }

    private let config: DashConfig
    private let sourceFactory: (Int, Int) -> FrameSource
    private let q = DispatchQueue(label: "dash.net")
    private let lock = NSLock()
    private let phoneUUID = UUID().uuidString

    private var running = false
    private var listeners: [NWListener] = []
    private var conns: [Conn] = []
    private var live = 0
    private var canvasW = 0
    private var canvasH = 0
    private var source: FrameSource?
    private var framesSent = 0

    init(config: DashConfig, sourceFactory: @escaping (Int, Int) -> FrameSource) {
        self.config = config
        self.sourceFactory = sourceFactory
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    private var isRunning: Bool { locked { running } }
    private var liveCount: Int { locked { live } }

    func start(manualIP: String?) {
        locked { running = true }
        Task.detached { [weak self] in await self?.runMain(manualIP: manualIP) }
    }

    func stop() {
        let (ls, cs): ([NWListener], [Conn]) = locked {
            running = false
            let r = (listeners, conns)
            listeners = []; conns = []
            return r
        }
        ls.forEach { $0.cancel() }
        cs.forEach { $0.alive = false; $0.nw.cancel() }
        stopSource()
        onState("已停止")
    }

    // MARK: 主流程

    private func runMain(manualIP: String?) async {
        onState("等待仪表热点")
        var host: String?
        while isRunning && host == nil {
            if let ip = manualIP?.trimmingCharacters(in: .whitespaces), !ip.isEmpty {
                host = ip
            } else {
                host = NetUtil.gateway()
            }
            if host == nil {
                onLog("没检测到 WiFi，请先在系统设置里连上仪表热点")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        guard isRunning, let dash = host else { return }
        onLog("仪表地址 \(dash)，本机 \(NetUtil.localIP() ?? "?")")

        for port: UInt16 in [10920, 10921, 10922] {
            do { try openListener(port) } catch {
                onLog("!! 无法监听 \(port)：\(error)")
                onState("出错：端口被占用")
                return
            }
        }

        var attempt = 0
        while isRunning {
            if liveCount > 0 {
                attempt = 0
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            attempt += 1
            onState("探测仪表（第 \(attempt) 次）")
            if await probe(dash) {
                onState("等待仪表回连")
                let deadline = Date().addingTimeInterval(10)
                while isRunning && liveCount == 0 && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if liveCount == 0 { onLog("仪表接受了探测但 10 秒内没有回连，重试") }
            } else {
                try? await Task.sleep(nanoseconds: UInt64(min(attempt, 5)) * 1_000_000_000)
            }
        }
    }

    private func openListener(_ port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] nw in self?.accept(nw, port: port) }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.onLog("[:\(port)] 监听失败：\(e)") }
        }
        l.start(queue: q)
        locked { listeners.append(l) }
    }

    private func accept(_ nw: NWConnection, port: UInt16) {
        let c = Conn(nw)
        locked { conns.append(c); live += 1 }
        onLog("[:\(port)] 仪表已连接 \(nw.endpoint)")
        nw.start(queue: q)
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                if port == 10922 { try await self.ctrlLoop(c) } else { try await self.mediaLoop(c, port: port) }
            } catch {
                if self.isRunning { self.onLog("[:\(port)] 连接结束：\(error)") }
            }
            c.alive = false
            nw.cancel()
            let left: Int = self.locked {
                self.conns.removeAll { $0 === c }
                self.live -= 1
                return self.live
            }
            if left == 0 && self.isRunning {
                self.onLog("仪表连接全部断开，准备重新探测")
                self.stopSource()
                self.locked { self.canvasW = 0; self.canvasH = 0 }
            }
        }
    }

    private func waitReady(_ nw: NWConnection, timeout: Double) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            nw.stateUpdateHandler = { st in
                switch st {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                case .waiting(let e): once.run { cont.resume(throwing: e) }
                case .cancelled: once.run { cont.resume(throwing: DashError.closed) }
                default: break
                }
            }
            nw.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { once.run { cont.resume(throwing: DashError.timeout) } }
        }
    }

    private func probe(_ host: String) async -> Bool {
        let nw = NWConnection(host: NWEndpoint.Host(host), port: 10930, using: .tcp)
        let c = Conn(nw)
        defer { nw.cancel() }
        do {
            try await waitReady(nw, timeout: 3)
            let body: [String: Any] = ["phoneType": config.phoneType, "packageName": config.spoofPackage]
            let json = try JSONSerialization.data(withJSONObject: body)
            onLog("[probe] → \(host):10930 \(json.utf8Text)")
            c.send(ctrlFrame(Cmd.mdnsRespond, json))
            let r = try await c.readCtrl()
            let ok = r.cmd == Cmd.mdnsRespondAck && r.payload.utf8Text.contains("true")
            onLog("[probe] ← \(hex(r.cmd)) \(r.payload.utf8Text) \(ok ? "（已接受）" : "（未接受）")")
            if !ok { onLog("提示：仪表拒绝了探测，可以试试改握手包名") }
            return ok
        } catch {
            onLog("[probe] 失败：\(error)")
            return false
        }
    }

    // MARK: 控制面（10922）

    private func ctrlLoop(_ c: Conn) async throws {
        var first = true
        while isRunning {
            let f = try await c.readCtrl()
            if first {
                first = false
                if f.cmd != Cmd.chCarCtrl && f.cmd != Cmd.chCarData {
                    onLog("⚠ 第一帧 \(hex(f.cmd)) 不是标准通道选择，这台仪表可能用了变体协议，请保存日志")
                }
            }
            handleCtrl(f.cmd, f.payload, c)
        }
    }

    private func handleCtrl(_ cmd: Int32, _ payload: Data, _ c: Conn) {
        switch cmd {
        case Cmd.chCarCtrl, Cmd.chCarData:
            let name = cmd == Cmd.chCarCtrl ? "CAR_CTRL" : "CAR_DATA"
            onLog("[ctrl] 仪表选择通道 \(name)")
            c.send(ctrlFrame(cmd + 1))
            startHeartbeat(c)
        case Cmd.clientInfo:
            onClientInfo(payload, c)
        case Cmd.checkSn:
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let sn = obj?["sn"] as? String ?? ""
            c.send(ctrlFrame(Cmd.checkSn + 1))
            let result: [String: Any] = ["isOk": true, "errCode": 0, "errMsg": "", "id": sn, "client_set": "easy_conn"]
            if let d = try? JSONSerialization.data(withJSONObject: result) { c.send(ctrlFrame(Cmd.checkSnResult, d)) }
            onLog("[ctrl] CHECK_SN 通过")
        case Cmd.heartbeat:
            c.send(ctrlFrame(Cmd.heartbeatAck))
        case Cmd.huTimeSync:
            c.send(ctrlFrame(Cmd.huTimeSync + 1, payload)) // 原样回显，不改仪表时钟
        default:
            if (cmd & 1) == 1 { return } // 奇数号是仪表的应答
            onLog("[ctrl] \(hex(cmd)) len=\(payload.count) \(String(payload.utf8Text.prefix(200))) → 应答 cmd+1")
            c.send(ctrlFrame(cmd + 1))
        }
    }

    private func onClientInfo(_ payload: Data, _ c: Conn) {
        let text = payload.utf8Text
        onLog("[ctrl] 仪表信息 CLIENT_INFO：\(text)")
        let info = ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]) ?? [:]
        let huid = (info["HUID"] as? String) ?? (info["huid"] as? String) ?? ""
        let reply: [String: Any] = [
            "pxcVersion": "1.0.2",
            "phoneUUID": phoneUUID,
            "phoneBrand": "Apple",
            "phoneModel": UIDevice.current.model,
            "phoneOsVersion": UIDevice.current.systemVersion,
            "phoneOs": config.phoneType,
            "package": config.spoofPackage,
            "versionCode": config.versionCode,
            "token": 0,
            "pubkey": RsaIdentity.publicKeyBase64,
            "encryptedHUID": huid.isEmpty ? "" : RsaIdentity.signHuid(huid),
            "bluetoothName": config.bluetoothName,
            "supportH264IFrame": true,
            "supportFunction": (info["supportFunction"] as? Int) ?? 0,
            "supportSyncCorrectTime": false,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: reply) { c.send(ctrlFrame(Cmd.clientInfoRly, d)) }
        onLog("[ctrl] 已回复手机信息（HUID=\(huid.isEmpty ? "无" : huid)）")
    }

    /// 部分仪表自己不发心跳，空闲约 7 秒就断，所以每个控制通道都主动发。
    private func startHeartbeat(_ c: Conn) {
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let s = self, s.isRunning, c.alive else { break }
                c.send(ctrlFrame(Cmd.heartbeat))
            }
        }
    }

    // MARK: 媒体面（10921 / 10920）

    private func mediaLoop(_ c: Conn, port: UInt16) async throws {
        while isRunning {
            let r = try await c.readMedia()
            try await handleMedia(r.type, r.body, c, port: port)
        }
    }

    private func handleMedia(_ type: Int, _ body: Data, _ c: Conn, port: UInt16) async throws {
        switch type {
        case 16: // REQ_CONFIG_CAPTURE
            let w = body.count >= 2 ? body.le16(0) : 0
            let h = body.count >= 4 ? body.le16(2) : 0
            let fps = body.count >= 8 ? Int(body.le32(4)) : 0
            let enc = body.count >= 12 ? body.le32(8) : 2
            let ext: UInt8 = body.count >= 30 ? body[body.startIndex + 29] : 0
            let cw = w & 0xFFF0, ch = h & 0xFFF0
            locked { canvasW = cw; canvasH = ch }
            onLog("[media] 仪表请求画布 \(w)x\(h) fps=\(fps) → 协商 \(cw)x\(ch)")
            onCanvas(cw, ch)
            var rly = Data()
            rly.putLE32(enc == 0 ? 2 : enc); rly.putLE16(cw); rly.putLE16(ch); rly.append(ext)
            c.send(mediaFrame(17, rly))
        case 48: // REQ_GET_VERSION
            var v = Data(); v.putLE32(3); v.putLE32(1)
            c.send(mediaFrame(49, v))
        case 64: // REQ_HEARTBEAT
            c.send(mediaFrame(65))
        case 96: // REQ_CONFIG_CAPTURE_EXTEND
            c.send(mediaFrame(97, Data("{\"state\":0}".utf8)))
        case 128: // REQ_START_H264
            c.send(mediaFrame(129))
        case 112: // REQ_DATA_START
            ensureSource().requestKeyFrame()
            c.send(mediaFrame(113))
            locked { framesSent = 0 }
            let size = locked { "\(canvasW)x\(canvasH)" }
            onState("投屏中（\(size)）")
            onLog("[media] 仪表开始拉流")
        case 114: // REQ_DATA_NEXT：仪表拉一帧
            let src = ensureSource()
            var frame: Data?
            while isRunning && frame == nil {
                frame = src.popFrame()
                if frame == nil { try await Task.sleep(nanoseconds: 4_000_000) }
            }
            if let f = frame {
                var d = Data(); d.putLE32(Int32(f.count)); d.append(f)
                c.send(d)
                let n: Int = locked { framesSent += 1; return framesSent }
                if n <= 3 || n % 600 == 0 { onLog("[media] 已发送第 \(n) 帧（\(f.count) 字节）") }
            }
        case 32: // 仪表触屏
            if body.count >= 8 {
                onLog("仪表触摸 action=\(body.le16(0)) (\(body.le16(2)),\(body.le16(4)))")
            }
        default:
            onLog("[media:\(port)] 未知 cmdType=\(type) len=\(body.count)")
        }
    }

    private func ensureSource() -> FrameSource {
        lock.lock()
        if let s = source { lock.unlock(); return s }
        if canvasW == 0 || canvasH == 0 { canvasW = 800; canvasH = 384 }
        let (w, h) = (canvasW, canvasH)
        let s = sourceFactory(w, h)
        source = s
        lock.unlock()
        s.start()
        return s
    }

    private func stopSource() {
        let s: FrameSource? = locked { let r = source; source = nil; return r }
        s?.stop()
    }
}
