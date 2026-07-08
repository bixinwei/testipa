#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Network/Network.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <errno.h>
#import <netdb.h>
#import <netinet/in.h>
#import <string.h>
#import <strings.h>
#import <sys/socket.h>
#import <sys/uio.h>
#import <unistd.h>

static NSString *const AppCtrlStateFileName = @"appctrl_state.plist";
static NSString *const AppCtrlDomainsFileName = @"appctrl_blocked_domains.txt";
static NSString *const AppCtrlWhiteDomainsFileName = @"appctrl_white_domains.txt";

static __weak UIWindow *gHostWindow;
static UIButton *gFloatingButton;
static UIView *gPanelView;
static UISwitch *gNetworkSwitch;
static UITextView *gDomainsTextView;
static UITextView *gWhiteDomainsTextView;
static UITextView *gLogTextView;
static UILabel *gBlockCountLabel;

static char kOrigWKDelegateDecisionKey;
static char kOrigWKUIDelegateCreateWebViewKey;
static char kAppCtrlWebViewConfiguredKey;
static char kAppCtrlAppliedContentRuleSignatureKey;

static NSString *const AppCtrlScriptMessageName = @"appctrlBlockNavigation";

static WKContentRuleList *gAppCtrlContentRuleList;
static NSString *gAppCtrlContentRuleListSignature;
static NSHashTable *gAppCtrlTrackedContentControllers;

static NSString *appctrl_documents_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *appctrl_state_path(void) {
    return [appctrl_documents_path() stringByAppendingPathComponent:AppCtrlStateFileName];
}

static NSString *appctrl_blocked_elements_path(void) {
    return [appctrl_documents_path() stringByAppendingPathComponent:@"appctrl_blocked_elements.json"];
}

static NSString *appctrl_domains_path(void) {
    return [appctrl_documents_path() stringByAppendingPathComponent:AppCtrlDomainsFileName];
}

static NSString *appctrl_white_domains_path(void) {
    return [appctrl_documents_path() stringByAppendingPathComponent:AppCtrlWhiteDomainsFileName];
}

static NSDictionary *appctrl_load_state_file(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:appctrl_state_path()];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : @{};
}

static NSString *appctrl_extract_host_from_rule(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"";
    }

    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return @"";
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    if (components.host.length > 0) {
        return components.host;
    }

    NSString *candidate = trimmed;
    NSRange schemeRange = [candidate rangeOfString:@"://"];
    if (schemeRange.location != NSNotFound) {
        candidate = [candidate substringFromIndex:schemeRange.location + schemeRange.length];
    }

    NSArray<NSString *> *splitters = @[@"/", @"?", @"#"];
    for (NSString *splitter in splitters) {
        NSRange range = [candidate rangeOfString:splitter];
        if (range.location != NSNotFound) {
            candidate = [candidate substringToIndex:range.location];
        }
    }

    NSRange atRange = [candidate rangeOfString:@"@" options:NSBackwardsSearch];
    if (atRange.location != NSNotFound) {
        candidate = [candidate substringFromIndex:atRange.location + 1];
    }

    if ([candidate hasPrefix:@"["]) {
        NSRange closing = [candidate rangeOfString:@"]"];
        if (closing.location != NSNotFound) {
            return [candidate substringWithRange:NSMakeRange(1, closing.location - 1)];
        }
    }

    NSArray<NSString *> *parts = [candidate componentsSeparatedByString:@":"];
    if (parts.count >= 2) {
        candidate = parts.firstObject ?: candidate;
    }

    return candidate;
}

static NSString *appctrl_normalize_host(NSString *host) {
    if (![host isKindOfClass:[NSString class]]) {
        return @"";
    }

    NSString *lower = [[host lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([lower hasSuffix:@"."]) {
        lower = [lower substringToIndex:lower.length - 1];
    }
    return lower;
}

static NSSet<NSString *> *appctrl_domains_from_raw(NSString *raw) {
    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",\n\r"]];
    NSMutableSet<NSString *> *domains = [NSMutableSet set];

    for (NSString *part in parts) {
        NSString *trimmed = appctrl_normalize_host(appctrl_extract_host_from_rule(part));
        if (trimmed.length > 0) {
            [domains addObject:trimmed];
        }
    }

    return [domains copy];
}

static BOOL appctrl_disable_network(void) {
    NSDictionary *state = appctrl_load_state_file();
    NSNumber *stored = state[@"disableNetwork"];
    if ([stored isKindOfClass:[NSNumber class]]) {
        return stored.boolValue;
    }

    const char *value = getenv("APPCTRL_DISABLE_NETWORK");
    return (value && strcmp(value, "1") == 0);
}

static NSString *appctrl_domains_file_content(void) {
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:appctrl_domains_path() encoding:NSUTF8StringEncoding error:&error];
    if (content.length > 0) {
        return content;
    }

    const char *value = getenv("APPCTRL_BLOCKED_DOMAINS");
    if (!value) {
        return @"";
    }
    return [NSString stringWithUTF8String:value];
}

static NSSet<NSString *> *appctrl_blocked_domains(void) {
    return appctrl_domains_from_raw(appctrl_domains_file_content());
}

static NSString *appctrl_white_domains_file_content(void) {
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:appctrl_white_domains_path() encoding:NSUTF8StringEncoding error:&error];
    if (content.length > 0) {
        return content;
    }

    const char *value = getenv("APPCTRL_WHITE_DOMAINS");
    if (!value) {
        return @"";
    }
    return [NSString stringWithUTF8String:value];
}

static NSSet<NSString *> *appctrl_white_domains(void) {
    return appctrl_domains_from_raw(appctrl_white_domains_file_content());
}

static NSArray *appctrl_load_blocked_elements(void) {
    NSString *path = appctrl_blocked_elements_path();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { return @[]; }
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}

static void appctrl_save_blocked_element(NSString *domain, NSString *selector) {
    if (!domain || !selector) { return; }
    NSMutableArray *list = [appctrl_load_blocked_elements() mutableCopy];
    NSDictionary *entry = @{@"domain": domain, @"selector": selector};
    [list addObject:entry];
    NSData *data = [NSJSONSerialization dataWithJSONObject:list options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        [data writeToFile:appctrl_blocked_elements_path() atomically:YES];
    }
}

static NSString *appctrl_blocked_elements_json(void) {
    NSArray *list = appctrl_load_blocked_elements();
    NSData *data = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
    if (!data) { return @"[]"; }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
}

static BOOL appctrl_host_matches_rule(NSString *host, NSString *rule) {
    if (host.length == 0 || rule.length == 0) {
        return NO;
    }

    return [host isEqualToString:rule] || [host hasSuffix:[@"." stringByAppendingString:rule]];
}

static BOOL appctrl_host_is_whitelisted(NSString *host) {
    NSString *lower = appctrl_normalize_host(host);
    if (lower.length == 0) {
        return NO;
    }

    NSSet<NSString *> *whiteDomains = appctrl_white_domains();
    if (whiteDomains.count == 0) {
        return YES;
    }

    for (NSString *allowed in whiteDomains) {
        if (appctrl_host_matches_rule(lower, allowed)) {
            return YES;
        }
    }
    return NO;
}

static BOOL appctrl_host_is_blocked(NSString *host) {
    NSString *lower = appctrl_normalize_host(host);
    if (lower.length == 0) {
        return NO;
    }

    for (NSString *blocked in appctrl_blocked_domains()) {
        if (appctrl_host_matches_rule(lower, blocked)) {
            return YES;
        }
    }
    return NO;
}

static BOOL appctrl_is_network_scheme(NSString *scheme) {
    if (scheme.length == 0) {
        return NO;
    }

    static NSSet<NSString *> *schemes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        schemes = [NSSet setWithObjects:@"http", @"https", @"ws", @"wss", @"ftp", @"ftps", nil];
    });
    return [schemes containsObject:scheme.lowercaseString];
}

static BOOL appctrl_should_block_all_network(void) {
    return appctrl_disable_network();
}

static NSUInteger appctrl_block_count(void) {
    NSNumber *count = appctrl_load_state_file()[@"blockCount"];
    return [count isKindOfClass:[NSNumber class]] ? count.unsignedIntegerValue : 0;
}

static void appctrl_log_to_panel(NSString *message) {
    if (!message || !gLogTextView) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                             dateStyle:NSDateFormatterNoStyle
                                                             timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

        NSString *newText = [gLogTextView.text stringByAppendingString:line];
        // 限制日志长度，避免无限增长导致主线程卡顿
        // 保留最后 10000 个字符（约 200-300 条日志）
        if (newText.length > 10000) {
            newText = [@"...(日志过长，已截断)\n" stringByAppendingString:[newText substringFromIndex:newText.length - 10000]];
        }
        gLogTextView.text = newText;
        [gLogTextView scrollRangeToVisible:NSMakeRange(gLogTextView.text.length, 0)];
    });
}

static void appctrl_refresh_block_count_label(void) {
    if (!gBlockCountLabel) {
        return;
    }
    gBlockCountLabel.text = [NSString stringWithFormat:@"Blocked: %lu", (unsigned long)appctrl_block_count()];
}

static void appctrl_record_block_hit(void) {
    NSMutableDictionary *state = [appctrl_load_state_file() mutableCopy];
    NSNumber *count = state[@"blockCount"];
    NSUInteger nextCount = [count isKindOfClass:[NSNumber class]] ? count.unsignedIntegerValue + 1 : 1;
    state[@"blockCount"] = @(nextCount);
    if (gFloatingButton) {
        state[@"floatingButtonCenterX"] = @(gFloatingButton.center.x);
        state[@"floatingButtonCenterY"] = @(gFloatingButton.center.y);
    }
    if (gNetworkSwitch) {
        state[@"disableNetwork"] = @(gNetworkSwitch.on);
    }
    [state writeToFile:appctrl_state_path() atomically:YES];

    dispatch_async(dispatch_get_main_queue(), ^{
        appctrl_refresh_block_count_label();
    });
}

