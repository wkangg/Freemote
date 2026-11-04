#import "FMEmoteManager.h"
#import "FMLog.h"

@interface FMEmoteManager ()
// Channels whose requests have all finished. Their emotes are published as each request finishes, before this.
@property (atomic, copy) NSSet<NSString *> *loadedChannelIDs;
@end

@implementation FMEmoteManager

- (id)init {
    self = [super init];

    if(self) {
        _httpClient = [[FMHTTPClient alloc] init];
        _emoteRegistry = @{};
        _channelNameRegistries = @{};
        _globalNameRegistry = @{};
        _loadedChannelIDs = [NSSet set];
    }

    return self;
}

- (void)loadEmotesForChannel:(NSString *)channelID {
    // Fetch everything in parallel and publish each provider's emotes as soon as its request finishes, so a slow
    // provider doesn't hold up the others. Returns once they're all in, which VOD chat waits on.
    FMHTTPClient *httpClient = _httpClient;
    NSDictionary *knownGlobals = self.globalNameRegistry;
    BOOL needsGlobals = knownGlobals.count == 0;
    // Each provider's emotes once its request is done, in name precedence order: later lists win a name, so channel
    // emotes win over globals with the same name
    NSMutableArray<NSArray<BTTVEmote *> *> *globalLists = [@[@[], @[], @[]] mutableCopy];
    NSMutableArray<NSArray<BTTVEmote *> *> *channelLists = [@[@[], @[], @[]] mutableCopy];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    void (^fetch)(NSMutableArray *, NSUInteger, NSArray *(^)(void)) = ^(NSMutableArray *lists, NSUInteger index, NSArray *(^fetchEmotes)(void)) {
        dispatch_group_async(group, queue, ^{
            NSArray<BTTVEmote *> *emotes = fetchEmotes();
            @synchronized(self) {
                lists[index] = emotes;
                [self publishEmotes:emotes channelID:channelID globals:needsGlobals ? nil : knownGlobals globalLists:globalLists channelLists:channelLists];
            }
            void (^channelEmotesChanged)(NSString *) = self.channelEmotesChanged;
            if(emotes.count && channelEmotesChanged)
                channelEmotesChanged(channelID);
        });
    };
    if(needsGlobals) {
        fetch(globalLists, 0, ^NSArray *{ return [self emotesFromInfo:[httpClient bttvGlobalEmotes] type:BTTVGlobal]; });
        fetch(globalLists, 1, ^NSArray *{ return [self emotesFromInfo:[httpClient ffzGlobalEmotes] type:FFZGlobal]; });
        fetch(globalLists, 2, ^NSArray *{
            NSDictionary *info = [httpClient sevenTVGlobalEmotes];
            return [self emotesFromInfo:[info isKindOfClass:[NSDictionary class]] ? info[@"emotes"] : nil type:SevenTVGlobal];
        });
    }
    fetch(channelLists, 0, ^NSArray *{
        NSDictionary *info = [httpClient bttvEmoteInformationForChannelID:channelID];
        if(![info isKindOfClass:[NSDictionary class]])
            return @[];
        return [[self emotesFromInfo:info[@"channelEmotes"] type:BTTV] arrayByAddingObjectsFromArray:[self emotesFromInfo:info[@"sharedEmotes"] type:BTTV]];
    });
    fetch(channelLists, 1, ^NSArray *{ return [self emotesFromInfo:[httpClient ffzEmoteInformationForChannelID:channelID] type:FFZ]; });
    fetch(channelLists, 2, ^NSArray *{
        NSDictionary *info = [httpClient sevenTVEmoteInformationForChannelID:channelID];
        id emoteSet = [info isKindOfClass:[NSDictionary class]] ? info[@"emote_set"] : nil;
        return [self emotesFromInfo:[emoteSet isKindOfClass:[NSDictionary class]] ? emoteSet[@"emotes"] : nil type:SevenTV];
    });
    // FFZ's own API is often several seconds slower and only adds sizes, so it isn't allowed to hold up the emotes
    __block NSDictionary *ffzGlobalSets, *ffzRoom;
    dispatch_group_t sizeGroup = dispatch_group_create();
    if(needsGlobals)
        dispatch_group_async(sizeGroup, queue, ^{ ffzGlobalSets = [httpClient ffzGlobalSets]; });
    dispatch_group_async(sizeGroup, queue, ^{ ffzRoom = [httpClient ffzRoomForChannelID:channelID]; });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if(needsGlobals)
        FMLog("Global emotes: BTTV %lu, FFZ %lu, 7TV %lu", (unsigned long)globalLists[0].count, (unsigned long)globalLists[1].count, (unsigned long)globalLists[2].count);
    // 0 for a provider usually means the channel has no account there (or the request failed, logged above)
    FMLog("Channel %{public}@ emotes: BTTV %lu, FFZ %lu, 7TV %lu", channelID, (unsigned long)channelLists[0].count, (unsigned long)channelLists[1].count, (unsigned long)channelLists[2].count);
    self.loadedChannelIDs = [self.loadedChannelIDs setByAddingObject:channelID];

    // Sizes land on the same emote objects, so messages after this show FFZ emotes at their own size
    dispatch_group_notify(sizeGroup, queue, ^{
        NSDictionary *registry = self.emoteRegistry;
        if(needsGlobals)
            [self addFFZSizes:ffzGlobalSets toRegistry:registry];
        [self addFFZSizes:ffzRoom toRegistry:registry];
    });
}

