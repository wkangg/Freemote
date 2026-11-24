#import <Foundation/Foundation.h>

typedef enum {
    BTTV, FFZ, BTTVGlobal, FFZGlobal, SevenTV, SevenTVGlobal
} EmoteType;

@interface FMEmote : NSObject
@property (nonatomic, strong) NSString *emoteText;
@property (nonatomic, strong) NSString *emoteID;
@property (nonatomic, strong) NSURL *image1x;
@property (nonatomic, strong) NSURL *image2x;
@property (nonatomic, strong) NSURL *pageURL; // the emote's page on its provider's site
@property (nonatomic, strong) NSString *ownerName; // who uploaded it, if the API says
@property (assign) BOOL isAnimated;
@property (assign) double aspectRatio; // width / height, 0 if the API doesn't say (drawn square like Twitch's)
@property (assign) BOOL isZeroWidth; // drawn over the emote before it (7TV)
@property (assign) EmoteType emoteType;
@property (readonly) BOOL isGlobal;
@property (readonly) NSString *providerName; // "BetterTTV", "FrankerFaceZ" or "7TV"

- (instancetype)initWithDictData:(NSDictionary *)data emoteType:(EmoteType)type;
// e.g. "7TV Channel Emote", for the emote card
- (NSString *)emoteDescription;
@end