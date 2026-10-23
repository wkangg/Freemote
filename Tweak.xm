#import <UIKit/UIKit.h>
#import "Tweak.h"
#import "FMEmoteManager.h"
#import "FMLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>


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
// Your own messages show up before the server gives them an ID, so they're found by the nonce they were sent with
static NSCache<NSString *, NSString *> *channelIDsByNonce;
static NSString *lastSentChannelID; // @synchronized(channelIDsByName)

// Zero-width and blank characters that chat clients add to get around Twitch's duplicate message check, and control
// characters (e.g. a line ending left on the message)
static BOOL isInvisibleCharacter(UTF32Char c) {
    return c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == 0xA0 || c == 0xAD || c == 0x034F || c == 0x115F || c == 0x1160 || c == 0x180E || (c >= 0x200B && c <= 0x200F) || (c >= 0x2060 && c <= 0x2064)
        || c == 0x2800 || c == 0x3164 || (c >= 0xFE00 && c <= 0xFE0F) || c == 0xFEFF || (c >= 0xE0000 && c <= 0xE007F);
}

// The range of the word without invisible characters at either end
static NSRange visibleRange(NSString *word) {
    NSUInteger start = 0, end = word.length;
    while(start < end) {
        // Code points, not composed sequences: U+034F etc. are combining, so they'd join the letter before them
        UTF32Char c = [word characterAtIndex:start];
        if(CFStringIsSurrogateHighCharacter(c) && start + 1 < end)
            c = CFStringGetLongCharacterForSurrogatePair(c, [word characterAtIndex:start + 1]);
        if(!isInvisibleCharacter(c))
            break;
        start += c > 0xFFFF ? 2 : 1;
    }
    while(end > start) {
        UTF32Char c = [word characterAtIndex:end - 1];
        NSUInteger length = 1;
        if(CFStringIsSurrogateLowCharacter(c) && end - 1 > start) {
            c = CFStringGetLongCharacterForSurrogatePair([word characterAtIndex:end - 2], c);
            length = 2;
        }
        if(!isInvisibleCharacter(c))
            break;
        end -= length;
    }
    return NSMakeRange(start, end - start);
}

static NSString *codePointsOf(NSString *word) {
    NSMutableArray *codePoints = [[NSMutableArray alloc] init];
    NSData *utf32 = [word dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *chars = (const uint32_t *)utf32.bytes;
    for(NSUInteger i = 0; i < utf32.length / 4; i++)
        [codePoints addObject:[NSString stringWithFormat:@"U+%04X", chars[i]]];
    return [codePoints componentsJoinedByString:@" "];
}

// For finding other characters that keep a word from matching: logs words that are an emote name once everything but
// letters and digits is taken out
static void logNearMiss(NSString *word, NSDictionary<NSString *, BTTVEmote *> *nameRegistry) {
    if([word rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet].invertedSet].location == NSNotFound)
        return;
    NSString *stripped = [[word componentsSeparatedByCharactersInSet:[NSCharacterSet alphanumericCharacterSet].invertedSet] componentsJoinedByString:@""];
    if(stripped.length && nameRegistry[stripped])
        FMLogFirst(10, "Word looks like emote %{public}@ but doesn't match: %{public}@", stripped, codePointsOf(word));
}

