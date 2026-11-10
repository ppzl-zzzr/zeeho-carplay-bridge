import SwiftUI

/// 面板版（可分发）：只有车辆面板，不含仪表投屏、地图和高德。
@main
struct ZeehoPanelApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                VehiclePanelView()
                    .ignoresSafeArea(edges: .bottom)
            }
            .preferredColorScheme(.dark)
        }
    }
}
