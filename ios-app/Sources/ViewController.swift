import SafariServices
import UIKit
import WebKit

final class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {
  private var webView: WKWebView!
  private let engine = YouTubeLocalEngine()
  private var server: LocalHTTPServer!

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    let bg = UIColor(red: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
    view.backgroundColor = bg

    let cfg = WKWebViewConfiguration()
    cfg.allowsInlineMediaPlayback = true
    cfg.allowsPictureInPictureMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []

    let inject = WKUserScript(
      source: "window.__NATIVE_IOS__ = true;",
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    )
    cfg.userContentController.addUserScript(inject)

    webView = WKWebView(frame: view.bounds, configuration: cfg)
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isOpaque = false
    webView.backgroundColor = bg
    webView.scrollView.backgroundColor = bg
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.bounces = true
    webView.scrollView.showsHorizontalScrollIndicator = false
    webView.uiDelegate = self
    webView.navigationDelegate = self
    view.addSubview(webView)

    server = LocalHTTPServer { [weak self] req in
      guard let self else { return LocalHTTPResponse.json(["detail": "stopped"], status: 500) }
      return await self.engine.handleHTTP(req)
    }
    server.start { [weak self] port in
      guard let self, let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
      self.webView.load(URLRequest(url: url))
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    pushSafeAreaInsets()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if webView.frame != view.bounds {
      webView.frame = view.bounds
    }
    pushSafeAreaInsets()
  }

  private func pushSafeAreaInsets() {
    guard let webView else { return }
    let s = view.safeAreaInsets
    let js = """
    document.documentElement.style.setProperty('--ios-safe-top', '\(Int(s.top))px');
    document.documentElement.style.setProperty('--ios-safe-bottom', '\(Int(s.bottom))px');
    document.documentElement.style.setProperty('--ios-safe-left', '\(Int(s.left))px');
    document.documentElement.style.setProperty('--ios-safe-right', '\(Int(s.right))px');
    """
    webView.evaluateJavaScript(js, completionHandler: nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    pushSafeAreaInsets()
  }

  @objc private func onForeground() {
    server?.ensureRunning()
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