// Splits text at emote names, but only if it contains one: returns NO without calling either block otherwise.
// afterEmote: the text comes right after an emote, which a zero-width emote at its start goes over.
static BOOL splitTextAtEmotes(NSString *text, NSDictionary<NSString *, BTTVEmote *> *nameRegistry, BOOL afterEmote, void (^onText)(NSString *text), void (^onEmote)(NSString *name, NSString *emoteID)) {
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    NSMutableString *pendingText = [[NSMutableString alloc] init];
    BOOL foundEmote = NO, lastWasEmote = afterEmote;
    for(NSUInteger i = 0; i < words.count; i++) {
        NSString *word = words[i];
        NSRange nameRange = NSMakeRange(0, word.length);
        BTTVEmote *emote = nameRegistry[word];
        if(!emote && word.length) {
            nameRange = visibleRange(word);
            if(nameRange.length < word.length && nameRange.length)
                emote = nameRegistry[[word substringWithRange:nameRange]];
            if(!emote)
                logNearMiss(word, nameRegistry);
        }

        if(emote) {
            foundEmote = YES;
            // Invisible characters around the name stay as text
            [pendingText appendString:[word substringToIndex:nameRange.location]];
            // A zero-width emote goes right after the emote it's drawn over, without the space between them
            if(emote.isZeroWidth && lastWasEmote && [pendingText isEqualToString:@" "])
                [pendingText setString:@""];
            if(pendingText.length)
                onText([pendingText copy]);
            onEmote([word substringWithRange:nameRange], [FMEmoteIDPrefix stringByAppendingString:emote.emoteID]);
            lastWasEmote = YES;
            [pendingText setString:[word substringFromIndex:NSMaxRange(nameRange)]];
        } else {
            [pendingText appendString:word];
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
        BOOL afterEmote = [newTokens.lastObject isKindOfClass:EmoteToken];
        BOOL foundEmote = splitTextAtEmotes(textToken.text, nameRegistry, afterEmote, ^(NSString *text) {
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

// The GQL operations in a request: its body is one operation or a batch of them
static NSArray *gqlOperations(NSURLRequest *request) {
    if(![request.URL.host isEqualToString:@"gql.twitch.tv"] || !request.HTTPBody)
        return @[];

    id json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    return [json isKindOfClass:[NSArray class]] ? json : @[json ?: @{}];
}

// The variables of each chat history operation in the request
static NSArray<NSDictionary *> *chatHistoryVariables(NSURLRequest *request, BOOL log) {
    NSMutableArray *variablesList = [[NSMutableArray alloc] init];
    for(NSDictionary *operation in gqlOperations(request)) {
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

        NSDictionary *previousContent = [newFragments.lastObject isKindOfClass:[NSDictionary class]] ? newFragments.lastObject[@"content"] : nil;
        BOOL afterEmote = [previousContent isKindOfClass:[NSDictionary class]] && [@"Emote" isEqual:previousContent[@"__typename"]];
        BOOL foundEmote = splitTextAtEmotes(fragment[@"text"], nameRegistry, afterEmote, ^(NSString *text) {
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

        NSString *fragmentType = fragment[@"__typename"] ?: @"VideoCommentMessageFragment";
        NSDictionary *previous = newFragments.lastObject;
        BOOL afterEmote = [previous isKindOfClass:[NSDictionary class]] && !isNull(previous[@"emote"]);
        BOOL foundEmote = splitTextAtEmotes(text, nameRegistry, afterEmote, ^(NSString *piece) {
            [newFragments addObject:@{@"__typename": fragmentType, @"text": piece, @"emote": [NSNull null], @"mention": [NSNull null]}];
            offset += codePointCount(piece);
        }, ^(NSString *name, NSString *emoteID) {
            NSUInteger length = codePointCount(name);
            [newFragments addObject:@{@"__typename": fragmentType, @"text": name, @"mention": [NSNull null], @"emote": @{
                @"__typename": @"EmbeddedEmote", @"emoteID": emoteID, @"id": emoteID, @"setID": @"", @"from": @(offset), @"to": @(offset + length - 1)
            }}];
            offset += length;
            (*emoteCount)++;
        });
        // Offsets follow the split pieces, which leave out the space before a zero-width emote
        if(!foundEmote) {
            [newFragments addObject:fragment];
            offset = fragmentEnd;
        }
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

#pragma mark - Emote cards

// The emote whose card is open, if it's one of ours. Main thread only.
static BTTVEmote *emoteCardEmote;

// Our emote that an EmoteCard operation asks for, or nil
static BTTVEmote *emoteCardEmoteFor(NSDictionary *operation) {
    if(![operation isKindOfClass:[NSDictionary class]] || ![@"EmoteCard" isEqual:operation[@"operationName"]])
        return nil;
    NSDictionary *variables = operation[@"variables"];
    NSString *emoteID = [variables isKindOfClass:[NSDictionary class]] ? variables[@"emoteID"] : nil;
    if(![emoteID isKindOfClass:[NSString class]] || ![emoteID hasPrefix:FMEmoteIDPrefix])
        return nil;
    BTTVEmote *emote = emoteManager.emoteRegistry[[emoteID substringFromIndex:FMEmoteIDPrefix.length]];
    if(!emote)
        FMLogFirst(10, "Emote card for unknown emote %{public}@", emoteID);
    return emote;
}

// Whether the request is an emote card for one of our emotes. Every emote card request switches which card is open.
static BOOL isEmoteCardRequest(NSURLRequest *request) {
    BOOL isEmoteCard = NO;
    BTTVEmote *emote;
    for(NSDictionary *operation in gqlOperations(request)) {
        if([operation isKindOfClass:[NSDictionary class]] && [@"EmoteCard" isEqual:operation[@"operationName"]]) {
            isEmoteCard = YES;
            emote = emoteCardEmoteFor(operation);
        }
    }
    if(!isEmoteCard)
        return NO;

    if(emote)
        FMLog("Holding back the emote card for %{public}@ (%{public}@)", emote.emoteText, emote.emoteID);
    dispatch_async(dispatch_get_main_queue(), ^{
        emoteCardEmote = emote;
    });
    return emote != nil;
}

// Twitch doesn't know our emotes, so their cards get a made-up emote instead: a global one with no owner, which the
// card shows with just the image and name. The image goes through the URL rewrite like in chat.
static void addEmoteCards(id json, NSURLRequest *request) {
    NSArray *operations = gqlOperations(request);
    NSArray *responses = [json isKindOfClass:[NSArray class]] ? json : @[json];
    for(NSUInteger i = 0; i < operations.count && i < responses.count; i++) {
        BTTVEmote *emote = emoteCardEmoteFor(operations[i]);
        NSMutableDictionary *response = responses[i];
        if(!emote || ![response isKindOfClass:[NSMutableDictionary class]])
            continue;
        response[@"data"] = @{@"emote": @{
            @"__typename": @"Emote", @"id": [FMEmoteIDPrefix stringByAppendingString:emote.emoteID], @"token": emote.emoteText, @"setID": @"",
            @"type": @"GLOBALS", @"owner": [NSNull null], @"subscriptionProduct": [NSNull null], @"bitsBadgeTierSummary": [NSNull null]
        }};
        [response removeObjectForKey:@"errors"];
        FMLog("Answered the emote card for %{public}@", emote.emoteText);
    }
}

static id swiftIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static char emoteCardLinkKey;

// The made-up card says "Twitch Global Emote": say where the emote is really from, and link to its page
static void updateEmoteCardTitle(UIView *titleView, BTTVEmote *emote) {
    // Lazy Swift properties: nil until the card first uses them
    UITextView *titleTextView = swiftIvar(titleView, "$__lazy_storage_$_titleTextView");
    UILabel *subtitleLabel = swiftIvar(titleView, "$__lazy_storage_$_subtitleLabel");
    UIStackView *labelsStackView = swiftIvar(titleView, "$__lazy_storage_$_labelsStackView");
    if(![titleTextView isKindOfClass:[UITextView class]] || ![subtitleLabel isKindOfClass:[UILabel class]] || ![labelsStackView isKindOfClass:[UIStackView class]])
        return;
    // A Twitch emote's card that opened before its request went out
    if([titleTextView.text rangeOfString:emote.emoteText].location == NSNotFound)
        return;

    NSString *description = [emote emoteDescription];
    if(![subtitleLabel.text isEqualToString:description]) {
        subtitleLabel.text = description;
        subtitleLabel.hidden = NO;
    }

    if(!emote.pageURL || objc_getAssociatedObject(titleView, &emoteCardLinkKey))
        return;
    // A text view opens its links when tapped, like a link in chat
    NSURL *pageURL = emote.pageURL;
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = subtitleLabel.textAlignment;
    UITextView *link = [[UITextView alloc] init];
    link.attributedText = [[NSAttributedString alloc] initWithString:[pageURL.host stringByAppendingString:pageURL.path] attributes:@{
        NSLinkAttributeName: pageURL, NSFontAttributeName: subtitleLabel.font, NSParagraphStyleAttributeName: paragraphStyle
    }];
    // Twitch's link purple
    link.linkTextAttributes = @{NSForegroundColorAttributeName: [UIColor colorWithRed:0xA9 / 255.0 green:0x70 / 255.0 blue:0xFF / 255.0 alpha:1]};
    link.editable = NO;
    link.scrollEnabled = NO;
    link.backgroundColor = [UIColor clearColor];
    link.textContainerInset = UIEdgeInsetsZero;
    link.textContainer.lineFragmentPadding = 0;
    link.textContainer.maximumNumberOfLines = 1;
    link.textContainer.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [labelsStackView addArrangedSubview:link];
    objc_setAssociatedObject(titleView, &emoteCardLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FMLog("Added details to the emote card for %{public}@", emote.emoteText);
}

%hook EmoteCardTitleView

// The card fills in its labels after the view is created, so check whenever it lays out
- (void)layoutSubviews {
    %orig;
    if(emoteCardEmote)
        updateEmoteCardTitle((UIView *)self, emoteCardEmote);
}

%end

#pragma mark - Held back responses

static NSData *responseDataWithEmotes(NSData *data, NSURLRequest *request) {
    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if(!json) {
        FMLog("Held back response isn't JSON (%lu bytes), left as is: %{public}@", (unsigned long)data.length, error.localizedDescription);
        return data;
    }
    addEmotesToChatHistory(json);
    addEmoteCards(json, request);

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
        FMLog("Couldn't serialize held back response, left as is: %{public}@", error.localizedDescription);
    return newData ?: data;
}

static char heldResponseBufferKey;

// The response buffer for a chat history or emote card task, or nil for any other task
static NSMutableData *heldResponseBuffer(NSURLSessionTask *task) {
    id buffer = objc_getAssociatedObject(task, &heldResponseBufferKey);
    if(!buffer) {
        // Both checks have to run: they start loading emotes and track which emote card is open
        BOOL hold = isChatHistoryRequest(task.originalRequest);
        hold = isEmoteCardRequest(task.originalRequest) || hold;
        buffer = hold ? [[NSMutableData alloc] init] : [NSNull null];
        objc_setAssociatedObject(task, &heldResponseBufferKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return [buffer isKindOfClass:[NSMutableData class]] ? buffer : nil;
}

// Apollo collects a task's data and only parses it on completion, so hold the chunks back and hand over
// the rewritten response right before that
%hook ApolloURLSessionClient

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSMutableData *buffer = heldResponseBuffer(dataTask);
    if(buffer)
        [buffer appendData:data];
    else
        %orig;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSMutableData *buffer = heldResponseBuffer(task);
    if(buffer && [task isKindOfClass:[NSURLSessionDataTask class]]) {
        objc_setAssociatedObject(task, &heldResponseBufferKey, [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(error)
            FMLog("Held back request failed, left as is: %{public}@", error.localizedDescription);
        NSData *data = error ? buffer : responseDataWithEmotes(buffer, task.originalRequest);
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

// Your own message, before the server echoes it back with an ID: it only has the client-nonce tag it was sent with
static NSString *sentMessageChannelID(KMPMCChatMessageInfo *messageInfo) {
    NSDictionary *tags = messageInfo.messageTags;
    NSString *nonce = [tags isKindOfClass:[NSDictionary class]] ? tags[@"client-nonce"] : nil;
    if(![nonce isKindOfClass:[NSString class]])
        return nil;
    NSString *channelID = [channelIDsByNonce objectForKey:nonce];
    if(channelID)
        return channelID;
    // The app made up the nonce itself: it's most likely from the chat you last sent to
    @synchronized(channelIDsByName) {
        channelID = lastSentChannelID;
    }
    FMLogFirst(5, "Sent message's nonce %{public}@ is unknown, using the last chat sent to (%{public}@)", nonce, channelID);
    return channelID;
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
    // Messages from other event types (e.g. resubs) aren't tagged, but carry the chat's ID in room-id
    if(!channelID) {
        NSDictionary *tags = self.messageTags;
        NSString *roomID = [tags isKindOfClass:[NSDictionary class]] ? tags[@"room-id"] : nil;
        if(isChannelID(roomID))
            channelID = roomID;
    }
    if(!channelID)
        channelID = sentMessageChannelID(self);
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

%group KMPSend

%hook ChatConnectionManager

- (id)sendMessageChannelName:(NSString *)channelName message:(NSString *)message reply:(id)reply clientNonce:(NSString *)clientNonce {
    NSString *key = channelKey(channelName), *channelID;
    @synchronized(channelIDsByName) {
        channelID = key ? channelIDsByName[key] : nil;
        if(channelID)
            lastSentChannelID = channelID;
    }
    if(channelID && [clientNonce isKindOfClass:[NSString class]])
        [channelIDsByNonce setObject:channelID forKey:clientNonce];
    FMLogFirst(5, "Sending a message to chat %{public}@ (%{public}@, nonce %{public}@)", key, channelID, clientNonce);
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
        if(class_getInstanceMethod(managerClass, @selector(sendMessageChannelName:message:reply:clientNonce:))) {
            %init(KMPSend, ChatConnectionManager = managerClass);
            FMLog("Hooked sent messages");
        } else {
            FMLog("KMPMobileChat API changed, not hooking sent messages");
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

#pragma mark - Emote sizes

// Chat lays out an emote as a text attachment, then draws its image from the left edge of the attachment's space.
// Twitch sizes both by Twitch emote ID, which makes ours 28pt squares, so ours get their own width here: the
// attachment's bounds are the space it takes in the line, and MessageString's sizeOfImageAttachment(at:) is the size
// of the image drawn there.

// An empty glyph rect doesn't get its image drawn, so an emote always takes up a little space
#define FMMinimumEmoteAdvance 0.01

// Set once the image sizes are replaced: widening the attachments without them would draw images over the text
static Class MessageStringLayoutManager;

static BTTVEmote *emoteForToken(TWMessageEmoteToken *token) {
    NSString *emoteID = [token respondsToSelector:@selector(emoteId)] ? token.emoteId : nil;
    if(![emoteID isKindOfClass:[NSString class]] || ![emoteID hasPrefix:FMEmoteIDPrefix])
        return nil;
    return emoteManager.emoteRegistry[[emoteID substringFromIndex:FMEmoteIDPrefix.length]];
}

static NSDictionary<NSNumber *, TWMessageEmoteToken *> *emoteTokens(TWMessageString *messageString) {
    NSDictionary *tokens = [messageString respondsToSelector:@selector(emoteLocationsMap)] ? messageString.emoteLocationsMap : nil;
    return [tokens isKindOfClass:[NSDictionary class]] ? tokens : nil;
}

// Our emotes keep Twitch's height, with their own width
static CGSize emoteImageSize(BTTVEmote *emote, CGSize size) {
    if(emote.aspectRatio > 0)
        size.width = MAX(1, floor(size.height * emote.aspectRatio));
    return size;
}

// Swift calls sizeOfImageAttachment(at:) through the class's vtable rather than the ObjC method, so the vtable entry is
// replaced. A Swift method gets self in x20, which clang calls swift_context.
typedef __attribute__((swiftcall)) CGSize (*FMImageSizeFunction)(NSInteger index, __attribute__((swift_context)) void *messageString);
static FMImageSizeFunction originalMessageStringImageSize, originalChatMessageStringImageSize;

static CGSize messageStringImageSize(void *messageString, NSInteger index, CGSize size) {
    BTTVEmote *emote = emoteForToken(emoteTokens((__bridge TWMessageString *)messageString)[@(index)]);
    return emote ? emoteImageSize(emote, size) : size;
}

__attribute__((swiftcall)) static CGSize newMessageStringImageSize(NSInteger index, __attribute__((swift_context)) void *messageString) {
    return messageStringImageSize(messageString, index, originalMessageStringImageSize(index, messageString));
}

__attribute__((swiftcall)) static CGSize newChatMessageStringImageSize(NSInteger index, __attribute__((swift_context)) void *messageString) {
    return messageStringImageSize(messageString, index, originalChatMessageStringImageSize(index, messageString));
}

// The vtable entry for the Swift method behind an ObjC method: the ObjC method is a thunk that calls it directly, so
// it's whichever of the thunk's calls is also in the vtable
static void **swiftMethodEntry(Class cls, SEL selector) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    uint8_t *metadata = (uint8_t *)(__bridge void *)cls;
    // Swift class metadata: ObjC class data at 32 (bit 1 set for Swift), class size and address point at 56 and 60,
    // then the class's members (field offsets and the vtable) from 80
    if(!method || !(*(uintptr_t *)(metadata + 32) & 2))
        return NULL;
    uint32_t classSize = *(uint32_t *)(metadata + 56), addressPoint = *(uint32_t *)(metadata + 60);
    void **members = (void **)(metadata + 80);
    NSUInteger memberCount = classSize > addressPoint + 80 ? (classSize - addressPoint - 80) / sizeof(void *) : 0;

    const uint32_t *code = (const uint32_t *)method_getImplementation(method);
    for(int i = 0; i < 16 && code[i] != 0xD65F03C0; i++) { // up to ret
        if((code[i] & 0xFC000000) != 0x94000000) // bl
            continue;
        const uint32_t *target = code + i + ((int32_t)(code[i] << 6) >> 6);
        for(NSUInteger j = 0; j < memberCount; j++) {
            if(members[j] == target)
                return &members[j];
        }
    }
    return NULL;
}

static BOOL replaceSwiftMethod(void **entry, void *replacement, void **original) {
    // Class metadata is writable data already; this only makes sure
    if(vm_protect(mach_task_self(), (vm_address_t)entry & ~(vm_address_t)vm_page_mask, vm_page_size, NO, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)
        return NO;
    *original = *entry;
    *entry = replacement;
    return YES;
}

static void hookEmoteSizes(void) {
    SEL selector = @selector(sizeOfImageAttachmentAtCharacterIndex:);
    void **entry = swiftMethodEntry(objc_getClass("_TtC6Twitch13MessageString"), selector);
    void **chatEntry = swiftMethodEntry(objc_getClass("_TtC6Twitch17ChatMessageString"), selector);
    // Both or neither, so a message's attachments and images always agree
    if(entry && chatEntry && replaceSwiftMethod(entry, (void *)newMessageStringImageSize, (void **)&originalMessageStringImageSize)
       && replaceSwiftMethod(chatEntry, (void *)newChatMessageStringImageSize, (void **)&originalChatMessageStringImageSize)) {
        MessageStringLayoutManager = objc_getClass("_TtC6Twitch26MessageStringLayoutManager");
        FMLog("Hooked emote sizes");
    } else {
        FMLog("MessageString changed, emotes stay square (%d, %d)", entry != NULL, chatEntry != NULL);
    }
}

// The width an emote takes in the line. A zero-width emote is drawn over the emote before it: the emotes in such a
// stack start in the same place and take up as much space as the widest one. Each one after the first is centered
// as far as it can be, since an image can't start further left than the one before it.
static CGFloat emoteAdvance(NSDictionary<NSNumber *, TWMessageEmoteToken *> *tokens, NSTextStorage *textStorage, NSUInteger index, CGSize size) {
    BOOL (^isOverlay)(NSUInteger) = ^BOOL(NSUInteger i) {
        return i > 0 && i < textStorage.length && tokens[@(i - 1)] && emoteForToken(tokens[@(i)]).isZeroWidth;
    };
    CGFloat (^width)(NSUInteger) = ^CGFloat(NSUInteger i) {
        if(i == index)
            return emoteImageSize(emoteForToken(tokens[@(i)]), size).width;
        NSTextAttachment *attachment = [textStorage attribute:NSAttachmentAttributeName atIndex:i effectiveRange:NULL];
        return [attachment isKindOfClass:[NSTextAttachment class]] ? emoteImageSize(emoteForToken(tokens[@(i)]), attachment.bounds.size).width : 0;
    };

    NSUInteger first = index, last = index;
    while(isOverlay(first))
        first--;
    while(isOverlay(last + 1))
        last++;
    if(first == last)
        return width(index);

    CGFloat stackWidth = 0;
    for(NSUInteger i = first; i <= last; i++)
        stackWidth = MAX(stackWidth, width(i));
    // Where this emote's image and the next one's start, from the left of the stack
    CGFloat start = 0, nextStart = stackWidth;
    for(NSUInteger i = first + 1; i <= last; i++) {
        CGFloat centered = MAX(start, (stackWidth - width(i)) / 2);
        if(i > index) {
            nextStart = centered;
            break;
        }
        start = centered;
    }
    FMLogFirst(5, "Emote at %lu is stacked with %lu others, %.1fpt wide", (unsigned long)index, (unsigned long)(last - first), stackWidth);
    return MAX(FMMinimumEmoteAdvance, nextStart - start);
}

%hook NSTextAttachment

- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer *)textContainer proposedLineFragment:(CGRect)lineFragment glyphPosition:(CGPoint)position characterIndex:(NSUInteger)characterIndex {
    CGRect bounds = %orig;
    NSLayoutManager *layoutManager = textContainer.layoutManager;
    if(!MessageStringLayoutManager || ![layoutManager isKindOfClass:MessageStringLayoutManager])
        return bounds;
    NSDictionary<NSNumber *, TWMessageEmoteToken *> *tokens = emoteTokens(swiftIvar(layoutManager, "messageString"));
    if(tokens[@(characterIndex)]) {
        bounds.size.width = emoteAdvance(tokens, layoutManager.textStorage, characterIndex, bounds.size);
        FMLogFirst(5, "Emote at %lu takes %.1fpt", (unsigned long)characterIndex, bounds.size.width);
    }
    return bounds;
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
    hookEmoteSizes();
    emoteQueue = dispatch_queue_create("com.gilesgc.freemote.emotes", DISPATCH_QUEUE_SERIAL);
    chatHistoryOperations = [NSSet setWithArray:@[@"ChatHistory", @"TheaterPortalPreload", @"VideoCommentsByContentOffset", @"VideoCommentsByCursor"]];
    channelIDsByName = [[NSMutableDictionary alloc] init];
    channelIDsByMessageID = [[NSCache alloc] init];
    channelIDsByMessageID.countLimit = 5000;
    channelIDsByVideoID = [[NSCache alloc] init];
    channelIDsByNonce = [[NSCache alloc] init];
    channelIDsByNonce.countLimit = 100;
    %init(ChannelSettingsRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager25ChannelSettingsRepository"), BitsConfigRepository = objc_getClass("_TtCC6Twitch17TwitchChatManager20BitsConfigRepository"), ApolloURLSessionClient = objc_getClass("_TtC6Apollo16URLSessionClient"), EmoteCardTitleView = objc_getClass("_TtC6Twitch18EmoteCardTitleView"));
}
