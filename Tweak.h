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

@interface KMPMCChatMessageInfo : NSObject
@property (readonly) NSArray *tokens;
@property (readonly) NSDictionary *messageTags;
@end
