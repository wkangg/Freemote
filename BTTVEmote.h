#import <Foundation/Foundation.h>

typedef enum {
    BTTV, FFZ, BTTVGlobal, FFZGlobal, SevenTV, SevenTVGlobal
} EmoteType;

@interface BTTVEmote : NSObject
@property (nonatomic, retain) NSString *emoteText;
@property (nonatomic, retain) NSString *emoteID;
@property (nonatomic, retain) NSURL *image1x;
@property (nonatomic, retain) NSURL *image2x;
@property (nonatomic, retain) NSURL *pageURL; // the emote's page on its provider's site
@property (nonatomic, retain) NSString *ownerName; // who uploaded it, if the API says
@property (assign) BOOL isAnimated;
@property (assign) double aspectRatio; // width / height, 0 if the API doesn't say (drawn square like Twitch's)
@property (assign) BOOL isZeroWidth; // drawn over the emote before it (7TV)
@property (assign) EmoteType emoteType;

- (id)initWithDictData:(NSDictionary *)data emoteType:(EmoteType)type;
// e.g. "7TV Channel Emote", for the emote card
- (NSString *)emoteDescription;
@end