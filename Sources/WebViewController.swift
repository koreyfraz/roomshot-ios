import UIKit
import WebKit

/// Serves the bundled web app and the latest LiDAR scan under roomshot://app/
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scanURL = FileManager.default.temporaryDirectory.appendingPathComponent("scan.bin")

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        var body: Data?
        var mime = "application/octet-stream"

        if url.lastPathComponent == "scan.bin" {
            body = try? Data(contentsOf: Self.scanURL)
        } else if let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            body = try? Data(contentsOf: file)
            mime = "text/html"
        }

        guard let data = body,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": mime,
                                                            "Content-Length": "\(data.count)",
                                                            "Cache-Control": "no-store"]) else {
            urlSchemeTask.didFailWithError(NSError(domain: "RoomShot", code: 404))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// Forwards script messages without the web view retaining the controller.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

final class WebViewController: UIViewController, WKScriptMessageHandler {
    private var webView: WKWebView!
    private let ble = BLEManager()
    private let stateURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("roomshot-state.json")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: "roomshot")

        let content = WKUserContentController()
        content.add(WeakMessageHandler(self), name: "native")

        // Hand saved rooms to the page before its script runs.
        var savedState = "null"
        if let data = try? Data(contentsOf: stateURL),
           let text = String(data: data, encoding: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            savedState = text
        }
        content.addUserScript(WKUserScript(source: "window.__nativeState = \(savedState);",
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        config.userContentController = content

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "roomshot://app/index.html")!))

        ble.onState = { [weak self] state, label in
            self?.runJS("window.nativeBle && window.nativeBle(\(WebViewController.jsString(state)), \(WebViewController.jsString(label)))")
            UIApplication.shared.isIdleTimerDisabled = (state == "on")
        }
        ble.onData = { [weak self] bytes in
            let list = bytes.map { String($0) }.joined(separator: ",")
            self?.runJS("window.nativeBleData && window.nativeBleData([\(list)])")
        }
    }

    // MARK: - Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }

        switch cmd {
        case "state":
            if let json = body["json"] as? String, let data = json.data(using: .utf8) {
                try? data.write(to: stateURL, options: .atomic)
            }
        case "bleConnect":
            ble.connect()
        case "bleDisconnect":
            ble.disconnect()
        case "scan":
            presentScanner()
        case "save":
            guard let rawName = body["name"] as? String,
                  let b64 = body["b64"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            share(data: data, name: rawName)
        default:
            break
        }
    }

    private func share(data: Data, name: String) {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe.isEmpty ? "RoomShot" : safe)
        do { try data.write(to: url, options: .atomic) } catch { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        topPresenter().present(sheet, animated: true)
    }

    private func presentScanner() {
        let scanner = ScanViewController()
        scanner.modalPresentationStyle = .fullScreen
        scanner.onFinish = { [weak self] triangles in
            self?.dismiss(animated: true) {
                if triangles > 0 {
                    self?.runJS("window.nativeScanReady && window.nativeScanReady(\(triangles))")
                }
            }
        }
        present(scanner, animated: true)
    }

    private func topPresenter() -> UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        return top
    }

    private func runJS(_ code: String) {
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(code, completionHandler: nil) }
    }

    static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}
