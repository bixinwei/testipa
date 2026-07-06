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
static UILabel *gBlockCountLabel;

static char kOrigWKDelegateDecisionKey;
static char kOrigWKUIDelegateCreateWebViewKey;

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

    gPanelView = [[UIView alloc] initWithFrame:CGRectMake(16, 188, 320, 402)];
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
            appctrl_swizzle_instance_method(wkwebview, @selector(setUIDelegate:), (IMP)repl_wk_setUIDelegate, (IMP *)&orig_wk_setUIDelegate);
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            appctrl_app_did_become_active(note);
        }];
        appctrl_schedule_panel_install();
    }
}
