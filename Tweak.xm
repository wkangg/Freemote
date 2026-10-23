#import "Tweak.h"
#import "FMEmoteManager.h"
#import "FMLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Emote tokens we inject get this ID prefix, so their image requests can be recognized and redirected
#define FMEmoteIDPrefix @"freemote_"

// How long a chat history response is held back waiting for the channel's emotes
#define FMHistoryEmoteTimeout 5

static Class EmoteToken, TextToken, MessagesReceived;
static FMEmoteManager *emoteManager;
static dispatch_queue_t emoteQueue;

// Chat messages don't say which channel they're from, so it's looked up by message ID from the
// channel event they arrived in, and that event's channel name from the join call
static NSMutableDictionary<NSString *, NSString *> *channelIDsByName; // @synchronized
static NSCache<NSString *, NSString *> *channelIDsByMessageID;
// VOD chat doesn't say whose video it is either, so that's looked up
static NSCache<NSString *, NSString *> *channelIDsByVideoID;

// Splits text at emote names, but only if it contains one: returns NO without calling either block otherwise
static BOOL splitTextAtEmotes(NSString *text, NSDictionary<NSString *, BTTVEmote *> *nameRegistry, void (^onText)(NSString *text), void (^onEmote)(NSString *name, NSString *emoteID)) {
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    NSMutableString *pendingText = [[NSMutableString alloc] init];
    BOOL foundEmote = NO;
    for(NSUInteger i = 0; i < words.count; i++) {
        BTTVEmote *emote = nameRegistry[words[i]];
        if(emote) {
            foundEmote = YES;
            if(pendingText.length)
                onText([pendingText copy]);
            [pendingText setString:@""];
            onEmote(words[i], [FMEmoteIDPrefix stringByAppendingString:emote.emoteID]);
        } else {
            [pendingText appendString:words[i]];
        }
        if(i + 1 < words.count)
            [pendingText appendString:@" "];
    }

    if(foundEmote && pendingText.length)
        onText([pendingText copy]);
    return foundEmote;
}

static NSArray *substituteBTTVStringsWithEmoteTokens(NSArray *tokens, NSDictionary<NSString *, BTTVEmote *> *nameRegistry) {
    if(nameRegistry.count == 0)
        return tokens;

    NSMutableArray *newTokens = [[NSMutableArray alloc] init];
    for(id token in tokens) {
        KMPMCMessageTokenTextToken *textToken = token;
        if(![token isKindOfClass:TextToken]) {
            [newTokens addObject:token];
            continue;
        }

        // flags is non-null in Kotlin and holds per-token AutoMod levels, so every split piece keeps it
        id flags = textToken.flags;
        BOOL foundEmote = splitTextAtEmotes(textToken.text, nameRegistry, ^(NSString *text) {
            [newTokens addObject:[[TextToken alloc] initWithText:text flags:flags]];
        }, ^(NSString *name, NSString *emoteID) {
            [newTokens addObject:[[EmoteToken alloc] initWithText:name id:emoteID]];
        });
        if(!foundEmote)
            [newTokens addObject:token];
    }

    return newTokens;
}

// Turns e.g. https://static-cdn.jtvnw.net/emoticons/v1/freemote_<id>/2.0 into the BTTV/FFZ/7TV image URL
static NSURL *rewriteEmoteURL(NSURL *url) {
    NSString *path = url.path;
    if(!path)
        return url;

    NSRange prefixRange = [path rangeOfString:@"/" FMEmoteIDPrefix];
    if(prefixRange.location == NSNotFound)
        return url;

    NSString *emoteID = [path substringFromIndex:NSMaxRange(prefixRange)].pathComponents.firstObject;
    NSURL *imageURL = [emoteManager imageURLForBTTVEmoteID:emoteID];
    if(!imageURL)
        FMLogFirst(10, "No image for emote %{public}@ (%{public}@)", emoteID, url);
    return imageURL ?: url;
}

