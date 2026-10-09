import SwiftUI
import WebKit

@main struct WebOfflineSaverApp: App { @StateObject var store = Store(); var body: some Scene { WindowGroup { Home().environmentObject(store) } } }
struct Plan: Codable { let contentSelector: String; let titleSelector: String?; let excludes: [String] }
struct CachedPlan: Codable { let version: Int; let plan: Plan }
struct Item: Codable, Identifiable, Hashable { let id: UUID; let title, url, file: String }
struct CapturedPage: Decodable { let title: String; let html: String; let resources: [String]; let selectedVideo: String? }

@MainActor final class Browser: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView; var wait: CheckedContinuation<Void,Error>?
    override init(){let c=WKWebViewConfiguration();c.websiteDataStore = .default();c.defaultWebpagePreferences.allowsContentJavaScript=true;view=WKWebView(frame:.zero,configuration:c);super.init();view.navigationDelegate=self}
    func open(_ s:String){if let u=URL(string:s){view.load(URLRequest(url:u))}}
    func load(_ s:String) async throws {guard let u=URL(string:s)else{throw URLError(.badURL)};try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in wait=c;view.load(URLRequest(url:u))}}
    func js(_ s:String) async throws->Any {try await withCheckedThrowingContinuation{c in view.evaluateJavaScript(s){v,e in if let e{c.resume(throwing:e)}else{c.resume(returning:v as Any)}}}}
    func cookieHeader(for url: URL) async -> String {
        await withCheckedContinuation { continuation in
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let host=url.host ?? ""
                let applicable=cookies.filter { host == $0.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")) || host.hasSuffix($0.domain) }
                continuation.resume(returning: HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] ?? "")
            }
        }
    }
    func webView(_ w:WKWebView,didFinish n:WKNavigation!){wait?.resume();wait=nil}; func webView(_ w:WKWebView,didFail n:WKNavigation!,withError e:Error){wait?.resume(throwing:e);wait=nil}; func webView(_ w:WKWebView,didFailProvisionalNavigation n:WKNavigation!,withError e:Error){wait?.resume(throwing:e);wait=nil}
}