static NSString *appctrl_json_array_from_domains(NSSet<NSString *> *domains) {
    NSArray<NSString *> *sorted = [[domains allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSData *data = [NSJSONSerialization dataWithJSONObject:sorted options:0 error:nil];
    if (!data) {
        return @"[]";
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return json ?: @"[]";
}

static NSArray<NSString *> *appctrl_content_rule_domains_from_set(NSSet<NSString *> *domains) {
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (NSString *domain in domains) {
        NSString *normalized = appctrl_normalize_host(domain);
        if (normalized.length == 0) {
            continue;
        }
        [result addObject:normalized];
        [result addObject:[@"*" stringByAppendingString:normalized]];
    }
    return result.array;
}

static NSString *appctrl_content_rule_list_json(void) {
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    NSSet<NSString *> *whiteDomainsSet = appctrl_white_domains();
    NSSet<NSString *> *blockedDomainsSet = appctrl_blocked_domains();

    if (whiteDomainsSet.count > 0) {
        // Whitelist mode — two separate block rules so resource-type filtering is precise:
        //
        // Rule 1: block document (page navigation) to any non-whitelisted host.
        //         This stops the user from navigating to bb.com even via address bar,
        //         because WKWebView issues a "document" request for top-level navigation.
        [rules addObject:@{
            @"trigger": @{
                @"url-filter": @"^https?://.*",
                @"resource-type": @[@"document"]
            },
            @"action": @{@"type": @"block"}
        }];
        // Rule 2: block image/media sub-resources from any non-whitelisted host.
        //         JS, CSS, fonts, XHR are intentionally excluded so the page can
        //         still load and function correctly.
        [rules addObject:@{
            @"trigger": @{
                @"url-filter": @"^https?://.*",
                @"resource-type": @[@"image", @"media", @"svg-document"]
            },
            @"action": @{@"type": @"block"}
        }];
        // For each whitelisted domain: cancel both block rules above.
        // The ignore-previous-rules action fires before any block action and
        // voids all earlier rules whose trigger matched this request.
        for (NSString *domain in whiteDomainsSet) {
            NSString *normalized = appctrl_normalize_host(domain);
            if (normalized.length == 0) { continue; }
            // Escape dots so "aaa.com" doesn't accidentally match "aaaxcom".
            NSString *escaped = [normalized stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
            // Matches: https://aaa.com, https://aaa.com/path, https://sub.aaa.com/img.jpg
            NSString *pattern = [NSString stringWithFormat:@"^https?://([^/?#]+\\.)?%@([/?#]|$)", escaped];
            [rules addObject:@{
                @"trigger": @{@"url-filter": pattern},
                @"action":  @{@"type": @"ignore-previous-rules"}
            }];
        }
    } else {
        // No whitelist active — apply blocked-domains list only.
        NSArray<NSString *> *blockedDomains = appctrl_content_rule_domains_from_set(blockedDomainsSet);
        for (NSString *domain in blockedDomains) {
            [rules addObject:@{
                @"trigger": @{
                    @"url-filter": @"^https?://.*",
                    @"if-domain": @[domain]
                },
                @"action": @{@"type": @"block"}
            }];
        }
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    if (!data) { return @"[]"; }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return json ?: @"[]";
}

static void appctrl_refresh_content_rule_list_if_needed(void) {
    if (![WKContentRuleListStore class]) {
        return;
    }

    NSString *json = appctrl_content_rule_list_json();
    if ([gAppCtrlContentRuleListSignature isEqualToString:json] && gAppCtrlContentRuleList != nil) {
        return;
    }

    gAppCtrlContentRuleListSignature = [json copy];
    NSString *compiledSignature = [json copy];
    [[WKContentRuleListStore defaultStore] compileContentRuleListForIdentifier:@"appctrl.dynamic.rules"
                                                         encodedContentRuleList:json
                                                              completionHandler:^(WKContentRuleList * _Nullable contentRuleList, NSError * _Nullable error) {
        if (!contentRuleList || error) { return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            gAppCtrlContentRuleList = contentRuleList;
            // Push new rules to every already-existing WKUserContentController.
            for (WKUserContentController *ctrl in gAppCtrlTrackedContentControllers) {
                NSString *applied = objc_getAssociatedObject(ctrl, &kAppCtrlAppliedContentRuleSignatureKey);
                if ([applied isEqualToString:compiledSignature]) { continue; }
                if ([ctrl respondsToSelector:@selector(removeAllContentRuleLists)]) {
                    [ctrl removeAllContentRuleLists];
                }
                [ctrl addContentRuleList:contentRuleList];
                objc_setAssociatedObject(ctrl, &kAppCtrlAppliedContentRuleSignatureKey, compiledSignature, OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
        });
    }];
}

static BOOL appctrl_should_block_host(NSString *host) {
    NSString *normalized = appctrl_normalize_host(host);
    if (normalized.length == 0) {
        return NO;
    }

    if (!appctrl_host_is_whitelisted(normalized)) {
        return YES;
    }

    return appctrl_host_is_blocked(normalized);
}

static BOOL appctrl_should_block_url(NSURL *url) {
    if (!url) {
        return NO;
    }

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (appctrl_should_block_all_network() && appctrl_is_network_scheme(scheme)) {
        return YES;
    }

    if (appctrl_is_network_scheme(scheme)) {
        return appctrl_should_block_host(url.host);
    }

    return NO;
}

static BOOL appctrl_sockaddr_is_loopback(const struct sockaddr *address) {
    if (!address) {
        return NO;
    }

    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *addr4 = (const struct sockaddr_in *)address;
        uint32_t host = ntohl(addr4->sin_addr.s_addr);
        return (host >> 24) == 127; // 127.0.0.0/8
    }

    if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *addr6 = (const struct sockaddr_in6 *)address;
        return IN6_IS_ADDR_LOOPBACK(&addr6->sin6_addr) != 0;
    }

    return NO;
}

static BOOL appctrl_sockaddr_is_network(const struct sockaddr *address) {
    if (!address) {
        return NO;
    }

    if (address->sa_family != AF_INET && address->sa_family != AF_INET6) {
        return NO;
    }

    // Treat loopback as local, not "network", so IPC / local servers keep working.
    return !appctrl_sockaddr_is_loopback(address);
}

static BOOL appctrl_hostname_is_loopback(const char *hostname) {
    if (!hostname || hostname[0] == '\0') {
        return NO;
    }

    if (strcasecmp(hostname, "localhost") == 0 ||
        strcmp(hostname, "127.0.0.1") == 0 ||
        strcmp(hostname, "::1") == 0 ||
        strcasecmp(hostname, "localhost.") == 0) {
        return YES;
    }

    return NO;
}

static BOOL appctrl_should_block_socket_address(const struct sockaddr *address) {
    if (!appctrl_sockaddr_is_network(address)) {
        return NO;
    }

    if (appctrl_should_block_all_network()) {
        return YES;
    }

    char hostBuffer[NI_MAXHOST] = {0};
    if (getnameinfo(address,
                    (address->sa_family == AF_INET) ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6),
                    hostBuffer,
                    sizeof(hostBuffer),
                    NULL,
                    0,
                    NI_NUMERICHOST) == 0) {
        return !appctrl_host_is_whitelisted([NSString stringWithUTF8String:hostBuffer]);
    }

    return NO;
}

static BOOL appctrl_should_count_block_for_url(NSURL *url) {
    if (!url) {
        return NO;
    }

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (!appctrl_is_network_scheme(scheme)) {
        return NO;
    }

    return appctrl_should_block_host(url.host);
}

static BOOL appctrl_should_count_block_for_hostname(const char *hostname) {
    if (!hostname || hostname[0] == '\0') {
        return NO;
    }

    if (appctrl_hostname_is_loopback(hostname)) {
        return NO;
    }

    return appctrl_should_block_host([NSString stringWithUTF8String:hostname]);
}

static void appctrl_handle_script_blocked_url_string(NSString *urlString) {
    if (urlString.length == 0) {
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return;
    }

    if (appctrl_should_count_block_for_url(url)) {
        appctrl_record_block_hit();
    }
}

static NSString *appctrl_webview_user_script_source(void) {
    NSString *blockedJSON = appctrl_json_array_from_domains(appctrl_blocked_domains());
    NSString *whiteJSON = appctrl_json_array_from_domains(appctrl_white_domains());
    NSString *blockedElementsJSON = appctrl_blocked_elements_json();
    NSString *disableNetwork = appctrl_should_block_all_network() ? @"true" : @"false";

    return [NSString stringWithFormat:
            @"(function(){\n"
             "try{\n"
             "  window.webkit.messageHandlers.%@.postMessage({action:'log',message:'Script entry point reached'});\n"
             "}catch(e){}\n"
             "if(window.__appctrlInstalled){return;}\n"
             "window.__appctrlInstalled=true;\n"
             "var blocked=%@;\n"
             "var white=%@;\n"
             "var blockedElements=%@;\n"
             "var disableNetwork=%@;\n"
             "var schemes={http:1,https:1,ws:1,wss:1,ftp:1,ftps:1};\n"
             "function __log(msg){\n"
             "  try{\n"
             "    window.webkit.messageHandlers.%@.postMessage({action:'log',message:msg});\n"
             "  }catch(e){}\n"
             "}\n"
             "function normalizeHost(host){return (host||'').toLowerCase().replace(/\\.+$/,'').trim();}\n"
             "function matches(host,rule){return host===rule || host.slice(-(rule.length+1))==='.'+rule;}\n"
             "function shouldBlock(urlString){\n"
             "  try {\n"
             "    var u=new URL(urlString, document.baseURI || location.href);\n"
             "    var scheme=(u.protocol||'').replace(':','').toLowerCase();\n"
             "    if(!schemes[scheme]){return false;}\n"
             "    if(disableNetwork){return true;}\n"
             "    var host=normalizeHost(u.hostname);\n"
             "    if(!host){return false;}\n"
             "    if(white.length){\n"
             "      var allowed=false;\n"
             "      for(var i=0;i<white.length;i++){ if(matches(host, white[i])){ allowed=true; break; } }\n"
             "      if(!allowed){return true;}\n"
             "    }\n"
             "    for(var j=0;j<blocked.length;j++){ if(matches(host, blocked[j])){ return true; } }\n"
             "    return false;\n"
             "  } catch(e) { return false; }\n"
             "}\n"
             "function report(urlString){ try { window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.%@ && window.webkit.messageHandlers.%@.postMessage({url:urlString}); } catch(e){} }\n"
             "function blockIfNeeded(urlString){ if(shouldBlock(urlString)){ report(urlString); return true; } return false; }\n"
             "document.addEventListener('click', function(event){\n"
             "  var node=event.target;\n"
             "  while(node && node!==document){\n"
             "    if(node.href && typeof node.href==='string'){\n"
             "      if(blockIfNeeded(node.href)){ event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation && event.stopImmediatePropagation(); }\n"
             "      return;\n"
             "    }\n"
             "    node=node.parentNode;\n"
             "  }\n"
             "}, true);\n"
             "if(window.HTMLAnchorElement && HTMLAnchorElement.prototype){\n"
             "  var origAnchorClick=HTMLAnchorElement.prototype.click;\n"
             "  HTMLAnchorElement.prototype.click=function(){ if(blockIfNeeded(this.href)){ return; } return origAnchorClick ? origAnchorClick.apply(this, arguments) : undefined; };\n"
             "}\n"
             "if(window.open){\n"
             "  var origOpen=window.open;\n"
             "  window.open=function(url){ if(url && blockIfNeeded(url)){ return null; } return origOpen.apply(window, arguments); };\n"
             "}\n"
             "if(window.Location && Location.prototype){\n"
             "  var origAssign=Location.prototype.assign;\n"
             "  if(origAssign){ Location.prototype.assign=function(url){ if(url && blockIfNeeded(url)){ return; } return origAssign.apply(this, arguments); }; }\n"
             "  var origReplace=Location.prototype.replace;\n"
             "  if(origReplace){ Location.prototype.replace=function(url){ if(url && blockIfNeeded(url)){ return; } return origReplace.apply(this, arguments); }; }\n"
             "}\n"
             "if(window.history && history.pushState){\n"
             "  var origPushState=history.pushState;\n"
             "  history.pushState=function(state,title,url){ if(url && blockIfNeeded(url)){ return; } return origPushState.apply(history, arguments); };\n"
             "}\n"
             "if(window.history && history.replaceState){\n"
             "  var origReplaceState=history.replaceState;\n"
             "  history.replaceState=function(state,title,url){ if(url && blockIfNeeded(url)){ return; } return origReplaceState.apply(history, arguments); };\n"
             "}\n"
             // Hook location.href setter — this is the most common redirect method used
             // by ad/malware scripts: document.location.href = 'http://bad.com'
             "try{\n"
             "  var locDesc=Object.getOwnPropertyDescriptor(Location.prototype,'href');\n"
             "  if(locDesc && locDesc.set){\n"
             "    var origHrefSet=locDesc.set;\n"
             "    Object.defineProperty(Location.prototype,'href',{\n"
             "      get: locDesc.get,\n"
             "      set: function(url){ if(url && blockIfNeeded(String(url))){ return; } origHrefSet.call(this,url); },\n"
             "      configurable:true\n"
             "    });\n"
             "  }\n"
             "}catch(e){}\n"
             // Also intercept direct document.location assignment attempts via a
             // passive touchstart/scroll listener that checks for pending redirects.
             // Some scripts set location via setTimeout — catch those too by patching setTimeout.
             "var __origSetTimeout=window.setTimeout;\n"
             "window.setTimeout=function(fn,delay){\n"
             "  var args=Array.prototype.slice.call(arguments,2);\n"
             "  var wrapped=(typeof fn==='function') ? function(){\n"
             "    try{ fn.apply(this,args); }catch(e){ if(!(e instanceof TypeError))throw e; }\n"
             "  } : fn;\n"
             "  return __origSetTimeout.call(window,wrapped,delay);\n"
             "};\n"
             // CSS: [data-appctrl-ad] hides marked elements; also hide known ad selectors up front.
             // Using attribute+CSS instead of remove() so ad scripts can't resurrect the element
             // by re-inserting it — even if the attribute is stripped, MutationObserver re-sets it.
             "try{\n"
             "  var __adStyle=document.createElement('style');\n"
             "  __adStyle.textContent=\n"
             "    '[data-appctrl-ad]{display:none!important;visibility:hidden!important;pointer-events:none!important;}'\n"
             "    'ins.adsbygoogle,[class*=\"adsbygoogle\"],ins[class*=\"ad-\"],'\n"
             "    'iframe[src*=\"googlesyndication\"],iframe[src*=\"doubleclick\"],'\n"
             "    'div[id*=\"google_ads\"],div[class*=\"google-ads\"]'\n"
             "    '{display:none!important;visibility:hidden!important;}';\n"
             "  (document.head||document.documentElement).appendChild(__adStyle);\n"
             "}catch(e){}\n"
             "function __hasNetRes(el){\n"
             "  try{\n"
             "    var t=el.tagName?el.tagName.toLowerCase():'';\n"
             "    if((t==='img'||t==='video'||t==='iframe'||t==='embed')&&el.src&&el.src.length>0)return true;\n"
             "    if(t==='canvas')return true;\n"
             "    if(t==='object'&&el.data&&el.data.length>0)return true;\n"
             "    var bg=window.getComputedStyle(el).backgroundImage;\n"
             "    if(bg&&bg!=='none'&&bg.indexOf('url(')!==-1)return true;\n"
             "    var kids=el.querySelectorAll('img[src],video[src],iframe[src],embed[src],object[data],canvas');\n"
             "    if(kids.length>0)return true;\n"
             "  }catch(e){}\n"
             "  return false;\n"
             "}\n"
             "function __markAd(el){\n"
             "  try{\n"
             "    el.setAttribute('data-appctrl-ad','1');\n"
             "    var medias=el.querySelectorAll('video,audio');\n"
             "    for(var m=0;m<medias.length;m++){try{medias[m].pause();medias[m].src='';}catch(e){}}\n"
             "  }catch(e){}\n"
             "}\n"
             // Walk UP from every <video>/<canvas> to find fixed/sticky ancestor
             "function removeVideoAdBanners(){\n"
             "  try{\n"
             "    var nodes=document.querySelectorAll('video,canvas');\n"
             "    for(var vi=0;vi<nodes.length;vi++){\n"
             "      var node=nodes[vi];\n"
             "      while(node&&node!==document.body&&node!==document.documentElement){\n"
             "        try{\n"
             "          var p=node.parentNode;\n"
             "          var cs=window.getComputedStyle(node);\n"
             "          if(cs.position==='fixed'||cs.position==='sticky'){__markAd(node);break;}\n"
             "          node=p;\n"
             "        }catch(e2){break;}\n"
             "      }\n"
             "    }\n"
             "  }catch(e){}\n"
             "}\n"
             "function removeAdOverlays(){\n"
             "  removeVideoAdBanners();\n"
             "  try{\n"
             "    var sel='ins,ins.adsbygoogle,[class*=\"adsbygoogle\"],'\n"
             "      +'iframe[src*=\"googlesyndication\"],iframe[src*=\"doubleclick\"],'\n"
             "      +'div[id*=\"google_ads\"],div[class*=\"google-ads\"]';\n"
             "    var ads=document.querySelectorAll(sel);\n"
             "    for(var i=ads.length-1;i>=0;i--){__markAd(ads[i]);}\n"
             "  }catch(e){}\n"
             "  try{\n"
             "    var all=document.querySelectorAll('*');\n"
             "    for(var i=all.length-1;i>=0;i--){\n"
             "      try{\n"
             "        var el=all[i];\n"
             "        if(el.getAttribute('data-appctrl-ad')==='1')continue;\n"
             "        var pos=window.getComputedStyle(el).position;\n"
             "        if((pos==='fixed'||pos==='sticky')&&__hasNetRes(el)){__markAd(el);}\n"
             "      }catch(e){}\n"
             "    }\n"
             "  }catch(e){}\n"
             "}\n"
             "if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',removeAdOverlays);}else{removeAdOverlays();}\n"
             "setTimeout(removeAdOverlays,300);\n"
             "setTimeout(removeAdOverlays,800);\n"
             "setTimeout(removeAdOverlays,2000);\n"
             "setTimeout(removeAdOverlays,5000);\n"
             "setInterval(removeAdOverlays,3000);\n"
             "var __adObsTimer=null;\n"
             "var __adObs=new MutationObserver(function(mutations){\n"
             "  for(var m=0;m<mutations.length;m++){\n"
             "    var mut=mutations[m];\n"
             "    if(mut.type==='attributes'&&mut.attributeName==='data-appctrl-ad'){\n"
             "      try{mut.target.setAttribute('data-appctrl-ad','1');}catch(e){}\n"
             "      continue;\n"
             "    }\n"
             "  }\n"
             "  if(!__adObsTimer){\n"
             "    __adObsTimer=__origSetTimeout(function(){__adObsTimer=null;removeAdOverlays();},200);\n"
             "  }\n"
             "});\n"
             "if(document.documentElement){\n"
             "  __adObs.observe(document.documentElement,{\n"
             "    childList:true,subtree:true,\n"
             "    attributes:true,attributeFilter:['data-appctrl-ad']\n"
             "  });\n"
             "}\n"
             // Auto-hide user-marked elements for current domain
             "function __hideMarkedElements(){\n"
             "  try{\n"
             "    var domain=window.location.hostname.toLowerCase();\n"
             "    for(var i=0;i<blockedElements.length;i++){\n"
             "      var entry=blockedElements[i];\n"
             "      if(entry.domain===domain&&entry.selector){\n"
             "        var els=document.querySelectorAll(entry.selector);\n"
             "        for(var j=0;j<els.length;j++){__markAd(els[j]);}\n"
             "      }\n"
             "    }\n"
             "  }catch(e){}\n"
             "}\n"
             "if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',__hideMarkedElements);}else{__hideMarkedElements();}\n"
             "setInterval(__hideMarkedElements,3000);\n"
             "var __tapCount=0,__tapTarget=null,__tapTimer=null,__tapStartTime=0;\n"
             "document.addEventListener('dblclick',function(e){\n"
             "  var target=e.target;\n"
             "  if(!target||target===document.body||target===document.documentElement){return;}\n"
             "  if(confirm('标记此元素为广告并在此网站隐藏?')){\n"
             "    var sel=__genSelector(target);\n"
             "    if(sel){\n"
             "      __markAd(target);\n"
             "      window.webkit.messageHandlers.%@.postMessage({\n"
             "        action:'markAdElement',\n"
             "        domain:window.location.hostname.toLowerCase(),\n"
             "        selector:sel\n"
             "      });\n"
             "    }\n"
             "  }\n"
             "},true);\n"
             // touchstart/touchend 仅用于计时判断双击，不逐次打日志（高频事件，打日志会拖慢主线程）
             "document.addEventListener('touchstart',function(e){\n"
             "  __tapStartTime=Date.now();\n"
             "},false);\n"
             "document.addEventListener('touchend',function(e){\n"
             "  var target=e.target;\n"
             "  if(target===__tapTarget){\n"
             "    __tapCount++;\n"
             "  }else{\n"
             "    __tapCount=1;\n"
             "    __tapTarget=target;\n"
             "  }\n"
             "  clearTimeout(__tapTimer);\n"
             "  if(__tapCount>=2){\n"
             "    e.preventDefault();\n"
             "    e.stopPropagation();\n"
             "    __tapCount=0;__tapTarget=null;\n"
             "    if(!target||target===document.body||target===document.documentElement){return;}\n"
             "    if(confirm('标记此元素为广告并在此网站隐藏?')){\n"
             "      var sel=__genSelector(target);\n"
             "      if(sel){\n"
             "        __markAd(target);\n"
             "        window.webkit.messageHandlers.%@.postMessage({\n"
             "          action:'markAdElement',\n"
             "          domain:window.location.hostname.toLowerCase(),\n"
             "          selector:sel\n"
             "        });\n"
             "      }\n"
             "    }\n"
             "  }else{\n"
             "    __tapTimer=__origSetTimeout(function(){__tapCount=0;__tapTarget=null;},500);\n"
             "  }\n"
             "},false);\n"
             // Generate unique CSS selector for an element
             "function __genSelector(el){\n"
             "  try{\n"
             "    if(el.id)return '#'+el.id;\n"
             "    var path=[];\n"
             "    while(el&&el!==document.body&&el!==document.documentElement){\n"
             "      var sel=el.tagName.toLowerCase();\n"
             "      if(el.className&&typeof el.className==='string'){\n"
             "        var cls=el.className.trim().split(/\\s+/).filter(function(c){return c.length>0;});\n"
             "        if(cls.length>0)sel+='.'+cls.join('.');\n"
             "      }\n"
             "      path.unshift(sel);\n"
             "      el=el.parentNode;\n"
             "    }\n"
             "    return path.join(' > ');\n"
             "  }catch(e){return '';}\n"
             "}\n"
             "})();",
             AppCtrlScriptMessageName,  // 第1个: Script entry point reached
             blockedJSON, whiteJSON, blockedElementsJSON, disableNetwork,  // JSON 数据
             AppCtrlScriptMessageName,  // 第2个: __log 函数
             AppCtrlScriptMessageName, AppCtrlScriptMessageName,  // 第3,4个: report 函数
             AppCtrlScriptMessageName,  // 第5个: dblclick 事件
             AppCtrlScriptMessageName]; // 第6个: touchend 事件
}

static NSError *appctrl_block_error(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
}

static BOOL appctrl_hostname_is_blocked(const char *hostname) {
    if (!hostname) {
        return NO;
    }

    NSString *host = [NSString stringWithUTF8String:hostname];
    return appctrl_should_block_host(host);
}

static NSMutableSet<NSNumber *> *appctrl_network_fds(void) {
    static NSMutableSet<NSNumber *> *fds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fds = [NSMutableSet set];
    });
    return fds;
}

static NSMutableSet<NSValue *> *appctrl_blocked_nw_connections(void) {
    static NSMutableSet<NSValue *> *connections;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        connections = [NSMutableSet set];
    });
    return connections;
}

