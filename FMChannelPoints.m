#import "FMChannelPoints.h"
#import "FMLog.h"
#import "FMSettings.h"

// Twitch 31.x's own operations (TwitchGraphQLAPI's ClaimChannelPoints and ChannelPoints), by their persisted query
// hashes. If the server stops knowing a hash, the query is sent as text instead (ours leaves out what isn't used, and
// GraphQL rejects variables a query declares without using, so includeSettings is only for the hashed one).
static NSString *const FMClaimHash = @"bb04fa30fb690d918db7776b4734f6ae86cd88e3029b4dabcf677eab0f9855b1";
static NSString *const FMClaimQuery = @"mutation ClaimChannelPoints($input: ClaimCommunityPointsInput!) { claimCommunityPoints(input: $input) { claim { id pointsEarnedTotal } currentPoints error { code } } }";
static NSString *const FMChannelPointsHash = @"821b719cdc52f972fc2a068b9a0217c60bffc9d508383c224a35441dbfb3e00f";
static NSString *const FMChannelPointsQuery = @"query ChannelPoints($channel: ID!, $includeUserInfo: Boolean!) { user(id: $channel) { channel { selfView: self @include(if: $includeUserInfo) { communityPoints { availableClaim { id } } } } } }";

// How long after checking a channel for a waiting bonus it isn't checked again: chats get joined from several places
#define FMChannelCheckInterval 60

// All only on pointsQueue
static NSDictionary<NSString *, id> *nativeHeaders, *reactHeaders;
static NSMutableSet<NSString *> *claimIDs; // claimed, or being claimed
static NSMutableDictionary<NSString *, NSDate *> *checkedChannels;
static NSMutableSet<NSString *> *pendingChannels; // joined before there were headers to check them with

static dispatch_queue_t pointsQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.gilesgc.freemote.channel-points", DISPATCH_QUEUE_SERIAL);
        claimIDs = [[NSMutableSet alloc] init];
        checkedChannels = [[NSMutableDictionary alloc] init];
        pendingChannels = [[NSMutableSet alloc] init];
    });
    return queue;
}

static BOOL claimingEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:FMClaimChannelPointsKey];
}

static BOOL isNumericID(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length]
        && [(NSString *)value rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound;
}

static id valueAt(id json, NSArray<NSString *> *path) {
    for(NSString *key in path)
        json = [json isKindOfClass:[NSDictionary class]] ? json[key] : nil;
    return json;
}

// Calls completion on pointsQueue with the response's data, or nil
static void sendGQL(NSDictionary<NSString *, id> *headers, NSString *operationName, NSString *hash, NSString *query, NSDictionary *variables, void (^completion)(NSDictionary *data)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 10;
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, id value, BOOL *stop) {
        [request setValue:[NSString stringWithFormat:@"%@", value] forHTTPHeaderField:name];
    }];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSMutableDictionary *body = [@{@"operationName": operationName, @"variables": variables} mutableCopy];
    if(hash)
        body[@"extensions"] = @{@"persistedQuery": @{@"version": @1, @"sha256Hash": hash}};
    else
        body[@"query"] = query;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
        id json = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
        NSArray *errors = valueAt(json, @[@"errors"]);
        NSString *message = [errors isKindOfClass:[NSArray class]] ? valueAt(errors.firstObject, @[@"message"]) : nil;
        message = [message isKindOfClass:[NSString class]] ? message : nil;
        if(hash && [message containsString:@"PersistedQuery"]) {
            FMLog("Twitch doesn't know the %{public}@ hash (%{public}@), sending it as text", operationName, message);
            sendGQL(headers, operationName, nil, query, variables, completion);
            return;
        }
        NSDictionary *data = valueAt(json, @[@"data"]);
        if(![data isKindOfClass:[NSDictionary class]] || message) {
            FMLog("%{public}@ failed (HTTP %ld): %{public}@", operationName, (long)((NSHTTPURLResponse *)response).statusCode, message ?: error.localizedDescription);
            data = nil;
        }
        dispatch_async(pointsQueue(), ^{
            completion(data);
        });
    }] resume];
}

// Only on pointsQueue
static NSDictionary<NSString *, id> *claimHeaders(void) {
    return nativeHeaders ?: reactHeaders;
}

// How long to wait before trying a claim that didn't get through once more: Hermes won't say it's there again
#define FMClaimRetryDelay 5

// Only on pointsQueue
static void claim(NSString *channelID, NSString *claimID, BOOL retry) {
    if(!claimingEnabled() || [claimIDs containsObject:claimID])
        return;
    NSDictionary *headers = claimHeaders();
    if(!headers) {
        FMLog("Channel points bonus in channel %{public}@, but no signed-in request to claim it with yet", channelID);
        return;
    }
    if(claimIDs.count > 100)
        [claimIDs removeAllObjects];
    [claimIDs addObject:claimID];
    FMLog("Claiming the channel points bonus in channel %{public}@", channelID);
    sendGQL(headers, @"ClaimChannelPoints", FMClaimHash, FMClaimQuery, @{@"input": @{@"channelID": channelID, @"claimID": claimID}}, ^(NSDictionary *data) {
        NSDictionary *result = valueAt(data, @[@"claimCommunityPoints"]);
        id errorCode = valueAt(result, @[@"error", @"code"]);
        if(![result isKindOfClass:[NSDictionary class]]) {
            // Didn't get through: it can be tried again
            [claimIDs removeObject:claimID];
            if(retry) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, FMClaimRetryDelay * NSEC_PER_SEC), pointsQueue(), ^{
                    claim(channelID, claimID, NO);
                });
            }
            return;
        }
        if(errorCode && errorCode != [NSNull null])
            FMLog("Couldn't claim the channel points bonus in channel %{public}@: %{public}@", channelID, errorCode);
        else
            FMLog("Claimed %{public}@ channel points in channel %{public}@ (%{public}@ now)", valueAt(result, @[@"claim", @"pointsEarnedTotal"]), channelID, result[@"currentPoints"]);
    });
}