// Adds the emotes from a request that just finished, and rebuilds the channel's name registry from every list so
// far (and the global one too, if `globals` is nil). Only under @synchronized(self).
- (void)publishEmotes:(NSArray<BTTVEmote *> *)emotes channelID:(NSString *)channelID globals:(NSDictionary *)globals
          globalLists:(NSArray<NSArray<BTTVEmote *> *> *)globalLists channelLists:(NSArray<NSArray<BTTVEmote *> *> *)channelLists {
    NSMutableDictionary *nameRegistry = [NSMutableDictionary dictionary];
    if(!globals) {
        for(NSArray<BTTVEmote *> *list in globalLists)
            for(BTTVEmote *emote in list)
                nameRegistry[emote.emoteText] = emote;
        globals = [nameRegistry copy];
    } else {
        [nameRegistry addEntriesFromDictionary:globals];
    }
    for(NSArray<BTTVEmote *> *list in channelLists)
        for(BTTVEmote *emote in list)
            nameRegistry[emote.emoteText] = emote;

    // Emote IDs are unique across channels and providers, so one ID registry holds everything
    NSMutableDictionary *registry = [self.emoteRegistry mutableCopy];
    for(BTTVEmote *emote in emotes)
        registry[emote.emoteID] = emote;
    NSMutableDictionary *channelNameRegistries = [self.channelNameRegistries mutableCopy];
    channelNameRegistries[channelID] = nameRegistry;

    // ID registry first: a message can only use a name once its image URL resolves
    self.emoteRegistry = registry;
    self.globalNameRegistry = globals;
    self.channelNameRegistries = channelNameRegistries;
}

- (BOOL)hasEmotesForChannel:(NSString *)channelID {
    return [self.loadedChannelIDs containsObject:channelID];
}

- (NSDictionary<NSString *, BTTVEmote *> *)emoteNameRegistryForChannel:(NSString *)channelID {
    return (channelID ? self.channelNameRegistries[channelID] : nil) ?: self.globalNameRegistry;
}

- (NSArray<BTTVEmote *> *)emotesFromInfo:(id)emoteInfo type:(EmoteType)type {
    // Error responses (e.g. unknown channel) are dictionaries rather than arrays
    if(![emoteInfo isKindOfClass:[NSArray class]])
        return @[];

    NSMutableArray<BTTVEmote *> *emotes = [NSMutableArray array];
    for(NSDictionary *emoteDict in emoteInfo) {
        if(![emoteDict isKindOfClass:[NSDictionary class]])
            continue;
        BTTVEmote *emote = [[BTTVEmote alloc] initWithDictData:emoteDict emoteType:type];
        if(emote.emoteID && emote.emoteText)
            [emotes addObject:emote];
    }
    return emotes;
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
