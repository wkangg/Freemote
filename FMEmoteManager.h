#import "FMHTTPClient.h"
#import "BTTVEmote.h"

@interface FMEmoteManager : NSObject
@property (nonatomic, retain) FMHTTPClient *httpClient;
// Replaced wholesale on update, so they can be read from any thread
@property (atomic, copy) NSDictionary<NSString *, BTTVEmote *> *emoteRegistry; // every loaded emote, by ID
@property (atomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, BTTVEmote *> *> *channelNameRegistries; // channel ID -> name -> emote, globals included
@property (atomic, copy) NSDictionary<NSString *, BTTVEmote *> *globalNameRegistry;
// Called on a background thread each time more of a channel's emotes are in
@property (atomic, copy) void (^channelEmotesChanged)(NSString *channelID);

// Blocks on network requests, don't call on the main thread. Each provider's emotes are usable as soon as its
// request finishes, before this returns.
- (void)loadEmotesForChannel:(NSString *)channelID;
// Whether all of the channel's requests have finished
- (BOOL)hasEmotesForChannel:(NSString *)channelID;
// Falls back to global emotes until one of the channel's requests finishes
- (NSDictionary<NSString *, BTTVEmote *> *)emoteNameRegistryForChannel:(NSString *)channelID;
- (NSURL *)imageURLForBTTVEmoteID:(NSString *)emoteID;

@end
