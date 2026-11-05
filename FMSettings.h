#import <UIKit/UIKit.h>

// NSUserDefaults keys, all on by default. They're read when emotes and the React Native screen load, so a change
// applies after restarting Twitch.
extern NSString *const FMBTTVEnabledKey;
extern NSString *const FMFFZEnabledKey;
extern NSString *const FMSevenTVEnabledKey;
extern NSString *const FMKeepDeletedMessagesKey;

void FMRegisterDefaults(void);

// Plain UIKit, like TwitchAdBlock's, so it doesn't depend on Twitch's own settings screens
@interface FMSettingsViewController : UITableViewController
@end
