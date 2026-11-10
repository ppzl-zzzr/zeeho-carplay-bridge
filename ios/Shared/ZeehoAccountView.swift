import SwiftUI

/// 原生车辆页：登录 + 车况 + 基础车控（替代原来的嵌入网页）。
struct ZeehoAccountView: View {
    @StateObject private var acc = ZeehoAccount.shared

    var body: some View {
        NavigationStack {
            Group {
                if acc.isLoggedIn {
                    VehicleHome(acc: acc)
                } else {
                    LoginView(acc: acc)
                }
            }
            .navigationTitle("车辆")
            .toolbar {
                if acc.isLoggedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("刷新车况") { Task { try? await acc.refreshStatus() } }
                            Button("退出登录", role: .destructive) { acc.logout() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
    }
}

// MARK: - 登录

private struct LoginView: View {
    @ObservedObject var acc: ZeehoAccount
    @State private var phone = ""
    @State private var code = ""
    @State private var token = ""
    @State private var useToken = false
    @State private var countdown = 0
    @State private var timer: Timer?

    var body: some View {
        Form {
            Picker("登录方式", selection: $useToken) {
                Text("手机验证码").tag(false)
                Text("粘贴 token").tag(true)
            }
            .pickerStyle(.segmented)

            if useToken {
                Section("token 登录") {
                    TextField("粘贴 token", text: $token, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("登录") { Task { _ = await acc.loginWithToken(token) } }
                        .disabled(token.isEmpty || acc.busy)
                }
            } else {
                Section("手机号登录") {
                    TextField("手机号", text: $phone).keyboardType(.numberPad)
                    HStack {
                        TextField("验证码", text: $code).keyboardType(.numberPad)
                        Button(countdown > 0 ? "\(countdown)s" : "获取验证码") {
                            Task {
                                if await acc.sendCode(phone: phone) { startCountdown() }
                            }
                        }
                        .disabled(phone.count < 11 || countdown > 0 || acc.busy)
                    }
                    Button("登录") { Task { _ = await acc.login(phone: phone, code: code) } }
                        .disabled(phone.count < 11 || code.isEmpty || acc.busy)
                }
                Section {
                    Text("手机号登录会使极核官方 App 的登录失效（同一账号同时只能在一处登录）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let e = acc.lastError {
                Section { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .overlay { if acc.busy { ProgressView() } }
    }

    private func startCountdown() {
        countdown = 60
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            countdown -= 1
            if countdown <= 0 { t.invalidate() }
        }
    }
}

// MARK: - 车况 + 车控

private struct VehicleHome: View {
    @ObservedObject var acc: ZeehoAccount

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if acc.vehicles.count > 1 {
                    Picker("车辆", selection: Binding(
                        get: { acc.currentVin ?? "" },
                        set: { acc.selectVehicle($0) })) {
                        ForEach(acc.vehicles) { Text($0.name).tag($0.vin) }
                    }
                    .pickerStyle(.menu)
                }

                let s = acc.status
                HStack(spacing: 12) {
                    StatCard(title: "电量", value: s.soc.map { "\($0)%" } ?? "--", icon: "battery.100",
                             tint: (s.soc ?? 100) <= 20 ? .red : .green)
                    StatCard(title: "续航", value: s.rangeKm.map { "\($0) km" } ?? "--", icon: "road.lanes", tint: .cyan)
                }
                HStack(spacing: 12) {
                    StatCard(title: "电压", value: s.voltage.map { String(format: "%.1f V", $0) } ?? "--",
                             icon: "bolt", tint: .yellow)
                    StatCard(title: "状态", value: s.charging ? "充电中" : (s.online == true ? "在线" : "离线"),
                             icon: s.charging ? "bolt.fill" : "wifi", tint: s.charging ? .green : .gray)
                }
                if let m = s.totalMileage {
                    StatCard(title: "总里程", value: String(format: "%.1f km", m), icon: "gauge", tint: .orange)
                        .frame(maxWidth: .infinity)
                }

                GroupBox("车控") {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            ControlButton(title: s.locked == false ? "关锁" : "开锁",
                                          icon: s.locked == false ? "lock" : "lock.open", acc: acc) {
                                await acc.setLock(!(s.locked ?? true))
                            }
                            ControlButton(title: "寻车", icon: "speaker.wave.3", acc: acc) { await acc.findVehicle() }
                            ControlButton(title: "坐垫", icon: "bicycle", acc: acc) { await acc.openSeat() }
                        }
                        Text("开锁部分车型需云端二次解锁，一次不成可重试。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if let e = acc.lastError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                Text(s.updatedAt.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" } ?? "下拉刷新车况")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .refreshable { try? await acc.refreshStatus() }
        .overlay(alignment: .top) { if acc.busy { ProgressView().padding(6) } }
        .task { if acc.vehicles.isEmpty { try? await acc.loadVehicles() } }
    }
}

private struct StatCard: View {
    let title: String, value: String, icon: String, tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ControlButton: View {
    let title: String, icon: String
    @ObservedObject var acc: ZeehoAccount
    let action: () async -> Bool
    var body: some View {
        Button { Task { _ = await action() } } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .disabled(acc.busy)
    }
}
