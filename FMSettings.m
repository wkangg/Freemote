#import "FMSettings.h"
#import "FMLog.h"

NSString *const FMBTTVEnabledKey = @"FreemoteBTTVEnabled";
NSString *const FMFFZEnabledKey = @"FreemoteFFZEnabled";
NSString *const FMSevenTVEnabledKey = @"FreemoteSevenTVEnabled";
NSString *const FMKeepDeletedMessagesKey = @"FreemoteKeepDeletedMessages";
NSString *const FMChatHistoryKey = @"FreemoteChatHistory";
NSString *const FMClaimChannelPointsKey = @"FreemoteClaimChannelPoints";
NSString *const FMDebugLogKey = @"FreemoteDebugLog";

void FMRegisterDefaults(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        FMBTTVEnabledKey: @YES,
        FMFFZEnabledKey: @YES,
        FMSevenTVEnabledKey: @YES,
        FMKeepDeletedMessagesKey: @YES,
        FMChatHistoryKey: @YES,
        FMClaimChannelPointsKey: @YES,
        FMDebugLogKey: @NO,
    }];
}

@implementation FMSettingsViewController {
    NSArray<NSArray<NSArray<NSString *> *> *> *_sections; // each row's [title, defaults key], or just [title] for the log row
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Freemote";
    _sections = @[
        @[@[@"BTTV Emotes", FMBTTVEnabledKey], @[@"FFZ Emotes", FMFFZEnabledKey], @[@"7TV Emotes", FMSevenTVEnabledKey]],
        @[@[@"Keep Deleted Messages", FMKeepDeletedMessagesKey]],
        @[@[@"Chat History", FMChatHistoryKey]],
        @[@[@"Claim Channel Points Bonus", FMClaimChannelPointsKey]],
        @[@[@"Debug Log", FMDebugLogKey], @[@"View Log"]],
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
    if(row.count == 1) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
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
        return @"Messages deleted by a moderator, or from a user who was timed out or banned, stay in chat, dimmed. Chat also stays when a moderator clears it.";
    if(section == 2)
        return @"Fills chat with up to 150 earlier messages when you open a stream, from recent-messages.robotty.de, which is sent the channel's name. Not on vertical streams.";
    if(section == 3)
        return @"Claims the bonus chest as soon as it shows up, in any chat you have open.";
    return @"Records emote loads, requests and channel points claims to a file you can share when something goes wrong.\n\n"
           @"Emote and deleted message changes apply after restarting Twitch.\n\nFreemote " FREEMOTE_VERSION;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(_sections[indexPath.section][indexPath.row].count == 1)
        [self.navigationController pushViewController:[[FMLogViewController alloc] init] animated:YES];
}

- (void)toggled:(UISwitch *)toggle {
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:toggle.accessibilityIdentifier];
}

@end

@implementation FMLogViewController {
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Log";
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _textView.alwaysBounceVertical = YES;
    [self.view addSubview:_textView];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(clear)],
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSString *contents = FMLogContents();
    // The log can reach 10 MB, too much for a text view, so show the end (share sends it all)
    static const NSUInteger kShownLength = 200 * 1024;
    if(contents.length > kShownLength) {
        NSRange range = [contents rangeOfComposedCharacterSequencesForRange:NSMakeRange(contents.length - kShownLength, kShownLength)];
        contents = [@"(Older lines hidden. Share sends the full log.)\n" stringByAppendingString:[contents substringWithRange:range]];
    }
    if(contents.length) {
        _textView.text = contents;
        [_textView scrollRangeToVisible:NSMakeRange(contents.length - 1, 1)];
    } else {
        _textView.text = [NSUserDefaults.standardUserDefaults boolForKey:FMDebugLogKey] ? @"Nothing logged yet." : @"Nothing logged yet. Turn on Debug Log to start.";
    }
}

- (void)share:(UIBarButtonItem *)sender {
    // As a file, so apps that take text don't cut a long log off
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Freemote.log"];
    [FMLogContents() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    controller.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)clear {
    FMLogClear();
    [self reload];
}

@end