static NSValue *appctrl_nw_connection_key(nw_connection_t connection) {
    return connection ? [NSValue valueWithPointer:(__bridge const void *)connection] : nil;
}

static void appctrl_mark_blocked_nw_connection(nw_connection_t connection) {
    NSValue *key = appctrl_nw_connection_key(connection);
    if (!key) {
        return;
    }

    NSMutableSet<NSValue *> *connections = appctrl_blocked_nw_connections();
    @synchronized (connections) {
        [connections addObject:key];
    }
}

static void appctrl_unmark_blocked_nw_connection(nw_connection_t connection) {
    NSValue *key = appctrl_nw_connection_key(connection);
    if (!key) {
        return;
    }

    NSMutableSet<NSValue *> *connections = appctrl_blocked_nw_connections();
    @synchronized (connections) {
        [connections removeObject:key];
    }
}

static BOOL appctrl_is_blocked_nw_connection(nw_connection_t connection) {
    NSValue *key = appctrl_nw_connection_key(connection);
    if (!key) {
        return NO;
    }

    NSMutableSet<NSValue *> *connections = appctrl_blocked_nw_connections();
    @synchronized (connections) {
        return [connections containsObject:key];
    }
}

static void appctrl_mark_network_fd(int fd) {
    if (fd < 0) {
        return;
    }

    NSMutableSet<NSNumber *> *fds = appctrl_network_fds();
    @synchronized (fds) {
        [fds addObject:@(fd)];
    }
}

