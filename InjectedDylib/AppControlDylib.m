#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const AppCtrlStateFileName = @"appctrl_state.plist";
static NSString *const AppCtrlDomainsFileName = @"appctrl_blocked_domains.txt";

static UIWindow *gPanelWindow;
static UIButton *gFloatingButton;
static UIView *gPanelView;
static UISwitch *gNetworkSwitch;
static UITextView *gDomainsTextView;

static char kOrigWKDelegateDecisionKey;

static NSString *appctrl_documents_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *appctrl_state_path(void) {
    return [appctrl_documents_path() stringByAppendingPathComponent:AppCtrlStateFileName];
}

static NSString *appctrl_domains_path(void) {
    return [appctrl_documents_path() stringByAppendingPathComponent:AppCtrlDomainsFileName];
}

static NSDictionary *appctrl_load_state_file(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:appctrl_state_path()];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : @{};
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
    NSString *raw = appctrl_domains_file_content();
    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",\n\r"]];
    NSMutableSet<NSString *> *domains = [NSMutableSet set];

    for (NSString *part in parts) {
        NSString *trimmed = [[part lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [domains addObject:trimmed];
        }
    }

    return [domains copy];
}

static BOOL appctrl_host_is_blocked(NSString *host) {
    if (host.length == 0) {
        return NO;
    }

    NSString *lower = [host lowercaseString];
    for (NSString *blocked in appctrl_blocked_domains()) {
        if ([lower isEqualToString:blocked] || [lower hasSuffix:[@"." stringByAppendingString:blocked]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL appctrl_should_block_url(NSURL *url) {
    if (!url) {
        return NO;
    }

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (appctrl_disable_network() && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return YES;
    }

    return appctrl_host_is_blocked(url.host);
}

static NSError *appctrl_block_error(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
}

static NSURLSessionDataTask *(*orig_dataTaskWithRequest_completionHandler)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *repl_dataTaskWithRequest_completionHandler(id self, SEL _cmd, NSURLRequest *request, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    if (appctrl_should_block_url(request.URL)) {
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
        return NO;
    }
    return orig_openURL_legacy(self, _cmd, url);
}

static id (*orig_wk_loadRequest)(id, SEL, NSURLRequest *);
static id repl_wk_loadRequest(id self, SEL _cmd, NSURLRequest *request) {
    if (appctrl_should_block_url(request.URL)) {
        return nil;
    }
    return orig_wk_loadRequest(self, _cmd, request);
}

static id (*orig_wk_loadFileURL_allowingReadAccessToURL)(id, SEL, NSURL *, NSURL *);
static id repl_wk_loadFileURL_allowingReadAccessToURL(id self, SEL _cmd, NSURL *url, NSURL *readAccessURL) {
    if (appctrl_should_block_url(url)) {
        return nil;
    }
    return orig_wk_loadFileURL_allowingReadAccessToURL(self, _cmd, url, readAccessURL);
}

typedef void (*WKDecisionOrigIMP)(id, SEL, WKWebView *, WKNavigationAction *, void (^)(WKNavigationActionPolicy));

static void repl_wkNavigationDelegate_decidePolicy(id self, SEL _cmd, WKWebView *webView, WKNavigationAction *navigationAction, void (^decisionHandler)(WKNavigationActionPolicy)) {
    NSURL *url = navigationAction.request.URL;
    if (appctrl_should_block_url(url)) {
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

static void appctrl_swizzle_navigation_delegate_if_needed(id delegate) {
    if (!delegate) {
        return;
    }

    Class cls = object_getClass(delegate);
    SEL sel = @selector(webView:decidePolicyForNavigationAction:decisionHandler:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }

    if (objc_getAssociatedObject(cls, &kOrigWKDelegateDecisionKey) != nil) {
        return;
    }

    IMP orig = method_getImplementation(method);
    objc_setAssociatedObject(cls, &kOrigWKDelegateDecisionKey, [NSValue valueWithPointer:orig], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    method_setImplementation(method, (IMP)repl_wkNavigationDelegate_decidePolicy);
}

static void (*orig_wk_setNavigationDelegate)(id, SEL, id);
static void repl_wk_setNavigationDelegate(id self, SEL _cmd, id delegate) {
    appctrl_swizzle_navigation_delegate_if_needed(delegate);
    orig_wk_setNavigationDelegate(self, _cmd, delegate);
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

static void appctrl_reload_panel_from_disk(void) {
    if (!gNetworkSwitch || !gDomainsTextView) {
        return;
    }
    gNetworkSwitch.on = appctrl_disable_network();
    gDomainsTextView.text = appctrl_domains_file_content();
}

static void appctrl_save_panel_state(void) {
    NSDictionary *state = @{@"disableNetwork": @(gNetworkSwitch.on)};
    [state writeToFile:appctrl_state_path() atomically:YES];

    NSString *domains = gDomainsTextView.text ?: @"";
    [domains writeToFile:appctrl_domains_path() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void appctrl_toggle_panel(void) {
    if (!gPanelView) {
        return;
    }
    gPanelView.hidden = !gPanelView.hidden;
    if (!gPanelView.hidden) {
        appctrl_reload_panel_from_disk();
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

@end

static AppCtrlPanelTarget *gPanelTarget;

static void appctrl_install_panel(void) {
    if (gPanelWindow) {
        return;
    }

    if (!UIApplication.sharedApplication) {
        return;
    }

    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:[UIWindowScene class]] && candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
    }

    CGRect frame = UIScreen.mainScreen.bounds;
    gPanelWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:frame];
    gPanelWindow.frame = frame;
    gPanelWindow.backgroundColor = UIColor.clearColor;
    gPanelWindow.windowLevel = UIWindowLevelAlert + 5;
    gPanelWindow.hidden = NO;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    gPanelWindow.rootViewController = vc;

    gPanelTarget = [AppCtrlPanelTarget new];

    gFloatingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gFloatingButton.frame = CGRectMake(16, 120, 56, 56);
    gFloatingButton.layer.cornerRadius = 28;
    gFloatingButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:0.88];
    [gFloatingButton setTitle:@"AC" forState:UIControlStateNormal];
    [gFloatingButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [gFloatingButton addTarget:gPanelTarget action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:gFloatingButton];

    gPanelView = [[UIView alloc] initWithFrame:CGRectMake(16, 188, 320, 260)];
    gPanelView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    gPanelView.layer.cornerRadius = 14;
    gPanelView.layer.borderWidth = 1;
    gPanelView.layer.borderColor = [UIColor colorWithWhite:0.82 alpha:1.0].CGColor;
    gPanelView.hidden = YES;
    [vc.view addSubview:gPanelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, 220, 24)];
    title.text = @"App Control";
    title.font = [UIFont boldSystemFontOfSize:18];
    [gPanelView addSubview:title];

    UILabel *networkLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 48, 200, 24)];
    networkLabel.text = @"Disable HTTP/HTTPS";
    networkLabel.font = [UIFont systemFontOfSize:15];
    [gPanelView addSubview:networkLabel];

    gNetworkSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(244, 44, 0, 0)];
    [gPanelView addSubview:gNetworkSwitch];

    UILabel *domainsLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 84, 220, 20)];
    domainsLabel.text = @"Blocked domains";
    domainsLabel.font = [UIFont systemFontOfSize:15];
    [gPanelView addSubview:domainsLabel];

    gDomainsTextView = [[UITextView alloc] initWithFrame:CGRectMake(12, 110, 296, 100)];
    gDomainsTextView.font = [UIFont systemFontOfSize:14];
    gDomainsTextView.layer.borderWidth = 1;
    gDomainsTextView.layer.borderColor = [UIColor colorWithWhite:0.84 alpha:1.0].CGColor;
    gDomainsTextView.layer.cornerRadius = 8;
    [gPanelView addSubview:gDomainsTextView];

    UIButton *save = appctrl_button(@"Save", @selector(savePressed), gPanelTarget);
    save.frame = CGRectMake(12, 222, 90, 30);
    [gPanelView addSubview:save];

    UIButton *reload = appctrl_button(@"Reload", @selector(reloadPressed), gPanelTarget);
    reload.frame = CGRectMake(112, 222, 90, 30);
    [gPanelView addSubview:reload];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(210, 220, 96, 34)];
    hint.numberOfLines = 2;
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.text = @"one per line\nor comma";
    [gPanelView addSubview:hint];

    appctrl_reload_panel_from_disk();
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
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            appctrl_app_did_become_active(note);
        }];
        appctrl_schedule_panel_install();
    }
}
