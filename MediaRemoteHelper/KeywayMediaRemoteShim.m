#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

typedef void (*MRMediaRemoteGetNowPlayingClientsFn)(dispatch_queue_t queue, void (^completion)(NSArray *clients));
typedef id (*MRMediaRemoteGetLocalOriginFn)(void);
typedef void (*MRMediaRemoteGetNowPlayingInfoFn)(dispatch_queue_t queue, void (^completion)(NSDictionary *info));
typedef void (*MRMediaRemoteGetNowPlayingClientFn)(dispatch_queue_t queue, void (^completion)(id client));
typedef void (*MRMediaRemoteGetNowPlayingInfoForClientFn)(id client, id origin, dispatch_queue_t queue, void (^completion)(NSDictionary *info));
typedef void (*MRMediaRemoteRegisterForNowPlayingNotificationsFn)(dispatch_queue_t queue);
typedef NSString *(*MRNowPlayingClientGetBundleIdentifierFn)(id client);
typedef NSString *(*MRNowPlayingClientGetParentAppBundleIdentifierFn)(id client);
typedef NSString *(*MRNowPlayingClientGetDisplayNameFn)(id client);
typedef pid_t (*MRNowPlayingClientGetProcessIdentifierFn)(id client);

@interface MRPlayerPath : NSObject
- (instancetype)initWithOrigin:(id)origin client:(id)client player:(id)player;
@end

@interface MRNowPlayingRequest : NSObject
- (instancetype)initWithPlayerPath:(id)playerPath;
- (void)requestNowPlayingInfoOnQueue:(dispatch_queue_t)queue completion:(void (^)(NSDictionary *info))completion;
- (void)sendCommand:(unsigned int)command options:(NSDictionary *)options appOptions:(NSDictionary *)appOptions queue:(dispatch_queue_t)queue completion:(void (^)(NSError *error))completion;
- (void)sendCommand:(unsigned int)command options:(NSDictionary *)options queue:(dispatch_queue_t)queue completion:(void (^)(NSError *error))completion;
@end

typedef struct {
    CFBundleRef bundle;
    MRMediaRemoteGetNowPlayingClientsFn getClients;
    MRMediaRemoteGetLocalOriginFn getLocalOrigin;
    MRMediaRemoteGetNowPlayingInfoFn getActiveInfo;
    MRMediaRemoteGetNowPlayingClientFn getActiveClient;
    MRNowPlayingClientGetBundleIdentifierFn getBundleID;
    MRNowPlayingClientGetParentAppBundleIdentifierFn getParentBundleID;
    MRNowPlayingClientGetDisplayNameFn getDisplayName;
    MRNowPlayingClientGetProcessIdentifierFn getPID;
} KeywayMediaRemoteSymbols;

static NSString *KeywayRequestID(void) {
    NSString *requestID = [NSProcessInfo processInfo].environment[@"KEYWAY_MEDIAREMOTE_REQUEST_ID"];
    return requestID ?: @"";
}

static NSString *KeywaySafeString(id value) {
    if (value == nil || value == [NSNull null]) {
        return @"";
    }
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return [value description];
}

static void KeywayPrintJSON(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (data == nil) {
        NSDictionary *fallback = @{
            @"type": @"error",
            @"requestID": KeywayRequestID(),
            @"message": error.localizedDescription ?: @"json encode failed"
        };
        data = [NSJSONSerialization dataWithJSONObject:fallback options:0 error:nil];
    }
    if (data != nil) {
        flockfile(stdout);
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
        funlockfile(stdout);
    }
}

static void KeywayPrintError(NSString *message) {
    KeywayPrintJSON(@{
        @"type": @"error",
        @"requestID": KeywayRequestID(),
        @"message": message ?: @"MediaRemote helper error"
    });
}

static void *KeywayLoadFunction(CFBundleRef bundle, CFStringRef name) {
    return CFBundleGetFunctionPointerForName(bundle, name);
}

