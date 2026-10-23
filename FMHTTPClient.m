#import "FMHTTPClient.h"
#import "FMLog.h"

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
    NSDate *start = [NSDate date];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    NSTimeInterval duration = -start.timeIntervalSinceNow;

    if(!data) {
        FMLog("Request failed after %.1fs: %{public}@ (%{public}@)", duration, url, error.localizedDescription);
        return nil;
    }

    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if(!result)
        FMLog("Invalid JSON from %{public}@ (%lu bytes): %{public}@", url, (unsigned long)data.length, error.localizedDescription);
    else
        FMLog("Fetched %{public}@ in %.1fs (%lu bytes)", url, duration, (unsigned long)data.length);
    return result;
}

@end