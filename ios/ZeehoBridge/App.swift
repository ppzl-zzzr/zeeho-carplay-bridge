import SwiftUI
import UIKit

@main
struct ZeehoBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("仪表", systemImage: "gauge.with.dots.needle.67percent") }
            VehiclePanelView()
                .ignoresSafeArea(edges: .bottom)
                .tabItem { Label("车辆", systemImage: "scooter") }
        }
    }
}

// MARK: - 状态

final class AppModel: ObservableObject {
    @Published var status = "未启动"
    @Published var logs: [String] = []
    @Published var running = false
    @Published var canvas = CGSize(width: 1024, height: 480)
    @Published var spoofPackage = UserDefaults.standard.string(forKey: "pkg") ?? "com.cfmoto"
    @Published var manualIP = UserDefaults.standard.string(forKey: "ip") ?? ""
    @Published var rideMode = UserDefaults.standard.object(forKey: "rideMode") as? Bool ?? true

    private var session: DashSession?
    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    // 仪表热点
    @Published var dashSSID = DashWifi.saved?.ssid ?? ""
    @Published var dashPwd = DashWifi.saved?.password ?? ""
    @Published var autoJoin = UserDefaults.standard.object(forKey: "autoJoin") as? Bool ?? true

    /// 扫到仪表二维码
    func scanned(_ raw: String) {
        log("[二维码] \(raw)")
        if let c = DashWifi.parse(raw) {
            dashSSID = c.ssid; dashPwd = c.password
            DashWifi.saved = c
            log("[二维码] 已保存仪表热点 \(c.ssid)")
        } else {
            log("[二维码] 没认出热点信息，请把这条日志发给开发者")
        }
    }

    func saveWifi() {
        let ssid = dashSSID.trimmingCharacters(in: .whitespaces)
        DashWifi.saved = ssid.isEmpty ? nil : DashWifi.Credentials(ssid: ssid, password: dashPwd)
        UserDefaults.standard.set(autoJoin, forKey: "autoJoin")
    }

    func start() {
        guard session == nil, !running else { return }
        let d = UserDefaults.standard
        d.set(spoofPackage, forKey: "pkg"); d.set(manualIP, forKey: "ip"); d.set(rideMode, forKey: "rideMode")
        saveWifi()
        UIApplication.shared.isIdleTimerDisabled = rideMode
        LocationService.shared.start()
        running = true
        if autoJoin, let c = DashWifi.saved {
            status = "连接仪表热点…"
            Task { [weak self] in
                _ = await DashWifi.join(c) { self?.log($0) }
                await MainActor.run { self?.startSession() }
            }
        } else {
            startSession()
        }
    }

    private func startSession() {
        guard running, session == nil else { return }
        var cfg = DashConfig()
        cfg.spoofPackage = spoofPackage.trimmingCharacters(in: .whitespaces).isEmpty ? "com.cfmoto" : spoofPackage
        let s = DashSession(config: cfg) { [weak self] w, h in
            RenderSource(width: w, height: h, fps: cfg.fps, bitrate: cfg.bitrate) { self?.log($0) }
        }
        s.onLog = { [weak self] in self?.log($0) }
        s.onState = { [weak self] st in DispatchQueue.main.async { self?.status = st } }
        s.onCanvas = { [weak self] w, h in DispatchQueue.main.async { self?.canvas = CGSize(width: w, height: h) } }
        session = s
        log("开始投屏，握手包名 \(cfg.spoofPackage)")
        s.start(manualIP: manualIP)
    }

    func stop() {
        session?.stop()
        session = nil
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = "已停止"
    }

    func log(_ line: String) {
        let stamped = "\(timeFmt.string(from: Date())) \(line)"
        DispatchQueue.main.async {
            self.logs.append(stamped)
            if self.logs.count > 600 { self.logs.removeFirst(self.logs.count - 600) }
        }
    }
}

// MARK: - 仪表页

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var vehicle = VehicleStore.shared
    @AppStorage("dashFont") private var dashFont = 0
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DashPreview(size: model.canvas)
                        .aspectRatio(model.canvas.width / max(model.canvas.height, 1), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    HStack {
                        Circle().fill(model.running ? Color.green : Color.gray).frame(width: 10, height: 10)
                        Text(model.status).font(.headline)
                    }

                    HStack(spacing: 12) {
                        Button(model.running ? "停止投屏" : "开始投屏") {
                            model.running ? model.stop() : model.start()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("复制日志") {
                            UIPasteboard.general.string = model.logs.joined(separator: "\n")
                        }
                        .buttonStyle(.bordered)
                    }

                    GroupBox("车况") {
                        let v = vehicle.current
                        VStack(alignment: .leading, spacing: 4) {
                            Text("电量 \(v.soc.map { "\($0)%" } ?? "--")    续航 \(v.rangeKm.map { "\($0) km" } ?? "--")\(v.charging ? "    充电中" : "")")
                            Text(v.updatedAt.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" } ?? "在「车辆」页登录极核账号后自动同步")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("仪表热点") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button {
                                    showScanner = true
                                } label: { Label("扫仪表二维码", systemImage: "qrcode.viewfinder") }
                                .buttonStyle(.bordered)
                                Spacer()
                                Toggle("自动连接", isOn: $model.autoJoin).fixedSize()
                            }
                            TextField("热点名称（扫码自动填）", text: $model.dashSSID)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("热点密码", text: $model.dashPwd)
                                .textFieldStyle(.roundedBorder)
                            Text("开始投屏时，App 会先自动连上这个热点。仪表停在投屏页时显示的二维码里就有热点信息。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.running)
                    .sheet(isPresented: $showScanner) {
                        NavigationStack {
                            QRScannerView { code in
                                model.scanned(code)
                                showScanner = false
                            }
                            .ignoresSafeArea()
                            .navigationTitle("扫描仪表二维码")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showScanner = false } } }
                        }
                    }

                    GroupBox("仪表字体") {
                        Picker("字体", selection: $dashFont) {
                            ForEach(DashFont.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                    }

                    GroupBox("投屏设置") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("骑行模式（屏幕常亮，推荐）", isOn: $model.rideMode)
                            Text("先在系统设置里连上仪表热点，并在车辆设置里打开「投屏（MotoPlay）」，仪表停在投屏页。")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("握手包名", text: $model.spoofPackage)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("仪表 IP（留空自动识别）", text: $model.manualIP)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    .disabled(model.running)

                    GroupBox("日志") {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.logs.suffix(200).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("极核仪表")
            .onAppear {
                LocationService.shared.start()
                NowPlaying.shared.start(log: model.log)
                if Demo.on {
                    VehicleStore.shared.override = .init(soc: 68, rangeKm: 30, charging: false, voltage: 82.8, updatedAt: Date())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { Demo.export(log: model.log) }
                }
            }
        }
    }
}

/// 仪表画面的实时预览（和推到仪表上的是同一个渲染器）
struct DashPreview: View {
    let size: CGSize
    private let renderer = DashRenderer()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Image(uiImage: renderer.previewImage(size: size))
                .resizable()
                .interpolation(.high)
        }
    }
}