static BOOL isChannelID(NSString *channelID) {
    return [channelID isKindOfClass:[NSString class]] && channelID.length
        && [channelID rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound;
}

// Only on emoteQueue
static void loadChannelEmotesNow(NSString *channelID) {
    if([emoteManager hasEmotesForChannel:channelID])
        return;
    NSDate *start = [NSDate date];
    [emoteManager loadEmotesForChannel:channelID];
    FMLog("Loaded %lu emotes for channel %{public}@ in %.1fs", (unsigned long)[emoteManager emoteNameRegistryForChannel:channelID].count, channelID, -start.timeIntervalSinceNow);
}

static void loadChannelEmotes(NSString *channelID, dispatch_block_t completion) {
    dispatch_async(emoteQueue, ^{
        loadChannelEmotesNow(channelID);
        if(completion)
            completion();
    });
}

// Looks up the video's channel, then loads its emotes
static void loadVideoEmotes(NSString *videoID, dispatch_block_t completion) {
    dispatch_async(emoteQueue, ^{
        NSString *channelID = [channelIDsByVideoID objectForKey:videoID];
        if(!channelID) {
            channelID = [emoteManager.httpClient ownerIDForVideoID:videoID];
            if(isChannelID(channelID))
                [channelIDsByVideoID setObject:channelID forKey:videoID];
        }
        if(isChannelID(channelID))
            loadChannelEmotesNow(channelID);
        if(completion)
            completion();
    });
}

static NSDictionary<NSString *, BTTVEmote *> *waitForChannelEmotes(NSString *channelID) {
    if(![emoteManager hasEmotesForChannel:channelID]) {
        FMLog("Chat history for channel %{public}@ is waiting for its emotes", channelID);
        dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
        loadChannelEmotes(channelID, ^{
            dispatch_semaphore_signal(loaded);
        });
        if(dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, FMHistoryEmoteTimeout * NSEC_PER_SEC)))
            FMLog("Timed out loading emotes for channel %{public}@ chat history", channelID);
    }
    return [emoteManager emoteNameRegistryForChannel:channelID];
}

static NSDictionary<NSString *, BTTVEmote *> *waitForVideoEmotes(NSString *videoID) {
    NSString *channelID = [channelIDsByVideoID objectForKey:videoID];
    if(!channelID || ![emoteManager hasEmotesForChannel:channelID]) {
        FMLog("VOD chat for video %{public}@ is waiting for its emotes", videoID);
        dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
        loadVideoEmotes(videoID, ^{
            dispatch_semaphore_signal(loaded);
        });
        if(dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, FMHistoryEmoteTimeout * NSEC_PER_SEC)))
            FMLog("Timed out loading emotes for video %{public}@ chat", videoID);
        channelID = [channelIDsByVideoID objectForKey:videoID];
    }
    return [emoteManager emoteNameRegistryForChannel:channelID];
}

#pragma mark - Chat history

// Chat history (ChatHistory, TheaterPortalPreload) and VOD chat (VideoCommentsBy*) come from GQL instead of KMPMobileChat
static NSSet<NSString *> *chatHistoryOperations;

// The variables of each chat history operation in the request
static NSArray<NSDictionary *> *chatHistoryVariables(NSURLRequest *request, BOOL log) {
    if(![request.URL.host isEqualToString:@"gql.twitch.tv"] || !request.HTTPBody)
        return @[];

    id json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    NSMutableArray *variablesList = [[NSMutableArray alloc] init];
    for(NSDictionary *operation in [json isKindOfClass:[NSArray class]] ? json : @[json ?: @{}]) {
        if(![operation isKindOfClass:[NSDictionary class]] || ![chatHistoryOperations containsObject:operation[@"operationName"]])
            continue;
        if(log)
            FMLog("Holding back %{public}@ response to add emotes", operation[@"operationName"]);
        NSDictionary *variables = operation[@"variables"];
        [variablesList addObject:[variables isKindOfClass:[NSDictionary class]] ? variables : @{}];
    }
    return variablesList;
}

