#import "FMRecentMessages.h"
#import "FMLog.h"

// More than the chat holds: deleted messages are among them, and are left out unless they're kept
#define FMRecentMessagesRequestLimit 250
#define FMRecentMessagesRequestTimeout 5

static BOOL isNull(id value) {
    return !value || value == [NSNull null];
}

// An IRC tag's value: "\s" is a space, "\:" a semicolon
static NSString *unescapedTagValue(NSString *value) {
    if([value rangeOfString:@"\\"].location == NSNotFound)
        return value;
    NSMutableString *result = [[NSMutableString alloc] init];
    for(NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if(c != '\\' || i + 1 == value.length) {
            // A lone backslash at the end is dropped
            if(c != '\\')
                [result appendFormat:@"%C", c];
            continue;
        }
        unichar escaped = [value characterAtIndex:++i];
        if(escaped == 's')
            [result appendString:@" "];
        else if(escaped == ':')
            [result appendString:@";"];
        else if(escaped == 'r')
            [result appendString:@"\r"];
        else if(escaped == 'n')
            [result appendString:@"\n"];
        else
            [result appendFormat:@"%C", escaped];
    }
    return result;
}

// The service leaves the "=" off an empty tag ("emotes;flags")
static NSDictionary<NSString *, NSString *> *tagsFromString(NSString *string) {
    NSMutableDictionary<NSString *, NSString *> *tags = [[NSMutableDictionary alloc] init];
    for(NSString *tag in [string componentsSeparatedByString:@";"]) {
        NSRange equals = [tag rangeOfString:@"="];
        if(equals.location == NSNotFound)
            tags[tag] = @"";
        else
            tags[[tag substringToIndex:equals.location]] = unescapedTagValue([tag substringFromIndex:NSMaxRange(equals)]);
    }
    return tags;
}

static NSISO8601DateFormatter *dateFormatter(BOOL fractionalSeconds) {
    static NSISO8601DateFormatter *formatters[2];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatters[0] = [[NSISO8601DateFormatter alloc] init];
        formatters[1] = [[NSISO8601DateFormatter alloc] init];
        formatters[1].formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return formatters[fractionalSeconds];
}

// A message's sentAt. Twitch's can have more than the three decimals the formatter takes.
static NSDate *dateFromSentAt(NSString *sentAt) {
    if(![sentAt isKindOfClass:[NSString class]])
        return nil;
    NSRange dot = [sentAt rangeOfString:@"."];
    if(dot.location == NSNotFound)
        return [dateFormatter(NO) dateFromString:sentAt];
    NSUInteger end = NSMaxRange(dot);
    while(end < sentAt.length && [sentAt characterAtIndex:end] >= '0' && [sentAt characterAtIndex:end] <= '9')
        end++;
    NSString *decimals = [[[sentAt substringWithRange:NSMakeRange(NSMaxRange(dot), end - NSMaxRange(dot))] stringByAppendingString:@"000"] substringToIndex:3];
    return [dateFormatter(YES) dateFromString:[NSString stringWithFormat:@"%@.%@%@", [sentAt substringToIndex:dot.location], decimals, [sentAt substringFromIndex:end]]];
}

static NSMutableDictionary *textFragment(NSString *text) {
    return [@{@"__typename": @"MessageFragment", @"text": text, @"content": [NSNull null]} mutableCopy];
}

