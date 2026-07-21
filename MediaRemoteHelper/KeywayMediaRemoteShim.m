#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <math.h>

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
@property (nonatomic, readonly, copy) id client;
@end

@interface MRCommandResult : NSObject
@property (nonatomic, readonly, copy) NSError *error;
@property (nonatomic, readonly, copy) MRPlayerPath *playerPath;
@end

@interface MRNowPlayingRequest : NSObject
- (instancetype)initWithPlayerPath:(id)playerPath;
- (void)requestNowPlayingInfoOnQueue:(dispatch_queue_t)queue completion:(void (^)(NSDictionary *info))completion;
- (void)sendCommand:(unsigned int)command options:(NSDictionary *)options appOptions:(unsigned int)appOptions queue:(dispatch_queue_t)queue completion:(void (^)(MRCommandResult *result))completion;
- (void)sendCommand:(unsigned int)command options:(NSDictionary *)options queue:(dispatch_queue_t)queue completion:(void (^)(MRCommandResult *result))completion;
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

static NSMutableDictionary *KeywayClientCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static void KeywayReplaceClientCache(NSDictionary *clientsByTargetID) {
    NSMutableDictionary *cache = KeywayClientCache();
    @synchronized (cache) {
        [cache removeAllObjects];
        [cache addEntriesFromDictionary:clientsByTargetID ?: @{}];
    }
}

static id KeywayCachedClientForTargetID(NSString *targetID) {
    NSMutableDictionary *cache = KeywayClientCache();
    @synchronized (cache) {
        return cache[targetID ?: @""];
    }
}

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

static NSNumber *KeywaySafeJSONNumber(id value, NSNumber *fallback) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return fallback;
    }

    NSNumber *number = (NSNumber *)value;
    double doubleValue = number.doubleValue;
    if (!isfinite(doubleValue)) {
        return fallback;
    }

    return number;
}

static NSString *KeywayStableHash(NSString *value) {
    const uint64_t offsetBasis = 1469598103934665603ULL;
    const uint64_t prime = 1099511628211ULL;
    uint64_t hash = offsetBasis;
    const char *bytes = value.UTF8String;
    if (bytes == NULL) {
        return @"0000000000000000";
    }

    for (const unsigned char *cursor = (const unsigned char *)bytes; *cursor != '\0'; cursor += 1) {
        hash ^= (uint64_t)(*cursor);
        hash *= prime;
    }
    return [NSString stringWithFormat:@"%016llx", hash];
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

static NSString *KeywayTargetIdentifierForRow(NSDictionary *row) {
    NSString *bundleID = KeywaySafeString(row[@"bundleIdentifier"]);
    NSString *parentBundleID = KeywaySafeString(row[@"parentBundleIdentifier"]);
    NSString *identityBundleID = bundleID.length > 0 ? bundleID : parentBundleID;
    NSString *normalizedBundleID = identityBundleID.length > 0 ? identityBundleID : @"unknown";
    NSString *fingerprint = [@[
        normalizedBundleID,
        parentBundleID,
        KeywaySafeString(row[@"displayName"])
    ] componentsJoinedByString:@"|"];
    return [NSString stringWithFormat:@"%@:%d:%@", normalizedBundleID, [row[@"pid"] intValue], KeywayStableHash(fingerprint)];
}

static void KeywayRefreshRowIdentifier(NSMutableDictionary *row) {
    row[@"id"] = KeywayTargetIdentifierForRow(row);
}

static NSMutableDictionary *KeywayRowForClient(id client, const KeywayMediaRemoteSymbols *symbols) {
    NSString *bundleID = KeywaySafeString(symbols->getBundleID(client));
    NSString *parentBundleID = KeywaySafeString(symbols->getParentBundleID(client));
    NSString *displayName = KeywaySafeString(symbols->getDisplayName(client));
    pid_t pid = symbols->getPID(client);

    NSMutableDictionary *row = [NSMutableDictionary dictionary];
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
    row[@"mediaType"] = @"";
    KeywayRefreshRowIdentifier(row);
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
        row[@"duration"] = KeywaySafeJSONNumber(duration, @0);
    }

    id elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    if ([elapsed isKindOfClass:[NSNumber class]]) {
        row[@"elapsedTime"] = KeywaySafeJSONNumber(elapsed, @0);
    }

    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSNumber class]]) {
        row[@"elapsedTimestamp"] = KeywaySafeJSONNumber(timestamp, @0);
    } else if ([timestamp isKindOfClass:[NSDate class]]) {
        row[@"elapsedTimestamp"] = KeywaySafeJSONNumber(@([(NSDate *)timestamp timeIntervalSince1970]), @0);
    }

}

