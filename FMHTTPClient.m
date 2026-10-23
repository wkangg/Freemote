#import "FMHTTPClient.h"

@implementation FMHTTPClient

- (NSDictionary *)bttvEmoteInformationForChannelID:(NSString *)channelID {
    return [self getJSON:[NSURL URLWithString:[@"https://api.betterttv.net/3/cached/users/twitch/" stringByAppendingString:channelID]]];  
}

- (NSDictionary *)ffzEmoteInformationForChannelID:(NSString *)channelID {
    return [self getJSON:[NSURL URLWithString:[@"https://api.betterttv.net/3/cached/frankerfacez/users/twitch/" stringByAppendingString:channelID]]];
}

- (NSDictionary *)sevenTVEmoteInformationForChannelID:(NSString *)channelID {
    return [self getJSON:[NSURL URLWithString:[@"https://7tv.io/v3/users/twitch/" stringByAppendingString:channelID]]];
}

- (NSDictionary *)bttvGlobalEmotes {
    return [self getJSON:[NSURL URLWithString:@"https://api.betterttv.net/3/cached/emotes/global"]];
}

- (NSDictionary *)ffzGlobalEmotes {
    return [self getJSON:[NSURL URLWithString:@"https://api.betterttv.net/3/cached/frankerfacez/emotes/global"]];
}

- (NSDictionary *)sevenTVGlobalEmotes {
    return [self getJSON:[NSURL URLWithString:@"https://7tv.io/v3/emote-sets/global"]];
}

- (NSDictionary *)getJSON:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];

    if(!data)
        return nil;

    NSError *error;
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    return result;  
}

@end