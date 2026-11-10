import Foundation
import MediaPlayer
import UIKit

/// 正在播放的媒体信息
struct NowPlayingInfo {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var artwork: UIImage?
    var source: String

    /// 按时间戳外推的当前播放位置（秒）
    var position: Double {
        let p = rate > 0 ? elapsed + Date().timeIntervalSince(timestamp) * rate : elapsed
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
    var key: String { "\(title)\u{1}\(artist)" }
}

/// 读取手机正在播放的内容。
/// 1. 先尝试系统私有接口 MediaRemote（控制中心用的就是它，能读到任何 App：酷狗、网易云、抖音……）；
/// 2. 读不到时退回 Apple Music（公开接口）。
/// 自签名安装不受 App Store 审核限制，但新版 iOS 可能不放行私有接口，结果以日志为准。
final class NowPlaying {
    static let shared = NowPlaying()

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private var getInfo: GetInfoFn?
    private let q = DispatchQueue(label: "nowplaying")
    private let lock = NSLock()
    private var info: NowPlayingInfo?
    private var timer: DispatchSourceTimer?
    private var started = false
    private var mrEmptyCount = 0
    private var mrReported = false
    private var log: (String) -> Void = { _ in }

    var current: NowPlayingInfo? {
        if Demo.on { return Demo.nowPlaying }
        lock.lock(); defer { lock.unlock() }; return info
    }

    func start(log: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        self.log = log
        if let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
           let sym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") {
            getInfo = unsafeBitCast(sym, to: GetInfoFn.self)
            log("[媒体] 已加载系统“正在播放”接口，尝试读取所有 App 的播放信息")
        } else {
            log("[媒体] 系统“正在播放”接口不可用，只能读取 Apple Music")
        }
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            MPMediaLibrary.requestAuthorization { _ in }
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        if let f = getInfo, mrEmptyCount < 20 {
            f(q) { [weak self] dict in self?.handleMediaRemote((dict as NSDictionary?) as? [String: Any]) }
        } else {
            DispatchQueue.main.async { [weak self] in self?.pollAppleMusic() }
        }
    }

    private func handleMediaRemote(_ d: [String: Any]?) {
        guard let d = d, let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
            mrEmptyCount += 1
            if mrEmptyCount == 20 && !mrReported {
                mrReported = true
                log("[媒体] 系统接口连续读不到内容（可能是 iOS 不放行，或者当前没有播放），改为读取 Apple Music")
            }
            DispatchQueue.main.async { [weak self] in self?.pollAppleMusic() }
            return
        }
        if !mrReported { mrReported = true; log("[媒体] ✅ 系统接口可用：正在播放「\(title)」") }
        mrEmptyCount = 0
        let num = { (k: String) -> Double in (d[k] as? NSNumber)?.doubleValue ?? 0 }
        var art: UIImage?
        let prev = current
        if let data = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            art = (prev?.title == title && prev?.artwork != nil) ? prev?.artwork : UIImage(data: data)
        }
        let next = NowPlayingInfo(
            title: title,
            artist: d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
            album: d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
            duration: num("kMRMediaRemoteNowPlayingInfoDuration"),
            elapsed: num("kMRMediaRemoteNowPlayingInfoElapsedTime"),
            rate: num("kMRMediaRemoteNowPlayingInfoPlaybackRate"),
            timestamp: d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date(),
            artwork: art ?? prev.flatMap { $0.title == title ? $0.artwork : nil },
            source: "正在播放")
        set(next)
    }

    private func pollAppleMusic() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { set(nil); return }
        let p = MPMusicPlayerController.systemMusicPlayer
        guard let item = p.nowPlayingItem, let title = item.title else { set(nil); return }
        let playing = p.playbackState == .playing
        let prev = current
        let art = prev?.title == title && prev?.artwork != nil
            ? prev?.artwork : item.artwork?.image(at: CGSize(width: 300, height: 300))
        set(NowPlayingInfo(title: title, artist: item.artist ?? "", album: item.albumTitle ?? "",
                           duration: item.playbackDuration, elapsed: p.currentPlaybackTime,
                           rate: playing ? 1 : 0, timestamp: Date(), artwork: art, source: "Apple Music"))
    }

    private func set(_ v: NowPlayingInfo?) {
        lock.lock()
        let changed = v?.key != info?.key
        info = v
        lock.unlock()
        if changed, let v = v {
            log("[媒体] 切换到「\(v.title)」\(v.artist.isEmpty ? "" : " - \(v.artist)")")
            CoverTint.shared.update(v.artwork)
            Lyrics.shared.load(title: v.title, artist: v.artist, duration: v.duration, log: log)
        }
    }
}

/// 专辑封面主色（给媒体卡染色）
final class CoverTint {
    static let shared = CoverTint()
    private let lock = NSLock()
    private var color = UIColor(red: 0.45, green: 0.3, blue: 0.75, alpha: 1)
    var current: UIColor { lock.lock(); defer { lock.unlock() }; return color }

    func update(_ img: UIImage?) {
        guard let cg = img?.cgImage else { return }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // 提亮、加饱和，避免灰扑扑
        let c = UIColor(hue: h, saturation: min(max(s, 0.35) * 1.2, 0.9), brightness: max(b, 0.55), alpha: 1)
        lock.lock(); color = c; lock.unlock()
    }
}
