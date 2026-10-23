#import "FMHTTPClient.h"
#import "BTTVEmote.h"

@interface FMEmoteManager : NSObject {
    NSMutableDictionary *_globalEmoteRegistry;
    NSMutableDictionary *_globalEmoteNameRegistry;
}
@property (nonatomic, retain) FMHTTPClient *httpClient;
// Replaced wholesale on update, so they can be read from any thread
@property (atomic, copy) NSDictionary<NSString *, BTTVEmote *> *emoteRegistry; // every loaded emote, by ID
@property (atomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, BTTVEmote *> *> *channelNameRegistries; // channel ID -> name -> emote, globals included
@property (atomic, copy) NSDictionary<NSString *, BTTVEmote *> *globalNameRegistry;
@property (atomic, copy) NSString *lastLoadedChannelID;

// Blocks on network requests, don't call on the main thread
- (void)loadEmotesForChannel:(NSString *)channelID;
- (BOOL)hasEmotesForChannel:(NSString *)channelID;
// Falls back to global emotes until the channel's emotes are loaded
- (NSDictionary<NSString *, BTTVEmote *> *)emoteNameRegistryForChannel:(NSString *)channelID;
- (NSURL *)imageURLForBTTVEmoteID:(NSString *)emoteID;

@end