static BOOL KeywayLoadSymbols(KeywayMediaRemoteSymbols *symbols) {
    memset(symbols, 0, sizeof(KeywayMediaRemoteSymbols));
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
    symbols->bundle = CFBundleCreate(kCFAllocatorDefault, url);
    if (symbols->bundle == NULL) {
        KeywayPrintError(@"failed to create MediaRemote bundle");
        return NO;
    }

    symbols->getClients = (MRMediaRemoteGetNowPlayingClientsFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRMediaRemoteGetNowPlayingClients"));
    symbols->getLocalOrigin = (MRMediaRemoteGetLocalOriginFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRMediaRemoteGetLocalOrigin"));
    symbols->getActiveInfo = (MRMediaRemoteGetNowPlayingInfoFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRMediaRemoteGetNowPlayingInfo"));
    symbols->getActiveClient = (MRMediaRemoteGetNowPlayingClientFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRMediaRemoteGetNowPlayingClient"));
    symbols->getBundleID = (MRNowPlayingClientGetBundleIdentifierFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRNowPlayingClientGetBundleIdentifier"));
    symbols->getParentBundleID = (MRNowPlayingClientGetParentAppBundleIdentifierFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRNowPlayingClientGetParentAppBundleIdentifier"));
    symbols->getDisplayName = (MRNowPlayingClientGetDisplayNameFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRNowPlayingClientGetDisplayName"));
    symbols->getPID = (MRNowPlayingClientGetProcessIdentifierFn)KeywayLoadFunction(symbols->bundle, CFSTR("MRNowPlayingClientGetProcessIdentifier"));

    if (!symbols->getClients || !symbols->getLocalOrigin || !symbols->getActiveInfo || !symbols->getActiveClient || !symbols->getBundleID || !symbols->getParentBundleID || !symbols->getDisplayName || !symbols->getPID) {
        KeywayPrintError(@"missing MediaRemote symbol");
        CFRelease(symbols->bundle);
        memset(symbols, 0, sizeof(KeywayMediaRemoteSymbols));
        return NO;
    }

    return YES;
}

static void KeywayReleaseSymbols(KeywayMediaRemoteSymbols *symbols) {
    if (symbols->bundle != NULL) {
        CFRelease(symbols->bundle);
    }
    memset(symbols, 0, sizeof(KeywayMediaRemoteSymbols));
}

static NSString *KeywayTargetIdentifier(NSString *bundleID, pid_t pid) {
    NSString *normalizedBundleID = bundleID.length > 0 ? bundleID : @"unknown";
    return [NSString stringWithFormat:@"%@:%d", normalizedBundleID, pid];
}

static NSMutableDictionary *KeywayRowForClient(id client, const KeywayMediaRemoteSymbols *symbols) {
    NSString *bundleID = KeywaySafeString(symbols->getBundleID(client));
    NSString *parentBundleID = KeywaySafeString(symbols->getParentBundleID(client));
    NSString *displayName = KeywaySafeString(symbols->getDisplayName(client));
    pid_t pid = symbols->getPID(client);
    NSString *identityBundleID = bundleID.length > 0 ? bundleID : parentBundleID;

    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"id"] = KeywayTargetIdentifier(identityBundleID, pid);
    row[@"bundleIdentifier"] = bundleID;
    row[@"parentBundleIdentifier"] = parentBundleID;
    row[@"displayName"] = displayName;
    row[@"pid"] = @(pid);
    row[@"title"] = @"";
    row[@"artist"] = @"";
    row[@"album"] = @"";
    row[@"playbackRate"] = @"";
    row[@"artworkBase64"] = @"";
    row[@"duration"] = @(0);
    row[@"elapsedTime"] = @(0);
    row[@"elapsedTimestamp"] = @(0);
    return row;
}

static void KeywayApplyNowPlayingInfo(NSMutableDictionary *row, NSDictionary *info) {
    row[@"title"] = KeywaySafeString(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    row[@"artist"] = KeywaySafeString(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    row[@"album"] = KeywaySafeString(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    row[@"playbackRate"] = KeywaySafeString(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
    row[@"mediaType"] = KeywaySafeString(info[@"kMRMediaRemoteNowPlayingInfoMediaType"]);

    id artworkData = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artworkData isKindOfClass:[NSData class]] && [(NSData *)artworkData length] > 0) {
        row[@"artworkBase64"] = [(NSData *)artworkData base64EncodedStringWithOptions:0];
    }

    id duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    if ([duration isKindOfClass:[NSNumber class]]) {
        row[@"duration"] = duration;
    }

    id elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    if ([elapsed isKindOfClass:[NSNumber class]]) {
        row[@"elapsedTime"] = elapsed;
    }

    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSNumber class]]) {
        row[@"elapsedTimestamp"] = timestamp;
    } else if ([timestamp isKindOfClass:[NSDate class]]) {
        row[@"elapsedTimestamp"] = @([(NSDate *)timestamp timeIntervalSince1970]);
    }
}

static BOOL KeywayRowHasMediaState(NSDictionary *row) {
    return [row[@"title"] length] > 0
        || [row[@"artist"] length] > 0
        || [row[@"album"] length] > 0
        || [row[@"playbackRate"] length] > 0
        || [row[@"mediaType"] length] > 0;
}

static BOOL KeywayClientMatchesTarget(id client, NSString *targetID, const KeywayMediaRemoteSymbols *symbols) {
    pid_t pid = symbols->getPID(client);
    NSString *bundleID = KeywaySafeString(symbols->getBundleID(client));
    NSString *parentBundleID = KeywaySafeString(symbols->getParentBundleID(client));
    NSString *identityBundleID = bundleID.length > 0 ? bundleID : parentBundleID;
    NSString *clientID = KeywayTargetIdentifier(identityBundleID, pid);

    return [clientID isEqualToString:targetID];
}

static NSNumber *KeywayCommandNumber(NSString *commandName) {
    if ([commandName isEqualToString:@"play"]) {
        return @(0);
    }
    if ([commandName isEqualToString:@"pause"]) {
        return @(1);
    }
    if ([commandName isEqualToString:@"playPause"]) {
        return @(2);
    }
    if ([commandName isEqualToString:@"next"]) {
        return @(4);
    }
    if ([commandName isEqualToString:@"previous"]) {
        return @(5);
    }
    return nil;
}

static NSString *KeywayBundleIdentifierFromTargetID(NSString *targetID) {
    NSRange separator = [targetID rangeOfString:@":" options:NSBackwardsSearch];
    if (separator.location == NSNotFound) {
        return targetID;
    }
    return [targetID substringToIndex:separator.location];
}

static NSString *KeywayFrontmostBundleIdentifier(void) {
    return KeywaySafeString([NSWorkspace sharedWorkspace].frontmostApplication.bundleIdentifier);
}

static void KeywaySendCommandToPlayerPath(
    id localOrigin,
    id client,
    unsigned int command,
    dispatch_queue_t queue,
    void (^completion)(BOOL sent, NSString *message)
) {
    Class playerPathClass = NSClassFromString(@"MRPlayerPath");
    Class requestClass = NSClassFromString(@"MRNowPlayingRequest");
    if (playerPathClass == Nil || requestClass == Nil || localOrigin == nil) {
        completion(NO, @"missing MediaRemote player-path command API");
        return;
    }

    id playerPath = [[playerPathClass alloc] initWithOrigin:localOrigin client:client player:nil];
    id request = [[requestClass alloc] initWithPlayerPath:playerPath];
    if (request == nil) {
        completion(NO, @"failed to create MediaRemote player-path request");
        return;
    }

    void (^finish)(NSError *) = ^(NSError *error) {
        if (error != nil) {
            completion(NO, error.localizedDescription ?: @"MediaRemote command failed");
            return;
        }
        completion(YES, @"");
    };

    if ([request respondsToSelector:@selector(sendCommand:options:appOptions:queue:completion:)]) {
        [request sendCommand:command options:@{} appOptions:@{} queue:queue completion:finish];
        return;
    }
    if ([request respondsToSelector:@selector(sendCommand:options:queue:completion:)]) {
        [request sendCommand:command options:@{} queue:queue completion:finish];
        return;
    }

    completion(NO, @"missing MediaRemote player-path sendCommand selector");
}

void keyway_mediaremote_snapshot(void) {
    @autoreleasepool {
        KeywayMediaRemoteSymbols symbols;
        if (!KeywayLoadSymbols(&symbols)) {
            return;
        }

        dispatch_queue_t queue = dispatch_queue_create("keyway.mediaremote.snapshot", DISPATCH_QUEUE_SERIAL);
        dispatch_group_t group = dispatch_group_create();
        id localOrigin = symbols.getLocalOrigin();
        Class playerPathClass = NSClassFromString(@"MRPlayerPath");
        Class requestClass = NSClassFromString(@"MRNowPlayingRequest");

        __block NSMutableArray *targets = [NSMutableArray array];
        __block NSString *activeTargetID = @"";

        dispatch_group_enter(group);
        symbols.getActiveClient(queue, ^(id activeClient) {
            if (activeClient != nil) {
                NSMutableDictionary *activeRow = KeywayRowForClient(activeClient, &symbols);
                activeTargetID = KeywaySafeString(activeRow[@"id"]);
                symbols.getActiveInfo(queue, ^(NSDictionary *info) {
                    dispatch_group_leave(group);
                });
            } else {
                dispatch_group_leave(group);
            }
        });

        dispatch_group_enter(group);
        symbols.getClients(queue, ^(NSArray *clients) {
            dispatch_group_t clientGroup = dispatch_group_create();
            for (id client in clients ?: @[]) {
                NSMutableDictionary *row = KeywayRowForClient(client, &symbols);
                BOOL hasIdentity = [row[@"bundleIdentifier"] length] > 0 || [row[@"parentBundleIdentifier"] length] > 0 || [row[@"displayName"] length] > 0;
                if (!hasIdentity) {
                    continue;
                }

                if (playerPathClass != Nil && requestClass != Nil && localOrigin != nil) {
                    id playerPath = [[playerPathClass alloc] initWithOrigin:localOrigin client:client player:nil];
                    id request = [[requestClass alloc] initWithPlayerPath:playerPath];
                    if ([request respondsToSelector:@selector(requestNowPlayingInfoOnQueue:completion:)]) {
                        dispatch_group_enter(clientGroup);
                        [request requestNowPlayingInfoOnQueue:queue completion:^(NSDictionary *info) {
                            KeywayApplyNowPlayingInfo(row, info ?: @{});
                            if (KeywayRowHasMediaState(row)) {
                                [targets addObject:row];
                            }
                            dispatch_group_leave(clientGroup);
                        }];
                    } else {
                        if (KeywayRowHasMediaState(row)) {
                            [targets addObject:row];
                        }
                    }
                } else {
                    if (KeywayRowHasMediaState(row)) {
                        [targets addObject:row];
                    }
                }
            }

            dispatch_group_notify(clientGroup, queue, ^{
                dispatch_group_leave(group);
            });
        });

        long waitResult = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        if (waitResult != 0) {
            KeywayPrintError(@"timed out waiting for MediaRemote snapshot");
            KeywayReleaseSymbols(&symbols);
            return;
        }

        KeywayPrintJSON(@{
            @"type": @"snapshot",
            @"requestID": KeywayRequestID(),
            @"activeTargetID": activeTargetID,
            @"targets": targets
        });
        KeywayReleaseSymbols(&symbols);
    }
}

void keyway_mediaremote_send_command(void) {
    @autoreleasepool {
        NSString *targetID = [NSProcessInfo processInfo].environment[@"KEYWAY_MEDIAREMOTE_TARGET_ID"] ?: @"";
        NSString *commandName = [NSProcessInfo processInfo].environment[@"KEYWAY_MEDIAREMOTE_COMMAND"] ?: @"";
        NSNumber *commandNumber = KeywayCommandNumber(commandName);
        if (targetID.length == 0 || commandNumber == nil) {
            KeywayPrintJSON(@{
                @"type": @"commandResult",
                @"requestID": KeywayRequestID(),
                @"targetID": targetID,
                @"command": commandName,
                @"ok": (__bridge id)kCFBooleanFalse,
                @"message": @"targetID and supported command are required"
            });
            return;
        }

        KeywayMediaRemoteSymbols symbols;
        if (!KeywayLoadSymbols(&symbols)) {
            return;
        }

        dispatch_queue_t queue = dispatch_queue_create("keyway.mediaremote.command", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        id localOrigin = symbols.getLocalOrigin();
        __block BOOL sent = NO;
        __block NSString *matchedTargetID = targetID;
        __block NSString *message = @"target not found";

        symbols.getClients(queue, ^(NSArray *clients) {
            for (id client in clients ?: @[]) {
                if (!KeywayClientMatchesTarget(client, targetID, &symbols)) {
                    continue;
                }

                NSMutableDictionary *row = KeywayRowForClient(client, &symbols);
                matchedTargetID = KeywaySafeString(row[@"id"]);
                KeywaySendCommandToPlayerPath(
                    localOrigin,
                    client,
                    commandNumber.unsignedIntValue,
                    queue,
                    ^(BOOL commandSent, NSString *commandMessage) {
                        sent = commandSent;
                        message = KeywaySafeString(commandMessage);
                        dispatch_semaphore_signal(done);
                    }
                );
                return;
            }

            dispatch_semaphore_signal(done);
        });

        long waitResult = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        BOOL timedOut = waitResult != 0;
        KeywayPrintJSON(@{
            @"type": @"commandResult",
            @"requestID": KeywayRequestID(),
            @"targetID": matchedTargetID,
            @"command": commandName,
            @"ok": (sent && !timedOut) ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse,
            @"message": sent ? @"" : (timedOut ? @"timed out" : message)
        });
        KeywayReleaseSymbols(&symbols);
    }
}

static void KeywayNotificationThreadMain(void) {
    @autoreleasepool {
        CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, url);
        if (bundle == NULL) {
            return;
        }

        dispatch_queue_t notifQueue = dispatch_queue_create("keyway.mediaremote.notifications", DISPATCH_QUEUE_SERIAL);

        MRMediaRemoteRegisterForNowPlayingNotificationsFn registerFn =
            (MRMediaRemoteRegisterForNowPlayingNotificationsFn)CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteRegisterForNowPlayingNotifications"));
        if (!registerFn) {
            CFRelease(bundle);

            return;
        }

        registerFn(notifQueue);

        NSArray *notificationNames = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
        ];

        NSOperationQueue *opQueue = [[NSOperationQueue alloc] init];
        opQueue.maxConcurrentOperationCount = 1;

        for (NSString *name in notificationNames) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:opQueue usingBlock:^(NSNotification *note) {
                KeywayPrintJSON(@{
                    @"type": @"now_playing_changed",
                    @"reason": note.name ?: @"unknown"
                });
            }];
        }

        [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        [[NSRunLoop currentRunLoop] run];
    }
}

void keyway_mediaremote_register_notifications(void) {
    [NSThread detachNewThreadWithBlock:^{
        KeywayNotificationThreadMain();
    }];
}
