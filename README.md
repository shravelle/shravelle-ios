# iOS (Swift Package)

Add `sdks/shravelle-sdk-ios` as a local package (or publish it), product `Shravelle`.
```swift
import Shravelle
Shravelle.start(.init(endpoint: "https://ingest.example.com", key: "shv_brw_xxx", app: "shop-ios",
                    release: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String))
let session = URLSession(configuration: .shravelle)     // network monitoring + traceparent
Text("Home").shravelleScreen("Home")                    // SwiftUI; UIKit: Shravelle.screen("Home")
Shravelle.setUser(user.id)
Shravelle.track("coupon_applied", attributes: ["code": "DIWALI"])
Shravelle.recordError(error)
Shravelle.recordNetwork(method: "GET", url: url, status: 200, durationMs: 120)   // manual
```
Crashes: Objective-C exceptions and fatal signals (SIGSEGV, SIGABRT, …) are saved to disk and sent on the
next launch. For symbolicated native stack traces, also use a dedicated crash reporter (e.g. PLCrashReporter);
see the [roadmap](https://shravelle.com/docs.html). Status: not compiled in this build environment.


---
Part of [Shravelle](https://shravelle.com). Setup guide for every platform: [shravelle.com/docs](https://shravelle.com/docs.html) · Get your keys: [shravelle.com/get-started](https://shravelle.com/get-started.html)
