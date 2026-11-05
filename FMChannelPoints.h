#import <Foundation/Foundation.h>

// Claims the channel points bonus as soon as there's one, with Twitch's own claim mutation and the headers of the app's
// own GQL requests. New bonuses come in as claim-available on the user's community-points-user-v1 topic, through Hermes;
// one that was already waiting when a chat is joined is asked for.

// Keeps the headers of the app's signed-in GQL requests to send claims with. native: Apollo's, rather than React Native's.
void FMChannelPointsNoteRequest(NSURLRequest *request, NSURLSession *session, BOOL native);
// A Hermes (or PubSub) WebSocket message
void FMChannelPointsHandleMessage(NSString *message);
// A chat was joined: claims its bonus if one is waiting
void FMChannelPointsCheckChannel(NSString *channelID);