@MainActor final class Store: ObservableObject {
    @Published var url=UserDefaults.standard.string(forKey:"wo.url") ?? ""
    @Published var key=UserDefaults.standard.string(forKey:"wo.key") ?? ""
    @Published var api=UserDefaults.standard.string(forKey:"wo.api") ?? "https://api.deepseek.com/v1"
    @Published var model=UserDefaults.standard.string(forKey:"wo.model") ?? "deepseek-chat"
    @Published var force=UserDefaults.standard.bool(forKey:"wo.force")
    @Published var browserShown = false
    @Published var logs:[String]=[]
    @Published var items:[Item]=[]
    @Published var models:[String]=[]
    let browser=Browser(); let fm=FileManager.default
    var root:URL{fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("OfflineLibrary",isDirectory:true)}
    init(){if let d=try?Data(contentsOf:root.appendingPathComponent("catalog.json")){items=(try?JSONDecoder().decode([Item].self,from:d)) ?? []}}
    func log(_ x:String){logs.append(x);if logs.count>150{logs.removeFirst()}}
    func saveConfig(){UserDefaults.standard.set(url,forKey:"wo.url");UserDefaults.standard.set(key,forKey:"wo.key");UserDefaults.standard.set(api,forKey:"wo.api");UserDefaults.standard.set(model,forKey:"wo.model");UserDefaults.standard.set(force,forKey:"wo.force");log("[程序] 配置已保存。")}
    func open(){saveConfig();browser.open(url);browserShown=true;log("[程序] 已打开验证浏览器，请完成验证。")}
    func save(){Task{await work()}}
    func refreshModels(){Task{await loadModels()}}
    func loadModels() async {
        guard !key.isEmpty, let endpoint = URL(string:api.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/models") else { log("[程序] 请先填写 API 地址和 API Key。"); return }
        do {
            var request=URLRequest(url:endpoint); request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
            let(data,response)=try await URLSession.shared.data(for:request)
            guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let dataModels=object["data"] as? [[String:Any]] else { throw URLError(.cannotParseResponse) }
            let list=dataModels.compactMap{$0["id"] as? String}.sorted()
            guard !list.isEmpty else { throw URLError(.cannotParseResponse) }
            models=list; if !list.contains(model){model=list[0]}; log("[程序] 已刷新模型列表，共 \(list.count) 个模型。")
        } catch { log("[程序] 刷新模型列表失败：\(error.localizedDescription)") }
    }
    func getPlan(host:String,skeleton:String) async throws->Plan {let k="wo.plan.\(host)";if !force,let d=UserDefaults.standard.data(forKey:k),let cached=try?JSONDecoder().decode(CachedPlan.self,from:d),cached.version == 2 {log("[程序] 复用 \(host) 已保存的网页结构，不调用 AI。");return cached.plan};log("[AI] 正在识别标题与主体区域…");let prompt="分析网页结构，不要输出正文。返回 JSON：contentSelector（标题 CSS selector 不在此；只包住正文/图片/视频的最小 CSS selector）、titleSelector（标题 CSS selector）、excludes（需从主体内删除的 CSS selector 数组）。必须排除广告、推广按钮、菜单、分享控件、上一篇下一篇、标签、下载推广、相关推荐、评论、侧栏和页脚。不要用一个包含这些区域的大容器代替排除规则。URL=\(url)\n结构：\(skeleton)";var r=URLRequest(url:URL(string:api.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/chat/completions")!);r.httpMethod="POST";r.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type");r.httpBody=try JSONSerialization.data(withJSONObject:["model":model,"temperature":0.1,"response_format":["type":"json_object"],"messages":[["role":"user","content":prompt]]]);let(d,_)=try await URLSession.shared.data(for:r);let o=try JSONSerialization.jsonObject(with:d)as![String:Any];let s=(((o["choices"]as?[[String:Any]])?.first?["message"]as?[String:Any])?["content"]as?String) ?? "{}";let p=try JSONDecoder().decode(Plan.self,from:Data(s.utf8));UserDefaults.standard.set(try JSONEncoder().encode(CachedPlan(version:2,plan:p)),forKey:k);return p}
    func localAsset(_ source: String, assets: URL, number: Int) async -> String? {
        if source.lowercased().hasPrefix("data:image/") {
            let parts=source.split(separator:",",maxSplits:1).map(String.init)
            guard parts.count == 2, let data=Data(base64Encoded:parts[1]) else { return nil }
            let mime=parts[0].lowercased(); let ext=mime.contains("png") ? "png" : mime.contains("gif") ? "gif" : mime.contains("webp") ? "webp" : "jpg"
            let name=String(format:"%03d.%@",number,ext); try? data.write(to:assets.appendingPathComponent(name),options:.atomic); return "assets/\(name)"
        }
        guard let remote = URL(string: source), ["http", "https"].contains(remote.scheme?.lowercased() ?? "") else { return nil }
        do {
            var request = URLRequest(url: remote); request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent"); request.setValue(url,forHTTPHeaderField:"Referer"); let cookies=await browser.cookieHeader(for:remote); if !cookies.isEmpty{request.setValue(cookies,forHTTPHeaderField:"Cookie")}
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
            let mime = (response.mimeType ?? "").lowercased()
            let pathExt = remote.pathExtension.lowercased()
            let ext: String = mime.contains("png") ? "png" : mime.contains("jpeg") || mime.contains("jpg") ? "jpg" : mime.contains("gif") ? "gif" : mime.contains("webp") ? "webp" : mime.contains("mp4") ? "mp4" : pathExt.isEmpty ? "bin" : pathExt
            let name = String(format: "%03d.%@", number, ext)
            try data.write(to: assets.appendingPathComponent(name), options: .atomic)
            return "assets/\(name)"
        } catch { log("[程序] 资源下载失败：\(source)（\(error.localizedDescription)）"); return nil }
    }
    func localHLS(_ source: String, assets: URL, number: Int) async -> String? {
        guard let remote=URL(string:source) else { return nil }
        let target=assets.appendingPathComponent(String(format:"%03d.mp4",number))
        log("[程序] 视频资源地址：\(source)")
        let cookies=await browser.cookieHeader(for:remote)
        let requestHeaders=cookies.isEmpty ? "" : "Cookie: \(cookies)\r\n"
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                var message: NSString?
                let succeeded=WOSRemuxHLS(remote,target,self.url,requestHeaders,&message)
                Task { @MainActor in
                    if succeeded { self.log("[程序] 已将 HLS 视频转存为本地 MP4。"); continuation.resume(returning:"assets/\(target.lastPathComponent)") }
                    else { self.log("[程序] HLS 视频转存失败：\(message as String? ?? "未知错误")"); continuation.resume(returning:nil) }
                }
            }
        }
    }
    func work() async {
        guard !url.isEmpty, !key.isEmpty else { log("[程序] 请填写网页地址和 API Key。"); return }
        do {
            saveConfig(); log("[程序] 正在读取网页…"); try await browser.load(url)
            let skeleton = try await browser.js("(()=>[...document.querySelectorAll('main,article,section,div')].slice(0,500).map(x=>'<'+x.tagName.toLowerCase()+' id=\"'+(x.id||'')+'\" class=\"'+(x.className||'')+'\">').join('\\n'))()") as? String ?? ""
            let host = URL(string:url)?.host ?? "site"; let p = try await getPlan(host:host, skeleton:skeleton)
            let q = String(data:try JSONEncoder().encode(p.contentSelector),encoding:.utf8)!; let ex = String(data:try JSONEncoder().encode(p.excludes),encoding:.utf8)!; let ti = String(data:try JSONEncoder().encode(p.titleSelector ?? ""),encoding:.utf8)!
            log("[程序] 正在从已验证浏览器读取视频播放资源…")
            let baseline = try await browser.js("JSON.stringify([...performance.getEntriesByType('resource')].map(x=>x.name).filter(x=>/\\.(m3u8|mp4)([?#]|$)|toutiaovod|douyinvod|bytecdn|\\/video\\/(play|stream)/i.test(x)))") as? String ?? "[]"
            _ = try await browser.js("(()=>{const play=document.querySelector('.tt-video-box .xgplayer-start,.xgplayer-start,.dplayer .dplayer-play-icon,.dplayer .dplayer-icon-play,video');if(play){try{play.click()}catch(_){}};const video=document.querySelector('video');if(video){try{video.play().catch(()=>{})}catch(_){}}})()")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let script = """
            (()=>{const n=document.querySelector(\(q));if(!n)return null;const c=n.cloneNode(true);const excludes=\(ex),baseline=new Set(\(baseline));excludes.forEach(s=>{try{c.querySelectorAll(s).forEach(x=>x.remove())}catch(_){}});c.querySelectorAll('script,style,iframe,nav,header,footer,aside,form,.ads,.advertisement,.share,.related,[class*="advert"],[class*="recommend"],[class*="comment"],[id*="advert"],[id*="ads"]').forEach(x=>x.remove());const abs=v=>{try{return new URL(v,document.baseURI).href}catch(_){return v}};const matches=x=>/\\.(m3u8|mp4)([?#]|$)|toutiaovod|douyinvod|bytecdn|\\/video\\/(play|stream)/i.test(x);const playing=[...document.querySelectorAll('video')].flatMap(v=>[v.currentSrc,v.src]).filter(x=>x&&/^https?:/i.test(x)&&matches(x));const allObserved=[...performance.getEntriesByType('resource')].map(x=>x.name).filter(matches).reverse();const observed=allObserved.filter(x=>!baseline.has(x));const declared=(document.documentElement.innerHTML.match(/https?:\\/\\/[^\\s\"'<>]+?\\.(?:m3u8|mp4)(?:\\?[^\\s\"'<>]*)?/ig)||[]).map(x=>x.replace(/\\\\\\//g,'/'));const media=[...new Set([...playing,...observed,...allObserved,...declared])];const images=[...n.querySelectorAll('img')];[...c.querySelectorAll('img')].forEach((x,i)=>{const o=images[i];const v=o?.currentSrc||o?.getAttribute('data-original')||o?.getAttribute('data-lazy-src')||o?.getAttribute('data-src')||o?.getAttribute('src')||x.getAttribute('src');if(v)x.setAttribute('src',abs(v));['srcset','data-src','data-original','data-lazy-src'].forEach(a=>x.removeAttribute(a))});const playerSel='.tt-video-box,[data-vid],[tt-videoid],.dplayer,video[src^="blob:"]';const originalPlayers=[...n.querySelectorAll(playerSel)],copyPlayers=[...c.querySelectorAll(playerSel)];let selectedVideo='';copyPlayers.forEach((box,i)=>{const original=originalPlayers[i];const active=original?.querySelector('video')?.currentSrc||original?.querySelector('video')?.src||'';const attrs=original?[...original.attributes].map(a=>a.value).join(' '):'';const localDeclared=(attrs.match(/https?:\\/\\/[^\\s\"'<>]+?\\.(?:m3u8|mp4)(?:\\?[^\\s\"'<>]*)?/ig)||[]).map(x=>x.replace(/\\\\\\//g,'/'));const v=(active&&matches(active)?active:'')||media.find(u=>/\\.mp4([?#]|$)/i.test(u))||media.find(u=>/\\.m3u8([?#]|$)/i.test(u))||localDeclared.find(u=>matches(u));if(!v)return;selectedVideo=selectedVideo||abs(v);let video=box.matches('video')?box:box.querySelector('video');if(!video){video=document.createElement('video');box.replaceChildren(video)}video.setAttribute('src',abs(v));video.setAttribute('controls','controls');video.removeAttribute('autoplay');video.querySelectorAll('source').forEach(s=>s.remove())});const videos=[...n.querySelectorAll('video')];[...c.querySelectorAll('video')].forEach((x,i)=>{const o=videos[i];let v=o?.currentSrc||o?.getAttribute('src')||o?.querySelector('source')?.getAttribute('src');if(!v||v.startsWith('blob:'))v=media.find(u=>/\\.mp4([?#]|$)/i.test(u))||media.find(u=>/\\.m3u8([?#]|$)/i.test(u));if(v){selectedVideo=selectedVideo||abs(v);x.setAttribute('src',abs(v));x.querySelectorAll('source').forEach(s=>s.remove())}x.setAttribute('controls','controls');x.removeAttribute('autoplay')});const resources=[...new Set([...c.querySelectorAll('img')].map(x=>x.getAttribute('src')).filter(Boolean).concat([...c.querySelectorAll('video')].map(x=>x.getAttribute('src')).filter(Boolean)))];const t=\(ti);return JSON.stringify({title:(t&&document.querySelector(t)?.innerText||c.querySelector('h1')?.innerText||document.title).trim(),html:c.outerHTML,resources,selectedVideo})})()
            """
            guard let raw=try await browser.js(script) as? String else { throw URLError(.cannotParseResponse) }
            let page = try JSONDecoder().decode(CapturedPage.self, from: Data(raw.utf8)); if let selected=page.selectedVideo,!selected.isEmpty{log("[程序] 已锁定当前播放器视频地址：\(selected)")}; let id=UUID(), dir=root.appendingPathComponent(id.uuidString), assets=dir.appendingPathComponent("assets",isDirectory:true)
            try fm.createDirectory(at: assets, withIntermediateDirectories:true)
            var fragment = page.html; var saved=0
            for (index, source) in page.resources.enumerated() {
                let isHLS=source.lowercased().contains(".m3u8")
                let isVideo=isHLS || source.lowercased().contains(".mp4")
                if isVideo { log("[程序] 视频资源地址：\(source)") }
                let local=isHLS ? await localHLS(source,assets:assets,number:index + 1) : await localAsset(source, assets:assets, number:index + 1)
                if let local { fragment = fragment.replacingOccurrences(of: source, with: local); saved += 1 }
                else if isVideo { throw NSError(domain:"WebOfflineSaver",code:1,userInfo:[NSLocalizedDescriptionKey:"视频资源未能下载，已取消保存以避免生成伪离线网页。"]) }
            }
            let file=dir.appendingPathComponent("index.html")
            let pageHTML="<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>body{max-width:760px;margin:24px auto;padding:0 16px;font:17px/1.7 -apple-system}img,video{max-width:100%;height:auto}video{display:block;margin:14px auto}</style>\(fragment)"
            try pageHTML.write(to:file,atomically:true,encoding:.utf8); let item=Item(id:id,title:page.title.isEmpty ? host : page.title,url:url,file:file.path);items.insert(item,at:0);persist();log("[阶段] 已保存《\(item.title)》；已离线保存 \(saved) 个资源。")
        } catch { log("[程序] 保存失败：\(error.localizedDescription)") }
    }
    func delete(_ o:IndexSet){for i in o{try?fm.removeItem(at:URL(fileURLWithPath:items[i].file).deletingLastPathComponent())};items.remove(atOffsets:o);persist()};func persist(){try?fm.createDirectory(at:root,withIntermediateDirectories:true);try?JSONEncoder().encode(items).write(to:root.appendingPathComponent("catalog.json"))}
}
struct Home:View{
    @EnvironmentObject var s:Store
    var body:some View{NavigationStack{List{Section("网页保存"){TextField("网页地址",text:$s.url).textInputAutocapitalization(.never);SecureField("API Key",text:$s.key);TextField("API 地址",text:$s.api).textInputAutocapitalization(.never);TextField("模型",text:$s.model).textInputAutocapitalization(.never);Button("刷新模型列表"){s.refreshModels()};if !s.models.isEmpty{Picker("已获取模型",selection:$s.model){ForEach(s.models,id:\.self){Text($0).tag($0)}}};Toggle("每次都 AI 识别",isOn:$s.force);Button("保存配置"){s.saveConfig()};Button("打开验证浏览器"){s.open()};Button("保存主体网页"){s.save()}};Section("已下载"){ForEach(s.items){i in NavigationLink(destination:OfflinePreview(item:i)){Text(i.title).foregroundStyle(.primary)}}.onDelete(perform:s.delete)};Section("日志"){ForEach(s.logs.indices,id:\.self){Text(s.logs[$0]).font(.caption).textSelection(.enabled)}}}.navigationTitle("网页离线保存器").sheet(isPresented:$s.browserShown){WebSheet(browser:s.browser)}}}
}
struct Web:UIViewRepresentable{@ObservedObject var browser:Browser;func makeUIView(context:Context)->WKWebView{browser.view};func updateUIView(_ v:WKWebView,context:Context){}}
struct WebSheet: View {
    @Environment(\.dismiss) private var dismiss
    let browser: Browser
    var body: some View {
        NavigationStack {
            Web(browser: browser)
                .navigationTitle("完成验证后返回")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成验证") { dismiss() }
                    }
                }
        }
    }
}
struct OfflinePreview: View {
    let item: Item
    var body: some View { LocalWebView(file: URL(fileURLWithPath: item.file)).navigationTitle(item.title).navigationBarTitleDisplayMode(.inline) }
}
struct LocalWebView: UIViewRepresentable {
    let file: URL
    func makeUIView(context: Context) -> WKWebView { let view=WKWebView(); view.loadFileURL(file, allowingReadAccessTo:file.deletingLastPathComponent()); return view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
