import SwiftUI
import WebKit

// MARK: - 车况数据（从面板的接口响应里读取，供仪表界面显示）

final class VehicleStore: ObservableObject {
    static let shared = VehicleStore()

    struct Snapshot {
        var soc: Int?
        var rangeKm: Int?
        var charging = false
        var voltage: Double?
        var updatedAt: Date?
    }

    @Published private(set) var current = Snapshot()
    private let lock = NSLock()
    private var snap = Snapshot()

    /// 渲染线程用
    func snapshot() -> Snapshot {
        if Demo.on { return Snapshot(soc: 68, rangeKm: 30, charging: false, voltage: 82.8, updatedAt: Date()) }
        lock.lock(); defer { lock.unlock() }; return snap
    }

    /// 面板每收到一个极核接口响应就会转过来；只认电量相关字段（字段名来自项目的 mock.json）。
    func ingest(url: String, body: String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        var found: [String: Any] = [:]
        Self.collect(obj, into: &found, depth: 0)
        func num(_ keys: [String]) -> Double? {
            for k in keys { if let v = found[k.lowercased()], let d = Self.double(v) { return d } }
            return nil
        }
        let soc = num(["bmssoc", "soc"])
        let range = num(["hmiRidableMile", "ridableMile", "remainMileage"])
        guard soc != nil || range != nil else { return }
        let charging = (found["whetherchargestate"] as? Bool) ?? false
        let volt = num(["voltage", "bmsVoltage"])

        lock.lock()
        if let soc = soc { snap.soc = Int(soc.rounded()) }
        if let range = range { snap.rangeKm = Int(range.rounded()) }
        snap.charging = charging
        if let volt = volt { snap.voltage = volt }
        snap.updatedAt = Date()
        let copy = snap
        lock.unlock()
        DispatchQueue.main.async { self.current = copy }
    }

    private static func collect(_ x: Any, into d: inout [String: Any], depth: Int) {
        guard depth < 6 else { return }
        if let m = x as? [String: Any] {
            for (k, v) in m {
                if v is [String: Any] || v is [Any] {
                    collect(v, into: &d, depth: depth + 1)
                } else if !(v is NSNull), d[k.lowercased()] == nil {
                    d[k.lowercased()] = v
                }
            }
        } else if let a = x as? [Any], let first = a.first {
            collect(first, into: &d, depth: depth + 1)
        }
    }

    private static func double(_ v: Any) -> Double? {
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

// MARK: - 嵌入的车辆面板（Zeeho Unlocker 网页）

struct VehiclePanelView: UIViewRepresentable {
    static let home = URL(string: "https://lswlc33.github.io/zeeho-3d-models/")!

    /// 只读监听：把面板访问极核接口拿到的响应文本转给原生，不改动请求本身。
    static let hookJS = """
    (function () {
      if (window.__zbHook) return; window.__zbHook = true;
      function post(url, text) {
        try {
          if (!/zeehoev\\.com/.test(String(url))) return;
          if (typeof text !== 'string' || !text || text.length > 400000) return;
          window.webkit.messageHandlers.zbVehicle.postMessage({ url: String(url), body: text });
        } catch (e) {}
      }
      var of = window.fetch;
      if (of) {
        var wrapped = function (input, init) {
          var url = (input && input.url) || String(input);
          return of.apply(this, arguments).then(function (r) {
            try { if (/zeehoev\\.com/.test(url)) r.clone().text().then(function (t) { post(url, t); }).catch(function () {}); } catch (e) {}
            return r;
          });
        };
        wrapped.toString = function () { return of.toString(); };
        window.fetch = wrapped;
      }
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__zbUrl = u; return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        var x = this;
        x.addEventListener('load', function () {
          try { if (x.responseType === '' || x.responseType === 'text') post(x.__zbUrl, x.responseText); } catch (e) {}
        });
        return os.apply(this, arguments);
      };
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // 登录信息、设置都持久保存
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(context.coordinator, name: "zbVehicle")
        cfg.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.isInspectable = true
        wv.scrollView.contentInsetAdjustmentBehavior = .automatic
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        wv.scrollView.refreshControl = refresh
        context.coordinator.webView = wv
        wv.load(URLRequest(url: Self.home))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        weak var webView: WKWebView?

        @objc func reload(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let d = message.body as? [String: Any],
                  let url = d["url"] as? String, let body = d["body"] as? String else { return }
            DispatchQueue.global(qos: .utility).async { VehicleStore.shared.ingest(url: url, body: body) }
        }

        // target=_blank / window.open：在当前页打开
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // 非网页链接（极核 App、地图、电话等）交给系统
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "data", "blob"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // alert / confirm / prompt
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            present(a, fallback: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            present(a, fallback: { completionHandler(false) })
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            a.addTextField { $0.text = defaultText }
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
            present(a, fallback: { completionHandler(nil) })
        }

        // 摄像头扫码：同一来源不重复询问
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.prompt)
        }

        private func present(_ vc: UIViewController, fallback: () -> Void) {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            while let p = top?.presentedViewController { top = p }
            guard let host = top else { fallback(); return }
            host.present(vc, animated: true)
        }
    }
}
