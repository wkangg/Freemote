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
    NSDate *start = [NSDate date];
    NSString *ownerID = [self gqlString:@"query($id: ID!) { video(id: $id) { owner { id } } }" variables:@{@"id": videoID} path:@[@"video", @"owner", @"id"]];
    if(!ownerID)
        FMLog("Couldn't find the owner of video %{public}@ after %.1fs", videoID, -start.timeIntervalSinceNow);
    else
        FMLog("Video %{public}@ is from channel %{public}@ (%.1fs)", videoID, ownerID, -start.timeIntervalSinceNow);
    return ownerID;
}

- (NSString *)channelIDForLogin:(NSString *)login {
    NSDate *start = [NSDate date];
    NSString *channelID = [self gqlString:@"query($login: String!) { user(login: $login) { id } }" variables:@{@"login": login} path:@[@"user", @"id"]];
    if(!channelID)
        FMLog("Couldn't find the channel ID of %{public}@ after %.1fs", login, -start.timeIntervalSinceNow);
    else
        FMLog("Chat %{public}@ is channel %{public}@ (%.1fs)", login, channelID, -start.timeIntervalSinceNow);
    return channelID;
}

// The string at `path` under the response's data, or nil
- (NSString *)gqlString:(NSString *)query variables:(NSDictionary *)variables path:(NSArray<NSString *> *)path {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 5;
    // Twitch's web client ID, which takes arbitrary queries
    [request setValue:@"kimne78kx3ncx6brgo4mv6wki5h1ko" forHTTPHeaderField:@"Client-ID"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"query": query, @"variables": variables} options:0 error:nil];

    __block NSData *data;
    __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *responseError) {
        data = responseData;
        error = responseError;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    // Any level can be null
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    for(NSString *key in [@[@"data"] arrayByAddingObjectsFromArray:path])
        value = [value isKindOfClass:[NSDictionary class]] ? value[key] : nil;
    if(![value isKindOfClass:[NSString class]]) {
        FMLog("GQL query failed (%lu bytes): %{public}@", (unsigned long)data.length, error.localizedDescription);
        return nil;
    }
    return value;
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