// Only on pointsQueue
static void checkChannel(NSString *channelID) {
    NSDictionary *headers = claimHeaders();
    if(!headers) {
        if(pendingChannels.count > 20)
            [pendingChannels removeAllObjects];
        [pendingChannels addObject:channelID];
        return;
    }
    NSDate *checked = checkedChannels[channelID];
    if(checked && -checked.timeIntervalSinceNow < FMChannelCheckInterval)
        return;
    checkedChannels[channelID] = [NSDate date];
    sendGQL(headers, @"ChannelPoints", FMChannelPointsHash, FMChannelPointsQuery, @{@"channel": channelID, @"includeSettings": @NO, @"includeUserInfo": @YES}, ^(NSDictionary *data) {
        NSString *claimID = valueAt(data, @[@"user", @"channel", @"selfView", @"communityPoints", @"availableClaim", @"id"]);
        if([claimID isKindOfClass:[NSString class]] && claimID.length)
            claim(channelID, claimID, YES);
    });
}

void FMChannelPointsNoteRequest(NSURLRequest *request, NSURLSession *session, BOOL native) {
    if(![request.URL.host isEqualToString:@"gql.twitch.tv"])
        return;
    NSMutableDictionary<NSString *, id> *headers = [[NSMutableDictionary alloc] init];
    NSDictionary *sessionHeaders = session.configuration.HTTPAdditionalHeaders;
    if([sessionHeaders isKindOfClass:[NSDictionary class]])
        [headers addEntriesFromDictionary:sessionHeaders];
    [headers addEntriesFromDictionary:request.allHTTPHeaderFields ?: @{}];
    // Only the ones that aren't about this request
    BOOL signedIn = NO;
    for(NSString *name in headers.allKeys) {
        NSString *lowercaseName = [name isKindOfClass:[NSString class]] ? name.lowercaseString : @"";
        if([lowercaseName isEqualToString:@"content-length"] || [lowercaseName isEqualToString:@"content-type"]
           || [lowercaseName hasPrefix:@"x-apollo"] || [lowercaseName hasPrefix:@"apollographql"])
            [headers removeObjectForKey:name];
        else if([lowercaseName isEqualToString:@"authorization"])
            signedIn = [headers[name] isKindOfClass:[NSString class]] && [(NSString *)headers[name] length] > 10; // more than "OAuth "
    }
    if(!signedIn)
        return;

    dispatch_async(pointsQueue(), ^{
        if(!claimHeaders())
            FMLog("Got %{public}s headers to claim channel points with", native ? "native" : "React Native");
        if(native)
            nativeHeaders = headers;
        else
            reactHeaders = headers;
        if(pendingChannels.count && claimingEnabled()) {
            for(NSString *channelID in pendingChannels)
                checkChannel(channelID);
        }
        [pendingChannels removeAllObjects];
    });
}

// Hermes notifications carry the PubSub message as a JSON string, and PubSub messages carry theirs as one too, so
// strings that are JSON get looked into
static void findClaims(id json, NSUInteger depth, void (^found)(NSString *channelID, NSString *claimID)) {
    if(depth > 8)
        return;
    if([json isKindOfClass:[NSString class]]) {
        NSString *text = json;
        NSData *data = [text hasPrefix:@"{"] && [text rangeOfString:@"claim-available"].location != NSNotFound ? [text dataUsingEncoding:NSUTF8StringEncoding] : nil;
        if(data)
            findClaims([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], depth + 1, found);
    } else if([json isKindOfClass:[NSArray class]]) {
        for(id item in json)
            findClaims(item, depth + 1, found);
    } else if([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *claim = valueAt(json, @[@"data", @"claim"]);
        if([@"claim-available" isEqual:json[@"type"]] && [claim isKindOfClass:[NSDictionary class]]) {
            if(isNumericID(claim[@"channel_id"]) && [claim[@"id"] isKindOfClass:[NSString class]])
                found(claim[@"channel_id"], claim[@"id"]);
            else
                FMLog("claim-available without a channel or claim ID: %{public}@", [claim.allKeys componentsJoinedByString:@", "]);
            return;
        }
        for(id value in [json allValues])
            findClaims(value, depth + 1, found);
    }
}

void FMChannelPointsHandleMessage(NSString *message) {
    if(![message isKindOfClass:[NSString class]] || [message rangeOfString:@"claim-available"].location == NSNotFound)
        return;
    findClaims(message, 0, ^(NSString *channelID, NSString *claimID) {
        dispatch_async(pointsQueue(), ^{
            claim(channelID, claimID, YES);
        });
    });
}

void FMChannelPointsCheckChannel(NSString *channelID) {
    if(!isNumericID(channelID) || !claimingEnabled())
        return;
    dispatch_async(pointsQueue(), ^{
        checkChannel(channelID);
    });
}
