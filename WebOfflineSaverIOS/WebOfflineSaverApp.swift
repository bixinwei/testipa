import SwiftUI
import WebKit
import CryptoKit
import UniformTypeIdentifiers

@main struct WebOfflineSaverApp: App { @StateObject var store = Store(); var body: some Scene { WindowGroup { Home().environmentObject(store) } } }
struct Plan: Codable { let contentSelector: String; let titleSelector: String?; let excludes: [String] }
struct CachedPlan: Codable { let version: Int; let plan: Plan }
struct Item: Codable, Identifiable, Hashable { let id: UUID; let title, url, file: String }
struct AssetRef: Codable { let url: String; let kind: String }
struct CapturedPage: Decodable { let title: String; let html: String; let resources: [AssetRef]; let selectedVideo: String?; let missingVideo: Bool? }
struct BookmarkJob: Codable, Identifiable { let id: UUID; let url: String; var status: String }

@MainActor final class Browser: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView; var wait: CheckedContinuation<Void,Error>?; var completedURL: URL?
    override init(){let c=WKWebViewConfiguration();c.websiteDataStore = .default();c.defaultWebpagePreferences.allowsContentJavaScript=true;view=WKWebView(frame:.zero,configuration:c);super.init();view.navigationDelegate=self}
    func open(_ s:String){if let u=URL(string:s){completedURL=nil;view.load(URLRequest(url:u))}}
    func load(_ s:String) async throws {guard let u=URL(string:s)else{throw URLError(.badURL)};if let completedURL,completedURL.absoluteString == u.absoluteString{return};try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in wait=c;view.load(URLRequest(url:u))}}
    func js(_ s:String) async throws->Any {try await withCheckedThrowingContinuation{c in view.evaluateJavaScript(s){v,e in if let e{c.resume(throwing:e)}else{c.resume(returning:v as Any)}}}}
    func asyncJS(_ script:String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning:value as Any)
                case .failure(let error): continuation.resume(throwing:error)
                }
            }
        }
    }
    func cookieHeader(for url: URL) async -> String {
        await withCheckedContinuation { continuation in
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let host=url.host ?? ""
                let applicable=cookies.filter { host == $0.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")) || host.hasSuffix($0.domain) }
                continuation.resume(returning: HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] ?? "")
            }
        }
    }
    /// Direct counterpart of desktop `current_page_media_urls`: activate the
    /// current player, wait, then return video element URLs followed by browser
    /// resource URLs in their original order.
    func currentPageMediaURLs() async throws -> [String] {
        _ = try await js("(()=>{const play=document.querySelector('.tt-video-box .xgplayer-start, .xgplayer-start, video');if(play){try{play.click()}catch(_){}}})()")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let expression="""
        JSON.stringify((()=>{const videoUrls=[...document.querySelectorAll('video')].flatMap(v=>[v.currentSrc,v.src]).filter(Boolean);const resourceUrls=performance.getEntriesByType('resource').map(e=>e.name).filter(n=>/\\.(?:mp4|m3u8)(?:[?#]|$)|douyinvod|toutiaovod|bytecdn|byteimg|videocdn|\\/video\\/(?:play|stream)/i.test(n));return [...new Set([...videoUrls,...resourceUrls])].filter(x=>/^https?:/i.test(x))})())
        """
        guard let raw=try await js(expression) as? String else { return [] }
        return (try? JSONDecoder().decode([String].self,from:Data(raw.utf8))) ?? []
    }
    func webView(_ w:WKWebView,didFinish n:WKNavigation!){completedURL=w.url;wait?.resume();wait=nil}; func webView(_ w:WKWebView,didFail n:WKNavigation!,withError e:Error){wait?.resume(throwing:e);wait=nil}; func webView(_ w:WKWebView,didFailProvisionalNavigation n:WKNavigation!,withError e:Error){wait?.resume(throwing:e);wait=nil}
}

