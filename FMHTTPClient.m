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

- (NSDictionary *)ffzRoomForChannelID:(NSString *)channelID {
    return [self getJSON:[NSURL URLWithString:[@"https://api.frankerfacez.com/v1/room/id/" stringByAppendingString:channelID]]];
}

- (NSDictionary *)ffzGlobalSets {
    return [self getJSON:[NSURL URLWithString:@"https://api.frankerfacez.com/v1/set/global"]];
}


- (NSString *)ownerIDForVideoID:(NSString *)videoID {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 5;
    // Twitch's web client ID, which takes arbitrary queries
    [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-ID"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"query": @"query($id: ID!) { video(id: $id) { owner { id } } }",
        @"variables": @{@"id": videoID}
    } options:0 error:nil];

    NSDate *start = [NSDate date];
    __block NSData *data;
    __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *responseError) {
        data = responseData;
        error = responseError;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    // data.video.owner.id, where any level can be null
    id ownerID = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    for(NSString *key in @[@"data", @"video", @"owner", @"id"])
        ownerID = [ownerID isKindOfClass:[NSDictionary class]] ? ownerID[key] : nil;
    if(![ownerID isKindOfClass:[NSString class]]) {
        FMLog("Couldn't find the owner of video %{public}@ after %.1fs (%lu bytes): %{public}@", videoID, -start.timeIntervalSinceNow, (unsigned long)data.length, error.localizedDescription);
        return nil;
    }
    FMLog("Video %{public}@ is from channel %{public}@ (%.1fs)", videoID, ownerID, -start.timeIntervalSinceNow);
    return ownerID;
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