#import <Foundation/Foundation.h>

@interface FMHTTPClient : NSObject
- (NSDictionary *)bttvEmoteInformationForChannelID:(NSString *)channelID;
- (NSDictionary *)ffzEmoteInformationForChannelID:(NSString *)channelID;
- (NSDictionary *)bttvGlobalEmotes;
- (NSDictionary *)ffzGlobalEmotes;
@end