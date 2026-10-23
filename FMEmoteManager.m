#import "FMEmoteManager.h"
#import "FMLog.h"

@implementation FMEmoteManager

- (id)init {
    self = [super init];

    if(self) {
        _httpClient = [[FMHTTPClient alloc] init];
        _emoteRegistry = @{};
        _channelNameRegistries = @{};
        _globalNameRegistry = @{};
        _globalEmoteRegistry = [[NSMutableDictionary alloc] init];
        _globalEmoteNameRegistry = [[NSMutableDictionary alloc] init];
    }

    return self;
}

- (void)loadEmotesForChannel:(NSString *)channelID {
    // Fetch everything in parallel; chat history waits on this
    FMHTTPClient *httpClient = _httpClient;
    BOOL needsGlobals = _globalEmoteRegistry.count == 0;
    __block NSDictionary *bttvGlobalInfo, *ffzGlobalInfo, *sevenTVGlobalInfo, *bttvEmoteInfo, *ffzEmoteInfo, *sevenTVEmoteInfo, *ffzGlobalSets, *ffzRoom;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    if(needsGlobals) {
        dispatch_group_async(group, queue, ^{ bttvGlobalInfo = [httpClient bttvGlobalEmotes]; });
        dispatch_group_async(group, queue, ^{ ffzGlobalInfo = [httpClient ffzGlobalEmotes]; });
        dispatch_group_async(group, queue, ^{ sevenTVGlobalInfo = [httpClient sevenTVGlobalEmotes]; });
    }
    dispatch_group_async(group, queue, ^{ bttvEmoteInfo = [httpClient bttvEmoteInformationForChannelID:channelID]; });
    dispatch_group_async(group, queue, ^{ ffzEmoteInfo = [httpClient ffzEmoteInformationForChannelID:channelID]; });
    dispatch_group_async(group, queue, ^{ sevenTVEmoteInfo = [httpClient sevenTVEmoteInformationForChannelID:channelID]; });
    // FFZ's own API is often several seconds slower and only adds sizes, so it isn't allowed to hold up the emotes
    dispatch_group_t sizeGroup = dispatch_group_create();
    if(needsGlobals)
        dispatch_group_async(sizeGroup, queue, ^{ ffzGlobalSets = [httpClient ffzGlobalSets]; });
    dispatch_group_async(sizeGroup, queue, ^{ ffzRoom = [httpClient ffzRoomForChannelID:channelID]; });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if(needsGlobals) {
        NSUInteger bttv = [self addEmoteInfo:bttvGlobalInfo toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:BTTVGlobal];
        NSUInteger ffz = [self addEmoteInfo:ffzGlobalInfo toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:FFZGlobal];
        NSUInteger sevenTV = [sevenTVGlobalInfo isKindOfClass:[NSDictionary class]]
            ? [self addEmoteInfo:sevenTVGlobalInfo[@"emotes"] toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:SevenTVGlobal] : 0;
        self.globalNameRegistry = _globalEmoteNameRegistry;
        FMLog("Global emotes: BTTV %lu, FFZ %lu, 7TV %lu", (unsigned long)bttv, (unsigned long)ffz, (unsigned long)sevenTV);
    }

    // Emote IDs are unique across channels and providers, so one ID registry holds everything
    NSMutableDictionary *registry = [self.emoteRegistry mutableCopy];
    [registry addEntriesFromDictionary:_globalEmoteRegistry];
    // Channel emotes are added last so they win over globals with the same name
    NSMutableDictionary *nameRegistry = [_globalEmoteNameRegistry mutableCopy];

    NSUInteger bttv = 0, ffz, sevenTV = 0;
    if([bttvEmoteInfo isKindOfClass:[NSDictionary class]] && bttvEmoteInfo[@"channelEmotes"]) {
        bttv += [self addEmoteInfo:bttvEmoteInfo[@"channelEmotes"] toRegistry:registry nameRegistry:nameRegistry type:BTTV];
        bttv += [self addEmoteInfo:bttvEmoteInfo[@"sharedEmotes"] toRegistry:registry nameRegistry:nameRegistry type:BTTV];
    }

    ffz = [self addEmoteInfo:ffzEmoteInfo toRegistry:registry nameRegistry:nameRegistry type:FFZ];

    if([sevenTVEmoteInfo isKindOfClass:[NSDictionary class]] && [sevenTVEmoteInfo[@"emote_set"] isKindOfClass:[NSDictionary class]])
        sevenTV = [self addEmoteInfo:sevenTVEmoteInfo[@"emote_set"][@"emotes"] toRegistry:registry nameRegistry:nameRegistry type:SevenTV];
    // 0 for a provider usually means the channel has no account there (or the request failed, logged above)
    FMLog("Channel %{public}@ emotes: BTTV %lu, FFZ %lu, 7TV %lu", channelID, (unsigned long)bttv, (unsigned long)ffz, (unsigned long)sevenTV);

    NSMutableDictionary *channelNameRegistries = [self.channelNameRegistries mutableCopy];
    channelNameRegistries[channelID] = nameRegistry;

    // ID registry first: a message can only use a name once its image URL resolves
    self.emoteRegistry = registry;
    self.channelNameRegistries = channelNameRegistries;

    // Sizes land on the same emote objects, so messages after this show FFZ emotes at their own size
    dispatch_group_notify(sizeGroup, queue, ^{
        if(needsGlobals)
            [self addFFZSizes:ffzGlobalSets toRegistry:registry];
        [self addFFZSizes:ffzRoom toRegistry:registry];
    });
}

