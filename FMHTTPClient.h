#import <Foundation/Foundation.h>

@interface FMHTTPClient : NSObject
- (NSDictionary *)bttvEmoteInformationForChannelID:(NSString *)channelID;
- (NSDictionary *)ffzEmoteInformationForChannelID:(NSString *)channelID;
- (NSDictionary *)sevenTVEmoteInformationForChannelID:(NSString *)channelID;
- (NSDictionary *)bttvGlobalEmotes;
- (NSDictionary *)ffzGlobalEmotes;
- (NSDictionary *)sevenTVGlobalEmotes;
// FFZ's own API, only for emote sizes: BTTV's copy of FFZ emotes doesn't have them, but its images are the ones the
// app can decode (FFZ's animated emotes are webp)
- (NSDictionary *)ffzRoomForChannelID:(NSString *)channelID;
- (NSDictionary *)ffzGlobalSets;

// The channel ID of a VOD's streamer, or nil
- (NSString *)ownerIDForVideoID:(NSString *)videoID;
@end