// VOD comment queries only have the video ID (numeric, like channel IDs)
static NSString *chatHistoryVideoID(NSURLRequest *request) {
    for(NSDictionary *variables in chatHistoryVariables(request, NO)) {
        if(isChannelID(variables[@"videoID"]))
            return variables[@"videoID"];
    }
    return nil;
}

static BOOL isChatHistoryRequest(NSURLRequest *request) {
    NSArray<NSDictionary *> *variablesList = chatHistoryVariables(request, YES);
    // Start on the emotes now so the response doesn't have to wait as long
    for(NSDictionary *variables in variablesList) {
        if(isChannelID(variables[@"channelID"]))
            loadChannelEmotes(variables[@"channelID"], nil);
        if(isChannelID(variables[@"videoID"]))
            loadVideoEmotes(variables[@"videoID"], nil);
    }
    return variablesList.count > 0;
}

static NSArray *addEmotesToFragments(NSArray *fragments, NSDictionary<NSString *, BTTVEmote *> *nameRegistry, NSUInteger *emoteCount) {
    NSMutableArray *newFragments = [[NSMutableArray alloc] init];
    for(NSDictionary *fragment in fragments) {
        // Plain text fragments have no content
        if(![fragment isKindOfClass:[NSDictionary class]] || ![fragment[@"text"] isKindOfClass:[NSString class]]
           || (fragment[@"content"] && fragment[@"content"] != [NSNull null])) {
            [newFragments addObject:fragment];
            continue;
        }

        BOOL foundEmote = splitTextAtEmotes(fragment[@"text"], nameRegistry, ^(NSString *text) {
            [newFragments addObject:@{@"__typename": @"MessageFragment", @"text": text, @"content": [NSNull null]}];
        }, ^(NSString *name, NSString *emoteID) {
            [newFragments addObject:@{@"__typename": @"MessageFragment", @"text": name, @"content": @{@"__typename": @"Emote", @"emoteID": emoteID, @"setID": @"", @"token": name}}];
            (*emoteCount)++;
        });
        if(!foundEmote)
            [newFragments addObject:fragment];
    }
    return newFragments;
}

// Finds every channel { id recentChatMessages { content { contentFragments|messageFragments } } } in a response
static void addEmotesToChatHistory(id json) {
    if([json isKindOfClass:[NSArray class]]) {
        for(id item in json)
            addEmotesToChatHistory(item);
        return;
    }
    if(![json isKindOfClass:[NSMutableDictionary class]])
        return;

    NSArray *messages = json[@"recentChatMessages"];
    if([messages isKindOfClass:[NSArray class]] && isChannelID(json[@"id"])) {
        NSDate *start = [NSDate date];
        NSDictionary<NSString *, BTTVEmote *> *nameRegistry = waitForChannelEmotes(json[@"id"]);
        NSTimeInterval waited = -start.timeIntervalSinceNow;
        NSUInteger emoteCount = 0, withoutFragments = 0;
        for(NSDictionary *message in messages) {
            NSMutableDictionary *content = [message isKindOfClass:[NSDictionary class]] ? message[@"content"] : nil;
            BOOL hasFragments = NO;
            if([content isKindOfClass:[NSMutableDictionary class]]) {
                for(NSString *key in @[@"contentFragments", @"messageFragments"]) {
                    if([content[key] isKindOfClass:[NSArray class]]) {
                        content[key] = addEmotesToFragments(content[key], nameRegistry, &emoteCount);
                        hasFragments = YES;
                    }
                }
            }
            if(!hasFragments)
                withoutFragments++;
        }
        // Many messages without fragments means the response shape changed
        FMLog("Chat history for channel %{public}@: added %lu emotes to %lu messages (%lu without fragments, %lu emote names, waited %.1fs)",
              json[@"id"], (unsigned long)emoteCount, (unsigned long)messages.count, (unsigned long)withoutFragments, (unsigned long)nameRegistry.count, waited);
        return;
    }

    for(id value in [json allValues])
        addEmotesToChatHistory(value);
}