- (BOOL)hasEmotesForChannel:(NSString *)channelID {
    return self.channelNameRegistries[channelID] != nil;
}

- (NSDictionary<NSString *, BTTVEmote *> *)emoteNameRegistryForChannel:(NSString *)channelID {
    return (channelID ? self.channelNameRegistries[channelID] : nil) ?: self.globalNameRegistry;
}

// Returns how many emotes were added
- (NSUInteger)addEmoteInfo:(id)emoteInfo toRegistry:(NSMutableDictionary *)registry nameRegistry:(NSMutableDictionary *)nameRegistry type:(EmoteType)type {
    // Error responses (e.g. unknown channel) are dictionaries rather than arrays
    if(![emoteInfo isKindOfClass:[NSArray class]])
        return 0;

    NSUInteger count = 0;

    for(NSDictionary *emoteDict in emoteInfo) {
        if(![emoteDict isKindOfClass:[NSDictionary class]])
            continue;
        BTTVEmote *emote = [[BTTVEmote alloc] initWithDictData:emoteDict emoteType:type];
        if(!emote.emoteID || !emote.emoteText)
            continue;
        [registry setObject:emote forKey:emote.emoteID];
        [nameRegistry setObject:emote forKey:emote.emoteText];
        count++;
    }
    return count;
}

// FFZ API response: {sets: {<set ID>: {emoticons: [{id, width, height, ...}]}}}. Sets the aspect ratio of the FFZ
// emotes with the same ID in the registry.
- (void)addFFZSizes:(NSDictionary *)ffzInfo toRegistry:(NSDictionary<NSString *, BTTVEmote *> *)registry {
    NSDictionary *sets = [ffzInfo isKindOfClass:[NSDictionary class]] ? ffzInfo[@"sets"] : nil;
    if(![sets isKindOfClass:[NSDictionary class]])
        return;

    NSUInteger count = 0;
    for(NSDictionary *set in sets.allValues) {
        NSArray *emoticons = [set isKindOfClass:[NSDictionary class]] ? set[@"emoticons"] : nil;
        if(![emoticons isKindOfClass:[NSArray class]])
            continue;
        for(NSDictionary *emoticon in emoticons) {
            if(![emoticon isKindOfClass:[NSDictionary class]] || ![emoticon[@"id"] isKindOfClass:[NSNumber class]]
               || ![emoticon[@"width"] isKindOfClass:[NSNumber class]] || ![emoticon[@"height"] isKindOfClass:[NSNumber class]]
               || [emoticon[@"height"] doubleValue] <= 0)
                continue;
            // Same ID suffix as BTTVEmote gives FFZ emotes
            BTTVEmote *emote = registry[[[emoticon[@"id"] stringValue] stringByAppendingString:@"ffz"]];
            if(emote.emoteType != FFZ && emote.emoteType != FFZGlobal)
                continue;
            emote.aspectRatio = [emoticon[@"width"] doubleValue] / [emoticon[@"height"] doubleValue];
            count++;
        }
    }
    FMLog("FFZ sizes for %lu emotes", (unsigned long)count);
}

- (NSURL *)imageURLForBTTVEmoteID:(NSString *)emoteID {

    BTTVEmote *emote = self.emoteRegistry[emoteID];
    if(emote) {
        if(emote.image2x)
            return emote.image2x;
        else if(emote.image1x)
            return emote.image1x;
    }
    return nil;
}

@end
