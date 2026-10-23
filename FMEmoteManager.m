#import "FMEmoteManager.h"

@implementation FMEmoteManager

- (id)init {
    self = [super init];

    if(self) {
        _httpClient = [[FMHTTPClient alloc] init];
        _emoteRegistry = @{};
        _emoteNameRegistry = @{};
        _globalEmoteRegistry = [[NSMutableDictionary alloc] init];
        _globalEmoteNameRegistry = [[NSMutableDictionary alloc] init];
    }

    return self;
}

- (void)updateEmoteRegistry:(NSString *)channelID {
    if(_globalEmoteRegistry.count == 0) {
        [self addEmoteInfo:[_httpClient bttvGlobalEmotes] toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:BTTVGlobal];
        [self addEmoteInfo:[_httpClient ffzGlobalEmotes] toRegistry:_globalEmoteRegistry nameRegistry:_globalEmoteNameRegistry type:FFZGlobal];
    }

    NSMutableDictionary *registry = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *nameRegistry = [[NSMutableDictionary alloc] init];

    NSDictionary *bttvEmoteInfo = [_httpClient bttvEmoteInformationForChannelID:channelID];
    NSDictionary *ffzEmoteInfo = [_httpClient ffzEmoteInformationForChannelID:channelID];

    if([bttvEmoteInfo isKindOfClass:[NSDictionary class]] && bttvEmoteInfo[@"channelEmotes"]) {
        [self addEmoteInfo:bttvEmoteInfo[@"channelEmotes"] toRegistry:registry nameRegistry:nameRegistry type:BTTV];
        [self addEmoteInfo:bttvEmoteInfo[@"sharedEmotes"] toRegistry:registry nameRegistry:nameRegistry type:BTTV];
    }

    [self addEmoteInfo:ffzEmoteInfo toRegistry:registry nameRegistry:nameRegistry type:FFZ];

    [registry addEntriesFromDictionary:_globalEmoteRegistry];
    [nameRegistry addEntriesFromDictionary:_globalEmoteNameRegistry];

    self.emoteRegistry = registry;
    self.emoteNameRegistry = nameRegistry;
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
