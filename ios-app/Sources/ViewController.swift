import SafariServices
import UIKit
import WebKit

final class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
  private var webView: WKWebView!
  private let engine = YouTubeLocalEngine()

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    let bg = UIColor(red: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
    view.backgroundColor = bg

    let cfg = WKWebViewConfiguration()
    cfg.allowsInlineMediaPlayback = true
    cfg.allowsPictureInPictureMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []
    cfg.setURLSchemeHandler(engine, forURLScheme: "ytlocal")

    let inject = WKUserScript(
      source: "window.__NATIVE_IOS__ = true;",
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    )
    cfg.userContentController.addUserScript(inject)
    cfg.userContentController.add(self, name: "nativeSaveProfile")

    webView = WKWebView(frame: view.bounds, configuration: cfg)
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isOpaque = false
    webView.backgroundColor = bg
    webView.scrollView.backgroundColor = bg
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.uiDelegate = self
    webView.navigationDelegate = self
    view.addSubview(webView)

    if let startURL = URL(string: "ytlocal://app/index.html") {
      webView.load(URLRequest(url: startURL))
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "nativeSaveProfile", let dict = message.body as? [String: Any] {
      engine.saveProfileFromBridge(dict)
    }
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url,
       url.scheme == "https" || url.scheme == "http" {
      let safari = SFSafariViewController(url: url)
      safari.preferredBarTintColor = UIColor(white: 0.08, alpha: 1)
      safari.preferredControlTintColor = .systemBlue
      present(safari, animated: true)
    }
    return nil
  }
}
