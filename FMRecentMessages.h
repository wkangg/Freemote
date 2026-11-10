#import <Foundation/Foundation.h>

// How many lines the React Native chat keeps (its MAX_VISIBLE_SIZE): history fills what's left of that
#define FMChatHistoryLimit 150

// A channel's chat from before you opened it, from https://recent-messages.robotty.de (the service Chatterino and
// others use). Twitch's own ChatHistory query only has the last few messages, so these are merged into its response.
@interface FMRecentMessages : NSObject
// Starts the request
- (instancetype)initWithChannelLogin:(NSString *)login;
@property (nonatomic, readonly) NSString *channelLogin;
// Whether the request has finished, failed or not
@property (atomic, readonly) BOOL done;
// The chat messages, oldest first, each shaped like one of recentChatMessages in the React Native screen's ChatHistory
// query. Mutable all the way down, like a response parsed with NSJSONReadingMutableContainers. Empty until done, and if
// the request failed.
@property (atomic, readonly) NSArray<NSMutableDictionary *> *messages;
// Calls the block on a background queue once the request has finished, or right away if it has
- (void)whenDone:(dispatch_block_t)block;
@end

// One IRC line (as the service returns them) as a recentChatMessages message, or nil if it isn't a chat message
NSMutableDictionary *FMChatHistoryMessageFromIRCLine(NSString *line);

// Twitch's recentChatMessages with the messages from recentMessages it doesn't have, by time, cut down to the newest
// FMChatHistoryLimit. Twitch's copy of a message wins. nil if one of Twitch's messages has no ID or time to go by.
NSArray *FMMergeChatHistory(NSArray *twitchMessages, NSArray<NSMutableDictionary *> *recentMessages);