static void appctrl_unmark_network_fd(int fd) {
    if (fd < 0) {
        return;
    }

    NSMutableSet<NSNumber *> *fds = appctrl_network_fds();
    @synchronized (fds) {
        [fds removeObject:@(fd)];
    }
}

static BOOL appctrl_is_network_fd(int fd) {
    if (fd < 0) {
        return NO;
    }

    NSMutableSet<NSNumber *> *fds = appctrl_network_fds();
    @synchronized (fds) {
        return [fds containsObject:@(fd)];
    }
}

static BOOL appctrl_should_block_network_fd(int fd) {
    return appctrl_should_block_all_network() && appctrl_is_network_fd(fd);
}

static BOOL appctrl_cf_native_socket_is_blocked(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) {
        return NO;
    }

    CFDataRef data = (CFDataRef)value;
    if (CFDataGetLength(data) < (CFIndex)sizeof(CFSocketNativeHandle)) {
        return NO;
    }

    CFSocketNativeHandle fd = -1;
    CFDataGetBytes(data, CFRangeMake(0, sizeof(fd)), (UInt8 *)&fd);
    return appctrl_should_block_network_fd(fd);
}

static int appctrl_socket(int domain, int type, int protocol) {
    // Do NOT block at creation time: we can't see the destination yet, and
    // refusing all AF_INET/AF_INET6 sockets would also break loopback / IPC.
    // Blocking happens later in connect()/send*() based on the actual address.
    return socket(domain, type, protocol);
}

static int appctrl_connect(int socketFD, const struct sockaddr *address, socklen_t address_len) {
    if (appctrl_sockaddr_is_network(address)) {
        appctrl_mark_network_fd(socketFD);
    }

    if (appctrl_should_block_socket_address(address)) {
        errno = ENETDOWN;
        return -1;
    }

    return connect(socketFD, address, address_len);
}

static int appctrl_close(int fd) {
    appctrl_unmark_network_fd(fd);
    return close(fd);
}

static ssize_t appctrl_send(int socketFD, const void *buffer, size_t length, int flags) {
    if (appctrl_should_block_network_fd(socketFD)) {
        errno = ENETDOWN;
        return -1;
    }
    return send(socketFD, buffer, length, flags);
}

static ssize_t appctrl_sendto(int socketFD, const void *buffer, size_t length, int flags, const struct sockaddr *dest_addr, socklen_t dest_len) {
    if (appctrl_sockaddr_is_network(dest_addr)) {
        appctrl_mark_network_fd(socketFD);
    }

    if (appctrl_should_block_network_fd(socketFD) || appctrl_should_block_socket_address(dest_addr)) {
        errno = ENETDOWN;
        return -1;
    }
    return sendto(socketFD, buffer, length, flags, dest_addr, dest_len);
}

static ssize_t appctrl_recv(int socketFD, void *buffer, size_t length, int flags) {
    if (appctrl_should_block_network_fd(socketFD)) {
        errno = ENETDOWN;
        return -1;
    }
    return recv(socketFD, buffer, length, flags);
}

static ssize_t appctrl_recvfrom(int socketFD, void *buffer, size_t length, int flags, struct sockaddr *address, socklen_t *address_len) {
    if (appctrl_should_block_network_fd(socketFD)) {
        errno = ENETDOWN;
        return -1;
    }
    return recvfrom(socketFD, buffer, length, flags, address, address_len);
}

static ssize_t appctrl_write(int fd, const void *buffer, size_t count) {
    if (appctrl_should_block_network_fd(fd)) {
        errno = ENETDOWN;
        return -1;
    }
    return write(fd, buffer, count);
}