static NSUInteger codePointCount(NSString *text) {
    return [text lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / 4;
}

static BOOL isNull(id value) {
    return !value || value == [NSNull null];
}

// VOD comment fragments: plain text has no emote or mention. Emotes say where they are in the message (in code
// points, `to` inclusive), so offsets are counted over every fragment.
static NSArray *addEmotesToVideoCommentFragments(NSArray *fragments, NSDictionary<NSString *, BTTVEmote *> *nameRegistry, NSUInteger *emoteCount) {
    NSMutableArray *newFragments = [[NSMutableArray alloc] init];
    __block NSUInteger offset = 0;
    for(NSDictionary *fragment in fragments) {
        NSString *text = [fragment isKindOfClass:[NSDictionary class]] ? fragment[@"text"] : nil;
        if(![text isKindOfClass:[NSString class]]) {
            [newFragments addObject:fragment];
            continue;
        }
        NSUInteger fragmentEnd = offset + codePointCount(text);
        if(!isNull(fragment[@"emote"]) || !isNull(fragment[@"mention"])) {
            [newFragments addObject:fragment];
            offset = fragmentEnd;
            continue;
        }

        NSString *typename = fragment[@"__typename"] ?: @"VideoCommentMessageFragment";
        BOOL foundEmote = splitTextAtEmotes(text, nameRegistry, ^(NSString *piece) {
            [newFragments addObject:@{@"__typename": typename, @"text": piece, @"emote": [NSNull null], @"mention": [NSNull null]}];
            offset += codePointCount(piece);
        }, ^(NSString *name, NSString *emoteID) {
            NSUInteger length = codePointCount(name);
            [newFragments addObject:@{@"__typename": typename, @"text": name, @"mention": [NSNull null], @"emote": @{
                @"__typename": @"EmbeddedEmote", @"emoteID": emoteID, @"id": emoteID, @"setID": @"", @"from": @(offset), @"to": @(offset + length - 1)
            }}];
            offset += length;
            (*emoteCount)++;
        });
        if(!foundEmote)
            [newFragments addObject:fragment];
        offset = fragmentEnd;
    }
    return newFragments;
}

// Finds every comments { edges { node { message { messageFragments } } } } in a response
static void addEmotesToVideoComments(id json, NSDictionary<NSString *, BTTVEmote *> *nameRegistry, NSUInteger *emoteCount, NSUInteger *commentCount) {
    if([json isKindOfClass:[NSArray class]]) {
        for(id item in json)
            addEmotesToVideoComments(item, nameRegistry, emoteCount, commentCount);
        return;
    }
    if(![json isKindOfClass:[NSMutableDictionary class]])
        return;

    NSArray *edges = json[@"edges"];
    if([edges isKindOfClass:[NSArray class]]) {
        for(NSDictionary *edge in edges) {
            NSDictionary *node = [edge isKindOfClass:[NSDictionary class]] ? edge[@"node"] : nil;
            NSMutableDictionary *message = [node isKindOfClass:[NSDictionary class]] ? node[@"message"] : nil;
            if([message isKindOfClass:[NSMutableDictionary class]] && [message[@"messageFragments"] isKindOfClass:[NSArray class]]) {
                message[@"messageFragments"] = addEmotesToVideoCommentFragments(message[@"messageFragments"], nameRegistry, emoteCount);
                (*commentCount)++;
            }
        }
        return;
    }

    for(id value in [json allValues])
        addEmotesToVideoComments(value, nameRegistry, emoteCount, commentCount);
}

static NSData *chatHistoryDataWithEmotes(NSData *data, NSURLRequest *request) {
    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if(!json) {
        FMLog("Chat history isn't JSON (%lu bytes), left as is: %{public}@", (unsigned long)data.length, error.localizedDescription);
        return data;
    }
    addEmotesToChatHistory(json);

    NSString *videoID = chatHistoryVideoID(request);
    if(videoID) {
        NSDate *start = [NSDate date];
        NSDictionary<NSString *, BTTVEmote *> *nameRegistry = waitForVideoEmotes(videoID);
        NSUInteger emoteCount = 0, commentCount = 0;
        addEmotesToVideoComments(json, nameRegistry, &emoteCount, &commentCount);
        // No comments means the response shape changed
        FMLog("VOD chat for video %{public}@ (channel %{public}@): added %lu emotes to %lu comments (%lu emote names, waited %.1fs)",
              videoID, [channelIDsByVideoID objectForKey:videoID], (unsigned long)emoteCount, (unsigned long)commentCount, (unsigned long)nameRegistry.count, -start.timeIntervalSinceNow);
    }

    NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if(!newData)
        FMLog("Couldn't serialize chat history, left as is: %{public}@", error.localizedDescription);
    return newData ?: data;
}

static char chatHistoryBufferKey;

// The response buffer for a chat history task, or nil for any other task
static NSMutableData *chatHistoryBuffer(NSURLSessionTask *task) {
    id buffer = objc_getAssociatedObject(task, &chatHistoryBufferKey);
    if(!buffer) {
        buffer = isChatHistoryRequest(task.originalRequest) ? [[NSMutableData alloc] init] : [NSNull null];
        objc_setAssociatedObject(task, &chatHistoryBufferKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return [buffer isKindOfClass:[NSMutableData class]] ? buffer : nil;
}

// Apollo collects a task's data and only parses it on completion, so hold the chunks back and hand over
// the rewritten response right before that
%hook ApolloURLSessionClient

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSMutableData *buffer = chatHistoryBuffer(dataTask);
    if(buffer)
        [buffer appendData:data];
    else
        %orig;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSMutableData *buffer = chatHistoryBuffer(task);
    if(buffer && [task isKindOfClass:[NSURLSessionDataTask class]]) {
        objc_setAssociatedObject(task, &chatHistoryBufferKey, [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(error)
            FMLog("Chat history request failed, left as is: %{public}@", error.localizedDescription);
        NSData *data = error ? buffer : chatHistoryDataWithEmotes(buffer, task.originalRequest);
        if(data.length)
            [self URLSession:session dataTask:(NSURLSessionDataTask *)task didReceiveData:data];
    }
    %orig;
}

%end

#pragma mark - Live chat

static NSString *chatMessageID(KMPMCChatMessageInfo *messageInfo) {
    // `id` can't be declared as a property, so call the getter directly
    NSString *messageID = ((id (*)(id, SEL))objc_msgSend)(messageInfo, sel_registerName("id"));
    return [messageID isKindOfClass:[NSString class]] && messageID.length ? messageID : nil;
}

static NSString *channelKey(NSString *channelName) {
    return [channelName isKindOfClass:[NSString class]] ? [channelName.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"#"]] : nil;
}

// Logs each kind of chat event the first time it shows up: messages that arrive through an event type
// other than MessagesReceived aren't tagged with a channel
static void logChatEventType(id event, NSString *channelName) {
    static NSMutableSet<NSString *> *seenTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seenTypes = [[NSMutableSet alloc] init];
    });

    NSString *type = event ? NSStringFromClass([event class]) : @"nil";
    @synchronized(seenTypes) {
        if([seenTypes containsObject:type])
            return;
        [seenTypes addObject:type];
    }
    FMLog("First chat event %{public}@ (chat %{public}@)", type, channelName);
}

// For figuring out where an untagged message came from
static NSString *describeChatMessage(KMPMCChatMessageInfo *messageInfo, NSArray *tokens) {
    NSMutableString *text = [[NSMutableString alloc] init];
    for(id token in tokens) {
        if([token isKindOfClass:TextToken])
            [text appendString:((KMPMCMessageTokenTextToken *)token).text ?: @""];
        else
            [text appendFormat:@"[%@]", NSStringFromClass([token class])];
    }
    if(text.length > 80)
        [text replaceCharactersInRange:NSMakeRange(80, text.length - 80) withString:@"..."];

    NSString *type = [messageInfo respondsToSelector:@selector(messageType)] ? messageInfo.messageType : nil;
    BOOL sharedChat = [messageInfo respondsToSelector:@selector(sourceInfo)] && messageInfo.sourceInfo;
    NSDictionary *tags = messageInfo.messageTags;
    NSArray *tagNames = [tags isKindOfClass:[NSDictionary class]] ? tags.allKeys : nil;
    return [NSString stringWithFormat:@"id %@, type %@, shared chat %@, tags [%@], text \"%@\"",
            chatMessageID(messageInfo), type, sharedChat ? @"yes" : @"no", [tagNames componentsJoinedByString:@","], text];
}

%group KMP

%hook KMPMCChatEvent

// Swift reads the event to get at its messages, so tag them with this event's channel on the way
- (id)event {
    id event = %orig;
    logChatEventType(event, self.channelName);
    if(![event isKindOfClass:MessagesReceived])
        return event;

    NSString *channelName = channelKey(self.channelName), *channelID;
    NSArray *joinedNames;
    @synchronized(channelIDsByName) {
        channelID = channelName ? channelIDsByName[channelName] : nil;
        joinedNames = channelID ? nil : channelIDsByName.allKeys;
    }
    if(!channelID) {
        FMLogFirst(5, "No channel ID for chat %{public}@ (joined: %{public}@)", channelName, [joinedNames componentsJoinedByString:@", "]);
        return event;
    }

    for(KMPMCChatLiveMessage *message in [event messageList]) {
        NSString *messageID = chatMessageID(message.messageInfo);
        if(messageID)
            [channelIDsByMessageID setObject:channelID forKey:messageID];
    }
    return event;
}

%end

%hook KMPMCChatMessageInfo

- (NSArray *)tokens {
    NSArray *tokens = %orig;

    // Several channels' chats can be joined at once (e.g. your own in the background), so use the message's channel
    NSString *messageID = chatMessageID(self);
    NSString *channelID = messageID ? [channelIDsByMessageID objectForKey:messageID] : nil;
    if(!channelID)
        FMLogFirst(10, "Message has no known channel, using global emotes: %{public}@", describeChatMessage(self, tokens));

    return substituteBTTVStringsWithEmoteTokens(tokens, [emoteManager emoteNameRegistryForChannel:channelID]);
}

%end

%end

%group KMPConnectionManager

%hook ChatConnectionManager

- (id)joinChannelName:(NSString *)channelName channelId:(NSString *)channelID {
    NSString *key = channelKey(channelName);
    if(key && isChannelID(channelID)) {
        @synchronized(channelIDsByName) {
            channelIDsByName[key] = channelID;
        }
        FMLog("Joining chat %{public}@ (%{public}@)", key, channelID);
    }
    return %orig;
}

%end

%end

%group KMPFactory

%hook KMPMCChatConnectionManagerFactory

// The connection manager is a Kotlin class without an ObjC name, so hook whatever class the factory returns
- (id)iosCreateSocketFactory:(id)socketFactory logger:(id)logger userEmoteSetsRepository:(id)userEmoteSetsRepository bitsConfigRepository:(id)bitsConfigRepository chatModeratorActionsRepository:(id)chatModeratorActionsRepository messageBatchingConfig:(id)messageBatchingConfig channelSettingsRepository:(id)channelSettingsRepository eventLogger:(id)eventLogger experimentHelper:(id)experimentHelper sendChatMessageApi:(id)sendChatMessageApi pageLoadTimeProvider:(id)pageLoadTimeProvider {
    id manager = %orig;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class managerClass = object_getClass(manager);
        if(class_getInstanceMethod(managerClass, @selector(joinChannelName:channelId:))) {
            %init(KMPConnectionManager, ChatConnectionManager = managerClass);
            FMLog("Hooked chat joins");
        } else {
            FMLog("KMPMobileChat API changed, not hooking chat joins");
        }
    });
    return manager;
}

