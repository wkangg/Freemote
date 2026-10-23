#import "Tweak.h"
#import "FMEmoteManager.h"
#import <objc/runtime.h>

// Emote tokens we inject get this ID prefix, so their image requests can be recognized and redirected
#define FMEmoteIDPrefix @"freemote_"

static Class EmoteToken, TextToken;
static FMEmoteManager *emoteManager;
static dispatch_queue_t emoteQueue;
static NSString *currentChannelID; // only touched on emoteQueue

static NSArray *substituteBTTVStringsWithEmoteTokens(NSArray *tokens) {
    NSDictionary<NSString *, BTTVEmote *> *nameRegistry = emoteManager.emoteNameRegistry;
    if(nameRegistry.count == 0)
        return tokens;

    NSMutableArray *newTokens = [[NSMutableArray alloc] init];
    for(id token in tokens) {
        // Flagged (AutoMod) text carries character ranges that splitting would invalidate
        KMPMCMessageTokenTextToken *textToken = token;
        if(![token isKindOfClass:TextToken] || textToken.flags) {
            [newTokens addObject:token];
            continue;
        }

        NSArray<NSString *> *words = [textToken.text componentsSeparatedByString:@" "];
        NSMutableString *pendingText = [[NSMutableString alloc] init];
        BOOL foundEmote = NO;
        for(NSUInteger i = 0; i < words.count; i++) {
            BTTVEmote *emote = nameRegistry[words[i]];
            if(emote) {
                foundEmote = YES;
                if(pendingText.length)
                    [newTokens addObject:[[TextToken alloc] initWithText:[pendingText copy] flags:nil]];
                [pendingText setString:@""];
                [newTokens addObject:[[EmoteToken alloc] initWithText:words[i] id:[FMEmoteIDPrefix stringByAppendingString:emote.emoteID]]];
            } else {
                [pendingText appendString:words[i]];
            }
            if(i + 1 < words.count)
                [pendingText appendString:@" "];
        }

        if(!foundEmote)
            [newTokens addObject:token];
        else if(pendingText.length)
            [newTokens addObject:[[TextToken alloc] initWithText:[pendingText copy] flags:nil]];
    }

    return newTokens;
}

// Turns e.g. https://static-cdn.jtvnw.net/emoticons/v2/freemote_<id>/default/dark/2.0 into the BTTV/FFZ image URL
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

%group KMP

%hook KMPMCChatMessageInfo

- (NSArray *)tokens {
    NSArray *tokens = %orig;
    return substituteBTTVStringsWithEmoteTokens(tokens);
}

%end

%end

// Kotlin/Native adds its ObjC methods in +initialize, so these hooks can only be installed once the
// classes have been touched. Called from the chat join hooks, i.e. after the Kotlin runtime is up.
static void hookKMPIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class messageInfo = objc_getClass("KMPMCChatMessageInfo");
        TextToken = objc_getClass("KMPMCMessageTokenTextToken");
        EmoteToken = objc_getClass("KMPMCMessageTokenEmoteToken");
        [messageInfo class];
        [TextToken class];
        [EmoteToken class];

        if(class_getInstanceMethod(messageInfo, @selector(tokens))
           && class_getInstanceMethod(TextToken, @selector(initWithText:flags:))
           && class_getInstanceMethod(EmoteToken, @selector(initWithText:id:)))
            %init(KMP);
        else
            NSLog(@"[Freemote] KMPMobileChat API changed, not hooking chat messages");
    });
}

static void joinedChannel(id channelID) {
    hookKMPIfNeeded();

    NSString *channel = [NSString stringWithFormat:@"%@", channelID];
    if(channel.length == 0 || [channel rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location != NSNotFound)
        return;

    dispatch_async(emoteQueue, ^{
        if([channel isEqualToString:currentChannelID])
            return;
        currentChannelID = channel;
        [emoteManager updateEmoteRegistry:channel];
    });
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
    %init(ChannelSettingsRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager25ChannelSettingsRepository"),
          BitsConfigRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager20BitsConfigRepository"));
    emoteManager = [[FMEmoteManager alloc] init];
    emoteQueue = dispatch_queue_create("com.gilesgc.freemote.emotes", DISPATCH_QUEUE_SERIAL);
}
