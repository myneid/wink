import AppKit
import WebKit

// No account or token used: exercise the SDK's actual DRM initialization gate.
final class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
  var view: WKWebView!
  let html = """
  <!doctype html><meta charset="utf-8"><script>
  function report(x) { window.webkit.messageHandlers.probe.postMessage(x); }
  report({secure: window.isSecureContext, origin: location.origin, eme: typeof navigator.requestMediaKeySystemAccess, webkitKeys: typeof WebKitMediaKeys});
  for (const key of ['com.widevine.alpha', 'com.apple.fps', 'com.microsoft.playready']) {
    navigator.requestMediaKeySystemAccess(key, [{initDataTypes:['cenc'], audioCapabilities:[{contentType:'audio/mp4; codecs=\"mp4a.40.2\"'}]}])
      .then(() => report({key, supported:true})).catch(e => report({key, error:e.name, message:e.message}));
  }
  window.onSpotifyWebPlaybackSDKReady = () => {
    report('SDK loaded');
    const p = new Spotify.Player({name:'Wink compatibility probe',getOAuthToken: cb => report('Token requested (not supplied)')});
    for (const e of ['initialization_error','authentication_error','account_error','playback_error']) p.addListener(e, x => report({event:e,message:x.message}));
    p.connect().then(x => report({connected:x})).catch(x => report({error:String(x)}));
  };
  </script><script src="https://sdk.scdn.co/spotify-player.js" onerror="report('SDK download failed')"></script>
  """
  func start() {
    let c = WKWebViewConfiguration()
    c.websiteDataStore = .nonPersistent()
    c.mediaTypesRequiringUserActionForPlayback = []
    c.userContentController.add(self, name: "probe")
    c.setURLSchemeHandler(self, forURLScheme: "blink-plugin")
    view = WKWebView(frame: NSRect(x:0,y:0,width:800,height:600), configuration:c)
    view.navigationDelegate = self
    if CommandLine.arguments.contains("--https") { view.loadHTMLString(html, baseURL:URL(string:"https://sdk.scdn.co/")) }
    else { view.load(URLRequest(url:URL(string:"blink-plugin://org.blink.spotify/index.html")!)) }
    DispatchQueue.main.asyncAfter(deadline:.now()+18) { print("Probe complete"); NSApp.terminate(nil) }
  }
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { print(m.body) }
  func webView(_ w:WKWebView,start t:WKURLSchemeTask) {
    t.didReceive(URLResponse(url:t.request.url!,mimeType:"text/html",expectedContentLength:html.utf8.count,textEncodingName:"utf-8")); t.didReceive(Data(html.utf8)); t.didFinish()
  }
  func webView(_ w:WKWebView,stop t:WKURLSchemeTask) {}
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe(); probe.start(); app.run()
