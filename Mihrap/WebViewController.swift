import UIKit
import UserNotifications
import WebKit

/// Shows the Mihrap web app (bundled copy, served through mihrap://app/) full screen.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private let files = WebFiles()

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(files, forURLScheme: WebFiles.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [] // the adhan starts on time without a tap
        config.userContentController.add(WeakMessageHandler(self), name: "mihrap")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 7 / 255, green: 26 / 255, blue: 48 / 255, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: URL(string: WebFiles.scheme + "://app/index.html")!))
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // Links to other sites (photo credits, licences) open in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme != WebFiles.scheme,
           navigationAction.targetFrame?.isMainFrame ?? true, url.scheme == "https" || url.scheme == "http" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "schedule", let items = body["items"] as? [[String: Any]] {
            PrayerNotifications.schedule(items)
        } else if type == "prefetch", let paths = body["paths"] as? [String] {
            files.prefetch(paths)
        }
    }
}

/// WKUserContentController keeps its handlers strongly; this avoids a retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Silent notifications at the prayer times the web app hands over (the user chose no sound).
enum PrayerNotifications {
    private static let prefix = "prayer-"

    static func schedule(_ items: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge]) { granted, _ in
                    if granted { replace(items, center) }
                }
            case .denied:
                return
            default:
                replace(items, center)
            }
        }
    }

    private static func replace(_ items: [[String: Any]], _ center: UNUserNotificationCenter) {
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map { $0.identifier }.filter { $0.hasPrefix(prefix) })
            let now = Date()
            for item in items.prefix(60) { // iOS keeps at most 64 pending notifications per app
                guard let ms = item["t"] as? Double, let title = item["title"] as? String else { continue }
                let when = Date(timeIntervalSince1970: ms / 1000)
                if when <= now { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = item["body"] as? String ?? ""
                content.sound = nil
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: prefix + String(Int64(ms)), content: content, trigger: trigger))
            }
        }
    }
}
