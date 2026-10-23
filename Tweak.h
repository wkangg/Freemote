#import <Foundation/Foundation.h>

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
