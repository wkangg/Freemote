#import <UIKit/UIKit.h>

// NSUserDefaults keys, all on by default except the debug log. The emote ones are read when emotes load, and the deleted
// message one when the React Native screen loads, so those apply after restarting Twitch. Native chat checks deleted
// messages on each one, channel points on each claim, and the log on each line.
extern NSString *const FMBTTVEnabledKey;
extern NSString *const FMFFZEnabledKey;
extern NSString *const FMSevenTVEnabledKey;
extern NSString *const FMKeepDeletedMessagesKey;
extern NSString *const FMClaimChannelPointsKey;
extern NSString *const FMDebugLogKey;

void FMRegisterDefaults(void);

// Plain UIKit, like TwitchAdBlock's, so it doesn't depend on Twitch's own settings screens
@interface FMSettingsViewController : UITableViewController
@end

@interface FMLogViewController : UIViewController
@end
