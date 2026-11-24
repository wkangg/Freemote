#import <Foundation/Foundation.h>

@interface FMHTTPClient : NSObject
// The emote APIs' parsed JSON, which is an array or a dictionary depending on the endpoint (and on errors), or nil
- (id)bttvEmoteInformationForChannelID:(NSString *)channelID;
- (id)ffzEmoteInformationForChannelID:(NSString *)channelID;
- (id)sevenTVEmoteInformationForChannelID:(NSString *)channelID;
- (id)bttvGlobalEmotes;
- (id)ffzGlobalEmotes;
- (id)sevenTVGlobalEmotes;
// FFZ's own API, only for emote sizes: BTTV's copy of FFZ emotes doesn't have them, but its images are the ones the
// app can decode (FFZ's animated emotes are webp)
- (id)ffzRoomForChannelID:(NSString *)channelID;
- (id)ffzGlobalSets;

// The channel ID of a VOD's streamer, or nil
- (NSString *)ownerIDForVideoID:(NSString *)videoID;
// The channel ID for a login name, or nil
- (NSString *)channelIDForLogin:(NSString *)login;
@end