// The text split at the emotes tag's emotes ("<id>:<from>-<to>,.../...", in code points, `to` inclusive)
static NSMutableArray *fragmentsFromText(NSString *text, NSString *emotesTag) {
    NSData *utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    NSUInteger length = utf32.length / 4;
    // Text that can't be converted (an unpaired surrogate) stays whole
    if(!utf32)
        return [@[textFragment(text)] mutableCopy];
    NSString *(^substring)(NSUInteger, NSUInteger) = ^NSString *(NSUInteger from, NSUInteger to) {
        return [[NSString alloc] initWithData:[utf32 subdataWithRange:NSMakeRange(from * 4, (to - from) * 4)] encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
    };

    // [from, to, emote ID]
    NSMutableArray<NSArray *> *emotes = [[NSMutableArray alloc] init];
    for(NSString *emote in [emotesTag componentsSeparatedByString:@"/"]) {
        NSRange colon = [emote rangeOfString:@":"];
        if(colon.location == NSNotFound || colon.location == 0)
            continue;
        for(NSString *range in [[emote substringFromIndex:NSMaxRange(colon)] componentsSeparatedByString:@","]) {
            NSArray<NSString *> *ends = [range componentsSeparatedByString:@"-"];
            if(ends.count == 2 && ends[0].integerValue >= 0 && ends[1].integerValue >= ends[0].integerValue && (NSUInteger)ends[1].integerValue < length)
                [emotes addObject:@[@(ends[0].integerValue), @(ends[1].integerValue), [emote substringToIndex:colon.location]]];
        }
    }
    [emotes sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [(NSNumber *)a[0] compare:b[0]];
    }];

    NSMutableArray *fragments = [[NSMutableArray alloc] init];
    NSUInteger position = 0;
    for(NSArray *emote in emotes) {
        NSUInteger from = [emote[0] unsignedIntegerValue], to = [emote[1] unsignedIntegerValue] + 1;
        if(from < position)
            continue;
        if(from > position)
            [fragments addObject:textFragment(substring(position, from))];
        NSString *name = substring(from, to);
        [fragments addObject:[@{@"__typename": @"MessageFragment", @"text": name, @"content": @{@"__typename": @"Emote", @"emoteID": emote[2], @"setID": @"", @"token": name}} mutableCopy]];
        position = to;
    }
    if(position < length || !fragments.count)
        [fragments addObject:textFragment(substring(position, length))];
    return fragments;
}

static NSDictionary *user(NSString *userID, NSString *login, NSString *displayName) {
    return @{@"__typename": @"User", @"id": userID, @"login": login, @"displayName": displayName.length ? displayName : login};
}

