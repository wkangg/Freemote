#import <UIKit/UIKit.h>

// Kotlin/Native classes exported by KMPMobileChat.framework (Twitch 31.x chat)
@interface KMPMCMessageTokenTextToken : NSObject
@property (readonly) NSString *text;
@property (readonly) id flags;
- (instancetype)initWithText:(NSString *)text flags:(id)flags;
@end

@interface KMPMCMessageTokenEmoteToken : NSObject
- (instancetype)initWithText:(NSString *)text id:(NSString *)emoteID;
@end

// Also has an `id` getter (the message ID), called through objc_msgSend
@interface KMPMCChatMessageInfo : NSObject
@property (readonly) NSArray *tokens;
@property (readonly) NSDictionary *messageTags;
@property (readonly) NSString *messageType;
@property (readonly) id sourceInfo; // shared chat only
@end

@interface KMPMCChatLiveMessage : NSObject
@property (readonly) KMPMCChatMessageInfo *messageInfo;
@end

@interface KMPMCChannelEventChatChannelMessagesReceived : NSObject
@property (readonly) NSArray<KMPMCChatLiveMessage *> *messageList;
@end

// What ChatConnectionManager.observeChatEvents() emits: one channel's event
@interface KMPMCChatEvent : NSObject
@property (readonly) NSString *channelName;
@property (readonly) id event;
@end


// Swift classes in Twitch, used through their ObjC methods (TwitchKit's TWMessageEmoteToken, Twitch's MessageString)
@interface TWMessageEmoteToken : NSObject
@property (readonly) NSString *emoteId;
@end

// A chat message's text, laid out by Twitch's MessageStringLayoutManager
@interface TWMessageString : NSObject
@property (readonly) NSDictionary<NSNumber *, TWMessageEmoteToken *> *emoteLocationsMap; // character index -> emote
@end

// SocketRocket, which React Native's WebSocket module uses
@interface SRWebSocket : NSObject
@property (readonly) NSURL *url;
@end

// React Native's fetch: the NSURLSession delegate for its requests
@interface RCTHTTPRequestHandler : NSObject <NSURLSessionDataDelegate>
@end

// A React Native JS runtime (bridgeless). A segment is a JS file it evaluates.
@interface RCTInstance : NSObject
- (void)registerSegmentWithId:(NSNumber *)segmentId path:(NSString *)path;
@end

// Fabric's Text view
@interface RCTParagraphComponentView : UIView
@property (readonly) NSAttributedString *attributedText;
@end
