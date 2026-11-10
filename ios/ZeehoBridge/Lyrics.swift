import Foundation

struct LyricLine {
    let time: Double
    let text: String
}

/// 带时间轴的歌词：先查 LRCLIB（开源歌词库），查不到再用网易云搜索。
final class Lyrics {
    static let shared = Lyrics()

    private let lock = NSLock()
    private var key = ""
    private var lines: [LyricLine] = []
    private var state = "" // 空=有歌词；否则是提示文字
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.allowsCellularAccess = true
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "ZeehoBridge/0.1 (lyrics)"]
        return URLSession(configuration: c)
    }()

    func snapshot() -> (lines: [LyricLine], state: String) {
        lock.lock(); defer { lock.unlock() }
        return (lines, state)
    }

    func load(title: String, artist: String, duration: Double, log: @escaping (String) -> Void) {
        let k = "\(title)\u{1}\(artist)"
        lock.lock()
        if k == key { lock.unlock(); return }
        key = k; lines = []; state = "正在查找歌词…"
        lock.unlock()
        Task.detached { [weak self] in
            guard let self = self else { return }
            var found = await self.lrclib(title: title, artist: artist, duration: duration)
            var from = "LRCLIB"
            if found.isEmpty { found = await self.netease(title: title, artist: artist); from = "网易云" }
            self.lock.lock()
            if self.key == k {
                self.lines = found
                self.state = found.isEmpty ? "暂无歌词" : ""
            }
            self.lock.unlock()
            log(found.isEmpty ? "[歌词] 没找到「\(title)」的歌词" : "[歌词] 已从\(from)获取 \(found.count) 行")
        }
    }

    /// 当前应高亮的行号，以及到下一行的进度（0~1，用于平滑滚动）
    static func cursor(_ lines: [LyricLine], at t: Double) -> (index: Int, frac: Double) {
        guard !lines.isEmpty else { return (-1, 0) }
        var i = -1
        for (n, l) in lines.enumerated() where l.time <= t + 0.15 { i = n }
        guard i >= 0 else { return (-1, 0) }
        guard i + 1 < lines.count else { return (i, 0) }
        let span = max(lines[i + 1].time - lines[i].time, 0.1)
        return (i, min(max((t - lines[i].time) / span, 0), 1))
    }

    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let re = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]")
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for m in ms {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(time: mm * 60 + ss, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    // MARK: - 数据源

    private func getJSON(_ url: URL) async -> Any? {
        guard let r = try? await session.data(from: url),
              (r.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: r.0)
    }

    private func lrclib(title: String, artist: String, duration: Double) async -> [LyricLine] {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 { c.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        if let u = c.url, let obj = await getJSON(u) as? [String: Any], let s = obj["syncedLyrics"] as? String {
            let l = Self.parse(s); if !l.isEmpty { return l }
        }
        var sc = URLComponents(string: "https://lrclib.net/api/search")!
        sc.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let u = sc.url, let arr = await getJSON(u) as? [[String: Any]] {
            for item in arr { if let s = item["syncedLyrics"] as? String { let l = Self.parse(s); if !l.isEmpty { return l } } }
        }
        return []
    }

    private func netease(title: String, artist: String) async -> [LyricLine] {
        var c = URLComponents(string: "https://music.163.com/api/search/get/web")!
        c.queryItems = [URLQueryItem(name: "s", value: "\(title) \(artist)"), URLQueryItem(name: "type", value: "1"),
                        URLQueryItem(name: "limit", value: "1")]
        guard let u = c.url, let obj = await getJSON(u) as? [String: Any],
              let result = obj["result"] as? [String: Any], let songs = result["songs"] as? [[String: Any]],
              let id = songs.first?["id"] as? Int,
              let lu = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1"),
              let lo = await getJSON(lu) as? [String: Any], let lrc = (lo["lrc"] as? [String: Any])?["lyric"] as? String
        else { return [] }
        return Self.parse(lrc)
    }
}