%end

%end

// Kotlin/Native adds a class's ObjC methods in its +initialize, and the factory is used before any channel
// is joined, so it's hooked right then. Don't look its methods up any earlier: the method resolver runs
// +initialize, i.e. this hook, from inside the lookup.
%hook KMPMCBase

+ (void)initialize {
    %orig;
    if(self != objc_getClass("KMPMCChatConnectionManagerFactory"))
        return;
    if(class_getInstanceMethod(self, @selector(iosCreateSocketFactory:logger:userEmoteSetsRepository:bitsConfigRepository:chatModeratorActionsRepository:messageBatchingConfig:channelSettingsRepository:eventLogger:experimentHelper:sendChatMessageApi:pageLoadTimeProvider:))) {
        %init(KMPFactory);
    } else {
        FMLog("KMPMobileChat API changed, not hooking chat joins");
    }
}

%end

// The other classes are touched here instead. Called from the chat join hooks, i.e. after the Kotlin runtime is up.
static void hookKMPIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class messageInfo = objc_getClass("KMPMCChatMessageInfo");
        Class chatEvent = objc_getClass("KMPMCChatEvent");
        Class liveMessage = objc_getClass("KMPMCChatLiveMessage");
        TextToken = objc_getClass("KMPMCMessageTokenTextToken");
        EmoteToken = objc_getClass("KMPMCMessageTokenEmoteToken");
        MessagesReceived = objc_getClass("KMPMCChannelEventChatChannelMessagesReceived");
        [messageInfo class];
        [chatEvent class];
        [liveMessage class];
        [TextToken class];
        [EmoteToken class];
        [MessagesReceived class];

        if(class_getInstanceMethod(messageInfo, @selector(tokens))
           && class_getInstanceMethod(messageInfo, sel_registerName("id"))
           && class_getInstanceMethod(chatEvent, @selector(event))
           && class_getInstanceMethod(chatEvent, @selector(channelName))
           && class_getInstanceMethod(liveMessage, @selector(messageInfo))
           && class_getInstanceMethod(MessagesReceived, @selector(messageList))
           && class_getInstanceMethod(TextToken, @selector(initWithText:flags:))
           && class_getInstanceMethod(EmoteToken, @selector(initWithText:id:))) {
            %init(KMP);
            FMLog("Hooked chat messages");
        } else {
            FMLog("KMPMobileChat API changed, not hooking chat messages");
        }
    });
}