static BOOL KeywayRowHasMediaState(NSDictionary *row) {
    return [row[@"title"] length] > 0
        || [row[@"artist"] length] > 0
        || [row[@"album"] length] > 0
        || [row[@"playbackRate"] length] > 0
        || [row[@"mediaType"] length] > 0
        || [row[@"artworkBase64"] length] > 0;
}

static BOOL KeywaySameClient(id lhs, id rhs) {
    if (lhs == nil || rhs == nil) {
        return NO;
    }
    if (lhs == rhs) {
        return YES;
    }
    if ([lhs respondsToSelector:@selector(isEqual:)]) {
        return [lhs isEqual:rhs];
    }
    return NO;
}

static NSString *KeywayReserveTargetRow(
    NSMutableArray *targets,
    NSMutableDictionary *clientsByTargetID,
    NSMutableDictionary *row,
    id client,
    BOOL exposeTarget
) {
    NSString *baseTargetID = KeywaySafeString(row[@"id"]);
    NSString *targetID = baseTargetID;
    NSUInteger suffix = 2;
    while (clientsByTargetID[targetID] != nil) {
        targetID = [NSString stringWithFormat:@"%@#%lu", baseTargetID, (unsigned long)suffix];
        suffix += 1;
    }
    row[@"id"] = targetID;
    clientsByTargetID[targetID] = client;
    if (exposeTarget) {
        [targets addObject:row];
    }
    return targetID;
}

static NSString *KeywayAddTargetRow(
    NSMutableArray *targets,
    NSMutableDictionary *clientsByTargetID,
    NSMutableDictionary *row,
    id client
) {
    return KeywayReserveTargetRow(targets, clientsByTargetID, row, client, YES);
}

