import SwiftUI
import WebKit
import CryptoKit
import UniformTypeIdentifiers
import UIKit

@main struct WebOfflineSaverApp: App { @StateObject var store = Store(); var body: some Scene { WindowGroup { Home().environmentObject(store) } } }
struct ManualExclusion: Codable, Hashable { let selector: String?; let id: String; let tag: String; let classes: String; let text: String }
struct Plan: Codable { let contentSelector: String; let titleSelector: String?; let excludes: [String]; let manualExclusions: [ManualExclusion]? }
struct CachedPlan: Codable { let version: Int; let plan: Plan }
struct Item: Codable, Identifiable, Hashable { let id: UUID; let title, url, file: String; var groupID: UUID? }
struct AssetRef: Codable { let url: String; let kind: String }
struct CapturedPage: Decodable { let title: String; let html: String; let resources: [AssetRef]; let selectedVideo: String?; let missingVideo: Bool?; let manualRemoved: Int? }
struct BookmarkJob: Codable, Identifiable {
    let id: UUID
    let url: String
    var status: String
    var videoSources: [String]?
    var downloadedVideoSources: [String]?
    var itemID: UUID?
    var groupID: UUID?
}
struct ArchiveGroup: Codable, Identifiable, Hashable { let id: UUID; var name: String }
struct SaveOutcome { let itemID: UUID; let videoSources: [String] }

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
    /// Trigger lazy-loading and wait for actual decoded pixels before cloning the article.
    /// This prevents a page's blurred/loading placeholder from being saved as its image.
    func prepareRenderedImages() async throws {
        let script="""
        (async()=>{const images=[...document.images];for(const image of images){const source=image.getAttribute('data-xkrkllgl')||image.getAttribute('data-original')||image.getAttribute('data-lazy-src')||image.getAttribute('data-src');if(source)image.src=new URL(source,document.baseURI).href;image.loading='eager'}const originalY=window.scrollY;for(let y=0;y<document.documentElement.scrollHeight;y+=Math.max(window.innerHeight,480)){window.scrollTo(0,y);await new Promise(resolve=>setTimeout(resolve,120))}await Promise.all(images.map(image=>image.decode().catch(()=>null)));window.scrollTo(0,originalY);return true})()
        """
        _ = try await asyncJS(script)
    }
    /// Canvas export is blocked by some image CDNs.  WKWebView's native snapshot
    /// captures the pixels already rendered by WebKit and therefore does not use
    /// the image URL again or depend on that CDN's CORS policy.
    func snapshotRenderedImage(_ source: String) async -> Data? {
        guard let encoded=try?JSONEncoder().encode(source),let literal=String(data:encoded,encoding:.utf8),
              let raw=try?await js("""
              (async()=>{const wanted=\(literal),same=value=>{if(!value)return false;if(value===wanted)return true;try{const a=new URL(value,document.baseURI),b=new URL(wanted,document.baseURI);return a.origin===b.origin&&a.pathname===b.pathname}catch(_){return false}};const image=[...document.images].find(item=>[item.currentSrc,item.src,item.getAttribute('data-xkrkllgl'),item.getAttribute('data-original'),item.getAttribute('data-lazy-src'),item.getAttribute('data-src')].some(same));if(!image)return null;image.scrollIntoView({block:'center',inline:'center'});await new Promise(resolve=>setTimeout(resolve,180));const rect=image.getBoundingClientRect();return JSON.stringify({x:rect.x,y:rect.y,width:rect.width,height:rect.height})})()
              """) as? String,
              let object=try?JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],
              let x=(object["x"] as? NSNumber)?.doubleValue,let y=(object["y"] as? NSNumber)?.doubleValue,let width=(object["width"] as? NSNumber)?.doubleValue,let height=(object["height"] as? NSNumber)?.doubleValue else{return nil}
        let requested=CGRect(x:x,y:y,width:width,height:height).intersection(view.bounds)
        guard requested.width > 1,requested.height > 1 else{return nil}
        let configuration=WKSnapshotConfiguration();configuration.rect=requested
        return await withCheckedContinuation { continuation in
            view.takeSnapshot(with:configuration) { image,error in
                continuation.resume(returning:error == nil ? image?.pngData() : nil)
            }
        }
    }
    func webView(_ w:WKWebView,didFinish n:WKNavigation!){completedURL=w.url;wait?.resume();wait=nil}; func webView(_ w:WKWebView,didFail n:WKNavigation!,withError e:Error){wait?.resume(throwing:e);wait=nil}; func webView(_ w:WKWebView,didFailProvisionalNavigation n:WKNavigation!,withError e:Error){wait?.resume(throwing:e);wait=nil}
}