// "@<tags> :<login>!<login>@<login>.tmi.twitch.tv PRIVMSG #<channel> :<text>". The service leaves the ":" off a text
// of one word.
NSMutableDictionary *FMChatHistoryMessageFromIRCLine(NSString *line, BOOL *deleted) {
    NSRange tagsEnd = [line isKindOfClass:[NSString class]] ? [line rangeOfString:@" "] : (NSRange){NSNotFound, 0};
    if(tagsEnd.location == NSNotFound || ![line hasPrefix:@"@"])
        return nil;
    NSString *rest = [line substringFromIndex:NSMaxRange(tagsEnd)];
    NSArray<NSString *> *words = [rest componentsSeparatedByString:@" "];
    if(words.count < 4 || ![words[1] isEqualToString:@"PRIVMSG"] || ![words[0] hasPrefix:@":"])
        return nil;

    NSDictionary<NSString *, NSString *> *tags = tagsFromString([line substringWithRange:NSMakeRange(1, tagsEnd.location - 1)]);
    NSRange loginEnd = [words[0] rangeOfString:@"!"];
    NSString *login = loginEnd.location == NSNotFound ? nil : [words[0] substringWithRange:NSMakeRange(1, loginEnd.location - 1)];
    long long sentMilliseconds = tags[@"tmi-sent-ts"].longLongValue;
    if(!tags[@"id"].length || !tags[@"user-id"].length || !login.length || sentMilliseconds <= 0)
        return nil;
    if(deleted)
        *deleted = [tags[@"rm-deleted"] isEqualToString:@"1"];

    NSString *text = [rest substringFromIndex:words[0].length + words[1].length + words[2].length + 3];
    if([text hasPrefix:@":"])
        text = [text substringFromIndex:1];
    // /me: the emotes tag counts from the start of the action's text
    if([text hasPrefix:@"\x01" "ACTION "])
        text = [[text substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\x01"]];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    NSMutableArray *badges = [[NSMutableArray alloc] init];
    for(NSString *badge in [tags[@"badges"] componentsSeparatedByString:@","]) {
        NSRange slash = [badge rangeOfString:@"/"];
        if(slash.location == NSNotFound || slash.location == 0)
            continue;
        NSString *setID = [badge substringToIndex:slash.location], *version = [badge substringFromIndex:NSMaxRange(slash)];
        // Apollo caches objects by ID, so not one a real badge could have
        [badges addObject:@{@"__typename": @"Badge", @"id": [NSString stringWithFormat:@"freemote_%@_%@", setID, version], @"setID": setID, @"version": version}];
    }

    id parentMessage = [NSNull null], threadParentMessage = [NSNull null];
    if(tags[@"reply-parent-msg-id"].length && tags[@"reply-parent-user-id"].length && tags[@"reply-parent-user-login"].length) {
        parentMessage = @{
            @"__typename": @"Message", @"id": tags[@"reply-parent-msg-id"], @"deletedAt": [NSNull null],
            @"content": @{@"__typename": @"MessageContent", @"text": tags[@"reply-parent-msg-body"] ?: @""},
            @"sender": user(tags[@"reply-parent-user-id"], tags[@"reply-parent-user-login"], tags[@"reply-parent-display-name"]),
        };
        if(tags[@"reply-thread-parent-msg-id"].length && tags[@"reply-thread-parent-user-id"].length && tags[@"reply-thread-parent-user-login"].length) {
            threadParentMessage = @{
                @"__typename": @"Message", @"id": tags[@"reply-thread-parent-msg-id"], @"deletedAt": [NSNull null],
                @"sender": user(tags[@"reply-thread-parent-user-id"], tags[@"reply-thread-parent-user-login"], tags[@"reply-thread-parent-display-name"]),
            };
        }
    }

    return [@{
        @"__typename": @"Message",
        @"id": tags[@"id"],
        @"deletedAt": [NSNull null],
        // Half a millisecond on, since the formatter cuts the decimals off rather than rounding
        @"sentAt": [dateFormatter(YES) stringFromDate:[NSDate dateWithTimeIntervalSince1970:(sentMilliseconds + 0.5) / 1000.0]],
        @"content": [@{@"__typename": @"MessageContent", @"text": text, @"fragments": fragmentsFromText(text, tags[@"emotes"] ?: @"")} mutableCopy],
        @"parentMessage": parentMessage,
        @"threadParentMessage": threadParentMessage,
        @"sender": user(tags[@"user-id"], login, tags[@"display-name"]),
        @"senderBadges": badges,
        @"senderChatColor": tags[@"color"].length ? (id)tags[@"color"] : [NSNull null],
        @"sourceChannel": [NSNull null],
        @"sourceSenderBadges": [NSNull null],
    } mutableCopy];
}

NSArray *FMMergeChatHistory(NSArray *twitchMessages, FMRecentMessages *recentMessages, NSMutableSet<NSString *> *deletedIDs) {
    NSSet<NSString *> *recentDeletedIDs = recentMessages.deletedIDs;
    NSMutableSet<NSString *> *recentIDs = [[NSMutableSet alloc] init];
    for(NSMutableDictionary *message in recentMessages.messages)
        [recentIDs addObject:message[@"id"]];

    NSMutableSet<NSString *> *seenIDs = [[NSMutableSet alloc] init];
    NSMutableArray<NSArray *> *dated = [[NSMutableArray alloc] init]; // [date, message]
    for(NSMutableDictionary *message in twitchMessages) {
        NSString *messageID = [message isKindOfClass:[NSDictionary class]] ? message[@"id"] : nil;
        NSDate *date = [messageID isKindOfClass:[NSString class]] ? dateFromSentAt(message[@"sentAt"]) : nil;
        if(!date)
            return nil;
        BOOL deleted = !isNull(message[@"deletedAt"]);
        if(deleted && deletedIDs) {
            // The service's copy is sure to have its text
            if([recentIDs containsObject:messageID]) {
                [deletedIDs addObject:messageID];
                continue;
            }
            NSDictionary *content = message[@"content"];
            NSString *text = [content isKindOfClass:[NSDictionary class]] ? content[@"text"] : nil;
            if([message isKindOfClass:[NSMutableDictionary class]] && [text isKindOfClass:[NSString class]] && text.length) {
                message[@"deletedAt"] = [NSNull null];
                [deletedIDs addObject:messageID];
            }
        } else if(!deleted && [recentDeletedIDs containsObject:messageID]) {
            // Deleted since Twitch answered, or Twitch doesn't say so
            [deletedIDs addObject:messageID];
        }
        [seenIDs addObject:messageID];
        [dated addObject:@[date, message]];
    }
    for(NSMutableDictionary *message in recentMessages.messages) {
        BOOL deleted = [recentDeletedIDs containsObject:message[@"id"]];
        NSDate *date = [seenIDs containsObject:message[@"id"]] || (deleted && !deletedIDs) ? nil : dateFromSentAt(message[@"sentAt"]);
        if(!date)
            continue;
        if(deleted)
            [deletedIDs addObject:message[@"id"]];
        [seenIDs addObject:message[@"id"]];
        [dated addObject:@[date, message]];
    }
    [dated sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [(NSDate *)a[0] compare:b[0]];
    }];
    if(dated.count > FMChatHistoryLimit)
        [dated removeObjectsInRange:NSMakeRange(0, dated.count - FMChatHistoryLimit)];
    NSMutableArray *messages = [[NSMutableArray alloc] init];
    for(NSArray *entry in dated)
        [messages addObject:entry[1]];
    return messages;
}

@interface FMRecentMessages ()
@property (atomic, readwrite) BOOL done;
@property (atomic, readwrite) NSArray<NSMutableDictionary *> *messages;
@property (atomic, readwrite) NSSet<NSString *> *deletedIDs;
@end

@implementation FMRecentMessages {
    dispatch_group_t _request;
}

- (instancetype)initWithChannelLogin:(NSString *)login {
    if(!(self = [super init]))
        return nil;
    _channelLogin = [login copy];
    _messages = @[];
    _deletedIDs = [NSSet set];
    _request = dispatch_group_create();
    dispatch_group_enter(_request);

    NSString *url = [NSString stringWithFormat:@"https://recent-messages.robotty.de/api/v2/recent-messages/%@?limit=%d&hide_moderation_messages=true", login, FMRecentMessagesRequestLimit];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = FMRecentMessagesRequestTimeout;
    [request setValue:@"Freemote/" FREEMOTE_VERSION forHTTPHeaderField:@"User-Agent"];
    NSDate *start = [NSDate date];
    // The task keeps the block, and so this object, until it's done
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [self finishWithData:data error:error duration:-start.timeIntervalSinceNow];
    }] resume];
    return self;
}

