#import "FMHTTPClient.h"
#import "BTTVEmote.h"

@interface FMEmoteManager : NSObject {
    NSMutableDictionary *_globalEmoteRegistry;
    NSMutableDictionary *_globalEmoteNameRegistry;
}
@property (nonatomic, retain) FMHTTPClient *httpClient;
// Replaced wholesale on update, so they can be read from any thread
@property (atomic, copy) NSDictionary<NSString *, BTTVEmote *> *emoteRegistry;
@property (atomic, copy) NSDictionary<NSString *, BTTVEmote *> *emoteNameRegistry;

// Blocks on network requests, don't call on the main thread
- (void)updateEmoteRegistry:(NSString *)channelID;
- (NSURL *)imageURLForBTTVEmoteID:(NSString *)emoteID;

@end
