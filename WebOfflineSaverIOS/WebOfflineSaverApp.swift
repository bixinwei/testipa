import SwiftUI
import WebKit

@main struct WebOfflineSaverApp: App { @StateObject var store = Store(); var body: some Scene { WindowGroup { Home().environmentObject(store) } } }
struct Plan: Codable { let contentSelector: String; let titleSelector: String?; let excludes: [String] }
struct Item: Codable, Identifiable { let id: UUID; let title, url, file: String }

@MainActor final class Browser: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView; var wait: CheckedContinuation<Void,Error>?
    override init(){let c=WKWebViewConfiguration();c.websiteDataStore = .default();c.defaultWebpagePreferences.allowsContentJavaScript=true;view=WKWebView(frame:.zero,configuration:c);super.init();view.navigationDelegate=self}
    func open(_ s:String){if let u=URL(string:s){view.load(URLRequest(url:u))}}
    func load(_ s:String) async throws {guard let u=URL(string:s)else{throw URLError(.badURL)};try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in wait=c;view.load(URLRequest(url:u))}}
    func js(_ s:String) async throws->Any {try await withCheckedThrowingContinuation{c in view.evaluateJavaScript(s){v,e in if let e{c.resume(throwing:e)}else{c.resume(returning:v as Any)}}}}
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
    let browser=Browser(); let fm=FileManager.default
    var root:URL{fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("OfflineLibrary",isDirectory:true)}
    init(){if let d=try?Data(contentsOf:root.appendingPathComponent("catalog.json")){items=(try?JSONDecoder().decode([Item].self,from:d)) ?? []}}
    func log(_ x:String){logs.append(x);if logs.count>150{logs.removeFirst()}}
    func saveConfig(){UserDefaults.standard.set(url,forKey:"wo.url");UserDefaults.standard.set(key,forKey:"wo.key");UserDefaults.standard.set(api,forKey:"wo.api");UserDefaults.standard.set(model,forKey:"wo.model");UserDefaults.standard.set(force,forKey:"wo.force");log("[程序] 配置已保存。")}
    func open(){saveConfig();browser.open(url);browserShown=true;log("[程序] 已打开验证浏览器，请完成验证。")}
    func save(){Task{await work()}}
    func getPlan(host:String,html:String) async throws->Plan {let k="wo.plan.\(host)";if !force,let d=UserDefaults.standard.data(forKey:k),let p=try?JSONDecoder().decode(Plan.self,from:d){log("[程序] 复用 \(host) 已保存的网页结构，不调用 AI。");return p};log("[AI] 正在识别标题与主体区域…");let prompt="只返回 JSON：contentSelector、titleSelector、excludes。识别主体最小容器；排除广告、导航、评论、相关推荐、分享。不要输出正文。HTML：\(html.prefix(24000))";var r=URLRequest(url:URL(string:api.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/chat/completions")!);r.httpMethod="POST";r.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type");r.httpBody=try JSONSerialization.data(withJSONObject:["model":model,"temperature":0.1,"response_format":["type":"json_object"],"messages":[["role":"user","content":prompt]]]);let(d,_)=try await URLSession.shared.data(for:r);let o=try JSONSerialization.jsonObject(with:d)as![String:Any];let s=(((o["choices"]as?[[String:Any]])?.first?["message"]as?[String:Any])?["content"]as?String) ?? "{}";let p=try JSONDecoder().decode(Plan.self,from:Data(s.utf8));UserDefaults.standard.set(try JSONEncoder().encode(p),forKey:k);return p}
    func work() async {guard !url.isEmpty,!key.isEmpty else{log("[程序] 请填写网页地址和 API Key。");return};do{saveConfig();log("[程序] 正在读取网页…");try await browser.load(url);let html=try await browser.js("document.documentElement.outerHTML")as?String ?? "";let host=URL(string:url)?.host ?? "site";let p=try await getPlan(host:host,html:html);let q=String(data:try JSONEncoder().encode(p.contentSelector),encoding:.utf8)!;let ex=String(data:try JSONEncoder().encode(p.excludes),encoding:.utf8)!;let ti=String(data:try JSONEncoder().encode(p.titleSelector ?? ""),encoding:.utf8)!;let script="(()=>{const n=document.querySelector(\(q));if(!n)return null;const c=n.cloneNode(true);JSON.parse(\(ex)).forEach(s=>{try{c.querySelectorAll(s).forEach(x=>x.remove())}catch(_){}});c.querySelectorAll('script,style,iframe,nav,.ads,.advertisement').forEach(x=>x.remove());const t=JSON.parse(\(ti));return JSON.stringify({title:(t&&document.querySelector(t)?.innerText||c.querySelector('h1')?.innerText||document.title).trim(),html:c.outerHTML})})()";guard let raw=try await browser.js(script)as?String,let obj=try JSONSerialization.jsonObject(with:Data(raw.utf8))as?[String:String],let fragment=obj["html"]else{throw URLError(.cannotParseResponse)};let id=UUID(),dir=root.appendingPathComponent(id.uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true);let file=dir.appendingPathComponent("index.html");try "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>body{max-width:760px;margin:24px auto;padding:0 16px;font:17px/1.7 -apple-system}img,video{max-width:100%;height:auto}</style>\(fragment)".write(to:file,atomically:true,encoding:.utf8);let item=Item(id:id,title:obj["title"] ?? host,url:url,file:file.path);items.insert(item,at:0);persist();log("[阶段] 已保存《\(item.title)》。") }catch{log("[程序] 保存失败：\(error.localizedDescription)")}}
    func delete(_ o:IndexSet){for i in o{try?fm.removeItem(at:URL(fileURLWithPath:items[i].file).deletingLastPathComponent())};items.remove(atOffsets:o);persist()};func persist(){try?fm.createDirectory(at:root,withIntermediateDirectories:true);try?JSONEncoder().encode(items).write(to:root.appendingPathComponent("catalog.json"))}
}
struct Home:View{@EnvironmentObject var s:Store;var body:some View{NavigationStack{List{Section("网页保存"){TextField("网页地址",text:$s.url).textInputAutocapitalization(.never);SecureField("API Key",text:$s.key);TextField("API 地址",text:$s.api);TextField("模型",text:$s.model);Toggle("每次都 AI 识别",isOn:$s.force);Button("保存配置"){s.saveConfig()};Button("打开验证浏览器"){s.open()};Button("保存主体网页"){s.save()}};Section("已下载"){ForEach(s.items){i in Link(i.title,destination:URL(fileURLWithPath:i.file))}.onDelete(perform:s.delete)};Section("日志"){ForEach(s.logs.indices,id:\.self){Text(s.logs[$0]).font(.caption)}}}.navigationTitle("网页离线保存器").sheet(isPresented:$s.browserShown){Web(browser:s.browser)}}}}
struct Web:UIViewRepresentable{@ObservedObject var browser:Browser;func makeUIView(context:Context)->WKWebView{browser.view};func updateUIView(_ v:WKWebView,context:Context){}}