- (void)finishWithData:(NSData *)data error:(NSError *)error duration:(NSTimeInterval)duration {
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *lines = [json isKindOfClass:[NSDictionary class]] ? json[@"messages"] : nil;
    if(![lines isKindOfClass:[NSArray class]]) {
        FMLog("Recent messages for %@ failed after %.1fs (%lu bytes): %@", _channelLogin, duration, (unsigned long)data.length, error.localizedDescription);
    } else {
        NSMutableArray<NSMutableDictionary *> *messages = [[NSMutableArray alloc] init];
        NSMutableSet<NSString *> *deletedIDs = [[NSMutableSet alloc] init];
        for(NSString *line in lines) {
            BOOL deleted = NO;
            NSMutableDictionary *message = FMChatHistoryMessageFromIRCLine(line, &deleted);
            if(!message)
                continue;
            [messages addObject:message];
            if(deleted)
                [deletedIDs addObject:message[@"id"]];
        }
        self.deletedIDs = deletedIDs;
        self.messages = messages;
        // error_code: e.g. channel_not_joined the first time anyone asks for a channel, with no messages yet
        FMLog("Recent messages for %@: %lu chat messages (%lu deleted) in %lu lines in %.1fs (%@)", _channelLogin, (unsigned long)messages.count, (unsigned long)deletedIDs.count, (unsigned long)lines.count, duration,
              isNull(json[@"error_code"]) ? @"no error" : json[@"error_code"]);
    }
    self.done = YES;
    dispatch_group_leave(_request);
}

- (void)whenDone:(dispatch_block_t)block {
    dispatch_group_notify(_request, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), block);
}

@end