static NSUInteger KeywayRefreshFastClientCache(
    NSString *matchingTargetID,
    const KeywayMediaRemoteSymbols *symbols,
    dispatch_queue_t queue,
    id *matchingClient
) {
    static const int64_t clientListTimeoutNanoseconds = 150 * NSEC_PER_MSEC;
    dispatch_group_t group = dispatch_group_create();
    __block NSArray *clients = @[];

    dispatch_group_enter(group);
    symbols->getClients(queue, ^(NSArray *receivedClients) {
        clients = receivedClients ?: @[];
        dispatch_group_leave(group);
    });

    long clientsWait = dispatch_group_wait(
        group,
        dispatch_time(DISPATCH_TIME_NOW, clientListTimeoutNanoseconds)
    );
    if (clientsWait != 0) {
        return 0;
    }

    NSMutableArray *targets = [NSMutableArray array];
    NSMutableDictionary *clientsByTargetID = [NSMutableDictionary dictionary];
    id resolvedClient = nil;
    for (id client in clients) {
        NSMutableDictionary *row = KeywayRowForClient(client, symbols);
        BOOL hasIdentity = [row[@"bundleIdentifier"] length] > 0
            || [row[@"parentBundleIdentifier"] length] > 0
            || [row[@"displayName"] length] > 0;
        if (!hasIdentity) {
            continue;
        }

        NSString *targetID = KeywayAddTargetRow(targets, clientsByTargetID, row, client);
        if (resolvedClient == nil && matchingTargetID.length > 0 && [targetID isEqualToString:matchingTargetID]) {
            resolvedClient = client;
        }
    }

    KeywayReplaceClientCache(clientsByTargetID);
    if (matchingClient != NULL) {
        *matchingClient = resolvedClient;
    }
    return clientsByTargetID.count;
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

static BOOL KeywaySubmitCommandToPlayerPath(
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
        return NO;
    }

    id playerPath = [[playerPathClass alloc] initWithOrigin:localOrigin client:client player:nil];
    id request = [[requestClass alloc] initWithPlayerPath:playerPath];
    if (request == nil) {
        completion(NO, @"failed to create MediaRemote player-path request");
        return NO;
    }

    void (^finish)(MRCommandResult *) = ^(MRCommandResult *result) {
        if (result == nil) {
            completion(NO, @"MediaRemote returned no command result");
        } else if (result.error != nil) {
            completion(NO, result.error.localizedDescription);
        } else if (!KeywaySameClient(result.playerPath.client, client)) {
            completion(NO, @"MediaRemote redirected command away from requested player");
        } else {
            completion(YES, @"MediaRemote player-path command completed");
        }
        (void)playerPath;
        (void)request;
        (void)queue;
    };

    if ([request respondsToSelector:@selector(sendCommand:options:appOptions:queue:completion:)]) {
        [request sendCommand:command options:@{} appOptions:0 queue:queue completion:finish];
    } else if ([request respondsToSelector:@selector(sendCommand:options:queue:completion:)]) {
        [request sendCommand:command options:@{} queue:queue completion:finish];
    } else {
        completion(NO, @"missing MediaRemote player-path sendCommand selector");
        return NO;
    }

    return YES;
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
        __block NSMutableDictionary *clientsByTargetID = [NSMutableDictionary dictionary];
        __block NSString *activeTargetID = @"";
        __block NSString *activeBaseTargetID = @"";
        __block id activeClientReference = nil;

        dispatch_group_enter(group);
        symbols.getActiveClient(queue, ^(id activeClient) {
            if (activeClient != nil) {
                activeClientReference = activeClient;
                NSMutableDictionary *activeRow = KeywayRowForClient(activeClient, &symbols);
                symbols.getActiveInfo(queue, ^(NSDictionary *info) {
                    KeywayApplyNowPlayingInfo(activeRow, info ?: @{});
                    activeBaseTargetID = KeywaySafeString(activeRow[@"id"]);
                    dispatch_group_leave(group);
                });
            } else {
                dispatch_group_leave(group);
            }
        });

        dispatch_group_enter(group);
        symbols.getClients(queue, ^(NSArray *clients) {
            dispatch_group_t clientGroup = dispatch_group_create();
            NSArray *receivedClients = clients ?: @[];
            NSMutableArray *targetEntries = [NSMutableArray arrayWithCapacity:receivedClients.count];
            for (NSUInteger index = 0; index < receivedClients.count; index += 1) {
                [targetEntries addObject:[NSNull null]];
            }
            void (^recordTargetEntry)(NSUInteger, NSMutableDictionary *, id) = ^(NSUInteger index, NSMutableDictionary *row, id client) {
                targetEntries[index] = @{
                    @"row": row,
                    @"client": client,
                    @"visible": @(KeywayRowHasMediaState(row))
                };
            };

            for (NSUInteger index = 0; index < receivedClients.count; index += 1) {
                id client = receivedClients[index];
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
                            recordTargetEntry(index, row, client);
                            dispatch_group_leave(clientGroup);
                        }];
                    } else {
                        recordTargetEntry(index, row, client);
                    }
                } else {
                    recordTargetEntry(index, row, client);
                }
            }

            dispatch_group_notify(clientGroup, queue, ^{
                for (id entry in targetEntries) {
                    if (![entry isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }
                    NSMutableDictionary *row = entry[@"row"];
                    id client = entry[@"client"];
                    BOOL visible = [entry[@"visible"] boolValue];
                    NSString *targetID = KeywayReserveTargetRow(targets, clientsByTargetID, row, client, visible);
                    if (visible && activeTargetID.length == 0 && KeywaySameClient(client, activeClientReference)) {
                        activeTargetID = targetID;
                    }
                }
                dispatch_group_leave(group);
            });
        });

        long waitResult = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        if (waitResult != 0) {
            KeywayPrintError(@"timed out waiting for MediaRemote snapshot");
            KeywayReleaseSymbols(&symbols);
            return;
        }

        if (activeTargetID.length == 0 && activeBaseTargetID.length > 0) {
            NSString *activeDuplicatePrefix = [activeBaseTargetID stringByAppendingString:@"#"];
            NSMutableArray *matchingActiveTargetIDs = [NSMutableArray array];
            for (NSDictionary *target in targets) {
                NSString *targetID = KeywaySafeString(target[@"id"]);
                if ([targetID isEqualToString:activeBaseTargetID] || [targetID hasPrefix:activeDuplicatePrefix]) {
                    [matchingActiveTargetIDs addObject:targetID];
                }
            }
            if (matchingActiveTargetIDs.count == 1) {
                activeTargetID = matchingActiveTargetIDs.firstObject;
            }
        }

        KeywayReplaceClientCache(clientsByTargetID);
        KeywayPrintJSON(@{
            @"type": @"snapshot",
            @"requestID": KeywayRequestID(),
            @"activeTargetID": activeTargetID,
            @"targets": targets
        });
        KeywayReleaseSymbols(&symbols);
    }
}

