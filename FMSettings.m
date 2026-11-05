#import "FMSettings.h"

NSString *const FMBTTVEnabledKey = @"FreemoteBTTVEnabled";
NSString *const FMFFZEnabledKey = @"FreemoteFFZEnabled";
NSString *const FMSevenTVEnabledKey = @"FreemoteSevenTVEnabled";
NSString *const FMKeepDeletedMessagesKey = @"FreemoteKeepDeletedMessages";
NSString *const FMClaimChannelPointsKey = @"FreemoteClaimChannelPoints";

void FMRegisterDefaults(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        FMBTTVEnabledKey: @YES,
        FMFFZEnabledKey: @YES,
        FMSevenTVEnabledKey: @YES,
        FMKeepDeletedMessagesKey: @YES,
        FMClaimChannelPointsKey: @YES,
    }];
}

@implementation FMSettingsViewController {
    NSArray<NSArray<NSArray<NSString *> *> *> *_sections; // each row's [title, defaults key]
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Freemote";
    _sections = @[
        @[@[@"BTTV Emotes", FMBTTVEnabledKey], @[@"FFZ Emotes", FMFFZEnabledKey], @[@"7TV Emotes", FMSevenTVEnabledKey]],
        @[@[@"Keep Deleted Messages", FMKeepDeletedMessagesKey]],
        @[@[@"Claim Channel Points Bonus", FMClaimChannelPointsKey]],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSString *> *row = _sections[indexPath.section][indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = row[0];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:row[1]];
    toggle.accessibilityIdentifier = row[1];
    [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section == 0)
        return @"Emotes from each provider, global and per channel.";
    if(section == 1)
        return @"Messages deleted by a moderator stay in chat, dimmed, on the React Native stream screen.";
    return @"Claims the bonus chest as soon as it shows up, in any chat you have open.\n\n"
           @"Emote and deleted message changes apply after restarting Twitch.\n\nFreemote " FREEMOTE_VERSION;
}

- (void)toggled:(UISwitch *)toggle {
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:toggle.accessibilityIdentifier];
}

@end