static void joinedChannel(id channelID) {
    hookKMPIfNeeded();

    NSString *channel = [NSString stringWithFormat:@"%@", channelID];
    FMLog("Joined channel %{public}@", channel);
    if(isChannelID(channel))
        loadChannelEmotes(channel, nil);
}

// KMPMobileChat calls into these Swift repositories (through ObjC) when it joins a channel's chat
%hook ChannelSettingsRepository

- (id)observeChannelSettingsChannelId:(id)channelID {
    joinedChannel(channelID);
    return %orig;
}

%end

%hook BitsConfigRepository

- (id)observeBitsConfigForChannelChannelId:(id)channelID {
    joinedChannel(channelID);
    return %orig;
}

%end

#pragma mark - Emote images

%hook NSURLRequest

- (instancetype)initWithURL:(NSURL *)url cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeoutInterval {
    return %orig(rewriteEmoteURL(url), cachePolicy, timeoutInterval);
}

%end

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)url {
    %orig(rewriteEmoteURL(url));
}

%end

%ctor {
    emoteManager = [[FMEmoteManager alloc] init];
    emoteQueue = dispatch_queue_create("com.gilesgc.freemote.emotes", DISPATCH_QUEUE_SERIAL);
    chatHistoryOperations = [NSSet setWithArray:@[@"ChatHistory", @"TheaterPortalPreload", @"VideoCommentsByContentOffset", @"VideoCommentsByCursor"]];
    channelIDsByName = [[NSMutableDictionary alloc] init];
    channelIDsByMessageID = [[NSCache alloc] init];
    channelIDsByMessageID.countLimit = 5000;
    channelIDsByVideoID = [[NSCache alloc] init];
    %init(ChannelSettingsRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager25ChannelSettingsRepository"), BitsConfigRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager20BitsConfigRepository"), ApolloURLSessionClient = objc_getClass("_TtC6Apollo16URLSessionClient"));
}
