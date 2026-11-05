#import <UIKit/UIKit.h>

// NSUserDefaults keys, all on by default. The emote ones are read when emotes load, and the deleted message one when the
// React Native screen loads, so those apply after restarting Twitch. Native chat checks deleted messages on each one, and
// channel points on each claim.
extern NSString *const FMBTTVEnabledKey;
extern NSString *const FMFFZEnabledKey;
extern NSString *const FMSevenTVEnabledKey;
extern NSString *const FMKeepDeletedMessagesKey;
extern NSString *const FMClaimChannelPointsKey;

void FMRegisterDefaults(void);

// Plain UIKit, like TwitchAdBlock's, so it doesn't depend on Twitch's own settings screens
@interface FMSettingsViewController : UITableViewController
@end