@MainActor final class Store: ObservableObject {
    @Published var url=UserDefaults.standard.string(forKey:"wo.url") ?? ""
    @Published var key=UserDefaults.standard.string(forKey:"wo.key") ?? ""
    @Published var api=UserDefaults.standard.string(forKey:"wo.api") ?? "https://api.deepseek.com/v1"
    @Published var model=UserDefaults.standard.string(forKey:"wo.model") ?? "deepseek-chat"
    @Published var force=UserDefaults.standard.bool(forKey:"wo.force")
    @Published var deferVideoDownloads=UserDefaults.standard.object(forKey:"wo.defer.videos") == nil ? true : UserDefaults.standard.bool(forKey:"wo.defer.videos")
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
    @Published var videoDownloadRunning=false
    @Published var videoDownloadingJobs=Set<UUID>()
    @Published var archiveGroups:[ArchiveGroup]=[]
    private var bookmarkStopRequested=false
    private var activeBookmarkFilter="all"
    private var renderedImageRules=Set(UserDefaults.standard.stringArray(forKey:"wo.rendered.image.rules") ?? [])
    let browser=Browser(); let fm=FileManager.default
    var root:URL{fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("OfflineLibrary",isDirectory:true)}
    var mediaCache:URL{root.appendingPathComponent("MediaCache",isDirectory:true)}
    init(){if let d=try?Data(contentsOf:root.appendingPathComponent("catalog.json")){items=(try?JSONDecoder().decode([Item].self,from:d)) ?? []};if let d=UserDefaults.standard.data(forKey:"wo.bookmark.queue"){bookmarkJobs=(try?JSONDecoder().decode([BookmarkJob].self,from:d)) ?? []};if let d=UserDefaults.standard.data(forKey:"wo.archive.groups"){archiveGroups=(try?JSONDecoder().decode([ArchiveGroup].self,from:d)) ?? []};_ = cleanupOrphanedLibrary()}
    func log(_ x:String){logs.append(x);if logs.count>50{logs.removeFirst(logs.count-50)}}
    func saveConfig(){UserDefaults.standard.set(url,forKey:"wo.url");UserDefaults.standard.set(key,forKey:"wo.key");UserDefaults.standard.set(api,forKey:"wo.api");UserDefaults.standard.set(model,forKey:"wo.model");UserDefaults.standard.set(force,forKey:"wo.force");UserDefaults.standard.set(deferVideoDownloads,forKey:"wo.defer.videos");UserDefaults.standard.set(bookmarkDomains,forKey:"wo.bookmark.domains");log("[程序] 配置已保存。")}
    func open(){saveConfig();browser.open(url);browserShown=true;log("[程序] 已打开验证浏览器，请完成验证。")}
    func openBookmarkVerification(){
        guard let job=bookmarkJobs.first(where:{$0.status == "pending"}) ?? bookmarkJobs.first else { log("[程序] 请先导入并匹配书签任务。"); return }
        url=job.url; open()
    }
    func save(){Task{if !bookmarkRunning{bookmarkStopRequested=false};downloading=true;downloadStatus="正在准备保存网页…";defer{downloading=false;downloadStatus=""};if let outcome=await work(deferVideos:deferVideoDownloads),deferVideoDownloads,!outcome.videoSources.isEmpty{let job=BookmarkJob(id:UUID(),url:url,status:"done",videoSources:outcome.videoSources,downloadedVideoSources:[],itemID:outcome.itemID,groupID:nil);bookmarkJobs.append(job);persistBookmarkQueue();log("[程序] 已保存视频地址，可在书签任务列表中按需下载。")}}}
    func bookmarkJobs(matching filter: String) -> [BookmarkJob] { filter == "all" ? bookmarkJobs : filter == "none" ? bookmarkJobs.filter{$0.groupID == nil} : bookmarkJobs.filter{$0.groupID?.uuidString == filter} }
    func bookmarkCompleted(matching filter: String) -> Int { bookmarkJobs(matching:filter).filter{$0.status == "done" || $0.status == "failed"}.count }
    func persistBookmarkQueue(){UserDefaults.standard.set(try?JSONEncoder().encode(bookmarkJobs),forKey:"wo.bookmark.queue")}
    func persistArchiveGroups(){UserDefaults.standard.set(try?JSONEncoder().encode(archiveGroups),forKey:"wo.archive.groups")}
    func createArchiveGroup(_ name: String) { let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !trimmed.isEmpty,!archiveGroups.contains(where:{$0.name == trimmed}) else{return};archiveGroups.append(ArchiveGroup(id:UUID(),name:trimmed));persistArchiveGroups();log("[程序] 已创建归档分组《\(trimmed)》。") }
    func removeArchiveGroups(_ offsets: IndexSet) { let ids=Set(offsets.map{archiveGroups[$0].id});archiveGroups.remove(atOffsets:offsets);for index in bookmarkJobs.indices where ids.contains(bookmarkJobs[index].groupID ?? UUID()){bookmarkJobs[index].groupID=nil};for index in items.indices where ids.contains(items[index].groupID ?? UUID()){items[index].groupID=nil};persistArchiveGroups();persistBookmarkQueue();persist() }
    func moveBookmarkJobs(_ ids: Set<UUID>, to groupID: UUID?) { for index in bookmarkJobs.indices where ids.contains(bookmarkJobs[index].id){bookmarkJobs[index].groupID=groupID};persistBookmarkQueue() }
    func moveItems(_ ids: Set<UUID>, to groupID: UUID?) { for index in items.indices where ids.contains(items[index].id){items[index].groupID=groupID};persist() }
    func deleteBookmarkJobs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        bookmarkJobs.removeAll { ids.contains($0.id) }
        persistBookmarkQueue()
        log("[程序] 已删除 \(ids.count) 个书签任务。")
    }
    func importBookmarks(_ file: URL) {
        guard let data=try?Data(contentsOf:file) else { log("[程序] 无法读取书签文件。"); return }
        let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) ?? ""
        let rules=bookmarkDomains.split(whereSeparator:{ $0.isWhitespace || $0 == "," || $0 == ";" }).map{String($0).lowercased().replacingOccurrences(of:"https://",with:"").replacingOccurrences(of:"http://",with:"").trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        guard !rules.isEmpty else { log("[程序] 请先填写要匹配的域名列表。"); return }
        func matches(_ address: URL, rule: String) -> Bool {
            guard let host=address.host?.lowercased() else{return false}
            let pieces=rule.split(separator:"/",maxSplits:1,omittingEmptySubsequences:false),ruleHost=String(pieces[0])
            guard host == ruleHost || host.hasSuffix("."+ruleHost) else{return false}
            guard pieces.count > 1 else{return true}
            return address.path.lowercased().hasPrefix("/" + String(pieces[1]))
        }
        guard let expression=try?NSRegularExpression(pattern:"(?i)href\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]") else { return }
        let links=expression.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap{match -> String? in guard let range=Range(match.range(at:1),in:text),let address=URL(string:String(text[range])),["http","https"].contains(address.scheme?.lowercased() ?? "") else{return nil};return rules.contains(where:{matches(address,rule:$0)}) ? address.absoluteString : nil}
        let known=Set(bookmarkJobs.map{$0.url}).union(Set(items.map{$0.url})); let unique=Array(Set(links)).filter{!known.contains($0)}.sorted()
        bookmarkJobs += unique.map{BookmarkJob(id:UUID(),url:$0,status:"pending",videoSources:[],downloadedVideoSources:[],itemID:nil,groupID:nil)}; persistBookmarkQueue(); log("[程序] 书签共匹配到 \(links.count) 个网页，已加入 \(unique.count) 个未重复任务。")
    }
    func startBookmarkQueue(filter: String="all") {
        guard !bookmarkRunning else{return}; guard !bookmarkJobs(matching:filter).isEmpty else{log("[程序] 当前分组暂无任务。");return}
        activeBookmarkFilter=filter
        for index in bookmarkJobs.indices where bookmarkJobs(matching:filter).contains(where:{$0.id == bookmarkJobs[index].id}) && bookmarkJobs[index].status == "failed" { bookmarkJobs[index].status="pending" }
        persistBookmarkQueue();bookmarkStopRequested=false;bookmarkRunning=true
        Task { await runBookmarkQueue() }
    }
    func stopBookmarkQueue(){bookmarkStopRequested=true;log("[程序] 已请求暂停；为保护当前网页，正在完成或安全中止当前任务。")}
    func runBookmarkQueue() async {
        defer { bookmarkRunning=false;persistBookmarkQueue() }
        while let index=bookmarkJobs.indices.first(where:{candidateIndex in bookmarkJobs[candidateIndex].status == "pending" && bookmarkJobs(matching:activeBookmarkFilter).contains(where:{job in job.id == bookmarkJobs[candidateIndex].id})}) {
            if bookmarkStopRequested || Task.isCancelled { break }
            bookmarkCurrent=bookmarkCompleted(matching:activeBookmarkFilter) + 1; url=bookmarkJobs[index].url; downloadStatus="正在准备保存网页…"; saveConfig();log("[程序] 正在处理书签任务 \(bookmarkCurrent)/\(bookmarkJobs(matching:activeBookmarkFilter).count)：\(url)")
            let outcome=await work(deferVideos:deferVideoDownloads)
            downloadStatus=""
            if bookmarkStopRequested || Task.isCancelled { break }
            if let outcome { bookmarkJobs[index].status="done";bookmarkJobs[index].itemID=outcome.itemID;bookmarkJobs[index].videoSources=outcome.videoSources;bookmarkJobs[index].downloadedVideoSources=[];if let itemIndex=items.firstIndex(where:{$0.id == outcome.itemID}){items[itemIndex].groupID=bookmarkJobs[index].groupID;persist()} }
            else { bookmarkJobs[index].status="failed" }
            persistBookmarkQueue()
        }
        if bookmarkStopRequested { log("[程序] 书签任务已暂停，可随时继续。") }
        else { log("[程序] 书签队列已处理完成：\(bookmarkCompleted(matching:activeBookmarkFilter))/\(bookmarkJobs(matching:activeBookmarkFilter).count)。") }
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
    func exclusionMarks(_ raw: String) -> [[String:String]] {
        guard let data=raw.data(using:.utf8) else{return []}
        return (try?JSONDecoder().decode([[String:String]].self,from:data)) ?? []
    }
    func manualRulesFromMarks(_ raw: String) -> [ManualExclusion] {
        exclusionMarks(raw).compactMap { mark in
            guard let tag=mark["tag"],!tag.isEmpty else{return nil}
            return ManualExclusion(selector:mark["selector"],id:mark["id"] ?? "",tag:tag,classes:mark["classes"] ?? "",text:mark["text"] ?? "")
        }
    }
    func selectorsFromManualMarks(_ raw: String) -> [String] {
        exclusionMarks(raw).compactMap { mark in
            if let selector=mark["selector"],!selector.isEmpty,selector != ":scope" { return selector }
            if let id=mark["id"],!id.isEmpty { return "#\(id)" }
            guard let tag=mark["tag"],!tag.isEmpty else{return nil}
            let classes=(mark["classes"] ?? "").split(separator:" ").filter { !$0.isEmpty && $0 != "wos-exclude-selected" }
            guard !classes.isEmpty else{return nil}
            return tag + classes.prefix(3).map { ".\($0)" }.joined()
        }
    }
    func getPlan(host:String,skeleton:String,exclusionHints:String="",forceFresh:Bool=false) async throws->Plan {let k="wo.plan.\(host)";if !force,!forceFresh,let d=UserDefaults.standard.data(forKey:k),let cached=try?JSONDecoder().decode(CachedPlan.self,from:d),cached.version == 3 {log("[程序] 复用 \(host) 已保存的网页结构，不调用 AI。");return cached.plan};log(exclusionHints.isEmpty ? "[AI] 正在识别标题与主体区域…" : "[AI] 正在根据非主体标记修正网页结构…");let hint=exclusionHints.isEmpty ? "" : "\n用户在已下载预览中标记了以下非主体 DOM 片段。必须在新的 excludes 中排除与这些片段对应的区域：\n\(exclusionHints)\n";let prompt="分析网页结构，不要输出正文。返回 JSON：contentSelector（标题 CSS selector 不在此；只包住正文/图片/视频的最小 CSS selector）、titleSelector（标题 CSS selector）、excludes（需从主体内删除的 CSS selector 数组）。必须排除广告、推广按钮、菜单、分享控件、上一篇下一篇、标签、下载推广、相关推荐、评论、侧栏和页脚。不要用一个包含这些区域的大容器代替排除规则。\(hint)URL=\(url)\n完整网页结构：\(skeleton)";var r=URLRequest(url:URL(string:api.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/chat/completions")!);r.httpMethod="POST";r.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type");r.httpBody=try JSONSerialization.data(withJSONObject:["model":model,"temperature":0.1,"response_format":["type":"json_object"],"messages":[["role":"user","content":prompt]]]);let(d,_)=try await URLSession.shared.data(for:r);let o=try JSONSerialization.jsonObject(with:d)as![String:Any];let s=(((o["choices"]as?[[String:Any]])?.first?["message"]as?[String:Any])?["content"]as?String) ?? "{}";let inferred=try JSONDecoder().decode(Plan.self,from:Data(s.utf8));let manual=manualRulesFromMarks(exclusionHints);let selectors=selectorsFromManualMarks(exclusionHints);let plan=Plan(contentSelector:inferred.contentSelector,titleSelector:inferred.titleSelector,excludes:Array(Set(inferred.excludes+selectors)).sorted(),manualExclusions:Array(Set((inferred.manualExclusions ?? [])+manual)));UserDefaults.standard.set(try JSONEncoder().encode(CachedPlan(version:3,plan:plan)),forKey:k);if !manual.isEmpty{log("[程序] 已将 \(manual.count) 条手动标记转为主体结构的 DOM 排除规则。")};return plan}
    func validImage(_ data: Data) -> Bool {
        let bytes=[UInt8](data.prefix(16))
        return bytes.starts(with:[0xFF,0xD8,0xFF]) || bytes.starts(with:[0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]) || bytes.starts(with:[0x47,0x49,0x46,0x38]) || (bytes.count >= 12 && Array(bytes[0..<4]) == [0x52,0x49,0x46,0x46] && Array(bytes[8..<12]) == [0x57,0x45,0x42,0x50]) || (bytes.count >= 12 && String(bytes:bytes[4..<12],encoding:.ascii)?.contains("ftypavif") == true)
    }
    func imageRuleKeys(_ host: String?, kind: String) -> [String] { guard let host else{return []};let parts=host.lowercased().split(separator:".");let root=parts.count >= 2 ? parts.suffix(2).joined(separator:".") : host.lowercased();return ["\(kind):\(host.lowercased())","\(kind):\(root)"] }
    func shouldUseRenderedImage(_ source: String) -> Bool {
        let imageKeys=imageRuleKeys(URL(string:source)?.host,kind:"image")
        let pageKeys=imageRuleKeys(URL(string:url)?.host,kind:"page")
        return imageKeys.contains(where:renderedImageRules.contains) || pageKeys.contains(where:renderedImageRules.contains)
    }
    func rememberRenderedImageRule(_ source: String) {
        let previous=renderedImageRules.count
        imageRuleKeys(URL(string:source)?.host,kind:"image").forEach{renderedImageRules.insert($0)}
        imageRuleKeys(URL(string:url)?.host,kind:"page").forEach{renderedImageRules.insert($0)}
        guard renderedImageRules.count != previous else { return }
        UserDefaults.standard.set(Array(renderedImageRules).sorted(),forKey:"wo.rendered.image.rules")
        log("[程序] 已记住该网页的图片需要从已渲染页面保存。")
    }
    func htmlEscaped(_ value: String) -> String { value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
    func replaceResourceReference(_ html: String, source: String, local: String) -> String { let replaced=html.replacingOccurrences(of:source,with:local);let escaped=source.replacingOccurrences(of:"&",with:"&amp;");return escaped == source ? replaced : replaced.replacingOccurrences(of:escaped,with:local) }
    func placeholderImage(in assets: URL) -> String {
        let file=assets.appendingPathComponent("placeholder.png")
        if !fm.fileExists(atPath:file.path) {
            let renderer=UIGraphicsImageRenderer(size:CGSize(width:200,height:200))
            let image=renderer.image { context in
                context.cgContext.setFillColor(UIColor(white:0.72,alpha:1).cgColor)
                context.cgContext.fill(CGRect(x:0,y:0,width:200,height:200))
                context.cgContext.setStrokeColor(UIColor(white:0.58,alpha:1).cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.stroke(CGRect(x:24,y:24,width:152,height:152))
            }
            if let data=image.pngData() { try?data.write(to:file,options:.atomic) }
        }
        return "assets/placeholder.png"
    }
    func renderedImage(_ source:String, assets:URL, number:Int) async -> String? {
        guard let encoded=try?JSONEncoder().encode(source),let literal=String(data:encoded,encoding:.utf8) else{return nil}
        // Return one rendered image at a time.  Returning every canvas together
        // with the article HTML exceeds WebKit's JS bridge response limit.
        let script="""
        (()=>{const wanted=\(literal),same=(value=>{if(!value)return false;if(value===wanted)return true;try{const a=new URL(value,document.baseURI),b=new URL(wanted,document.baseURI);return a.origin===b.origin&&a.pathname===b.pathname}catch(_){return false}});const image=[...document.images].find(x=>[x.currentSrc,x.src,x.getAttribute('data-xkrkllgl'),x.getAttribute('data-original'),x.getAttribute('data-lazy-src'),x.getAttribute('data-src')].some(same));if(!image)return null;try{const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;if(!canvas.width||!canvas.height)return null;canvas.getContext('2d').drawImage(image,0,0);return canvas.toDataURL('image/png')}catch(_){return null}})()
        """
        if let value=try?await browser.js(script),let raw=value as? String,let comma=raw.firstIndex(of:","),let data=Data(base64Encoded:String(raw[raw.index(after:comma)...])),validImage(data) {
            let name=String(format:"%03d.png",number);try?data.write(to:assets.appendingPathComponent(name),options:.atomic);return "assets/\(name)"
        }
        guard let snapshot=await browser.snapshotRenderedImage(source),validImage(snapshot) else{return nil}
        let name=String(format:"%03d.png",number);try?snapshot.write(to:assets.appendingPathComponent(name),options:.atomic);return "assets/\(name)"
    }
    func localAsset(_ source: String, assets: URL, number: Int, imageOnly: Bool=false) async -> String? {
        if source.lowercased().hasPrefix("data:image/") {
            let parts=source.split(separator:",",maxSplits:1).map(String.init)
            guard parts.count == 2, let data=Data(base64Encoded:parts[1]) else { return nil }
            let mime=parts[0].lowercased(); let ext=mime.contains("png") ? "png" : mime.contains("gif") ? "gif" : mime.contains("webp") ? "webp" : "jpg"
            let name=String(format:"%03d.%@",number,ext); try? data.write(to:assets.appendingPathComponent(name),options:.atomic); return "assets/\(name)"
        }
        guard let remote = URL(string: source), ["http", "https"].contains(remote.scheme?.lowercased() ?? "") else { return nil }
        if imageOnly {
            for _ in 0..<3 {
                if let rendered=await renderedImage(source,assets:assets,number:number) { return rendered }
                try?await Task.sleep(nanoseconds:250_000_000)
            }
            return nil
        }
        do {
            var request = URLRequest(url: remote); request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", forHTTPHeaderField: "User-Agent"); request.setValue(imageOnly ? "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" : "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",forHTTPHeaderField:"Accept");request.setValue("zh-CN,zh;q=0.9,en;q=0.8",forHTTPHeaderField:"Accept-Language");request.setValue(url,forHTTPHeaderField:"Referer"); let cookies=await browser.cookieHeader(for:remote); if !cookies.isEmpty{request.setValue(cookies,forHTTPHeaderField:"Cookie")}
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { if imageOnly { rememberRenderedImageRule(source);return await renderedImage(source,assets:assets,number:number) };return nil }
            let mime = (response.mimeType ?? "").lowercased()
            let pathExt = remote.pathExtension.lowercased()
            let ext: String = mime.contains("png") ? "png" : mime.contains("jpeg") || mime.contains("jpg") ? "jpg" : mime.contains("gif") ? "gif" : mime.contains("webp") ? "webp" : mime.contains("mp4") ? "mp4" : pathExt.isEmpty ? "bin" : pathExt
            let name = String(format: "%03d.%@", number, ext)
            guard !imageOnly || validImage(data) else { rememberRenderedImageRule(source);return await renderedImage(source,assets:assets,number:number) }
            try data.write(to: assets.appendingPathComponent(name), options: .atomic)
            return "assets/\(name)"
        } catch { if imageOnly { rememberRenderedImageRule(source);return await renderedImage(source,assets:assets,number:number) };log("[程序] 资源下载失败：\(source)（\(error.localizedDescription)）");return nil }
    }
    func legacyImageSource(for item: Item, ordinal: Int) async throws -> String? {
        url=item.url
        try await browser.load(item.url)
        try await browser.prepareRenderedImages()
        let skeleton=try await browser.js("(()=>[...document.querySelectorAll('main,article,section,div')].slice(0,500).map(x=>'<'+x.tagName.toLowerCase()+' id=\"'+(x.id||'')+'\" class=\"'+(x.className||'')+'\">').join('\\n'))()") as? String ?? ""
        let host=URL(string:item.url)?.host ?? "site"
        let plan=try await getPlan(host:host,skeleton:skeleton)
        let selector=String(data:try JSONEncoder().encode(plan.contentSelector),encoding:.utf8)!
        let excludes=String(data:try JSONEncoder().encode(plan.excludes),encoding:.utf8)!
        let script="""
        (()=>{const root=document.querySelector(\(selector))?.cloneNode(true);if(!root)return '[]';const remove=value=>{try{root.querySelectorAll(value).forEach(node=>node.remove())}catch(_){}};\(excludes).forEach(remove);const absolute=value=>{try{return new URL(value,document.baseURI).href}catch(_){return value}};return JSON.stringify([...root.querySelectorAll('img')].map(image=>image.getAttribute('data-xkrkllgl')||image.getAttribute('data-original')||image.getAttribute('data-lazy-src')||image.getAttribute('data-src')||image.getAttribute('src')||'').filter(Boolean).map(absolute))})()
        """
        guard let raw=try await browser.js(script) as? String,
              let sources=try?JSONDecoder().decode([String].self,from:Data(raw.utf8)),
              sources.indices.contains(ordinal) else{return nil}
        return sources[ordinal]
    }
    func rerenderImage(for item: Item, source: String, ordinal: Int, destination: URL) async -> Bool {
        let previousURL=url
        defer { url=previousURL }
        do {
            var original=source
            if !(original.lowercased().hasPrefix("http://") || original.lowercased().hasPrefix("https://")) {
                guard let recovered=try await legacyImageSource(for:item,ordinal:ordinal) else { log("[程序] 无法从原网页恢复这张图片的地址。");return false }
                original=recovered
            } else {
                url=item.url
                try await browser.load(item.url)
                try await browser.prepareRenderedImages()
            }
            let assets=destination.deletingLastPathComponent()
            guard let relative=await renderedImage(original,assets:assets,number:9999) else { log("[程序] 重新渲染保存失败：页面没有可捕获的图片像素。");return false }
            let temporary=assets.appendingPathComponent(relative.replacingOccurrences(of:"assets/",with:""))
            guard fm.fileExists(atPath:temporary.path) else{return false}
            try?fm.removeItem(at:destination)
            try fm.moveItem(at:temporary,to:destination)
            log("[程序] 已重新渲染保存图片。")
            return true
        } catch {
            log("[程序] 重新渲染保存失败：\(error.localizedDescription)")
            return false
        }
    }
    /// Fetches the ordinary HLS media playlist and its dependencies in batches of
    /// four.  FFmpeg is still used for the final remux so encrypted/fMP4 streams
    /// retain their original timing and container metadata.
    func hlsRequest(_ remote: URL) async throws -> (Data, URL) {
        var request=URLRequest(url:remote)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",forHTTPHeaderField:"User-Agent")
        request.setValue(url,forHTTPHeaderField:"Referer")
        let cookies=await browser.cookieHeader(for:remote)
        if !cookies.isEmpty { request.setValue(cookies,forHTTPHeaderField:"Cookie") }
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),!data.isEmpty else { throw URLError(.badServerResponse) }
        return (data,response.url ?? remote)
    }
    func hlsURI(_ text: String) -> String? {
        guard let regex=try?NSRegularExpression(pattern:"URI=\\\"([^\\\"]+)\\\""),let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let range=Range(match.range(at:1),in:text) else { return nil }
        return String(text[range])
    }
    func hlsMediaPlaylist(_ source: URL) async throws -> (String, URL) {
        var current=source
        for _ in 0..<3 {
            let (data,finalURL)=try await hlsRequest(current)
            guard let playlist=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.unicode) else { throw URLError(.cannotDecodeContentData) }
            let lines=playlist.components(separatedBy:.newlines)
            guard let marker=lines.firstIndex(where:{$0.uppercased().hasPrefix("#EXT-X-STREAM-INF")}) else { return (playlist,finalURL) }
            guard let path=lines[(marker + 1)...].first(where:{let clean=$0.trimmingCharacters(in:.whitespacesAndNewlines);return !clean.isEmpty && !clean.hasPrefix("#")}),let next=URL(string:path.trimmingCharacters(in:.whitespacesAndNewlines),relativeTo:finalURL)?.absoluteURL else { throw URLError(.cannotParseResponse) }
            current=next
        }
        throw URLError(.cannotParseResponse)
    }
    func fourWayHLS(_ remote: URL, assets: URL, number: Int) async throws -> URL {
        let (playlist,playlistURL)=try await hlsMediaPlaylist(remote)
        let lines=playlist.components(separatedBy:.newlines)
        // Byte-range playlists need their original HTTP range semantics; the
        // sequential FFmpeg fallback below remains the safe path for those.
        guard !lines.contains(where:{$0.uppercased().hasPrefix("#EXT-X-BYTERANGE")}) else { throw URLError(.unsupportedURL) }
        var originals:[String]=[]
        for line in lines {
            let clean=line.trimmingCharacters(in:.whitespacesAndNewlines)
            let raw: String?
            if clean.uppercased().hasPrefix("#EXT-X-KEY") || clean.uppercased().hasPrefix("#EXT-X-MAP") { raw=hlsURI(clean) }
            else if !clean.isEmpty && !clean.hasPrefix("#") { raw=clean }
            else { raw=nil }
            if let raw,let absolute=URL(string:raw,relativeTo:playlistURL)?.absoluteURL.absoluteString,!originals.contains(absolute) { originals.append(absolute) }
        }
        guard !originals.isEmpty else { throw URLError(.cannotParseResponse) }
        let work=assets.appendingPathComponent("hls-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:work,withIntermediateDirectories:true)
        var names:[String:String]=[:]
        for (index,original) in originals.enumerated() {
            let ext=URL(string:original)?.pathExtension.isEmpty == false ? URL(string:original)!.pathExtension : "bin"
            names[original]=String(format:"%04d.%@",index,ext)
        }
        var payloads=[String:Data]()
        var completed=0
        var start=0
        while start < originals.count {
            let batch=Array(originals[start..<min(start + 4,originals.count)])
            let received=try await withThrowingTaskGroup(of:(String,Data).self,returning:[(String,Data)].self) { group in
                for original in batch { group.addTask { let (data,_)=try await self.hlsRequest(URL(string:original)!); return (original,data) } }
                var result:[(String,Data)]=[]
                for try await part in group { result.append(part) }
                return result
            }
            for (original,data) in received { payloads[original]=data }
            completed += batch.count
            downloadStatus="正在以 4 线程下载 HLS 分片：\(completed)/\(originals.count)"
            start += batch.count
        }
        for original in originals { guard let name=names[original],let data=payloads[original] else { throw URLError(.cannotLoadFromNetwork) };try data.write(to:work.appendingPathComponent(name),options:.atomic) }
        var rewritten:[String]=[]
        for line in lines {
            let clean=line.trimmingCharacters(in:.whitespacesAndNewlines)
            if (clean.uppercased().hasPrefix("#EXT-X-KEY") || clean.uppercased().hasPrefix("#EXT-X-MAP")),let raw=hlsURI(clean),let absolute=URL(string:raw,relativeTo:playlistURL)?.absoluteURL.absoluteString,let local=names[absolute] { rewritten.append(line.replacingOccurrences(of:raw,with:local)) }
            else if !clean.isEmpty && !clean.hasPrefix("#"),let absolute=URL(string:clean,relativeTo:playlistURL)?.absoluteURL.absoluteString,let local=names[absolute] { rewritten.append(local) }
            else { rewritten.append(line) }
        }
        let localPlaylist=work.appendingPathComponent("offline.m3u8")
        try rewritten.joined(separator:"\n").write(to:localPlaylist,atomically:true,encoding:.utf8)
        return localPlaylist
    }
    func remuxHLS(_ input: URL, target: URL, referer: String, requestHeaders: String) async -> Bool {
        let monitor=Task { [weak self] in
            while !Task.isCancelled {
                let size=((try?target.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
                await MainActor.run { self?.downloadStatus="正在转存 HLS 视频：已写入 \(String(format:"%.1f",Double(size)/1_048_576)) MB" }
                try? await Task.sleep(nanoseconds:500_000_000)
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool,Never>) in
            DispatchQueue.global(qos:.userInitiated).async {
                var message: NSString?
                let succeeded=WOSRemuxHLS(input,target,referer,requestHeaders,&message)
                Task { @MainActor in
                    monitor.cancel()
                    if succeeded { self.downloadStatus="HLS 视频已转存完成";self.log("[程序] 已将 HLS 视频转存为本地 MP4。"); continuation.resume(returning:true) }
                    else { self.log("[程序] HLS 视频转存失败：\(message as String? ?? "未知错误")"); continuation.resume(returning:false) }
                }
            }
        }
    }
    func localHLS(_ source: String, assets: URL, number: Int) async -> String? {
        guard let remote=URL(string:source) else { return nil }
        let target=assets.appendingPathComponent(String(format:"%03d.mp4",number))
        downloadStatus="正在准备 4 线程 HLS 下载…"
        do {
            let localPlaylist=try await fourWayHLS(remote,assets:assets,number:number)
            defer { try?fm.removeItem(at:localPlaylist.deletingLastPathComponent()) }
            log("[程序] HLS 视频正在以 4 线程并发下载分片。")
            let result=await remuxHLS(localPlaylist,target:target,referer:"",requestHeaders:"")
            if result { return "assets/\(target.lastPathComponent)" }
        } catch { log("[程序] 4 线程 HLS 下载不适用于此播放列表，已切换兼容模式。") }
        downloadStatus="正在兼容模式转存 HLS 视频…"
        let cookies=await browser.cookieHeader(for:remote)
        let requestHeaders=cookies.isEmpty ? "" : "Cookie: \(cookies)\r\n"
        return await remuxHLS(remote,target:target,referer:url,requestHeaders:requestHeaders) ? "assets/\(target.lastPathComponent)" : nil
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
    func discardStoredPage(for index: Int) {
        if let itemID=bookmarkJobs[index].itemID,let itemIndex=items.firstIndex(where:{$0.id == itemID}) { try?fm.removeItem(at:URL(fileURLWithPath:items[itemIndex].file).deletingLastPathComponent());items.remove(at:itemIndex);persist() }
        bookmarkJobs[index].status="pending";bookmarkJobs[index].videoSources=[];bookmarkJobs[index].downloadedVideoSources=[];bookmarkJobs[index].itemID=nil
        _ = cleanupOrphanedLibrary()
    }
    func refreshVideoAddresses(for index: Int) async -> Bool {
        let pageURL=bookmarkJobs[index].url
        discardStoredPage(for:index); url=pageURL; downloadStatus="视频地址已失效，正在重新解析…"; log("[程序] 视频地址已失效，正在自动重新解析网页。")
        guard let outcome=await work(deferVideos:true) else { bookmarkJobs[index].status="failed";return false }
        bookmarkJobs[index].status="done";bookmarkJobs[index].itemID=outcome.itemID;bookmarkJobs[index].videoSources=outcome.videoSources;bookmarkJobs[index].downloadedVideoSources=[]
        return true
    }
    func downloadVideosForJob(_ index: Int) async -> Bool {
        let job=bookmarkJobs[index], sources=job.videoSources ?? [], downloaded=Set(job.downloadedVideoSources ?? [])
        let pending=sources.filter{!downloaded.contains($0)}
        guard !pending.isEmpty else { log("[程序] 该任务没有待下载的视频。"); return true }
        guard let itemID=job.itemID,let item=items.first(where:{$0.id == itemID}),var html=try?String(contentsOfFile:item.file,encoding:.utf8) else { return false }
        url=job.url; let folder=URL(fileURLWithPath:item.file).deletingLastPathComponent(),assets=folder.appendingPathComponent("assets",isDirectory:true);var failed=false
        for (offset,source) in pending.enumerated() {
            let ordinal=(sources.firstIndex(of:source) ?? offset) + 1
            downloadStatus="正在下载视频 \(offset + 1)/\(pending.count)…"; log("[程序] 视频资源地址：\(source)")
            let cache=videoCacheFile(pageURL:job.url,ordinal:ordinal)
            var local:String?
            if fm.fileExists(atPath:cache.path) { local="../MediaCache/\(cache.lastPathComponent)" }
            else { let raw=source.lowercased().contains(".m3u8") ? await localHLS(source,assets:assets,number:1000 + ordinal) : await localAsset(source,assets:assets,number:1000 + ordinal);if let raw { local=cacheVideo(local:raw,folder:folder,pageURL:job.url,ordinal:ordinal) } }
            if let local { html=replaceResourceReference(html,source:source,local:local);bookmarkJobs[index].downloadedVideoSources=(bookmarkJobs[index].downloadedVideoSources ?? []) + [source] }
            else { failed=true }
        }
        try?html.write(toFile:item.file,atomically:true,encoding:.utf8)
        return !failed
    }
    func downloadVideos(for ids: Set<UUID>) {
        guard !ids.isEmpty, !videoDownloadRunning else { return }
        bookmarkStopRequested=false
        Task {
            videoDownloadRunning=true; defer { videoDownloadRunning=false;videoDownloadingJobs=[];downloadStatus="";persistBookmarkQueue() }
            for index in bookmarkJobs.indices where ids.contains(bookmarkJobs[index].id) {
                videoDownloadingJobs.insert(bookmarkJobs[index].id)
                var succeeded=await downloadVideosForJob(index)
                if !succeeded,await refreshVideoAddresses(for:index) { succeeded=await downloadVideosForJob(index) }
                if !succeeded { log("[程序] 视频下载失败，自动重新解析后仍未成功。") }
                videoDownloadingJobs.remove(bookmarkJobs[index].id)
            }
        }
    }
    func work(deferVideos: Bool=false,exclusionHints:String="",forceFreshPlan:Bool=false) async -> SaveOutcome? {
        guard !url.isEmpty, !key.isEmpty else { log("[程序] 请填写网页地址和 API Key。"); return nil }
        guard !bookmarkStopRequested, !Task.isCancelled else { return nil }
        var stage="初始化"
        do {
            saveConfig(); stage="读取已验证网页";log("[程序] 正在读取网页…");try await browser.load(url)
            stage="等待正文图片渲染";try await browser.prepareRenderedImages()
            stage="生成网页结构骨架"
            let skeleton = try await browser.js("(()=>[...document.querySelectorAll('main,article,section,div')].slice(0,500).map(x=>'<'+x.tagName.toLowerCase()+' id=\"'+(x.id||'')+'\" class=\"'+(x.className||'')+'\">').join('\\n'))()") as? String ?? ""
            let host = URL(string:url)?.host ?? "site"; stage="AI 主体结构识别";let p = try await getPlan(host:host, skeleton:skeleton,exclusionHints:exclusionHints,forceFresh:forceFreshPlan)
            let q = String(data:try JSONEncoder().encode(p.contentSelector),encoding:.utf8)!; let ex = String(data:try JSONEncoder().encode(p.excludes),encoding:.utf8)!; let ti = String(data:try JSONEncoder().encode(p.titleSelector ?? ""),encoding:.utf8)!; let manualExclusions = String(data:try JSONEncoder().encode(p.manualExclusions ?? []),encoding:.utf8)!
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
              // A user-selected exclusion must be honored even when the AI cannot
              // reconstruct a sufficiently specific CSS selector from the hint.
              // Match the saved DOM by stable ID first, then tag/classes, then text.
              const manualExclusions=\(manualExclusions), normal=value=>(value||'').replace(/\\s+/g,' ').trim(); let manualRemoved=0;
              manualExclusions.forEach(mark=>{
                let candidates=[];
                const tag=(mark.tag||'*').toLowerCase();
                if(mark.selector){try{candidates=[...root.querySelectorAll(mark.selector)]}catch(_){}}
                if(!candidates.length&&mark.id){try{candidates=[...root.querySelectorAll('[id="'+CSS.escape(mark.id)+'"]')]}catch(_){}}
                if(!candidates.length&&mark.classes){const classes=String(mark.classes).split(/\\s+/).filter(value=>value&&value!=='wos-exclude-selected');if(classes.length){try{candidates=[...root.querySelectorAll(tag+classes.map(value=>'.'+CSS.escape(value)).join(''))]}catch(_){}}}
                const text=normal(mark.text).slice(0,140);
                if(!candidates.length&&text){try{candidates=[...root.querySelectorAll(tag)].filter(element=>normal(element.innerText).includes(text))}catch(_){}}
                candidates.filter(element=>element!==root).forEach(element=>{element.remove();manualRemoved++});
              });
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
              root.querySelectorAll('img').forEach(el=>{const source=el.getAttribute('data-xkrkllgl')||el.getAttribute('data-original')||el.getAttribute('data-lazy-src')||el.getAttribute('data-src')||el.getAttribute('src')||'';const resolved=absolute(source);el.setAttribute('src',resolved);el.setAttribute('data-offline-source',resolved);['srcset','data-src','data-original','data-lazy-src','data-xkrkllgl','onload','onclick','style'].forEach(a=>el.removeAttribute(a))});
              root.querySelectorAll('video,source').forEach(el=>{const source=el.getAttribute('src');if(source)el.setAttribute('src',absolute(source));if(el.tagName==='VIDEO'){el.controls=true;el.preload='metadata'}['srcset','onload','onclick','style','autoplay'].forEach(a=>el.removeAttribute(a))});
              root.querySelectorAll('a[href]').forEach(a=>{a.href=absolute(a.getAttribute('href'));a.target='_blank';a.rel='noopener'});
              const resources=[...new Map([...root.querySelectorAll('img')].map(el=>[el.getAttribute('src'),{url:el.getAttribute('src'),kind:'image'}]).concat([...root.querySelectorAll('video,source')].map(el=>[el.getAttribute('src'),{url:el.getAttribute('src'),kind:'video'}])).filter(([url])=>Boolean(url))).values()];
              const titleSelector=\(ti), title=(titleSelector&&document.querySelector(titleSelector)?.innerText||root.querySelector('h1')?.innerText||document.querySelector('h1.entry-title,h1.post-title,.entry-title,.post-title')?.innerText||document.querySelector('meta[property="og:title"],meta[name="twitter:title"]')?.getAttribute('content')||document.title).trim();
              return JSON.stringify({title,html:root.outerHTML,resources,selectedVideo,missingVideo,manualRemoved});
            })()
            """
            stage="提取正文和已渲染图片";guard let raw=try await browser.js(script) as? String else { throw URLError(.cannotParseResponse) }
            let page = try JSONDecoder().decode(CapturedPage.self, from: Data(raw.utf8)); if page.missingVideo == true { throw NSError(domain:"WebOfflineSaver",code:2,userInfo:[NSLocalizedDescriptionKey:"未能从已验证页面取得实际视频资源；已取消保存，避免生成伪离线网页。"])}; if manualExclusions != "[]",(page.manualRemoved ?? 0) == 0{log("[程序] 手动标记未在当前正文根节点中匹配到内容，已继续由 AI 排除规则处理。")}; if let removed=page.manualRemoved,removed>0{log("[程序] 已按手动标记剔除 \(removed) 个非主体节点。")}; if let selected=page.selectedVideo,!selected.isEmpty{log("[程序] 已锁定当前播放器视频地址：\(selected)")}; let id=UUID(), dir=root.appendingPathComponent(id.uuidString), assets=dir.appendingPathComponent("assets",isDirectory:true)
            try fm.createDirectory(at: assets, withIntermediateDirectories:true)
            var fragment = page.html; var saved=0; var videoOrdinal=0; var deferredVideos:[String]=[]
            for (index, asset) in page.resources.enumerated() {
                if bookmarkStopRequested || Task.isCancelled { throw CancellationError() }
                let source=asset.url; let isHLS=source.lowercased().contains(".m3u8")
                let isVideo=asset.kind == "video"
                if isVideo && deferVideos { deferredVideos.append(source); continue }
                if isVideo { videoOrdinal += 1; if let cache=cachedVideo(pageURL:url,ordinal:videoOrdinal){fragment=replaceResourceReference(fragment,source:source,local:"../MediaCache/\(cache.lastPathComponent)");saved += 1;continue};log("[程序] 视频资源地址：\(source)") }
                if isVideo && !isHLS { downloadStatus="正在下载 MP4 视频…" }
                let downloaded=isHLS ? await localHLS(source,assets:assets,number:index + 1) : await localAsset(source, assets:assets, number:index + 1, imageOnly:asset.kind == "image")
                let local=isVideo ? downloaded.flatMap{cacheVideo(local:$0,folder:dir,pageURL:url,ordinal:videoOrdinal)} : downloaded
                if let local { fragment = replaceResourceReference(fragment,source:source,local:local); saved += 1 }
                else if asset.kind == "image" { fragment = replaceResourceReference(fragment,source:source,local:placeholderImage(in:assets)) }
                else if isVideo { throw NSError(domain:"WebOfflineSaver",code:1,userInfo:[NSLocalizedDescriptionKey:"视频资源未能下载，已取消保存以避免生成伪离线网页。"]) }
            }
            let file=dir.appendingPathComponent("index.html"),item=Item(id:id,title:page.title.isEmpty ? host : page.title,url:url,file:file.path,groupID:nil)
            let pageHTML="<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>body{max-width:760px;margin:24px auto;padding:0 16px;font:17px/1.7 -apple-system}.offline-page-title{font-size:1.45em;line-height:1.35;margin:0 0 1em}img,video{max-width:100%;height:auto}video{display:block;margin:14px auto}</style><h1 class='offline-page-title'>\(htmlEscaped(item.title))</h1>\(fragment)"
            try pageHTML.write(to:file,atomically:true,encoding:.utf8);items.insert(item,at:0);persist();var message="[阶段] 已保存《\(item.title)》；已离线保存 \(saved) 个资源。";if deferVideos && !deferredVideos.isEmpty{message += "视频地址已保存，尚未下载。"};log(message); return SaveOutcome(itemID:id,videoSources:deferredVideos)
        } catch is CancellationError { log("[程序] 当前网页保存已安全暂停。"); return nil }
        catch { log("[程序] 保存失败（\(stage)）：\(error.localizedDescription)"); return nil }
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
    func deleteItems(_ ids: Set<UUID>) {
        guard !ids.isEmpty else{return}
        for item in items where ids.contains(item.id) { try?fm.removeItem(at:URL(fileURLWithPath:item.file).deletingLastPathComponent()) }
        items.removeAll{ids.contains($0.id)};persist();_ = cleanupOrphanedLibrary();log("[程序] 已删除 \(ids.count) 个已下载网页及对应资源。")
    }
    func reparseExcluding(_ item: Item, hints: String, onReplacement: @escaping (Item) -> Void = { _ in }) {
        guard !downloading else { return }
        guard !hints.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,hints != "[]" else { log("[程序] 请先标记需要剔除的非主体内容。");return }
        Task {
            bookmarkStopRequested=false;url=item.url;downloading=true;downloadStatus="正在按非主体标记重新识别网页…"
            defer { downloading=false;downloadStatus="" }
            guard let outcome=await work(deferVideos:deferVideoDownloads,exclusionHints:hints,forceFreshPlan:true) else { return }
            guard let replacement=items.firstIndex(where:{$0.id == outcome.itemID}) else { return }
            items[replacement].groupID=item.groupID
            let replacementItem=items[replacement]
            if let previous=items.firstIndex(where:{$0.id == item.id}) { try?fm.removeItem(at:URL(fileURLWithPath:items[previous].file).deletingLastPathComponent());items.remove(at:previous) }
            if let jobIndex=bookmarkJobs.firstIndex(where:{$0.itemID == item.id}) { bookmarkJobs[jobIndex].itemID=outcome.itemID;bookmarkJobs[jobIndex].videoSources=outcome.videoSources;bookmarkJobs[jobIndex].downloadedVideoSources=[] }
            else if deferVideoDownloads,!outcome.videoSources.isEmpty { bookmarkJobs.append(BookmarkJob(id:UUID(),url:item.url,status:"done",videoSources:outcome.videoSources,downloadedVideoSources:[],itemID:outcome.itemID,groupID:item.groupID)) }
            persist();persistBookmarkQueue();_ = cleanupOrphanedLibrary();log("[程序] 已按非主体标记重新识别并替换《\(item.title)》。")
            onReplacement(replacementItem)
        }
    }
    func persist(){try?fm.createDirectory(at:root,withIntermediateDirectories:true);try?JSONEncoder().encode(items).write(to:root.appendingPathComponent("catalog.json"))}
}
struct Home:View{
    @EnvironmentObject var s:Store
    var body:some View{
        TabView {
            WebSaveTab().tabItem{Label("网页保存",systemImage:"square.and.pencil")}
            BookmarkBatchTab().tabItem{Label("书签批量保存",systemImage:"book")}
            DownloadedTab().tabItem{Label("已下载",systemImage:"tray.full")}
            ConfigurationTab().tabItem{Label("配置",systemImage:"gearshape")}
        }.sheet(isPresented:$s.browserShown){WebSheet(browser:s.browser)}
    }
}
struct WebSaveTab:View{
    @EnvironmentObject var s:Store
    var body:some View{NavigationStack{List{
        Section("网页保存"){
            TextField("网页地址",text:$s.url).textInputAutocapitalization(.never)
            Button("打开验证浏览器"){s.open()}
            Button("保存主体网页"){s.save()}.disabled(s.downloading || s.bookmarkRunning)
        }
        if s.downloading || !s.downloadStatus.isEmpty{Section("下载进度"){HStack{if s.downloading{ProgressView()};Text(s.downloadStatus).font(.subheadline)}}}
        Section("日志"){ForEach(s.logs.indices,id:\.self){Text(s.logs[$0]).font(.caption).textSelection(.enabled)}}
    }.navigationTitle("网页保存")}}
}
struct BookmarkBatchTab:View{
    @EnvironmentObject var s:Store
    @State private var importingBookmarks=false
    @State private var selectedJobs=Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var groupFilter="all"
    var visibleJobs:[BookmarkJob] { groupFilter == "all" ? s.bookmarkJobs : groupFilter == "none" ? s.bookmarkJobs.filter{$0.groupID == nil} : s.bookmarkJobs.filter{$0.groupID?.uuidString == groupFilter} }
    var body:some View{NavigationStack{List(selection:$selectedJobs){
        Section("书签批量保存"){
            TextEditor(text:$s.bookmarkDomains).frame(minHeight:72).textInputAutocapitalization(.never)
            Text("填写允许的域名；可用换行、逗号或分号分隔。导入 HTML 书签后，仅保存这些域名及其子域名的超链接。").font(.caption).foregroundStyle(.secondary)
            Button("导入 HTML 书签"){importingBookmarks=true}.disabled(s.bookmarkRunning)
            Button("打开验证浏览器"){s.openBookmarkVerification()}.disabled(s.bookmarkRunning || s.bookmarkJobs.isEmpty)
            if groupFilter != "all" && groupFilter != "none" {
                ProgressView(value:Double(s.bookmarkCompleted(matching:groupFilter)),total:Double(visibleJobs.count))
                Text("任务总数：\(visibleJobs.count)　已处理：\(s.bookmarkCompleted(matching:groupFilter))　当前：\(s.bookmarkRunning ? s.bookmarkCurrent : 0)").font(.subheadline)
                HStack {
                    Button(s.bookmarkRunning ? "正在处理" : "开始／继续"){s.startBookmarkQueue(filter:groupFilter)}.disabled(s.bookmarkRunning)
                    Button("暂停"){s.stopBookmarkQueue()}.disabled(!s.bookmarkRunning)
                }
            } else if !visibleJobs.isEmpty {
                HStack {
                    Button(s.bookmarkRunning ? "正在处理" : "开始／继续"){s.startBookmarkQueue(filter:groupFilter)}.disabled(s.bookmarkRunning)
                    Button("暂停"){s.stopBookmarkQueue()}.disabled(!s.bookmarkRunning)
                }
            }
        }
        Section("归档筛选"){Picker("显示",selection:$groupFilter){Text("全部任务").tag("all");Text("未分组").tag("none");ForEach(s.archiveGroups){group in Text(group.name).tag(group.id.uuidString)}}.onChange(of:groupFilter){_ in selectedJobs.removeAll()}}
        Section("任务列表（\(visibleJobs.count)）"){
            if visibleJobs.isEmpty { Text("当前分组没有任务。").foregroundStyle(.secondary) }
            else { ForEach(visibleJobs){job in
                let videoCount=job.videoSources?.count ?? 0, downloadedCount=job.downloadedVideoSources?.count ?? 0
                HStack {
                    NavigationLink(destination:BookmarkPreview(url:job.url)){VStack(alignment:.leading,spacing:4){Text(job.url).font(.subheadline).lineLimit(2);Text(job.status == "done" ? (videoCount > 0 ? "已保存 \(videoCount) 个视频地址，已下载 \(downloadedCount) 个" : "已完成，无视频") : job.status == "failed" ? "失败，继续时会重试" : "待处理").font(.caption).foregroundStyle(job.status == "failed" ? .red : .secondary)}}
                    if videoCount > 0 { Button { s.downloadVideos(for:Set([job.id])) } label: { Image(systemName:s.videoDownloadingJobs.contains(job.id) ? "arrow.down.circle.fill" : "arrow.down.circle") }.buttonStyle(.borderless).disabled(s.videoDownloadingJobs.contains(job.id) || downloadedCount >= videoCount) }
                }.tag(job.id)
            } }
        }
        if s.bookmarkRunning || s.videoDownloadRunning || !s.downloadStatus.isEmpty{Section("任务进度"){HStack{if s.bookmarkRunning || s.videoDownloadRunning{ProgressView()};Text(s.downloadStatus.isEmpty ? "正在处理书签任务…" : s.downloadStatus).font(.subheadline)}}}
        Section("日志"){ForEach(s.logs.indices,id:\.self){Text(s.logs[$0]).font(.caption).textSelection(.enabled)}}
    }.navigationTitle("书签批量保存").environment(\.editMode,$editMode).toolbar{ToolbarItemGroup(placement:.topBarLeading){Button(editMode.isEditing ? "完成" : "多选"){editMode=editMode.isEditing ? .inactive : .active;if !editMode.isEditing{selectedJobs.removeAll()}};if editMode.isEditing{Button("全选"){selectedJobs=Set(visibleJobs.map{$0.id})}.disabled(visibleJobs.isEmpty)}};ToolbarItem(placement:.topBarTrailing){Button("删除选中"){s.deleteBookmarkJobs(selectedJobs);selectedJobs.removeAll()}.disabled(selectedJobs.isEmpty || s.bookmarkRunning || s.videoDownloadRunning)};ToolbarItemGroup(placement:.bottomBar){Button("下载选中视频"){s.downloadVideos(for:selectedJobs)}.disabled(selectedJobs.isEmpty || s.videoDownloadRunning);Menu("移动到分组"){Button("未分组"){s.moveBookmarkJobs(selectedJobs,to:nil);selectedJobs.removeAll()};ForEach(s.archiveGroups){group in Button(group.name){s.moveBookmarkJobs(selectedJobs,to:group.id);selectedJobs.removeAll()}}}.disabled(selectedJobs.isEmpty);Spacer()}}.fileImporter(isPresented:$importingBookmarks,allowedContentTypes:[.html,.plainText],allowsMultipleSelection:false){result in switch result {case .success(let files):guard let file=files.first else{return};let allowed=file.startAccessingSecurityScopedResource();defer{if allowed{file.stopAccessingSecurityScopedResource()}};s.importBookmarks(file);case .failure(let error):s.log("[程序] 导入书签失败：\(error.localizedDescription)")}}}
    }
}
struct DownloadedTab:View{
    @EnvironmentObject var s:Store
    @State private var selectedItems=Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var groupFilter="all"
    var visibleItems:[Item] { groupFilter == "all" ? s.items : groupFilter == "none" ? s.items.filter{$0.groupID == nil} : s.items.filter{$0.groupID?.uuidString == groupFilter} }
    var body:some View{NavigationStack{
        List(selection:$selectedItems){
            Section("归档筛选"){Picker("显示",selection:$groupFilter){Text("全部网页").tag("all");Text("未分组").tag("none");ForEach(s.archiveGroups){group in Text(group.name).tag(group.id.uuidString)}}.onChange(of:groupFilter){_ in selectedItems.removeAll()}}
            Section("已下载网页（\(visibleItems.count)）") { if visibleItems.isEmpty { Text("当前分组没有已下载网页。").foregroundStyle(.secondary) } else { ForEach(visibleItems){item in NavigationLink(destination:OfflinePreview(item:item)){Text(item.title).foregroundStyle(.primary)}.tag(item.id)}.onDelete { offsets in s.deleteItems(Set(offsets.map{visibleItems[$0].id})) } } }
        }.navigationTitle("已下载").environment(\.editMode,$editMode).toolbar{
            ToolbarItemGroup(placement:.topBarLeading){Button(editMode.isEditing ? "完成" : "多选"){editMode=editMode.isEditing ? .inactive : .active;if !editMode.isEditing{selectedItems.removeAll()}};if editMode.isEditing{Button("全选"){selectedItems=Set(visibleItems.map{$0.id})}.disabled(visibleItems.isEmpty)}}
            ToolbarItem(placement:.topBarTrailing){Button("删除选中"){s.deleteItems(selectedItems);selectedItems.removeAll()}.disabled(selectedItems.isEmpty)}
            ToolbarItem(placement:.bottomBar){Menu("移动到分组"){Button("未分组"){s.moveItems(selectedItems,to:nil);selectedItems.removeAll()};ForEach(s.archiveGroups){group in Button(group.name){s.moveItems(selectedItems,to:group.id);selectedItems.removeAll()}}}.disabled(selectedItems.isEmpty)}
        }
    }}
}
struct ConfigurationTab: View {
    @EnvironmentObject var s: Store
    @State private var newGroupName=""
    var body: some View { NavigationStack { List {
        Section("大模型配置") {
            SecureField("DeepSeek API Key", text: $s.key)
            TextField("API URL", text: $s.api).textInputAutocapitalization(.never)
            TextField("模型", text: $s.model).textInputAutocapitalization(.never)
            Button("刷新模型列表") { s.refreshModels() }
            if !s.models.isEmpty { Picker("选择模型", selection: $s.model) { ForEach(s.models,id:\.self) { Text($0).tag($0) } } }
            Toggle("每次都 AI 识别", isOn: $s.force)
            Toggle("延后下载视频（仅保存视频地址）", isOn: $s.deferVideoDownloads)
            Text("默认开启。开启后，网页会先保存正文、图片和视频地址；可稍后在“书签批量保存”中手动下载视频。关闭后会在保存网页时直接下载视频。").font(.caption).foregroundStyle(.secondary)
            Button("保存配置") { s.saveConfig() }
        }
        Section("归档分组") {
            HStack { TextField("新分组名称",text:$newGroupName);Button("新建"){s.createArchiveGroup(newGroupName);newGroupName=""} }
            if s.archiveGroups.isEmpty { Text("创建分组后，可将书签任务和已下载网页移动到其中。删除分组不会删除其中的内容，只会恢复为未分组。").font(.caption).foregroundStyle(.secondary) }
            else { ForEach(s.archiveGroups){group in Text(group.name)}.onDelete(perform:s.removeArchiveGroups) }
        }
    }.navigationTitle("配置") } }
}
struct BookmarkPreview: View {
    let url: String
    @StateObject private var browser = Browser()
    var body: some View {
        Web(browser: browser)
            .navigationTitle("网页预览")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { browser.open(url) }
    }
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
    @EnvironmentObject var s: Store
    @State private var activeItem: Item
    @State private var markingNonContent=false
    @State private var collectGeneration=0
    @State private var clearGeneration=0
    init(item: Item) { _activeItem=State(initialValue:item) }
    var body: some View {
        LocalWebView(file: URL(fileURLWithPath: activeItem.file),title:activeItem.title,markingNonContent:$markingNonContent,collectGeneration:collectGeneration,clearGeneration:clearGeneration,onCollected: { hints in
            s.reparseExcluding(activeItem,hints:hints) { replacement in activeItem=replacement;markingNonContent=false }
        },onRerender: { destination,source,ordinal in
            await s.rerenderImage(for:activeItem,source:source,ordinal:ordinal,destination:destination)
        }).id(activeItem.id)
            .navigationTitle(markingNonContent ? "点选应剔除的内容" : activeItem.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement:.topBarTrailing) {
                    Button { markingNonContent.toggle() } label: { Image(systemName:markingNonContent ? "minus.circle.fill" : "minus.circle") }.accessibilityLabel(markingNonContent ? "结束标记非主体" : "标记非主体")
                    Button { collectGeneration += 1 } label: { Image(systemName:"paperplane.fill") }.accessibilityLabel("提交非主体标记并重新识别").disabled(s.downloading)
                    Button { clearGeneration += 1 } label: { Image(systemName:"trash") }.accessibilityLabel("清除非主体标记")
                }
            }
    }
}
struct LocalWebView: UIViewRepresentable {
    let file: URL
    let title: String
    @Binding var markingNonContent: Bool
    let collectGeneration: Int
    let clearGeneration: Int
    let onCollected: (String) -> Void
    let onRerender: (URL, String, Int) async -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(owner:self) }
    func makeUIView(context: Context) -> WKWebView { let configuration=WKWebViewConfiguration();configuration.userContentController.add(context.coordinator,name:"offlineImage");let view=WKWebView(frame:.zero,configuration:configuration);view.navigationDelegate=context.coordinator;view.uiDelegate=context.coordinator;view.loadFileURL(file, allowingReadAccessTo:file.deletingLastPathComponent().deletingLastPathComponent());return view }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.onCollected=onCollected;context.coordinator.onRerender=onRerender;context.coordinator.setExcludeMode(in:view,enabled:markingNonContent);if context.coordinator.lastClearGeneration != clearGeneration { context.coordinator.lastClearGeneration=clearGeneration;context.coordinator.clearExcluded(in:view) };if context.coordinator.lastCollectGeneration != collectGeneration { context.coordinator.lastCollectGeneration=collectGeneration;context.coordinator.collectExcluded(in:view) } }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let owner: LocalWebView
        var onCollected: (String) -> Void
        var onRerender: (URL, String, Int) async -> Bool
        var excludeMode=false
        var lastCollectGeneration=0
        var lastClearGeneration=0
        init(owner: LocalWebView) { self.owner=owner;self.onCollected=owner.onCollected;self.onRerender=owner.onRerender }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let encoded=try?JSONEncoder().encode(owner.title),let literal=String(data:encoded,encoding:.utf8) else{return}
            let script="""
            (()=>{if(!document.getElementById('offline-page-title')){const title=document.createElement('h1');title.id='offline-page-title';title.textContent=\(literal);title.style.cssText='font-size:1.45em;line-height:1.35;margin:0 0 1em';document.body.prepend(title)}if(!document.getElementById('offline-image-style')){const style=document.createElement('style');style.id='offline-image-style';style.textContent='img{-webkit-touch-callout:none!important;-webkit-user-select:none!important;user-select:none!important}';document.head.append(style)}const send=(action,image,ordinal)=>window.webkit.messageHandlers.offlineImage.postMessage({action:action,src:image.currentSrc||image.src,source:image.dataset.offlineSource||'',ordinal:ordinal});document.querySelectorAll('img').forEach((image,ordinal)=>{if(image.dataset.offlineGesture)return;image.dataset.offlineGesture='1';let hold=null,lastTap=0;image.addEventListener('contextmenu',event=>event.preventDefault());image.addEventListener('touchstart',()=>{if(window.__wosExcludeMode)return;hold=setTimeout(()=>send('menu',image,ordinal),550)},{passive:true});image.addEventListener('touchmove',()=>{clearTimeout(hold)},{passive:true});image.addEventListener('touchcancel',()=>{clearTimeout(hold)},{passive:true});image.addEventListener('touchend',event=>{if(window.__wosExcludeMode)return;clearTimeout(hold);const now=Date.now();if(now-lastTap<300){event.preventDefault();send('preview',image,ordinal);lastTap=0}else{lastTap=now}},{passive:false})})})()
            """
            webView.evaluateJavaScript(script)
            setExcludeMode(in:webView,enabled:excludeMode)
        }
        func setExcludeMode(in webView: WKWebView, enabled: Bool) {
            guard excludeMode != enabled || enabled else { return }
            excludeMode=enabled
            let script="""
            (()=>{const cls='wos-exclude-selected',styleID='wos-exclude-selection-style';window.__wosExcludeMode=\(enabled ? "true" : "false");if(!document.getElementById(styleID)){const style=document.createElement('style');style.id=styleID;style.textContent='.'+cls+'{outline:3px solid #e5484d!important;background-color:rgba(229,72,77,.16)!important}';document.head.append(style)}if(window.__wosExcludeHandler){document.removeEventListener('click',window.__wosExcludeHandler,true);window.__wosExcludeHandler=null}if(\(enabled ? "true" : "false")){window.__wosExcludeHandler=event=>{const node=event.target.closest('body *');if(!node||node.id===styleID)return;event.preventDefault();event.stopImmediatePropagation();node.classList.toggle(cls)};document.addEventListener('click',window.__wosExcludeHandler,true)}return true})()
            """
            webView.evaluateJavaScript(script)
        }
        func clearExcluded(in webView: WKWebView) { webView.evaluateJavaScript("(()=>{document.querySelectorAll('.wos-exclude-selected').forEach(node=>node.classList.remove('wos-exclude-selected'));return true})()") }
        func collectExcluded(in webView: WKWebView) {
            let script="""
            (()=>{const nodes=[...document.querySelectorAll('.wos-exclude-selected')].filter(node=>!node.parentElement?.closest('.wos-exclude-selected'));const segment=node=>{const tag=node.tagName.toLowerCase(),classes=[...node.classList].filter(value=>value&&value!=='wos-exclude-selected').slice(0,3);if(node.id)return tag+'#'+CSS.escape(node.id);if(classes.length)return tag+classes.map(value=>'.'+CSS.escape(value)).join('');const siblings=[...node.parentElement.children].filter(item=>item.tagName===node.tagName);return tag+':nth-of-type('+(siblings.indexOf(node)+1)+')'};const selector=node=>{if(node.id)return '#'+CSS.escape(node.id);const parts=[];let current=node;while(current&&current.parentElement&&current.parentElement!==document.body&&parts.length<4){parts.unshift(segment(current));current=current.parentElement;if(current?.id){parts.unshift('#'+CSS.escape(current.id));break}}return parts.length?':scope > '+parts.join(' > '):':scope'};const describe=node=>({tag:node.tagName.toLowerCase(),id:node.id||'',classes:node.className||'',selector:selector(node),text:(node.innerText||'').trim().slice(0,500),html:node.outerHTML.slice(0,1600)});return JSON.stringify(nodes.map(describe)).slice(0,12000)})()
            """
            webView.evaluateJavaScript(script) { value,_ in guard let raw=value as? String,!raw.isEmpty else{return};DispatchQueue.main.async { self.onCollected(raw) } }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "offlineImage",let payload=message.body as? [String:Any],let action=payload["action"] as? String,let raw=payload["src"] as? String,let imageURL=URL(string:raw),let webView=message.webView,let controller=topController(from:webView.window?.rootViewController) else{return}
            if action == "preview" { controller.present(ImagePreviewController(imageURL:imageURL),animated:true); return }
            let source=payload["source"] as? String ?? ""
            let ordinal=(payload["ordinal"] as? NSNumber)?.intValue ?? 0
            let sheet=UIAlertController(title:"图片",message:nil,preferredStyle:.actionSheet)
            sheet.addAction(UIAlertAction(title:"导出图片",style:.default){_ in self.export(imageURL,from:webView)})
            sheet.addAction(UIAlertAction(title:"重新渲染保存",style:.default){_ in self.rerender(imageURL,source:source,ordinal:ordinal,in:webView)})
            sheet.addAction(UIAlertAction(title:"取消",style:.cancel))
            sheet.popoverPresentationController?.sourceView=webView
            controller.present(sheet,animated:true)
        }
        func export(_ imageURL: URL, from webView: WKWebView?) {
            guard let controller=topController(from:webView?.window?.rootViewController) else{return}
            let sheet=UIActivityViewController(activityItems:[imageURL],applicationActivities:nil)
            sheet.popoverPresentationController?.sourceView=webView
            controller.present(sheet,animated:true)
        }
        func rerender(_ imageURL: URL, source: String, ordinal: Int, in webView: WKWebView) {
            guard imageURL.isFileURL else{return}
            Task { [onRerender] in
                if await onRerender(imageURL,source,ordinal) { await MainActor.run { webView.reload() } }
            }
        }
        func topController(from controller: UIViewController?) -> UIViewController? { if let presented=controller?.presentedViewController{return topController(from:presented)};if let navigation=controller as? UINavigationController{return topController(from:navigation.visibleViewController)};if let tab=controller as? UITabBarController{return topController(from:tab.selectedViewController)};return controller }
    }
}
final class ImagePreviewController: UIViewController, UIScrollViewDelegate {
    let imageURL: URL
    private let scrollView=UIScrollView()
    private let imageView=UIImageView()
    init(imageURL: URL) { self.imageURL=imageURL;super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .fullScreen
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.delegate = self
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.image = UIImage(contentsOfFile:imageURL.path)
        scrollView.addSubview(imageView)
        let close = UIButton(type: .close)
        close.tintColor = .white
        close.frame = CGRect(x: 18, y: 56, width: 36, height: 36)
        close.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
        close.addTarget(self, action: #selector(dismissPreview), for: .touchUpInside)
        view.addSubview(close)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    @objc func dismissPreview(){dismiss(animated:true)}
    @objc func toggleZoom(){scrollView.setZoomScale(scrollView.zoomScale > 1 ? 1 : 2.5,animated:true)}
}