void keyway_mediaremote_refresh_client_cache(void) {
    @autoreleasepool {
        KeywayMediaRemoteSymbols symbols;
        if (!KeywayLoadSymbols(&symbols)) {
            return;
        }

        dispatch_queue_t queue = dispatch_queue_create("keyway.mediaremote.command-cache", DISPATCH_QUEUE_SERIAL);
        NSUInteger cachedCount = KeywayRefreshFastClientCache(nil, &symbols, queue, NULL);
        KeywayPrintJSON(@{
            @"type": @"clientCache",
            @"requestID": KeywayRequestID(),
            @"ok": cachedCount > 0 ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse,
            @"targetCount": @(cachedCount),
            @"message": cachedCount > 0 ? @"refreshed fast MediaRemote command cache" : @"no MediaRemote clients available for command cache"
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

        id localOrigin = symbols.getLocalOrigin();
        dispatch_queue_t queue = dispatch_queue_create("keyway.mediaremote.command", DISPATCH_QUEUE_SERIAL);
        id resolvedClient = nil;
        NSUInteger freshClientCount = KeywayRefreshFastClientCache(targetID, &symbols, queue, &resolvedClient);
        id client = resolvedClient;
        NSString *message = freshClientCount > 0
            ? @"target not found in fresh MediaRemote client cache"
            : @"fresh MediaRemote client cache unavailable";
        NSString *requestID = KeywayRequestID();
        void (^printCommandResult)(BOOL, NSString *) = ^(BOOL ok, NSString *resultMessage) {
            KeywayPrintJSON(@{
                @"type": @"commandResult",
                @"requestID": requestID,
                @"targetID": targetID,
                @"command": commandName,
                @"ok": ok ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse,
                @"message": KeywaySafeString(resultMessage)
            });
        };
        if (client != nil) {
            message = @"resolved MediaRemote player path from fresh command cache";
            KeywaySubmitCommandToPlayerPath(
                localOrigin,
                client,
                commandNumber.unsignedIntValue,
                queue,
                ^(BOOL commandSent, NSString *commandMessage) {
                    NSString *resultMessage = commandMessage.length > 0 ? commandMessage : message;
                    printCommandResult(commandSent, resultMessage);
                }
            );
        } else {
            printCommandResult(NO, message);
        }
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
