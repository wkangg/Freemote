#import "Tweak.h"
#import "FMEmoteManager.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

// NSLog redacts arguments as <private> on device
#define FMLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[Freemote] " fmt, ##__VA_ARGS__)

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
    return [emoteManager imageURLForBTTVEmoteID:emoteID] ?: url;
}

static BOOL isChannelID(NSString *channelID) {
    return [channelID isKindOfClass:[NSString class]] && channelID.length
        && [channelID rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound;
}

static void loadChannelEmotes(NSString *channelID, dispatch_block_t completion) {
    dispatch_async(emoteQueue, ^{
        if(![emoteManager hasEmotesForChannel:channelID]) {
            [emoteManager loadEmotesForChannel:channelID];
            FMLog("Loaded %lu emotes for channel %{public}@", (unsigned long)[emoteManager emoteNameRegistryForChannel:channelID].count, channelID);
        }
        if(completion)
            completion();
    });
}

static NSDictionary<NSString *, BTTVEmote *> *waitForChannelEmotes(NSString *channelID) {
    if(![emoteManager hasEmotesForChannel:channelID]) {
        dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
        loadChannelEmotes(channelID, ^{
            dispatch_semaphore_signal(loaded);
        });
        if(dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, FMHistoryEmoteTimeout * NSEC_PER_SEC)))
            FMLog("Timed out loading emotes for channel %{public}@ chat history", channelID);
    }
    return [emoteManager emoteNameRegistryForChannel:channelID];
}

#pragma mark - Chat history

// Chat history comes from GQL (ChatHistory, TheaterPortalPreload) instead of KMPMobileChat
static NSSet<NSString *> *chatHistoryOperations;

static BOOL isChatHistoryRequest(NSURLRequest *request) {
    if(![request.URL.host isEqualToString:@"gql.twitch.tv"] || !request.HTTPBody)
        return NO;

    id json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    BOOL isChatHistory = NO;
    for(NSDictionary *operation in [json isKindOfClass:[NSArray class]] ? json : @[json ?: @{}]) {
        if(![operation isKindOfClass:[NSDictionary class]] || ![chatHistoryOperations containsObject:operation[@"operationName"]])
            continue;
        isChatHistory = YES;

        // Start on the emotes now so the response doesn't have to wait as long
        NSDictionary *variables = operation[@"variables"];
        if([variables isKindOfClass:[NSDictionary class]] && isChannelID(variables[@"channelID"]))
            loadChannelEmotes(variables[@"channelID"], nil);
    }
    return isChatHistory;
}

static NSArray *addEmotesToFragments(NSArray *fragments, NSDictionary<NSString *, BTTVEmote *> *nameRegistry) {
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
        NSDictionary<NSString *, BTTVEmote *> *nameRegistry = waitForChannelEmotes(json[@"id"]);
        for(NSDictionary *message in messages) {
            NSMutableDictionary *content = [message isKindOfClass:[NSDictionary class]] ? message[@"content"] : nil;
            if(![content isKindOfClass:[NSMutableDictionary class]])
                continue;
            for(NSString *key in @[@"contentFragments", @"messageFragments"]) {
                if([content[key] isKindOfClass:[NSArray class]])
                    content[key] = addEmotesToFragments(content[key], nameRegistry);
            }
        }
        return;
    }

    for(id value in [json allValues])
        addEmotesToChatHistory(value);
}

static NSData *chatHistoryDataWithEmotes(NSData *data) {
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if(!json)
        return data;
    addEmotesToChatHistory(json);
    return [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] ?: data;
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
        NSData *data = error ? buffer : chatHistoryDataWithEmotes(buffer);
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

%group KMP

%hook KMPMCChatEvent

// Swift reads the event to get at its messages, so tag them with this event's channel on the way
- (id)event {
    id event = %orig;
    if(![event isKindOfClass:MessagesReceived])
        return event;

    NSString *channelName = channelKey(self.channelName), *channelID;
    @synchronized(channelIDsByName) {
        channelID = channelName ? channelIDsByName[channelName] : nil;
    }
    if(!channelID) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            FMLog("No channel ID for chat %{public}@", channelName);
        });
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
    if(!channelID) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            FMLog("Message has no known channel, using global emotes");
        });
    }

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

// Kotlin/Native adds a class's ObjC methods in its +initialize. The factory is used before any channel
// is joined, so it's hooked right then; returns whether it was.
static BOOL hookFactoryIfReady(Class cls) {
    static BOOL hooked;
    if(hooked || cls != objc_getClass("KMPMCChatConnectionManagerFactory")
       || !class_getInstanceMethod(cls, @selector(iosCreateSocketFactory:logger:userEmoteSetsRepository:bitsConfigRepository:chatModeratorActionsRepository:messageBatchingConfig:channelSettingsRepository:eventLogger:experimentHelper:sendChatMessageApi:pageLoadTimeProvider:)))
        return hooked;
    hooked = YES;
    %init(KMPFactory);
    return YES;
}

%hook KMPMCBase

+ (void)initialize {
    %orig;
    hookFactoryIfReady(self);
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
    chatHistoryOperations = [NSSet setWithArray:@[@"ChatHistory", @"TheaterPortalPreload"]];
    channelIDsByName = [[NSMutableDictionary alloc] init];
    channelIDsByMessageID = [[NSCache alloc] init];
    channelIDsByMessageID.countLimit = 5000;
    %init(ChannelSettingsRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager25ChannelSettingsRepository"), BitsConfigRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager20BitsConfigRepository"), ApolloURLSessionClient = objc_getClass("_TtC6Apollo16URLSessionClient"));
    // In case the Kotlin runtime was already set up before the tweak loaded
    if(!hookFactoryIfReady(objc_getClass("KMPMCChatConnectionManagerFactory")))
        FMLog("Waiting for KMPMobileChat to hook chat joins");
}
