#import "FMEmoteManager.h"

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
    __block NSDictionary *bttvGlobalInfo, *ffzGlobalInfo, *sevenTVGlobalInfo, *bttvEmoteInfo, *ffzEmoteInfo, *sevenTVEmoteInfo;
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
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if(needsGlobals) {
        [self addEmoteInfo:bttvGlobalInfo toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:BTTVGlobal];
        [self addEmoteInfo:ffzGlobalInfo toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:FFZGlobal];
        if([sevenTVGlobalInfo isKindOfClass:[NSDictionary class]])
            [self addEmoteInfo:sevenTVGlobalInfo[@"emotes"] toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:SevenTVGlobal];
        self.globalNameRegistry = _globalEmoteNameRegistry;
    }

    // Emote IDs are unique across channels and providers, so one ID registry holds everything
    NSMutableDictionary *registry = [self.emoteRegistry mutableCopy];
    [registry addEntriesFromDictionary:_globalEmoteRegistry];
    // Channel emotes are added last so they win over globals with the same name
    NSMutableDictionary *nameRegistry = [_globalEmoteNameRegistry mutableCopy];

    if([bttvEmoteInfo isKindOfClass:[NSDictionary class]] && bttvEmoteInfo[@"channelEmotes"]) {
        [self addEmoteInfo:bttvEmoteInfo[@"channelEmotes"] toRegistry:registry nameRegistry:nameRegistry type:BTTV];
        [self addEmoteInfo:bttvEmoteInfo[@"sharedEmotes"] toRegistry:registry nameRegistry:nameRegistry type:BTTV];
    }

    [self addEmoteInfo:ffzEmoteInfo toRegistry:registry nameRegistry:nameRegistry type:FFZ];

    if([sevenTVEmoteInfo isKindOfClass:[NSDictionary class]] && [sevenTVEmoteInfo[@"emote_set"] isKindOfClass:[NSDictionary class]])
        [self addEmoteInfo:sevenTVEmoteInfo[@"emote_set"][@"emotes"] toRegistry:registry nameRegistry:nameRegistry type:SevenTV];

    NSMutableDictionary *channelNameRegistries = [self.channelNameRegistries mutableCopy];
    channelNameRegistries[channelID] = nameRegistry;

    // ID registry first: a message can only use a name once its image URL resolves
    self.emoteRegistry = registry;
    self.channelNameRegistries = channelNameRegistries;
}

- (BOOL)hasEmotesForChannel:(NSString *)channelID {
    return self.channelNameRegistries[channelID] != nil;
}

- (NSDictionary<NSString *, BTTVEmote *> *)emoteNameRegistryForChannel:(NSString *)channelID {
    return (channelID ? self.channelNameRegistries[channelID] : nil) ?: self.globalNameRegistry;
}

- (void)addEmoteInfo:(id)emoteInfo toRegistry:(NSMutableDictionary *)registry nameRegistry:(NSMutableDictionary *)nameRegistry type:(EmoteType)type {
    // Error responses (e.g. unknown channel) are dictionaries rather than arrays
    if(![emoteInfo isKindOfClass:[NSArray class]])
        return;

    for(NSDictionary *emoteDict in emoteInfo) {
        if(![emoteDict isKindOfClass:[NSDictionary class]])
            continue;
        BTTVEmote *emote = [[BTTVEmote alloc] initWithDictData:emoteDict emoteType:type];
        if(!emote.emoteID || !emote.emoteText)
            continue;
        [registry setObject:emote forKey:emote.emoteID];
        [nameRegistry setObject:emote forKey:emote.emoteText];
    }
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