static ssize_t appctrl_writev(int fd, const struct iovec *iov, int iovcnt) {
    if (appctrl_should_block_network_fd(fd)) {
        errno = ENETDOWN;
        return -1;
    }
    return writev(fd, iov, iovcnt);
}

static ssize_t appctrl_read(int fd, void *buffer, size_t count) {
    if (appctrl_should_block_network_fd(fd)) {
        errno = ENETDOWN;
        return -1;
    }
    return read(fd, buffer, count);
}

static ssize_t appctrl_readv(int fd, const struct iovec *iov, int iovcnt) {
    if (appctrl_should_block_network_fd(fd)) {
        errno = ENETDOWN;
        return -1;
    }
    return readv(fd, iov, iovcnt);
}

static BOOL appctrl_should_block_hostname(const char *name) {
    // Never block loopback lookups: local servers / IPC must keep resolving.
    if (appctrl_hostname_is_loopback(name)) {
        return NO;
    }
    if (appctrl_should_block_all_network() && name && name[0] != '\0') {
        return YES;
    }
    return appctrl_hostname_is_blocked(name);
}

static int appctrl_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (appctrl_should_block_hostname(node)) {
        if (appctrl_should_count_block_for_hostname(node)) {
            appctrl_record_block_hit();
        }
        if (res) {
            *res = NULL;
        }
        return EAI_FAIL;
    }
    return getaddrinfo(node, service, hints, res);
}

static struct hostent *appctrl_gethostbyname(const char *name) {
    if (appctrl_should_block_hostname(name)) {
        if (appctrl_should_count_block_for_hostname(name)) {
            appctrl_record_block_hit();
        }
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname(name);
}

static struct hostent *appctrl_gethostbyname2(const char *name, int af) {
    if (appctrl_should_block_hostname(name)) {
        if (appctrl_should_count_block_for_hostname(name)) {
            appctrl_record_block_hit();
        }
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname2(name, af);
}

static void appctrl_CFStreamCreatePairWithSocketToHost(CFAllocatorRef alloc, CFStringRef host, UInt32 port, CFReadStreamRef *readStream, CFWriteStreamRef *writeStream) {
    NSString *hostString = host ? (__bridge NSString *)host : nil;
    BOOL isLoopback = hostString.length > 0 && appctrl_hostname_is_loopback(hostString.UTF8String);
    if (!isLoopback && ((appctrl_should_block_all_network() && hostString.length > 0) || appctrl_should_block_host(hostString))) {
        if (appctrl_should_block_host(hostString)) {
            appctrl_record_block_hit();
        }
        if (readStream) {
            *readStream = NULL;
        }
        if (writeStream) {
            *writeStream = NULL;
        }
        return;
    }
    CFStreamCreatePairWithSocketToHost(alloc, host, port, readStream, writeStream);
}

static void appctrl_CFStreamCreatePairWithSocket(CFAllocatorRef alloc, CFSocketNativeHandle sock, CFReadStreamRef *readStream, CFWriteStreamRef *writeStream) {
    if (appctrl_should_block_network_fd(sock)) {
        if (readStream) {
            *readStream = NULL;
        }
        if (writeStream) {
            *writeStream = NULL;
        }
        return;
    }
    CFStreamCreatePairWithSocket(alloc, sock, readStream, writeStream);
}

static Boolean appctrl_CFReadStreamOpen(CFReadStreamRef stream) {
    CFTypeRef nativeHandle = stream ? CFReadStreamCopyProperty(stream, kCFStreamPropertySocketNativeHandle) : NULL;
    BOOL shouldBlock = appctrl_cf_native_socket_is_blocked(nativeHandle);
    if (nativeHandle) {
        CFRelease(nativeHandle);
    }

    if (shouldBlock) {
        return false;
    }
    return CFReadStreamOpen(stream);
}

static Boolean appctrl_CFWriteStreamOpen(CFWriteStreamRef stream) {
    CFTypeRef nativeHandle = stream ? CFWriteStreamCopyProperty(stream, kCFStreamPropertySocketNativeHandle) : NULL;
    BOOL shouldBlock = appctrl_cf_native_socket_is_blocked(nativeHandle);
    if (nativeHandle) {
        CFRelease(nativeHandle);
    }

    if (shouldBlock) {
        return false;
    }
    return CFWriteStreamOpen(stream);
}

static void appctrl_nw_connection_start(nw_connection_t connection) {
    if (appctrl_should_block_all_network() || appctrl_is_blocked_nw_connection(connection)) {
        nw_connection_cancel(connection);
        appctrl_unmark_blocked_nw_connection(connection);
        return;
    }
    nw_connection_start(connection);
}

static nw_connection_t appctrl_nw_connection_create(nw_endpoint_t endpoint, nw_parameters_t parameters) {
    nw_connection_t connection = nw_connection_create(endpoint, parameters);
    if (!connection) {
        return connection;
    }

    const char *hostname = endpoint ? nw_endpoint_get_hostname(endpoint) : NULL;
    if (appctrl_should_block_hostname(hostname)) {
        appctrl_mark_blocked_nw_connection(connection);
        if (appctrl_should_count_block_for_hostname(hostname)) {
            appctrl_record_block_hit();
        }
    }

    return connection;
}

@interface AppCtrlScriptMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation AppCtrlScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    appctrl_log_to_panel([NSString stringWithFormat:@"收到消息: %@", message.name]);

    if (![message.name isEqualToString:AppCtrlScriptMessageName]) {
        return;
    }

