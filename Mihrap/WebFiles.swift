import Foundation
import WebKit

/// Serves mihrap://app/<path>: first from the web files inside the app, then from the photos and
/// recordings already downloaded, otherwise downloads them once from the published web version
/// (GitHub Pages) and keeps them in Library/Caches so they work offline afterwards.
/// Byte ranges are answered so <audio> can play and seek.
final class WebFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "mihrap"
    private static let remote = URL(string: "https://mihrapnidaapp.github.io/mihrap-web/")!

    private let bundleRoot = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
    private let cacheRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("web", isDirectory: true)
    }()
    private var running = Set<ObjectIdentifier>() // main thread only
    private var downloading = [String: [(WKURLSchemeTask) -> Void]]()
    private var waiting = [String: [WKURLSchemeTask]]()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        running.insert(ObjectIdentifier(task))
        guard let url = task.request.url, let path = Self.relativePath(url) else {
            fail(task, code: 400)
            return
        }
        if let file = localFile(path) {
            serve(file, path: path, to: task)
            return
        }
        waiting[path, default: []].append(task)
        download(path)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// Downloads files (adhan recordings) in the background so they are there when needed.
    func prefetch(_ paths: [String]) {
        for raw in paths {
            guard let url = URL(string: raw, relativeTo: URL(string: Self.scheme + "://app/")!),
                  let path = Self.relativePath(url), localFile(path) == nil else { continue }
            download(path)
        }
    }

    private static func relativePath(_ url: URL) -> String? {
        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }
        if path.split(separator: "/").contains("..") { return nil }
        return path
    }

    private func localFile(_ path: String) -> URL? {
        for root in [bundleRoot, cacheRoot] {
            let file = root.appendingPathComponent(path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue { return file }
        }
        return nil
    }

    private func download(_ path: String) {
        if downloading[path] != nil { return }
        downloading[path] = []
        let target = cacheRoot.appendingPathComponent(path)
        let source = Self.remote.appendingPathComponent(path)
        URLSession.shared.downloadTask(with: source) { temp, response, _ in
            var ok = false
            if let temp = temp, (response as? HTTPURLResponse)?.statusCode == 200 {
                let fm = FileManager.default
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                ok = (try? fm.moveItem(at: temp, to: target)) != nil
            }
            DispatchQueue.main.async {
                self.downloading[path] = nil
                let tasks = self.waiting.removeValue(forKey: path) ?? []
                for task in tasks {
                    if ok { self.serve(target, path: path, to: task) } else { self.fail(task, code: 404) }
                }
            }
        }.resume()
    }

    private func serve(_ file: URL, path: String, to task: WKURLSchemeTask) {
        guard running.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            fail(task, code: 404)
            return
        }
        var status = 200
        var body = data
        var headers = [
            "Content-Type": Self.mimeType(path),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        if let range = task.request.value(forHTTPHeaderField: "Range"), let (start, end) = Self.parse(range, size: data.count) {
            status = 206
            body = data.subdata(in: start..<(end + 1))
            headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
        }
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
        running.remove(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        guard running.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "0", "Content-Type": "text/plain"])!
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
        running.remove(ObjectIdentifier(task))
    }

    /// "bytes=a-b", "bytes=a-" or "bytes=-n" -> inclusive byte offsets.
    private static func parse(_ header: String, size: Int) -> (Int, Int)? {
        guard size > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",")[0]
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        var start: Int, end: Int
        if parts[0].isEmpty {
            guard let n = Int(parts[1]), n > 0 else { return nil }
            start = max(0, size - n)
            end = size - 1
        } else {
            guard let a = Int(parts[0]) else { return nil }
            start = a
            end = parts[1].isEmpty ? size - 1 : min(Int(parts[1]) ?? size - 1, size - 1)
        }
        if start > end || start >= size { return nil }
        return (start, end)
    }

    private static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }
}
