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

@interface KMPMCChatMessageInfo : NSObject
@property (readonly) NSString *id; // the message ID
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

// A moderator deleted one message (CLEARMSG)
@interface KMPMCChannelEventChatChannelMessageDeleted : NSObject
@property (readonly) NSString *messageId;
@property (readonly) NSString *senderLoginName;
@property (readonly) NSString *deletedMessageContent;
- (instancetype)initWithMessageId:(NSString *)messageId senderLoginName:(NSString *)senderLoginName deletedMessageContent:(NSString *)deletedMessageContent;
@end

// A user was timed out or banned, which clears their messages (CLEARCHAT with a user)
@interface KMPMCChannelEventChatChannelUserMessagesCleared : NSObject
@property (readonly) NSString *clearUserId;
- (instancetype)initWithClearUserId:(NSString *)clearUserId;
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

// TwitchKit's chat message, as Twitch's native chat draws it
@interface TWChatMessage : NSObject
@property (readonly) NSString *messageID;
@property (readonly) id senderId;
@property (readonly) NSDate *date;
@end

// The text of a native chat message (Twitch.ChatMessageString, a MessageString)
@interface TWChatMessageString : TWMessageString
@property (readonly) TWChatMessage *chatMessage;
@end

// Draws a MessageString (Twitch.MessageStringView), e.g. in a chat row
@interface MessageStringView : UIView
@property (nonatomic, assign) BOOL freemote_dimmed; // %property
@property (nonatomic, assign) CGFloat freemote_undimmedAlpha; // %property: its alpha before it was dimmed
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
// Calls a method of a module the JS registered with RN$registerCallableModule, once the bundle has loaded
- (void)callFunctionOnJSModule:(NSString *)moduleName method:(NSString *)method args:(NSArray *)args;
@end

// React Native's log function (RCTLog.h): level and source are the RCTLogLevel and RCTLogSource enums
typedef void (^RCTLogFunction)(NSInteger level, NSInteger source, NSString *fileName, NSNumber *lineNumber, NSString *message);

// Fabric's Text view
@interface RCTParagraphComponentView : UIView
@property (readonly) NSAttributedString *attributedText;
@property (nonatomic, strong) UITapGestureRecognizer *freemote_emoteCardLinkTap; // %property
@end

// The title of the native emote card (Twitch.EmoteCardTitleView)
@interface EmoteCardTitleView : UIView
@property (nonatomic, strong) UITextView *freemote_emoteCardLink; // %property
@end

// Twitch's account menu (Twitch.AccountMenuViewController), where our settings row goes
@interface AccountMenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, assign) NSInteger freemote_settingsRow; // %property
- (BOOL)freemote_isSettingsRow:(NSIndexPath *)indexPath tableView:(UITableView *)tableView; // %new
@end

// The account menu's rows (Twitch.ConfigurableAccessoryTableViewCell)
@interface ConfigurableAccessoryTableViewCell : UITableViewCell
@property (nonatomic, assign) BOOL useDefaultBackgroundColor;
- (void)configureWithTitle:(NSString *)title;
@end