    id body = message.body;
    if ([body isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)body;
        NSString *action = dict[@"action"];

        if ([action isEqualToString:@"markAdElement"]) {
            NSString *domain = dict[@"domain"];
            NSString *selector = dict[@"selector"];
            appctrl_log_to_panel([NSString stringWithFormat:@"标记广告元素 - domain: %@, selector: %@", domain, selector]);
            if (domain && selector) {
                appctrl_save_blocked_element(domain, selector);
            }
            return;
        }
        if ([action isEqualToString:@"log"]) {
            NSString *logMsg = dict[@"message"];
            if (logMsg) {
                appctrl_log_to_panel(logMsg);
            }
            return;
        }
        NSString *urlString = dict[@"url"];
        if (urlString) {
            appctrl_handle_script_blocked_url_string(urlString);
        }
    } else if ([body isKindOfClass:[NSString class]]) {
        appctrl_handle_script_blocked_url_string(body);
    }
}

@end

static AppCtrlScriptMessageHandler *gScriptMessageHandler;

static void appctrl_configure_webview_configuration(WKWebViewConfiguration *configuration) {
    if (!configuration) {
        return;
    }

    appctrl_log_to_panel(@"配置 WKWebView");

    appctrl_refresh_content_rule_list_if_needed();

    if (!configuration.userContentController) {
        configuration.userContentController = [WKUserContentController new];
    }

    if (!gScriptMessageHandler) {
        gScriptMessageHandler = [AppCtrlScriptMessageHandler new];
        appctrl_log_to_panel(@"创建消息处理器");
    }

    WKUserContentController *controller = configuration.userContentController;
    // 注意：标记必须打在 controller 上，而不是 configuration 上。
    // 因为有些 App 会先创建 configuration（此时其默认 userContentController 会被我们配置），
    // 然后再整体替换 configuration.userContentController 为一个新对象。
    // 如果标记打在 configuration 上，第二次调用会误以为"已配置"，
    // 导致新的 controller 上永远没有被注入脚本和消息处理器。
    BOOL alreadyConfigured = (objc_getAssociatedObject(controller, &kAppCtrlWebViewConfiguredKey) != nil);
    appctrl_log_to_panel([NSString stringWithFormat:@"controller=%p alreadyConfigured=%d", controller, alreadyConfigured]);
    if (!alreadyConfigured) {
        @try {
            [controller removeScriptMessageHandlerForName:AppCtrlScriptMessageName];
        } @catch (__unused NSException *exception) {
        }
        [controller addScriptMessageHandler:gScriptMessageHandler name:AppCtrlScriptMessageName];
        appctrl_log_to_panel([NSString stringWithFormat:@"添加消息处理器: %@", AppCtrlScriptMessageName]);

        WKUserScript *script = [[WKUserScript alloc] initWithSource:appctrl_webview_user_script_source()
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:NO];
        [controller addUserScript:script];
        appctrl_log_to_panel(@"添加用户脚本");
        objc_setAssociatedObject(controller, &kAppCtrlWebViewConfiguredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *appliedSignature = objc_getAssociatedObject(controller, &kAppCtrlAppliedContentRuleSignatureKey);
    if (gAppCtrlContentRuleList && ![appliedSignature isEqualToString:gAppCtrlContentRuleListSignature]) {
        if ([controller respondsToSelector:@selector(removeAllContentRuleLists)]) {
            [controller removeAllContentRuleLists];
        }
        [controller addContentRuleList:gAppCtrlContentRuleList];
        if (gAppCtrlContentRuleListSignature) {
            objc_setAssociatedObject(controller, &kAppCtrlAppliedContentRuleSignatureKey, gAppCtrlContentRuleListSignature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }

    // Track this controller so newly compiled rules can be pushed to it later.
    if (!gAppCtrlTrackedContentControllers) {
        gAppCtrlTrackedContentControllers = [NSHashTable weakObjectsHashTable];
    }
    [gAppCtrlTrackedContentControllers addObject:controller];
}

#define APPCTRL_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _appctrl_interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }

APPCTRL_INTERPOSE(appctrl_socket, socket);
APPCTRL_INTERPOSE(appctrl_connect, connect);
APPCTRL_INTERPOSE(appctrl_close, close);
APPCTRL_INTERPOSE(appctrl_send, send);
APPCTRL_INTERPOSE(appctrl_sendto, sendto);
APPCTRL_INTERPOSE(appctrl_recv, recv);
APPCTRL_INTERPOSE(appctrl_recvfrom, recvfrom);
APPCTRL_INTERPOSE(appctrl_write, write);
APPCTRL_INTERPOSE(appctrl_writev, writev);
APPCTRL_INTERPOSE(appctrl_read, read);
APPCTRL_INTERPOSE(appctrl_readv, readv);
APPCTRL_INTERPOSE(appctrl_getaddrinfo, getaddrinfo);
APPCTRL_INTERPOSE(appctrl_gethostbyname, gethostbyname);
APPCTRL_INTERPOSE(appctrl_gethostbyname2, gethostbyname2);
APPCTRL_INTERPOSE(appctrl_CFStreamCreatePairWithSocketToHost, CFStreamCreatePairWithSocketToHost);
APPCTRL_INTERPOSE(appctrl_CFStreamCreatePairWithSocket, CFStreamCreatePairWithSocket);
APPCTRL_INTERPOSE(appctrl_CFReadStreamOpen, CFReadStreamOpen);
APPCTRL_INTERPOSE(appctrl_CFWriteStreamOpen, CFWriteStreamOpen);
APPCTRL_INTERPOSE(appctrl_nw_connection_create, nw_connection_create);
APPCTRL_INTERPOSE(appctrl_nw_connection_start, nw_connection_start);

static NSURLSessionDataTask *(*orig_dataTaskWithRequest_completionHandler)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *repl_dataTaskWithRequest_completionHandler(id self, SEL _cmd, NSURLRequest *request, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    if (appctrl_should_block_url(request.URL)) {
        if (appctrl_should_count_block_for_url(request.URL)) {
            appctrl_record_block_hit();
        }
        if (completion) {
            completion(nil, nil, appctrl_block_error());
        }
        return nil;
    }
    return orig_dataTaskWithRequest_completionHandler(self, _cmd, request, completion);
}

static NSURLSessionDataTask *(*orig_dataTaskWithURL_completionHandler)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *repl_dataTaskWithURL_completionHandler(id self, SEL _cmd, NSURL *url, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    if (appctrl_should_block_url(url)) {
        if (appctrl_should_count_block_for_url(url)) {
            appctrl_record_block_hit();
        }
        if (completion) {
            completion(nil, nil, appctrl_block_error());
        }
        return nil;
    }
    return orig_dataTaskWithURL_completionHandler(self, _cmd, url, completion);
}

static NSURLSessionUploadTask *(*orig_uploadTaskWithRequest_fromData_completionHandler)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionUploadTask *repl_uploadTaskWithRequest_fromData_completionHandler(id self, SEL _cmd, NSURLRequest *request, NSData *bodyData, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    if (appctrl_should_block_url(request.URL)) {
        if (appctrl_should_count_block_for_url(request.URL)) {
            appctrl_record_block_hit();
        }
        if (completion) {
            completion(nil, nil, appctrl_block_error());
        }
        return nil;
    }
    return orig_uploadTaskWithRequest_fromData_completionHandler(self, _cmd, request, bodyData, completion);
}

static NSURLSessionDownloadTask *(*orig_downloadTaskWithRequest_completionHandler)(id, SEL, NSURLRequest *, void (^)(NSURL *, NSURLResponse *, NSError *));
static NSURLSessionDownloadTask *repl_downloadTaskWithRequest_completionHandler(id self, SEL _cmd, NSURLRequest *request, void (^completion)(NSURL *, NSURLResponse *, NSError *)) {
    if (appctrl_should_block_url(request.URL)) {
        if (appctrl_should_count_block_for_url(request.URL)) {
            appctrl_record_block_hit();
        }
        if (completion) {
            completion(nil, nil, appctrl_block_error());
        }
        return nil;
    }
    return orig_downloadTaskWithRequest_completionHandler(self, _cmd, request, completion);
}

static NSData *(*orig_sendSynchronousRequest_returningResponse_error)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **);
static NSData *repl_sendSynchronousRequest_returningResponse_error(id self, SEL _cmd, NSURLRequest *request, NSURLResponse **response, NSError **error) {
    if (appctrl_should_block_url(request.URL)) {
        if (appctrl_should_count_block_for_url(request.URL)) {
            appctrl_record_block_hit();
        }
        if (error) {
            *error = appctrl_block_error();
        }
        return nil;
    }
    return orig_sendSynchronousRequest_returningResponse_error(self, _cmd, request, response, error);
}

static void (*orig_sendAsynchronousRequest_queue_completionHandler)(id, SEL, NSURLRequest *, NSOperationQueue *, void (^)(NSURLResponse *, NSData *, NSError *));
static void repl_sendAsynchronousRequest_queue_completionHandler(id self, SEL _cmd, NSURLRequest *request, NSOperationQueue *queue, void (^completion)(NSURLResponse *, NSData *, NSError *)) {
    if (appctrl_should_block_url(request.URL)) {
        if (appctrl_should_count_block_for_url(request.URL)) {
            appctrl_record_block_hit();
        }
        if (completion) {
            completion(nil, nil, appctrl_block_error());
        }
        return;
    }
    orig_sendAsynchronousRequest_queue_completionHandler(self, _cmd, request, queue, completion);
}

static BOOL (*orig_openURL_options_completionHandler)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static BOOL repl_openURL_options_completionHandler(id self, SEL _cmd, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
    if (appctrl_should_block_url(url)) {
        if (appctrl_should_count_block_for_url(url)) {
            appctrl_record_block_hit();
        }
        if (completion) {
            completion(NO);
        }
        return NO;
    }
    return orig_openURL_options_completionHandler(self, _cmd, url, options, completion);
}

static BOOL (*orig_openURL_legacy)(id, SEL, NSURL *);
static BOOL repl_openURL_legacy(id self, SEL _cmd, NSURL *url) {
    if (appctrl_should_block_url(url)) {
        if (appctrl_should_count_block_for_url(url)) {
            appctrl_record_block_hit();
        }
        return NO;
    }
    return orig_openURL_legacy(self, _cmd, url);
}

static id (*orig_wk_loadRequest)(id, SEL, NSURLRequest *);
static id repl_wk_loadRequest(id self, SEL _cmd, NSURLRequest *request) {
    if ([self isKindOfClass:[WKWebView class]]) {
        appctrl_configure_webview_configuration(((WKWebView *)self).configuration);
    }
    if (appctrl_should_block_url(request.URL)) {
        if (appctrl_should_count_block_for_url(request.URL)) {
            appctrl_record_block_hit();
        }
        return nil;
    }
    return orig_wk_loadRequest(self, _cmd, request);
}

static id (*orig_wk_loadFileURL_allowingReadAccessToURL)(id, SEL, NSURL *, NSURL *);
static id repl_wk_loadFileURL_allowingReadAccessToURL(id self, SEL _cmd, NSURL *url, NSURL *readAccessURL) {
    if ([self isKindOfClass:[WKWebView class]]) {
        appctrl_configure_webview_configuration(((WKWebView *)self).configuration);
    }
    if (appctrl_should_block_url(url)) {
        if (appctrl_should_count_block_for_url(url)) {
            appctrl_record_block_hit();
        }
        return nil;
    }
    return orig_wk_loadFileURL_allowingReadAccessToURL(self, _cmd, url, readAccessURL);
}

typedef void (*WKDecisionOrigIMP)(id, SEL, WKWebView *, WKNavigationAction *, void (^)(WKNavigationActionPolicy));

static void repl_wkNavigationDelegate_decidePolicy(id self, SEL _cmd, WKWebView *webView, WKNavigationAction *navigationAction, void (^decisionHandler)(WKNavigationActionPolicy)) {
    NSURL *url = navigationAction.request.URL;
    if (appctrl_should_block_url(url)) {
        if (appctrl_should_count_block_for_url(url)) {
            appctrl_record_block_hit();
        }
        if (decisionHandler) {
            decisionHandler(WKNavigationActionPolicyCancel);
        }
        return;
    }

    NSValue *origValue = objc_getAssociatedObject(object_getClass(self), &kOrigWKDelegateDecisionKey);
    WKDecisionOrigIMP orig = (WKDecisionOrigIMP)[origValue pointerValue];
    if (orig) {
        orig(self, _cmd, webView, navigationAction, decisionHandler);
    } else if (decisionHandler) {
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

typedef WKWebView *(*WKCreateWebViewOrigIMP)(id, SEL, WKWebView *, WKWebViewConfiguration *, WKNavigationAction *, WKWindowFeatures *);

static WKWebView *repl_wkUIDelegate_createWebView(id self, SEL _cmd, WKWebView *webView, WKWebViewConfiguration *configuration, WKNavigationAction *navigationAction, WKWindowFeatures *windowFeatures) {
    NSURL *url = navigationAction.request.URL;
    if (appctrl_should_block_url(url)) {
        if (appctrl_should_count_block_for_url(url)) {
            appctrl_record_block_hit();
        }
        return nil;
    }

    NSValue *origValue = objc_getAssociatedObject(object_getClass(self), &kOrigWKUIDelegateCreateWebViewKey);
    WKCreateWebViewOrigIMP orig = (WKCreateWebViewOrigIMP)[origValue pointerValue];
    if (orig) {
        return orig(self, _cmd, webView, configuration, navigationAction, windowFeatures);
    }
    return nil;
}

static void appctrl_swizzle_navigation_delegate_if_needed(id delegate) {
    if (!delegate) {
        return;
    }

    Class cls = object_getClass(delegate);
    SEL sel = @selector(webView:decidePolicyForNavigationAction:decisionHandler:);

    // Guard: already patched this class.
    if (objc_getAssociatedObject(cls, &kOrigWKDelegateDecisionKey) != nil) {
        return;
    }

    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        // Delegate already has this method — swizzle it and save the original IMP.
        IMP orig = method_getImplementation(method);
        objc_setAssociatedObject(cls, &kOrigWKDelegateDecisionKey, [NSValue valueWithPointer:orig], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        method_setImplementation(method, (IMP)repl_wkNavigationDelegate_decidePolicy);
    } else {
        // Delegate does NOT implement the policy method at all — add it dynamically.
        // Store a sentinel (NULL pointer) so the replacement IMP falls through to "allow"
        // instead of trying to call a missing orig.
        objc_setAssociatedObject(cls, &kOrigWKDelegateDecisionKey, [NSValue valueWithPointer:NULL], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Fetch the type encoding from the protocol so we don't hard-code it.
        struct objc_method_description desc = protocol_getMethodDescription(
            @protocol(WKNavigationDelegate), sel, NO /* optional */, YES /* instance */);
        const char *types = desc.types;
        if (!types) { types = "v@:@@@?"; } // fallback
        class_addMethod(cls, sel, (IMP)repl_wkNavigationDelegate_decidePolicy, types);
    }
}

static void appctrl_swizzle_ui_delegate_if_needed(id delegate) {
    if (!delegate) {
        return;
    }

    Class cls = object_getClass(delegate);
    SEL sel = @selector(webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }

    if (objc_getAssociatedObject(cls, &kOrigWKUIDelegateCreateWebViewKey) != nil) {
        return;
    }

    IMP orig = method_getImplementation(method);
    objc_setAssociatedObject(cls, &kOrigWKUIDelegateCreateWebViewKey, [NSValue valueWithPointer:orig], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    method_setImplementation(method, (IMP)repl_wkUIDelegate_createWebView);
}

static void (*orig_wk_setNavigationDelegate)(id, SEL, id);
static void repl_wk_setNavigationDelegate(id self, SEL _cmd, id delegate) {
    appctrl_swizzle_navigation_delegate_if_needed(delegate);
    orig_wk_setNavigationDelegate(self, _cmd, delegate);
}

static void (*orig_wk_setUIDelegate)(id, SEL, id);
static void repl_wk_setUIDelegate(id self, SEL _cmd, id delegate) {
    appctrl_swizzle_ui_delegate_if_needed(delegate);
    orig_wk_setUIDelegate(self, _cmd, delegate);
}

static id (*orig_wkwebviewconfiguration_init)(id, SEL);
static id repl_wkwebviewconfiguration_init(id self, SEL _cmd) {
    id result = orig_wkwebviewconfiguration_init(self, _cmd);
    if ([result isKindOfClass:[WKWebViewConfiguration class]]) {
        appctrl_configure_webview_configuration((WKWebViewConfiguration *)result);
    }
    return result;
}

static id (*orig_wk_initWithFrame_configuration)(id, SEL, CGRect, WKWebViewConfiguration *);
static id repl_wk_initWithFrame_configuration(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *configuration) {
    appctrl_configure_webview_configuration(configuration);
    id result = orig_wk_initWithFrame_configuration(self, _cmd, frame, configuration);
    if ([result isKindOfClass:[WKWebView class]]) {
        WKWebView *webView = (WKWebView *)result;
        if (webView.UIDelegate) {
            appctrl_swizzle_ui_delegate_if_needed(webView.UIDelegate);
        }
        if (webView.navigationDelegate) {
            appctrl_swizzle_navigation_delegate_if_needed(webView.navigationDelegate);
        }
    }
    return result;
}

static id (*orig_wk_initWithCoder)(id, SEL, NSCoder *);
static id repl_wk_initWithCoder(id self, SEL _cmd, NSCoder *coder) {
    id result = orig_wk_initWithCoder(self, _cmd, coder);
    if ([result isKindOfClass:[WKWebView class]]) {
        WKWebView *webView = (WKWebView *)result;
        appctrl_configure_webview_configuration(webView.configuration);
        if (webView.UIDelegate) {
            appctrl_swizzle_ui_delegate_if_needed(webView.UIDelegate);
        }
        if (webView.navigationDelegate) {
            appctrl_swizzle_navigation_delegate_if_needed(webView.navigationDelegate);
        }
    }
    return result;
}

static void appctrl_swizzle_instance_method(Class cls, SEL sel, IMP repl, IMP *orig) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }
    if (orig) {
        *orig = method_getImplementation(method);
    }
    method_setImplementation(method, repl);
}

static void appctrl_swizzle_class_method(Class cls, SEL sel, IMP repl, IMP *orig) {
    Class meta = object_getClass(cls);
    Method method = class_getClassMethod(cls, sel);
    if (!method || !meta) {
        return;
    }
    if (orig) {
        *orig = method_getImplementation(method);
    }
    method_setImplementation(method, repl);
}

static CGFloat appctrl_clamp(CGFloat value, CGFloat minValue, CGFloat maxValue) {
    if (maxValue < minValue) {
        return minValue;
    }
    return MIN(MAX(value, minValue), maxValue);
}

static void appctrl_clamp_floating_button(void) {
    if (!gFloatingButton || !gFloatingButton.superview) {
        return;
    }

    UIView *container = gFloatingButton.superview;
    CGSize boundsSize = container.bounds.size;
    CGSize buttonSize = gFloatingButton.bounds.size;
    CGFloat halfWidth = buttonSize.width / 2.0;
    CGFloat halfHeight = buttonSize.height / 2.0;

    gFloatingButton.center = CGPointMake(
        appctrl_clamp(gFloatingButton.center.x, halfWidth, boundsSize.width - halfWidth),
        appctrl_clamp(gFloatingButton.center.y, halfHeight, boundsSize.height - halfHeight)
    );
}

static void appctrl_position_panel_near_button(void) {
    if (!gFloatingButton || !gPanelView || !gFloatingButton.superview) {
        return;
    }

    UIView *container = gFloatingButton.superview;
    CGSize panelSize = gPanelView.bounds.size;
    if (panelSize.width <= 0 || panelSize.height <= 0) {
        panelSize = gPanelView.frame.size;
    }

    CGFloat margin = 8.0;
    CGRect buttonFrame = gFloatingButton.frame;
    CGFloat x = CGRectGetMinX(buttonFrame);
    CGFloat y = CGRectGetMaxY(buttonFrame) + 12.0;
    CGFloat maxX = container.bounds.size.width - panelSize.width - margin;

    x = appctrl_clamp(x, margin, maxX);
    if (y + panelSize.height + margin > container.bounds.size.height) {
        y = CGRectGetMinY(buttonFrame) - panelSize.height - 12.0;
    }
    y = appctrl_clamp(y, margin, container.bounds.size.height - panelSize.height - margin);

    gPanelView.frame = (CGRect){CGPointMake(x, y), panelSize};
}

static void appctrl_apply_saved_button_position(void) {
    if (!gFloatingButton) {
        return;
    }

    NSDictionary *state = appctrl_load_state_file();
    NSNumber *x = state[@"floatingButtonCenterX"];
    NSNumber *y = state[@"floatingButtonCenterY"];
    if (![x isKindOfClass:[NSNumber class]] || ![y isKindOfClass:[NSNumber class]]) {
        return;
    }

    gFloatingButton.center = CGPointMake(x.doubleValue, y.doubleValue);
    appctrl_clamp_floating_button();
}

static void appctrl_save_button_position(void) {
    if (!gFloatingButton) {
        return;
    }

    NSMutableDictionary *state = [appctrl_load_state_file() mutableCopy];
    state[@"disableNetwork"] = @(gNetworkSwitch ? gNetworkSwitch.on : appctrl_disable_network());
    state[@"floatingButtonCenterX"] = @(gFloatingButton.center.x);
    state[@"floatingButtonCenterY"] = @(gFloatingButton.center.y);
    [state writeToFile:appctrl_state_path() atomically:YES];
}

static void appctrl_reload_panel_from_disk(void) {
    if (!gNetworkSwitch || !gDomainsTextView || !gWhiteDomainsTextView) {
        return;
    }
    gNetworkSwitch.on = appctrl_disable_network();
    gDomainsTextView.text = appctrl_domains_file_content();
    gWhiteDomainsTextView.text = appctrl_white_domains_file_content();
    appctrl_refresh_block_count_label();
}

static void appctrl_save_panel_state(void) {
    NSMutableDictionary *state = [appctrl_load_state_file() mutableCopy];
    state[@"disableNetwork"] = @(gNetworkSwitch.on);
    if (gFloatingButton) {
        state[@"floatingButtonCenterX"] = @(gFloatingButton.center.x);
        state[@"floatingButtonCenterY"] = @(gFloatingButton.center.y);
    }
    [state writeToFile:appctrl_state_path() atomically:YES];

    NSString *domains = gDomainsTextView.text ?: @"";
    [domains writeToFile:appctrl_domains_path() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *whiteDomains = gWhiteDomainsTextView.text ?: @"";
    [whiteDomains writeToFile:appctrl_white_domains_path() atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Re-compile rules immediately so already-open WebViews pick up the change.
    appctrl_refresh_content_rule_list_if_needed();
}

static void appctrl_toggle_panel(void) {
    if (!gPanelView) {
        return;
    }
    gPanelView.hidden = !gPanelView.hidden;
    if (!gPanelView.hidden) {
        appctrl_reload_panel_from_disk();
        appctrl_position_panel_near_button();
    }
}

static UIButton *appctrl_button(NSString *title, SEL action, id target) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    button.layer.cornerRadius = 8.0;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@interface AppCtrlPanelTarget : NSObject
@end

@implementation AppCtrlPanelTarget

- (void)togglePanel {
    appctrl_toggle_panel();
}

- (void)savePressed {
    appctrl_save_panel_state();
}

- (void)reloadPressed {
    appctrl_reload_panel_from_disk();
}

- (void)floatingButtonDragged:(UIPanGestureRecognizer *)recognizer {
    UIView *button = recognizer.view;
    UIView *container = button.superview;
    if (!button || !container) {
        return;
    }

    CGPoint translation = [recognizer translationInView:container];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [recognizer setTranslation:(CGPoint){0, 0} inView:container];

    appctrl_clamp_floating_button();
    appctrl_position_panel_near_button();

    if (recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled) {
        appctrl_save_button_position();
    }
}

@end

static AppCtrlPanelTarget *gPanelTarget;

static UIWindow *appctrl_find_host_window(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if (![candidate isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *scene = (UIWindowScene *)candidate;
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }

            UIWindow *first = scene.windows.firstObject;
            if (first) {
                return first;
            }
        }
    }

    return nil;
}

static void appctrl_install_panel(void) {
    if (gFloatingButton.superview && gPanelView.superview) {
        return;
    }

    if (!UIApplication.sharedApplication) {
        return;
    }

    UIWindow *hostWindow = appctrl_find_host_window();
    if (!hostWindow) {
        return;
    }

    gHostWindow = hostWindow;
    UIView *container = hostWindow.rootViewController ? hostWindow.rootViewController.view : hostWindow;
    if (!container) {
        container = hostWindow;
    }

    gPanelTarget = [AppCtrlPanelTarget new];

    gFloatingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gFloatingButton.frame = CGRectMake(16, 120, 56, 56);
    gFloatingButton.layer.cornerRadius = 28;
    gFloatingButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:0.88];
    [gFloatingButton setTitle:@"AC" forState:UIControlStateNormal];
    [gFloatingButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [gFloatingButton addTarget:gPanelTarget action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [gFloatingButton addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gPanelTarget action:@selector(floatingButtonDragged:)]];
    [container addSubview:gFloatingButton];
    appctrl_apply_saved_button_position();

    gPanelView = [[UIView alloc] initWithFrame:CGRectMake(16, 188, 320, 550)];
    gPanelView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    gPanelView.layer.cornerRadius = 14;
    gPanelView.layer.borderWidth = 1;
    gPanelView.layer.borderColor = [UIColor colorWithWhite:0.82 alpha:1.0].CGColor;
    gPanelView.hidden = YES;
    [container addSubview:gPanelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, 220, 24)];
    title.text = @"App Control";
    title.font = [UIFont boldSystemFontOfSize:18];
    [gPanelView addSubview:title];

    UILabel *networkLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 48, 200, 24)];
    networkLabel.text = @"Disable Network";
    networkLabel.font = [UIFont systemFontOfSize:15];
    [gPanelView addSubview:networkLabel];

    gNetworkSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(244, 44, 0, 0)];
    [gPanelView addSubview:gNetworkSwitch];

    gBlockCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 72, 296, 20)];
    gBlockCountLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    gBlockCountLabel.textColor = UIColor.secondaryLabelColor;
    [gPanelView addSubview:gBlockCountLabel];

    UILabel *domainsLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 100, 220, 20)];
    domainsLabel.text = @"Blocked domains";
    domainsLabel.font = [UIFont systemFontOfSize:15];
    [gPanelView addSubview:domainsLabel];

    gDomainsTextView = [[UITextView alloc] initWithFrame:CGRectMake(12, 126, 296, 92)];
    gDomainsTextView.font = [UIFont systemFontOfSize:14];
    gDomainsTextView.layer.borderWidth = 1;
    gDomainsTextView.layer.borderColor = [UIColor colorWithWhite:0.84 alpha:1.0].CGColor;
    gDomainsTextView.layer.cornerRadius = 8;
    [gPanelView addSubview:gDomainsTextView];

    UILabel *whiteDomainsLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 226, 220, 20)];
    whiteDomainsLabel.text = @"White domains";
    whiteDomainsLabel.font = [UIFont systemFontOfSize:15];
    [gPanelView addSubview:whiteDomainsLabel];

    gWhiteDomainsTextView = [[UITextView alloc] initWithFrame:CGRectMake(12, 252, 296, 92)];
    gWhiteDomainsTextView.font = [UIFont systemFontOfSize:14];
    gWhiteDomainsTextView.layer.borderWidth = 1;
    gWhiteDomainsTextView.layer.borderColor = [UIColor colorWithWhite:0.84 alpha:1.0].CGColor;
    gWhiteDomainsTextView.layer.cornerRadius = 8;
    [gPanelView addSubview:gWhiteDomainsTextView];

    UIButton *save = appctrl_button(@"Save", @selector(savePressed), gPanelTarget);
    save.frame = CGRectMake(12, 356, 90, 30);
    [gPanelView addSubview:save];

    UIButton *reload = appctrl_button(@"Reload", @selector(reloadPressed), gPanelTarget);
    reload.frame = CGRectMake(112, 356, 90, 30);
    [gPanelView addSubview:reload];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(210, 352, 96, 34)];
    hint.numberOfLines = 2;
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.text = @"one per line\nor comma";
    [gPanelView addSubview:hint];

    UILabel *logLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 394, 220, 20)];
    logLabel.text = @"Debug Log";
    logLabel.font = [UIFont systemFontOfSize:15];
    [gPanelView addSubview:logLabel];

    gLogTextView = [[UITextView alloc] initWithFrame:CGRectMake(12, 420, 296, 110)];
    gLogTextView.font = [UIFont systemFontOfSize:12];
    gLogTextView.layer.borderWidth = 1;
    gLogTextView.layer.borderColor = [UIColor colorWithWhite:0.84 alpha:1.0].CGColor;
    gLogTextView.layer.cornerRadius = 8;
    gLogTextView.editable = NO;
    gLogTextView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    gLogTextView.text = @"[Init] 日志面板已初始化\n";
    [gPanelView addSubview:gLogTextView];

    appctrl_reload_panel_from_disk();

    // 面板安装完成后立即记录
    appctrl_log_to_panel(@"AC 面板安装完成");
}

