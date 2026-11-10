import AVFoundation
import Foundation
import NetworkExtension
import SwiftUI

/// 仪表热点：从仪表投屏二维码里读出 WiFi 名称和密码，保存后由 App 自动连接。
/// 需要描述文件带 “Hotspot Configuration” 权限（ZeehoBridge_Dev.mobileprovision 已包含）。
enum DashWifi {
    struct Credentials: Equatable {
        var ssid: String
        var password: String
    }

    private static let ssidKey = "dashSSID", pwdKey = "dashPwd"

    static var saved: Credentials? {
        get {
            let d = UserDefaults.standard
            guard let s = d.string(forKey: ssidKey), !s.isEmpty else { return nil }
            return Credentials(ssid: s, password: d.string(forKey: pwdKey) ?? "")
        }
        set {
            UserDefaults.standard.set(newValue?.ssid, forKey: ssidKey)
            UserDefaults.standard.set(newValue?.password, forKey: pwdKey)
        }
    }

    /// 解析仪表二维码：Carbit/MotoPlay 链接（…?ssid=…&pwd=…）或标准 WIFI:S:…;P:…;;
    static func parse(_ raw: String) -> Credentials? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("WIFI:") {
            var ssid = "", pwd = ""
            for part in text.dropFirst(5).components(separatedBy: ";") {
                if part.hasPrefix("S:") { ssid = String(part.dropFirst(2)) }
                if part.hasPrefix("P:") { pwd = String(part.dropFirst(2)) }
            }
            return ssid.isEmpty ? nil : Credentials(ssid: ssid, password: pwd)
        }
        // 链接或纯查询串都按 key=value 解析
        let query: String
        if let q = URLComponents(string: text)?.percentEncodedQuery { query = q }
        else if let i = text.firstIndex(of: "?") { query = String(text[text.index(after: i)...]) }
        else { query = text }
        var map: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count >= 2 else { continue }
            let v = kv.dropFirst().joined(separator: "=")
            map[kv[0].lowercased()] = v.removingPercentEncoding ?? v
        }
        let ssid = map["ssid"] ?? map["s"] ?? map["name"] ?? map["wifi"] ?? ""
        let pwd = map["pwd"] ?? map["password"] ?? map["pass"] ?? map["p"] ?? ""
        return ssid.isEmpty ? nil : Credentials(ssid: ssid, password: pwd)
    }

    /// 当前连接的 WiFi 名称（需要定位权限 + “读取 WiFi 信息”权限）
    static func currentSSID() async -> String? {
        await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { cont.resume(returning: $0?.ssid) }
        }
    }

    /// 连接仪表热点；已连接时直接返回成功
    static func join(_ c: Credentials, log: @escaping (String) -> Void) async -> Bool {
        if let cur = await currentSSID(), cur == c.ssid {
            log("[WiFi] 已连接仪表热点 \(c.ssid)")
            return true
        }
        let conf = c.password.isEmpty
            ? NEHotspotConfiguration(ssid: c.ssid)
            : NEHotspotConfiguration(ssid: c.ssid, passphrase: c.password, isWEP: false)
        conf.joinOnce = false
        log("[WiFi] 正在连接仪表热点 \(c.ssid)…")
        let err: Error? = await withCheckedContinuation { cont in
            NEHotspotConfigurationManager.shared.apply(conf) { cont.resume(returning: $0) }
        }
        if let e = err as NSError?, !(e.domain == NEHotspotConfigurationErrorDomain
                                      && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
            log("[WiFi] 连接失败：\(e.localizedDescription)（code \(e.code)）")
            return false
        }
        // 等系统真正切过去（拿到 IP）
        for _ in 0..<20 {
            if let cur = await currentSSID(), cur == c.ssid { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("[WiFi] 已连接仪表热点 \(c.ssid)")
        return true
    }
}

// MARK: - 二维码扫描

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let dev = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resizeAspectFill
            view.layer.addSublayer(p)
            preview = p
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(s)
        }
    }
}