@MainActor final class Store: ObservableObject {
    @Published var url=UserDefaults.standard.string(forKey:"wo.url") ?? ""
    @Published var key=UserDefaults.standard.string(forKey:"wo.key") ?? ""
    @Published var api=UserDefaults.standard.string(forKey:"wo.api") ?? "https://api.deepseek.com/v1"
    @Published var model=UserDefaults.standard.string(forKey:"wo.model") ?? "deepseek-chat"
    @Published var force=UserDefaults.standard.bool(forKey:"wo.force")
    @Published var bookmarkDomains=UserDefaults.standard.string(forKey:"wo.bookmark.domains") ?? ""
    @Published var browserShown = false
    @Published var logs:[String]=[]
    @Published var items:[Item]=[]
    @Published var models:[String]=[]
    @Published var downloading=false
    @Published var downloadStatus=""
    @Published var bookmarkJobs:[BookmarkJob]=[]
    @Published var bookmarkRunning=false
    @Published var bookmarkCurrent=0
    private var bookmarkStopRequested=false
    let browser=Browser(); let fm=FileManager.default
    var root:URL{fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("OfflineLibrary",isDirectory:true)}
    var mediaCache:URL{root.appendingPathComponent("MediaCache",isDirectory:true)}
    init(){if let d=try?Data(contentsOf:root.appendingPathComponent("catalog.json")){items=(try?JSONDecoder().decode([Item].self,from:d)) ?? []};if let d=UserDefaults.standard.data(forKey:"wo.bookmark.queue"){bookmarkJobs=(try?JSONDecoder().decode([BookmarkJob].self,from:d)) ?? []};_ = cleanupOrphanedLibrary()}
    func log(_ x:String){logs.append(x);if logs.count>150{logs.removeFirst()}}
    func saveConfig(){UserDefaults.standard.set(url,forKey:"wo.url");UserDefaults.standard.set(key,forKey:"wo.key");UserDefaults.standard.set(api,forKey:"wo.api");UserDefaults.standard.set(model,forKey:"wo.model");UserDefaults.standard.set(force,forKey:"wo.force");UserDefaults.standard.set(bookmarkDomains,forKey:"wo.bookmark.domains");log("[程序] 配置已保存。")}
    func open(){saveConfig();browser.open(url);browserShown=true;log("[程序] 已打开验证浏览器，请完成验证。")}
    func openBookmarkVerification(){
        guard let job=bookmarkJobs.first(where:{$0.status == "pending"}) ?? bookmarkJobs.first else { log("[程序] 请先导入并匹配书签任务。"); return }
        url=job.url; open()
    }
    func save(){Task{if !bookmarkRunning{bookmarkStopRequested=false};downloading=true;downloadStatus="正在准备保存网页…";defer{downloading=false;downloadStatus=""};_ = await work()}}
    var bookmarkCompleted: Int { bookmarkJobs.filter{$0.status == "done" || $0.status == "failed"}.count }
    func persistBookmarkQueue(){UserDefaults.standard.set(try?JSONEncoder().encode(bookmarkJobs),forKey:"wo.bookmark.queue")}
    func importBookmarks(_ file: URL) {
        guard let data=try?Data(contentsOf:file) else { log("[程序] 无法读取书签文件。"); return }
        let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) ?? ""
        let domains=bookmarkDomains.split(whereSeparator:{ $0.isWhitespace || $0 == "," || $0 == ";" }).map{String($0).lowercased().replacingOccurrences(of:"https://",with:"").replacingOccurrences(of:"http://",with:"").trimmingCharacters(in:CharacterSet(charactersIn:"/"))}.filter{!$0.isEmpty}
        guard !domains.isEmpty else { log("[程序] 请先填写要匹配的域名列表。"); return }
        guard let expression=try?NSRegularExpression(pattern:"(?i)href\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]") else { return }
        let links=expression.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap{match -> String? in guard let range=Range(match.range(at:1),in:text),let address=URL(string:String(text[range])),let host=address.host?.lowercased(),["http","https"].contains(address.scheme?.lowercased() ?? "") else{return nil};return domains.contains(where:{host == $0 || host.hasSuffix("."+$0)}) ? address.absoluteString : nil}
        let known=Set(bookmarkJobs.map{$0.url}).union(Set(items.map{$0.url})); let unique=Array(Set(links)).filter{!known.contains($0)}.sorted()
        bookmarkJobs += unique.map{BookmarkJob(id:UUID(),url:$0,status:"pending")}; persistBookmarkQueue(); log("[程序] 书签共匹配到 \(links.count) 个网页，已加入 \(unique.count) 个未重复任务。")
    }
    func startBookmarkQueue() {
        guard !bookmarkRunning else{return}; guard !bookmarkJobs.isEmpty else{log("[程序] 暂无书签任务。");return}
        bookmarkJobs=bookmarkJobs.map{var job=$0;if job.status == "failed"{job.status="pending"};return job};persistBookmarkQueue();bookmarkStopRequested=false;bookmarkRunning=true
        Task { await runBookmarkQueue() }
    }
    func stopBookmarkQueue(){bookmarkStopRequested=true;log("[程序] 已请求暂停；为保护当前网页，正在完成或安全中止当前任务。")}
    func runBookmarkQueue() async {
        defer { bookmarkRunning=false;persistBookmarkQueue() }
        while let index=bookmarkJobs.indices.first(where:{bookmarkJobs[$0].status == "pending"}) {
            if bookmarkStopRequested || Task.isCancelled { break }
            bookmarkCurrent=bookmarkCompleted + 1; url=bookmarkJobs[index].url; saveConfig();log("[程序] 正在处理书签任务 \(bookmarkCurrent)/\(bookmarkJobs.count)：\(url)")
            let succeeded=await work()
            if bookmarkStopRequested || Task.isCancelled { break }
            bookmarkJobs[index].status=succeeded ? "done" : "failed";persistBookmarkQueue()
        }
        if bookmarkStopRequested { log("[程序] 书签任务已暂停，可随时继续。") }
        else { log("[程序] 书签队列已处理完成：\(bookmarkCompleted)/\(bookmarkJobs.count)。") }
    }
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
    func validImage(_ data: Data) -> Bool {
        let bytes=[UInt8](data.prefix(16))
        return bytes.starts(with:[0xFF,0xD8,0xFF]) || bytes.starts(with:[0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]) || bytes.starts(with:[0x47,0x49,0x46,0x38]) || (bytes.count >= 12 && Array(bytes[0..<4]) == [0x52,0x49,0x46,0x46] && Array(bytes[8..<12]) == [0x57,0x45,0x42,0x50]) || (bytes.count >= 12 && String(bytes:bytes[4..<12],encoding:.ascii)?.contains("ftypavif") == true)
    }
    func renderedImage(_ source:String, assets:URL, number:Int) async -> String? {
        guard let encoded=try?JSONEncoder().encode(source),let literal=String(data:encoded,encoding:.utf8) else{return nil}
        // Return one rendered image at a time.  Returning every canvas together
        // with the article HTML exceeds WebKit's JS bridge response limit.
        let script="""
        (()=>{const wanted=\(literal);const image=[...document.images].find(x=>[x.currentSrc,x.src,x.getAttribute('data-xkrkllgl'),x.getAttribute('data-original'),x.getAttribute('data-lazy-src'),x.getAttribute('data-src')].includes(wanted));if(!image)return null;try{const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;if(!canvas.width||!canvas.height)return null;canvas.getContext('2d').drawImage(image,0,0);return canvas.toDataURL('image/png')}catch(_){return null}})()
        """
        guard let value=try?await browser.js(script),let raw=value as? String,let comma=raw.firstIndex(of:","),let data=Data(base64Encoded:String(raw[raw.index(after:comma)...])),validImage(data) else{return nil}
        let name=String(format:"%03d.png",number);try?data.write(to:assets.appendingPathComponent(name),options:.atomic);log("[程序] 已从验证浏览器的渲染图片生成本地 PNG：\(source)");return "assets/\(name)"
    }
    func localAsset(_ source: String, assets: URL, number: Int, imageOnly: Bool=false) async -> String? {
        if source.lowercased().hasPrefix("data:image/") {
            let parts=source.split(separator:",",maxSplits:1).map(String.init)
            guard parts.count == 2, let data=Data(base64Encoded:parts[1]) else { return nil }
            let mime=parts[0].lowercased(); let ext=mime.contains("png") ? "png" : mime.contains("gif") ? "gif" : mime.contains("webp") ? "webp" : "jpg"
            let name=String(format:"%03d.%@",number,ext); try? data.write(to:assets.appendingPathComponent(name),options:.atomic); return "assets/\(name)"
        }
        guard let remote = URL(string: source), ["http", "https"].contains(remote.scheme?.lowercased() ?? "") else { return nil }
        do {
            var request = URLRequest(url: remote); request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", forHTTPHeaderField: "User-Agent"); request.setValue(imageOnly ? "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" : "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",forHTTPHeaderField:"Accept");request.setValue("zh-CN,zh;q=0.9,en;q=0.8",forHTTPHeaderField:"Accept-Language");request.setValue(url,forHTTPHeaderField:"Referer"); let cookies=await browser.cookieHeader(for:remote); if !cookies.isEmpty{request.setValue(cookies,forHTTPHeaderField:"Cookie")}
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
            let mime = (response.mimeType ?? "").lowercased()
            let pathExt = remote.pathExtension.lowercased()
            let ext: String = mime.contains("png") ? "png" : mime.contains("jpeg") || mime.contains("jpg") ? "jpg" : mime.contains("gif") ? "gif" : mime.contains("webp") ? "webp" : mime.contains("mp4") ? "mp4" : pathExt.isEmpty ? "bin" : pathExt
            let name = String(format: "%03d.%@", number, ext)
            guard !imageOnly || validImage(data) else { log("[程序] 图片原文件不是有效图片，尝试读取验证浏览器已渲染的图片：\(source)"); return await renderedImage(source,assets:assets,number:number) }
            try data.write(to: assets.appendingPathComponent(name), options: .atomic)
            if imageOnly { log("[程序] 图片已保存：\(source)") }
            return "assets/\(name)"
        } catch { log("[程序] 资源下载失败：\(source)（\(error.localizedDescription)）"); return imageOnly ? await renderedImage(source,assets:assets,number:number) : nil }
    }
    func localHLS(_ source: String, assets: URL, number: Int) async -> String? {
        guard let remote=URL(string:source) else { return nil }
        let target=assets.appendingPathComponent(String(format:"%03d.mp4",number))
        downloadStatus="正在转存 HLS 视频…"
        let cookies=await browser.cookieHeader(for:remote)
        let requestHeaders=cookies.isEmpty ? "" : "Cookie: \(cookies)\r\n"
        let monitor=Task { [weak self] in
            while !Task.isCancelled {
                let size=((try?target.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
                await MainActor.run { self?.downloadStatus="正在转存 HLS 视频：已写入 \(String(format:"%.1f",Double(size)/1_048_576)) MB" }
                try? await Task.sleep(nanoseconds:500_000_000)
            }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                var message: NSString?
                let succeeded=WOSRemuxHLS(remote,target,self.url,requestHeaders,&message)
                Task { @MainActor in
                    monitor.cancel()
                    if succeeded { self.downloadStatus="HLS 视频已转存完成";self.log("[程序] 已将 HLS 视频转存为本地 MP4。"); continuation.resume(returning:"assets/\(target.lastPathComponent)") }
                    else { self.log("[程序] HLS 视频转存失败：\(message as String? ?? "未知错误")"); continuation.resume(returning:nil) }
                }
            }
        }
    }
    func videoCacheFile(pageURL:String, ordinal:Int) -> URL {
        let key="\(pageURL)#video-\(ordinal)"
        let hash=SHA256.hash(data:Data(key.utf8)).map{String(format:"%02x",$0)}.joined()
        return mediaCache.appendingPathComponent("\(hash).mp4")
    }
    func cachedVideo(pageURL:String, ordinal:Int) -> URL? {
        let cache=videoCacheFile(pageURL:pageURL,ordinal:ordinal)
        if fm.fileExists(atPath:cache.path){ return cache }
        guard let existing=items.first(where:{$0.url == pageURL}),let html=try?String(contentsOfFile:existing.file,encoding:.utf8) else{return nil}
        let pattern="<video[^>]+src=[\\\"']([^\\\"']+)"
        guard let regex=try?NSRegularExpression(pattern:pattern),let match=regex.matches(in:html,range:NSRange(html.startIndex...,in:html)).dropFirst(ordinal - 1).first,let range=Range(match.range(at:1),in:html) else{return nil}
        let value=String(html[range]); guard !value.hasPrefix("http"),!value.hasPrefix("../") else{return nil}
        let source=URL(fileURLWithPath:existing.file).deletingLastPathComponent().appendingPathComponent(value)
        guard fm.fileExists(atPath:source.path) else{return nil}
        do{try fm.createDirectory(at:mediaCache,withIntermediateDirectories:true);try fm.copyItem(at:source,to:cache);log("[程序] 已复用此前保存的视频，无需重复下载。");return cache}catch{return nil}
    }
    func cacheVideo(local:String, folder:URL, pageURL:String, ordinal:Int) -> String? {
        let source=folder.appendingPathComponent(local);let cache=videoCacheFile(pageURL:pageURL,ordinal:ordinal)
        guard fm.fileExists(atPath:source.path) else{return nil}
        do{try fm.createDirectory(at:mediaCache,withIntermediateDirectories:true);if !fm.fileExists(atPath:cache.path){try fm.copyItem(at:source,to:cache)};try?fm.removeItem(at:source);return "../MediaCache/\(cache.lastPathComponent)"}catch{return nil}
    }
    func work() async -> Bool {
        guard !url.isEmpty, !key.isEmpty else { log("[程序] 请填写网页地址和 API Key。"); return false }
        guard !bookmarkStopRequested, !Task.isCancelled else { return false }
        var stage="初始化"
        do {
            saveConfig(); stage="读取已验证网页";log("[程序] 正在读取网页…"); try await browser.load(url)
            stage="生成网页结构骨架"
            let skeleton = try await browser.js("(()=>[...document.querySelectorAll('main,article,section,div')].slice(0,500).map(x=>'<'+x.tagName.toLowerCase()+' id=\"'+(x.id||'')+'\" class=\"'+(x.className||'')+'\">').join('\\n'))()") as? String ?? ""
            let host = URL(string:url)?.host ?? "site"; stage="AI 主体结构识别";let p = try await getPlan(host:host, skeleton:skeleton)
            let q = String(data:try JSONEncoder().encode(p.contentSelector),encoding:.utf8)!; let ex = String(data:try JSONEncoder().encode(p.excludes),encoding:.utf8)!; let ti = String(data:try JSONEncoder().encode(p.titleSelector ?? ""),encoding:.utf8)!
            stage="读取当前播放器资源";log("[程序] 正在从已验证浏览器读取视频播放资源…")
            let mediaJSON=String(data:try JSONEncoder().encode(try await browser.currentPageMediaURLs()),encoding:.utf8)!
            let baseline=mediaJSON
            let obsoleteScript = """
            (()=>{const n=document.querySelector(\(q));if(!n)return null;const c=n.cloneNode(true);const excludes=\(ex),baseline=new Set(\(baseline));excludes.forEach(s=>{try{c.querySelectorAll(s).forEach(x=>x.remove())}catch(_){}});c.querySelectorAll('script,style,iframe,nav,header,footer,aside,form,.ads,.advertisement,.share,.related,[class*="advert"],[class*="recommend"],[class*="comment"],[id*="advert"],[id*="ads"]').forEach(x=>x.remove());const abs=v=>{try{return new URL(v,document.baseURI).href}catch(_){return v}};const matches=x=>/\\.(m3u8|mp4)([?#]|$)|toutiaovod|douyinvod|bytecdn|\\/video\\/(play|stream)/i.test(x);const playing=[...document.querySelectorAll('video')].flatMap(v=>[v.currentSrc,v.src]).filter(x=>x&&/^https?:/i.test(x)&&matches(x));const allObserved=[...performance.getEntriesByType('resource')].map(x=>x.name).filter(matches).reverse();const observed=allObserved.filter(x=>!baseline.has(x));const declared=(document.documentElement.innerHTML.match(/https?:\\/\\/[^\\s\"'<>]+?\\.(?:m3u8|mp4)(?:\\?[^\\s\"'<>]*)?/ig)||[]).map(x=>x.replace(/\\\\\\//g,'/'));const media=[...new Set([...playing,...observed,...allObserved,...declared])];const images=[...n.querySelectorAll('img')];[...c.querySelectorAll('img')].forEach((x,i)=>{const o=images[i];const v=o?.currentSrc||o?.getAttribute('data-original')||o?.getAttribute('data-lazy-src')||o?.getAttribute('data-src')||o?.getAttribute('src')||x.getAttribute('src');if(v)x.setAttribute('src',abs(v));['srcset','data-src','data-original','data-lazy-src'].forEach(a=>x.removeAttribute(a))});const playerSel='.tt-video-box,[data-vid],[tt-videoid],.dplayer,video[src^="blob:"]';const originalPlayers=[...n.querySelectorAll(playerSel)],copyPlayers=[...c.querySelectorAll(playerSel)];let selectedVideo='';copyPlayers.forEach((box,i)=>{const original=originalPlayers[i];const active=original?.querySelector('video')?.currentSrc||original?.querySelector('video')?.src||'';const attrs=original?[...original.attributes].map(a=>a.value).join(' '):'';const localDeclared=(attrs.match(/https?:\\/\\/[^\\s\"'<>]+?\\.(?:m3u8|mp4)(?:\\?[^\\s\"'<>]*)?/ig)||[]).map(x=>x.replace(/\\\\\\//g,'/'));const v=(active&&matches(active)?active:'')||media.find(u=>/\\.mp4([?#]|$)/i.test(u))||media.find(u=>/\\.m3u8([?#]|$)/i.test(u))||localDeclared.find(u=>matches(u));if(!v)return;selectedVideo=selectedVideo||abs(v);let video=box.matches('video')?box:box.querySelector('video');if(!video){video=document.createElement('video');box.replaceChildren(video)}video.setAttribute('src',abs(v));video.setAttribute('controls','controls');video.removeAttribute('autoplay');video.querySelectorAll('source').forEach(s=>s.remove())});const videos=[...n.querySelectorAll('video')];[...c.querySelectorAll('video')].forEach((x,i)=>{const o=videos[i];let v=o?.currentSrc||o?.getAttribute('src')||o?.querySelector('source')?.getAttribute('src');if(!v||v.startsWith('blob:'))v=media.find(u=>/\\.mp4([?#]|$)/i.test(u))||media.find(u=>/\\.m3u8([?#]|$)/i.test(u));if(v){selectedVideo=selectedVideo||abs(v);x.setAttribute('src',abs(v));x.querySelectorAll('source').forEach(s=>s.remove())}x.setAttribute('controls','controls');x.removeAttribute('autoplay')});const resources=[...new Set([...c.querySelectorAll('img')].map(x=>x.getAttribute('src')).filter(Boolean).concat([...c.querySelectorAll('video')].map(x=>x.getAttribute('src')).filter(Boolean)))];const t=\(ti);return JSON.stringify({title:(t&&document.querySelector(t)?.innerText||c.querySelector('h1')?.innerText||document.title).trim(),html:c.outerHTML,resources,selectedVideo})})()
            """
            let script = """
            (()=>{
              const node=document.querySelector(\(q)); if(!node)return null;
              const root=node.cloneNode(true), excludes=\(ex), media=\(mediaJSON);
              const absolute=value=>{try{return new URL(value,document.baseURI).href}catch(_){return value}};
              const matchesMP4=value=>/\\.mp4(?:[?#]|$)|douyinvod|toutiaovod|bytecdn|videocdn|\\/video\\/(?:play|stream)/i.test(value);
              const matchesHLS=value=>/\\.m3u8(?:[?#]|$)/i.test(value);
              const remove=selector=>{try{root.querySelectorAll(selector).forEach(el=>el.remove())}catch(_){}};
              root.querySelectorAll('script,style,iframe,form,noscript,svg').forEach(el=>el.remove());
              excludes.forEach(remove);
              ['nav','[role="navigation"]','.article-ads-btn','.a2a_kit','.post-near','.tags','.article-download','.content-tabs','[class*="advert"]','[class*="ads-"]','[id*="advert"]','[id*="ads-"]'].forEach(remove);
              [...root.querySelectorAll('blockquote,p,strong')].forEach(el=>{if((el.innerText||'').includes('每日大赛最新地址'))(el.closest('blockquote')||el).remove()});
              const keyword=[...root.querySelectorAll('p,div,strong')].find(el=>(el.innerText||'').trim().startsWith('关键词：'));
              if(keyword){const parent=keyword.parentElement;let found=false;[...parent.children].forEach(el=>{if(found)el.remove();if(el===keyword)found=true});keyword.remove()}
              const urlsFromBox=box=>{const declared=[...box.attributes].flatMap(a=>((a.value||'').replace(/\\\\\\//g,'/').match(/https?:\\/\\/[^\\s\"'<>]+?\\.(?:m3u8|mp4)(?:\\?[^\\s\"'<>]*)?/ig)||[]));return [...new Set([...declared,...media])];};
              let selectedVideo=''; let missingVideo=false;
              const replacePlayer=box=>{const urls=urlsFromBox(box), src=urls.find(matchesMP4)||urls.find(matchesHLS);if(!src){missingVideo=true;return;} selectedVideo=selectedVideo||absolute(src);const poster=box.getAttribute('data-poster')||box.getAttribute('tt-poster')||box.querySelector('video')?.getAttribute('poster')||'';const figure=document.createElement('figure');figure.className='offline-video';if(poster){const image=document.createElement('img');image.src=absolute(poster);image.alt='视频封面';figure.append(image)}const video=document.createElement('video');video.src=absolute(src);video.controls=true;video.preload='metadata';if(poster)video.poster=absolute(poster);figure.append(video);box.replaceWith(figure);};
              [...root.querySelectorAll('.tt-video-box,[data-vid],[tt-videoid]')].forEach(replacePlayer);
              [...root.querySelectorAll('.dplayer')].filter(el=>el.querySelector('video')).forEach(replacePlayer);
              [...root.querySelectorAll('video[src^="blob:"]')].forEach(replacePlayer);
              [...root.querySelectorAll('p')].filter(el=>!(el.innerText||'').trim()&&!el.querySelector('img,video,figure')).forEach(el=>el.remove());
              root.querySelectorAll('img').forEach(el=>{const source=el.getAttribute('data-xkrkllgl')||el.getAttribute('data-original')||el.getAttribute('data-lazy-src')||el.getAttribute('data-src')||el.getAttribute('src')||'';el.setAttribute('src',absolute(source));['srcset','data-src','data-original','data-lazy-src','data-xkrkllgl','onload','onclick','style'].forEach(a=>el.removeAttribute(a))});
              root.querySelectorAll('video,source').forEach(el=>{const source=el.getAttribute('src');if(source)el.setAttribute('src',absolute(source));if(el.tagName==='VIDEO'){el.controls=true;el.preload='metadata'}['srcset','onload','onclick','style','autoplay'].forEach(a=>el.removeAttribute(a))});
              root.querySelectorAll('a[href]').forEach(a=>{a.href=absolute(a.getAttribute('href'));a.target='_blank';a.rel='noopener'});
              const resources=[...new Map([...root.querySelectorAll('img')].map(el=>[el.getAttribute('src'),{url:el.getAttribute('src'),kind:'image'}]).concat([...root.querySelectorAll('video,source')].map(el=>[el.getAttribute('src'),{url:el.getAttribute('src'),kind:'video'}])).filter(([url])=>Boolean(url))).values()];
              const titleSelector=\(ti), title=(titleSelector&&document.querySelector(titleSelector)?.innerText||root.querySelector('h1')?.innerText||document.querySelector('h1.entry-title,h1.post-title,.entry-title,.post-title')?.innerText||document.querySelector('meta[property="og:title"],meta[name="twitter:title"]')?.getAttribute('content')||document.title).trim();
              return JSON.stringify({title,html:root.outerHTML,resources,selectedVideo,missingVideo});
            })()
            """
            stage="提取正文和已渲染图片";guard let raw=try await browser.js(script) as? String else { throw URLError(.cannotParseResponse) }
            let page = try JSONDecoder().decode(CapturedPage.self, from: Data(raw.utf8)); if page.missingVideo == true { throw NSError(domain:"WebOfflineSaver",code:2,userInfo:[NSLocalizedDescriptionKey:"未能从已验证页面取得实际视频资源；已取消保存，避免生成伪离线网页。"])}; if let selected=page.selectedVideo,!selected.isEmpty{log("[程序] 已锁定当前播放器视频地址：\(selected)")}; let id=UUID(), dir=root.appendingPathComponent(id.uuidString), assets=dir.appendingPathComponent("assets",isDirectory:true)
            try fm.createDirectory(at: assets, withIntermediateDirectories:true)
            var fragment = page.html; var saved=0; var videoOrdinal=0
            for (index, asset) in page.resources.enumerated() {
                if bookmarkStopRequested || Task.isCancelled { throw CancellationError() }
                let source=asset.url; let isHLS=source.lowercased().contains(".m3u8")
                let isVideo=asset.kind == "video"
                if isVideo { videoOrdinal += 1; if let cache=cachedVideo(pageURL:url,ordinal:videoOrdinal){fragment=fragment.replacingOccurrences(of:source,with:"../MediaCache/\(cache.lastPathComponent)");saved += 1;continue};log("[程序] 视频资源地址：\(source)") }
                if isVideo && !isHLS { downloadStatus="正在下载 MP4 视频…" }
                let downloaded=isHLS ? await localHLS(source,assets:assets,number:index + 1) : await localAsset(source, assets:assets, number:index + 1, imageOnly:asset.kind == "image")
                let local=isVideo ? downloaded.flatMap{cacheVideo(local:$0,folder:dir,pageURL:url,ordinal:videoOrdinal)} : downloaded
                if let local { fragment = fragment.replacingOccurrences(of: source, with: local); saved += 1 }
                else if isVideo { throw NSError(domain:"WebOfflineSaver",code:1,userInfo:[NSLocalizedDescriptionKey:"视频资源未能下载，已取消保存以避免生成伪离线网页。"]) }
            }
            let file=dir.appendingPathComponent("index.html")
            let pageHTML="<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>body{max-width:760px;margin:24px auto;padding:0 16px;font:17px/1.7 -apple-system}img,video{max-width:100%;height:auto}video{display:block;margin:14px auto}</style>\(fragment)"
            try pageHTML.write(to:file,atomically:true,encoding:.utf8); let item=Item(id:id,title:page.title.isEmpty ? host : page.title,url:url,file:file.path);items.insert(item,at:0);persist();log("[阶段] 已保存《\(item.title)》；已离线保存 \(saved) 个资源。"); return true
        } catch is CancellationError { log("[程序] 当前网页保存已安全暂停。"); return false }
        catch { log("[程序] 保存失败（\(stage)）：\(error.localizedDescription)"); return false }
    }
    /// Keep only folders and cached videos that are still referenced by catalog.json.
    /// Failed saves create a UUID folder before their later network steps can fail,
    /// so this also cleans up abandoned partial downloads on the next launch.
    @discardableResult func cleanupOrphanedLibrary() -> Int {
        let activeFolders=Set(items.map{URL(fileURLWithPath:$0.file).deletingLastPathComponent().standardizedFileURL.path})
        var removed=0
        if let entries=try?fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:.skipsHiddenFiles) {
            for entry in entries where entry.lastPathComponent != "MediaCache" {
                let isDirectory=(try?entry.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory, UUID(uuidString:entry.lastPathComponent) != nil, !activeFolders.contains(entry.standardizedFileURL.path) else { continue }
                if (try?fm.removeItem(at:entry)) != nil { removed += 1 }
            }
        }
        var referencedCache=Set<String>()
        let expression="\\.\\./MediaCache/([A-Fa-f0-9]+\\.mp4)"
        let regex=try?NSRegularExpression(pattern:expression)
        for item in items {
            guard let html=try?String(contentsOfFile:item.file,encoding:.utf8) else { continue }
            for match in regex?.matches(in:html,range:NSRange(html.startIndex...,in:html)) ?? [] {
                if let range=Range(match.range(at:1),in:html) { referencedCache.insert(String(html[range])) }
            }
        }
        if let cacheFiles=try?fm.contentsOfDirectory(at:mediaCache,includingPropertiesForKeys:nil,options:.skipsHiddenFiles) {
            for cache in cacheFiles where !referencedCache.contains(cache.lastPathComponent) {
                if (try?fm.removeItem(at:cache)) != nil { removed += 1 }
            }
        }
        return removed
    }
    func delete(_ offsets: IndexSet) {
        for index in offsets {
            try? fm.removeItem(at: URL(fileURLWithPath: items[index].file).deletingLastPathComponent())
        }
        items.remove(atOffsets: offsets)
        persist()
        let removed = cleanupOrphanedLibrary()
        var message = "[程序] 已删除网页及对应资源。"
        if removed > 0 { message += "已额外清理 \(removed) 项遗留资源。" }
        log(message)
    }
    func persist(){try?fm.createDirectory(at:root,withIntermediateDirectories:true);try?JSONEncoder().encode(items).write(to:root.appendingPathComponent("catalog.json"))}
}
struct Home:View{
    @EnvironmentObject var s:Store
    @State private var importingBookmarks=false
    var body:some View{NavigationStack{List{
        Section("网页保存"){
            TextField("网页地址",text:$s.url).textInputAutocapitalization(.never)
            SecureField("API Key",text:$s.key)
            TextField("API 地址",text:$s.api).textInputAutocapitalization(.never)
            TextField("模型",text:$s.model).textInputAutocapitalization(.never)
            Button("刷新模型列表"){s.refreshModels()}
            if !s.models.isEmpty{Picker("已获取模型",selection:$s.model){ForEach(s.models,id:\.self){Text($0).tag($0)}}}
            Toggle("每次都 AI 识别",isOn:$s.force)
            Button("保存配置"){s.saveConfig()}
            Button("打开验证浏览器"){s.open()}
            Button("保存主体网页"){s.save()}.disabled(s.downloading || s.bookmarkRunning)
        }
        Section("书签批量保存"){
            TextEditor(text:$s.bookmarkDomains).frame(minHeight:72).textInputAutocapitalization(.never)
            Text("填写允许的域名；可用换行、逗号或分号分隔。导入 HTML 书签后，仅保存这些域名及其子域名的超链接。").font(.caption).foregroundStyle(.secondary)
            Button("导入 HTML 书签"){importingBookmarks=true}.disabled(s.bookmarkRunning)
            Button("打开验证浏览器"){s.openBookmarkVerification()}.disabled(s.bookmarkRunning || s.bookmarkJobs.isEmpty)
            if !s.bookmarkJobs.isEmpty {
                ProgressView(value:Double(s.bookmarkCompleted),total:Double(s.bookmarkJobs.count))
                Text("任务总数：\(s.bookmarkJobs.count)　已处理：\(s.bookmarkCompleted)　当前：\(s.bookmarkRunning ? s.bookmarkCurrent : 0)").font(.subheadline)
                HStack {
                    Button(s.bookmarkRunning ? "正在处理" : "开始／继续"){s.startBookmarkQueue()}.disabled(s.bookmarkRunning)
                    Button("暂停"){s.stopBookmarkQueue()}.disabled(!s.bookmarkRunning)
                }
            }
        }
        if s.downloading || !s.downloadStatus.isEmpty{Section("下载进度"){HStack{if s.downloading || s.bookmarkRunning{ProgressView()};Text(s.downloadStatus.isEmpty && s.bookmarkRunning ? "正在处理书签任务…" : s.downloadStatus).font(.subheadline)}}}
        Section("已下载"){ForEach(s.items){i in NavigationLink(destination:OfflinePreview(item:i)){Text(i.title).foregroundStyle(.primary)}}.onDelete(perform:s.delete)}
        Section("日志"){ForEach(s.logs.indices,id:\.self){Text(s.logs[$0]).font(.caption).textSelection(.enabled)}}
    }.navigationTitle("网页离线保存器").sheet(isPresented:$s.browserShown){WebSheet(browser:s.browser)}.fileImporter(isPresented:$importingBookmarks,allowedContentTypes:[.html,.plainText],allowsMultipleSelection:false){result in switch result {case .success(let files):guard let file=files.first else{return};let allowed=file.startAccessingSecurityScopedResource();defer{if allowed{file.stopAccessingSecurityScopedResource()}};s.importBookmarks(file);case .failure(let error):s.log("[程序] 导入书签失败：\(error.localizedDescription)")}}}}
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
    func makeUIView(context: Context) -> WKWebView { let view=WKWebView(); view.loadFileURL(file, allowingReadAccessTo:file.deletingLastPathComponent().deletingLastPathComponent()); return view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