static void appctrl_schedule_panel_install(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        appctrl_install_panel();
    });
}

static void appctrl_app_did_become_active(NSNotification *note) {
    appctrl_schedule_panel_install();
}

__attribute__((constructor))
static void appctrl_init(void) {
    @autoreleasepool {
        Class nsurlsession = objc_getClass("NSURLSession");
        if (nsurlsession) {
            appctrl_swizzle_instance_method(nsurlsession, @selector(dataTaskWithRequest:completionHandler:), (IMP)repl_dataTaskWithRequest_completionHandler, (IMP *)&orig_dataTaskWithRequest_completionHandler);
            appctrl_swizzle_instance_method(nsurlsession, @selector(dataTaskWithURL:completionHandler:), (IMP)repl_dataTaskWithURL_completionHandler, (IMP *)&orig_dataTaskWithURL_completionHandler);
            appctrl_swizzle_instance_method(nsurlsession, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)repl_uploadTaskWithRequest_fromData_completionHandler, (IMP *)&orig_uploadTaskWithRequest_fromData_completionHandler);
            appctrl_swizzle_instance_method(nsurlsession, @selector(downloadTaskWithRequest:completionHandler:), (IMP)repl_downloadTaskWithRequest_completionHandler, (IMP *)&orig_downloadTaskWithRequest_completionHandler);
        }

        Class nsurlconnection = objc_getClass("NSURLConnection");
        if (nsurlconnection) {
            appctrl_swizzle_class_method(nsurlconnection, @selector(sendSynchronousRequest:returningResponse:error:), (IMP)repl_sendSynchronousRequest_returningResponse_error, (IMP *)&orig_sendSynchronousRequest_returningResponse_error);
            appctrl_swizzle_class_method(nsurlconnection, @selector(sendAsynchronousRequest:queue:completionHandler:), (IMP)repl_sendAsynchronousRequest_queue_completionHandler, (IMP *)&orig_sendAsynchronousRequest_queue_completionHandler);
        }

        Class uiapplication = objc_getClass("UIApplication");
        if (uiapplication) {
            appctrl_swizzle_instance_method(uiapplication, @selector(openURL:options:completionHandler:), (IMP)repl_openURL_options_completionHandler, (IMP *)&orig_openURL_options_completionHandler);
            appctrl_swizzle_instance_method(uiapplication, @selector(openURL:), (IMP)repl_openURL_legacy, (IMP *)&orig_openURL_legacy);
        }

        Class wkwebview = objc_getClass("WKWebView");
        if (wkwebview) {
            appctrl_swizzle_instance_method(wkwebview, @selector(loadRequest:), (IMP)repl_wk_loadRequest, (IMP *)&orig_wk_loadRequest);
            appctrl_swizzle_instance_method(wkwebview, @selector(loadFileURL:allowingReadAccessToURL:), (IMP)repl_wk_loadFileURL_allowingReadAccessToURL, (IMP *)&orig_wk_loadFileURL_allowingReadAccessToURL);
            appctrl_swizzle_instance_method(wkwebview, @selector(setNavigationDelegate:), (IMP)repl_wk_setNavigationDelegate, (IMP *)&orig_wk_setNavigationDelegate);
            appctrl_swizzle_instance_method(wkwebview, @selector(setUIDelegate:), (IMP)repl_wk_setUIDelegate, (IMP *)&orig_wk_setUIDelegate);
            appctrl_swizzle_instance_method(wkwebview, @selector(initWithFrame:configuration:), (IMP)repl_wk_initWithFrame_configuration, (IMP *)&orig_wk_initWithFrame_configuration);
            appctrl_swizzle_instance_method(wkwebview, @selector(initWithCoder:), (IMP)repl_wk_initWithCoder, (IMP *)&orig_wk_initWithCoder);
        }

        Class wkwebviewconfiguration = objc_getClass("WKWebViewConfiguration");
        if (wkwebviewconfiguration) {
            appctrl_swizzle_instance_method(wkwebviewconfiguration, @selector(init), (IMP)repl_wkwebviewconfiguration_init, (IMP *)&orig_wkwebviewconfiguration_init);
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            appctrl_app_did_become_active(note);
        }];
        appctrl_schedule_panel_install();
    }
}
