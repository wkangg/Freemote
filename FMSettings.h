#import <UIKit/UIKit.h>

// NSUserDefaults keys, all on by default. The emote and deleted message ones are read when emotes and the React Native
// screen load, so a change applies after restarting Twitch. Claiming channel points is checked on each claim.
extern NSString *const FMBTTVEnabledKey;
extern NSString *const FMFFZEnabledKey;
extern NSString *const FMSevenTVEnabledKey;
extern NSString *const FMKeepDeletedMessagesKey;
extern NSString *const FMClaimChannelPointsKey;

void FMRegisterDefaults(void);

// Plain UIKit, like TwitchAdBlock's, so it doesn't depend on Twitch's own settings screens
@interface FMSettingsViewController : UITableViewController
@end
