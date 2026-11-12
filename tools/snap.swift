// Renders a local HTML page with WebKit and saves a full-page PNG.
// Usage: snap <file.html> <out.png> [width] [scale]
import AppKit
import WebKit

final class Snapper: NSObject, WKNavigationDelegate {
    let web: WKWebView; let out: URL; let width: CGFloat; let scale: CGFloat
    init(url: URL, out: URL, width: CGFloat, scale: CGFloat) {
        self.out = out; self.width = width; self.scale = scale
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
        super.init()
        web.navigationDelegate = self
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent().deletingLastPathComponent())
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        // give web fonts and images time to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            w.evaluateJavaScript("document.fonts.ready.then(()=>0); Math.ceil(document.documentElement.scrollHeight)") { h, _ in
                let height = CGFloat((h as? NSNumber)?.doubleValue ?? 1000)
                w.frame = NSRect(x: 0, y: 0, width: self.width, height: height)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = NSRect(x: 0, y: 0, width: self.width, height: height)
                    cfg.snapshotWidth = NSNumber(value: Double(self.width * self.scale))
                    w.takeSnapshot(with: cfg) { img, err in
                        guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else { print("fail", err as Any); exit(1) }
                        try! png.write(to: self.out); print("wrote", self.out.path, Int(self.width), "x", Int(height)); exit(0)
                    }
                }
            }
        }
    }
}
let a = CommandLine.arguments
let app = NSApplication.shared
let s = Snapper(url: URL(fileURLWithPath: a[1]), out: URL(fileURLWithPath: a[2]),
                width: CGFloat(Double(a.count > 3 ? a[3] : "1600") ?? 1600), scale: CGFloat(Double(a.count > 4 ? a[4] : "1") ?? 1))
_ = s
app.run()
