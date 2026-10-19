// qt-nowplaying — read (and, for our own app only, drive) the system's Now Playing state.
//
// Since macOS 15.4 MediaRemote answers only Apple-entitled processes, so this is a dylib that
// Scripts/now-playing.sh loads into /usr/bin/perl (which is) — the technique of `mediaremote-adapter`.
// Read-only except `send`, which refuses unless the system's active Now Playing player belongs to the bundle id
// given (so it can never pause or skip the user's own music in another app).
//
// Env:  QT_NP_MODE   clients | info | send
//       QT_NP_CMD    play | pause | toggle | next | previous          (send)
//       QT_NP_BUNDLE bundle id that must own the active player         (send)
// Prints one JSON object on stdout.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#import <objc/message.h>

typedef void (*QTGetClients)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*QTGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));

static id qt_value(id object, NSString *key) {
    if (!object || ![object respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [object valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSDictionary *qt_client(id client) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"description"] = [client description] ?: @"";
    for (NSString *key in @[ @"bundleIdentifier", @"parentApplicationBundleIdentifier", @"displayName", @"processIdentifier" ]) {
        id v = qt_value(client, key);
        if (v) d[key] = [v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]] ? v : [v description];
    }
    return d;
}

static void qt_print(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (data) fwrite(data.bytes, 1, data.length, stdout);
    fputs("\n", stdout);
    fflush(stdout);
}

static id qt_activePlayerPath(void) {
    Class request = NSClassFromString(@"MRNowPlayingRequest");
    SEL sel = NSSelectorFromString(@"localNowPlayingPlayerPath");
    if (![request respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(request, sel);
}

__attribute__((constructor)) static void qt_nowplaying(void) {
    @autoreleasepool {
        NSDictionary *env = NSProcessInfo.processInfo.environment;
        NSString *mode = env[@"QT_NP_MODE"] ?: @"clients";
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { qt_print(@{ @"error" : @"MediaRemote not found" }); return; }
        dispatch_queue_t queue = dispatch_queue_create("com.roderickqiu.qtube.nowplaying", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSMutableDictionary *out = [NSMutableDictionary dictionary];

        id path = qt_activePlayerPath();
        id client = qt_value(path, @"client");
        out[@"active"] = path ? [path description] : [NSNull null];
        out[@"activeClient"] = client ? qt_client(client) : [NSNull null];

        if ([mode isEqualToString:@"clients"]) {
            QTGetClients getClients = (QTGetClients)dlsym(h, "MRMediaRemoteGetNowPlayingClients");
            if (!getClients) { out[@"error"] = @"no MRMediaRemoteGetNowPlayingClients"; qt_print(out); return; }
            getClients(queue, ^(NSArray *clients) {
                NSMutableArray *list = [NSMutableArray array];
                for (id c in clients) [list addObject:qt_client(c)];
                out[@"clients"] = list;
                dispatch_semaphore_signal(done);
            });
        } else if ([mode isEqualToString:@"item"]) {
            Class request = NSClassFromString(@"MRNowPlayingRequest");
            id item = [request respondsToSelector:NSSelectorFromString(@"localNowPlayingItem")]
                ? ((id (*)(id, SEL))objc_msgSend)(request, NSSelectorFromString(@"localNowPlayingItem")) : nil;
            id metadata = qt_value(item, @"metadata");
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            for (NSString *key in @[ @"title", @"trackArtistName", @"albumName", @"duration", @"elapsedTime", @"playbackRate",
                                     @"elapsedTimeTimestamp", @"artworkAvailable", @"artworkIdentifier", @"contentIdentifier",
                                     @"mediaType", @"artworkMIMEType" ]) {
                id v = qt_value(metadata, key);
                if ([v isKindOfClass:[NSDate class]]) m[key] = @([(NSDate *)v timeIntervalSince1970]);
                else if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) m[key] = v;
                else if (v) m[key] = [v description];
            }
            out[@"item"] = m;
            out[@"now"] = @([NSDate date].timeIntervalSince1970);
            qt_print(out);
            return;
        } else if ([mode isEqualToString:@"info"]) {
            QTGetInfo getInfo = (QTGetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
            if (!getInfo) { out[@"error"] = @"no MRMediaRemoteGetNowPlayingInfo"; qt_print(out); return; }
            getInfo(queue, ^(NSDictionary *info) {
                NSMutableDictionary *i = [NSMutableDictionary dictionary];
                for (NSString *key in info) {
                    id v = info[key];
                    NSString *k = [key stringByReplacingOccurrencesOfString:@"kMRMediaRemoteNowPlayingInfo" withString:@""];
                    if ([v isKindOfClass:[NSData class]]) i[k] = @{ @"bytes" : @([(NSData *)v length]) };
                    else if ([v isKindOfClass:[NSDate class]]) i[k] = @([(NSDate *)v timeIntervalSince1970]);
                    else if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) i[k] = v;
                    else i[k] = [v description];
                }
                out[@"info"] = i;
                out[@"now"] = @([NSDate date].timeIntervalSince1970);
                dispatch_semaphore_signal(done);
            });
        } else if ([mode isEqualToString:@"send"]) {
            NSString *bundle = env[@"QT_NP_BUNDLE"] ?: @"";
            NSDictionary *commands = @{ @"play" : @0, @"pause" : @1, @"toggle" : @2, @"next" : @4, @"previous" : @5 };
            NSNumber *command = commands[env[@"QT_NP_CMD"] ?: @""];
            NSString *owner = qt_value(client, @"bundleIdentifier");
            if (!command || bundle.length == 0) { out[@"error"] = @"usage"; qt_print(out); return; }
            if (![owner isEqualToString:bundle]) {
                out[@"error"] = @"refused: the active Now Playing player is not the given bundle";
                qt_print(out);
                return;
            }
            Class requestClass = NSClassFromString(@"MRNowPlayingRequest");
            id request = ((id (*)(id, SEL, id))objc_msgSend)([requestClass alloc], NSSelectorFromString(@"initWithPlayerPath:"), path);
            SEL send = NSSelectorFromString(@"sendCommand:options:queue:completion:");
            if (![request respondsToSelector:send]) { out[@"error"] = @"no sendCommand"; qt_print(out); return; }
            ((void (*)(id, SEL, unsigned int, id, dispatch_queue_t, void (^)(id)))objc_msgSend)(
                request, send, command.unsignedIntValue, @{}, queue, ^(id result) {
                    out[@"result"] = result ? [result description] : [NSNull null];
                    dispatch_semaphore_signal(done);
                });
        } else {
            out[@"error"] = @"unknown mode";
            qt_print(out);
            return;
        }
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) != 0) out[@"timeout"] = @YES;
        qt_print(out);
    }
}
