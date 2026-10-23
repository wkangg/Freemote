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
    if(_globalEmoteRegistry.count == 0) {
        [self addEmoteInfo:[_httpClient bttvGlobalEmotes] toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:BTTVGlobal];
        [self addEmoteInfo:[_httpClient ffzGlobalEmotes] toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:FFZGlobal];
        NSDictionary *sevenTVGlobalInfo = [_httpClient sevenTVGlobalEmotes];
        if([sevenTVGlobalInfo isKindOfClass:[NSDictionary class]])
            [self addEmoteInfo:sevenTVGlobalInfo[@"emotes"] toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:SevenTVGlobal];
        self.globalNameRegistry = _globalEmoteNameRegistry;
    }

    // Emote IDs are unique across channels and providers, so one ID registry holds everything
    NSMutableDictionary *registry = [self.emoteRegistry mutableCopy];
    [registry addEntriesFromDictionary:_globalEmoteRegistry];
    // Channel emotes are added last so they win over globals with the same name
    NSMutableDictionary *nameRegistry = [_globalEmoteNameRegistry mutableCopy];

    NSDictionary *bttvEmoteInfo = [_httpClient bttvEmoteInformationForChannelID:channelID];
    NSDictionary *ffzEmoteInfo = [_httpClient ffzEmoteInformationForChannelID:channelID];
    NSDictionary *sevenTVEmoteInfo = [_httpClient sevenTVEmoteInformationForChannelID:channelID];

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
    self.lastLoadedChannelID = channelID;
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
