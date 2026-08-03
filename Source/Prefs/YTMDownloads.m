#import "YTMDownloads.h"
#import "../Player/YTMOfflinePlayerManager.h"
#import "../Player/YTMOfflinePlayerViewController.h"

@implementation YTMDownloads

- (void)viewDidLoad {
    [super viewDidLoad];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor colorWithRed:3/255.0 green:3/255.0 blue:3/255.0 alpha:1.0];
    [self.view addSubview:self.tableView];

    self.miniPlayerView = [[YTMOfflineMiniPlayerView alloc] initWithFrame:CGRectZero];
    self.miniPlayerView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    self.miniPlayerView.onTapExpandBlock = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        YTMOfflinePlayerViewController *playerVC = [[YTMOfflinePlayerViewController alloc] init];
        playerVC.modalPresentationStyle = UIModalPresentationFullScreen;
        [strongSelf presentViewController:playerVC animated:YES completion:nil];
    };
    [self.view addSubview:self.miniPlayerView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.miniPlayerView.topAnchor],

        [self.miniPlayerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.miniPlayerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.miniPlayerView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.miniPlayerView.heightAnchor constraintEqualToConstant:64]
    ]];

    [self maybeShowEmptyState];
    [self refreshAudioFiles];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData) name:@"ReloadDataNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTrackChanged) name:YTMOfflinePlayerTrackDidChangeNotification object:nil];
}

- (void)maybeShowEmptyState {
    if (self.audioFiles.count == 0) {
        self.imageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"yt_outline_audio_48pt" inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil]];
        self.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.imageView.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
        self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.tableView addSubview:self.imageView];

        self.label = [[UILabel alloc] initWithFrame:CGRectZero];
        self.label.text = LOC(@"EMPTY");
        self.label.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
        self.label.numberOfLines = 0;
        self.label.font = [UIFont systemFontOfSize:16];
        self.label.textAlignment = NSTextAlignmentCenter;
        self.label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.label sizeToFit];
        [self.tableView addSubview:self.label];

        [NSLayoutConstraint activateConstraints:@[
            [self.imageView.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
            [self.imageView.bottomAnchor constraintEqualToAnchor:self.tableView.centerYAnchor constant:-30],
            [self.imageView.widthAnchor constraintEqualToConstant:48],
            [self.imageView.heightAnchor constraintEqualToConstant:48],

            [self.label.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
            [self.label.topAnchor constraintEqualToAnchor:self.imageView.bottomAnchor constant:20],
            [self.label.leadingAnchor constraintEqualToAnchor:self.tableView.leadingAnchor constant:20],
            [self.label.trailingAnchor constraintEqualToAnchor:self.tableView.trailingAnchor constant:-20],
        ]];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadData {
    [self refreshAudioFiles];
    [self.tableView reloadData];
}

- (void)onTrackChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

- (void)refreshAudioFiles {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *downloadsURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];

    NSError *error;
    NSArray *allFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:downloadsURL.path error:&error];

    if (error) {
        NSLog(@"Error reading contents of directory: %@", error.localizedDescription);
        return;
    }

    NSPredicate *m4aPredicate = [NSPredicate predicateWithFormat:@"SELF ENDSWITH[c] '.m4a'"];
    NSPredicate *mp3Predicate = [NSPredicate predicateWithFormat:@"SELF ENDSWITH[c] '.mp3'"];
    NSPredicate *predicate = [NSCompoundPredicate orPredicateWithSubpredicates:@[m4aPredicate, mp3Predicate]];

    self.audioFiles = [NSMutableArray arrayWithArray:[allFiles filteredArrayUsingPredicate:predicate]];

    self.imageView.tintColor = self.audioFiles.count == 0 ? [[UIColor whiteColor] colorWithAlphaComponent:0.8] : [UIColor clearColor];
    self.label.textColor = self.audioFiles.count == 0 ? [[UIColor whiteColor] colorWithAlphaComponent:0.8] : [UIColor clearColor];
}

#pragma mark - Table view stuff
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"\n\n" : nil; //Temporary, see YTMTab.x
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? @"\n\n\n" : nil; //Temporary, see YTMTab.x
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && self.audioFiles.count == 0) {
        return 0;
    }
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return self.audioFiles.count;
    }

    if (section == 1) {
        return 2;
    }

    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }

    if (indexPath.section == 0 && indexPath.row < self.audioFiles.count) {
        NSString *fileName = self.audioFiles[indexPath.row];
        cell.textLabel.text = [fileName stringByDeletingPathExtension];
        cell.textLabel.numberOfLines = 0;

        BOOL isCurrentPlaying = [fileName isEqualToString:[YTMOfflinePlayerManager sharedManager].currentFileName];
        if (isCurrentPlaying) {
            cell.textLabel.textColor = [UIColor colorWithRed:255/255.0 green:80/255.0 blue:80/255.0 alpha:1.0];
            UIImageView *playingIconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform"]];
            playingIconView.tintColor = [UIColor redColor];
            cell.accessoryView = playingIconView;
        } else {
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.accessoryView = nil;
        }

        cell.backgroundColor = [[UIColor grayColor] colorWithAlphaComponent:0.25];

        NSString *imageName = [NSString stringWithFormat:@"%@.png", [fileName stringByDeletingPathExtension]];
        NSString *documentsDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];

        UIImage *image = [UIImage imageWithContentsOfFile:[[documentsDirectory stringByAppendingPathComponent:@"YTMusicUltimate"] stringByAppendingPathComponent:imageName]];
        CGFloat targetSize = 37.5;
        CGFloat scaleFactor = targetSize / MAX(image.size.width, image.size.height);
        CGSize scaledSize = CGSizeMake(image.size.width * scaleFactor, image.size.height * scaleFactor);
        UIGraphicsBeginImageContextWithOptions(scaledSize, NO, 0.0);
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, scaledSize.width, scaledSize.height) cornerRadius:6] addClip];
        [image drawInRect:CGRectMake(0, 0, scaledSize.width, scaledSize.height)];
        UIImage *roundedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        roundedImage = [roundedImage imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        cell.imageView.image = roundedImage;
    }

    else if (indexPath.section == 1) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell0"];
        NSArray *settingsData = @[
            @{@"title": LOC(@"SHARE_ALL"), @"icon": @"square.and.arrow.up.on.square"},
            @{@"title": LOC(@"REMOVE_ALL"), @"icon": @"trash"},
        ];

        NSDictionary *data = settingsData[indexPath.row];

        cell.textLabel.text = data[@"title"];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.imageView.image = [UIImage systemImageNamed:data[@"icon"]];
        cell.imageView.tintColor = indexPath.row == 1 ? [UIColor redColor] : [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
        cell.backgroundColor = [[UIColor grayColor] colorWithAlphaComponent:0.25];
        cell.accessoryView = nil;
    }

    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UIContextualAction *shareAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            [self showActivityViewControllerForIndexPath:indexPath];
            completionHandler(YES);
        }];
        shareAction.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        shareAction.backgroundColor = [UIColor systemBlueColor];

        UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            [self renameFileForIndexPath:indexPath];
            completionHandler(YES);
        }];
        renameAction.image = [UIImage systemImageNamed:@"pencil"];
        renameAction.backgroundColor = [UIColor systemOrangeColor];

        UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            [self deleteFileForIndexPath:indexPath];
            completionHandler(YES);
        }];
        deleteAction.image = [UIImage systemImageNamed:@"trash"];

        UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, renameAction, shareAction]];
        configuration.performsFirstActionWithFullSwipe = YES;

        return configuration;
    } else {
        return nil;
    }
}

- (void)showActivityViewControllerForIndexPath:(NSIndexPath *)indexPath {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *audioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", self.audioFiles[indexPath.row]]];

    [self activityControllerWithObjects:@[audioURL] sender:[self.tableView cellForRowAtIndexPath:indexPath]];
}

- (void)renameFileForIndexPath:(NSIndexPath *)indexPath {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *audioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", self.audioFiles[indexPath.row]]];
    NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@.png", [self.audioFiles[indexPath.row] stringByDeletingPathExtension]]];

    UITextView *textView = [[UITextView alloc] init];
    textView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.15];
    textView.layer.cornerRadius = 3.0;
    textView.layer.borderWidth = 1.0;
    textView.layer.borderColor = [[UIColor grayColor] colorWithAlphaComponent:0.5].CGColor;
    textView.textColor = [UIColor whiteColor];
    textView.text = [self.audioFiles[indexPath.row] stringByDeletingPathExtension];
    textView.editable = YES;
    textView.scrollEnabled = YES;
    textView.textAlignment = NSTextAlignmentNatural;
    textView.font = [UIFont systemFontOfSize:14.0];

    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        NSString *newName = [textView.text stringByReplacingOccurrencesOfString:@"/" withString:@""];
        NSString *extension = [audioURL pathExtension];

        NSURL *newAudioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@.%@", newName, extension]];
        NSURL *newCoverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@.png", newName]];

        NSError *error = nil;
        [[NSFileManager defaultManager] moveItemAtURL:audioURL toURL:newAudioURL error:&error];
        [[NSFileManager defaultManager] moveItemAtURL:coverURL toURL:newCoverURL error:&error];

        if (!error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reloadData];
                [[YTMOfflinePlayerManager sharedManager] updatePlaylist:self.audioFiles];
                [[NSClassFromString(@"YTMToastController") alloc] showMessage:LOC(@"DONE")];
            });
        }
    }
    actionTitle:LOC(@"RENAME")];
    alertView.title = @"YTMusicUltimate";

    UIView *customView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, alertView.frameForDialog.size.width - 50, 75)];
    textView.frame = customView.frame;
    [customView addSubview:textView];

    alertView.customContentView = customView;
    [alertView show];
}

- (void)deleteFileForIndexPath:(NSIndexPath *)indexPath {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *audioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", self.audioFiles[indexPath.row]]];
    NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@.png", [self.audioFiles[indexPath.row] stringByDeletingPathExtension]]];

    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        BOOL audioRemoved = [[NSFileManager defaultManager] removeItemAtURL:audioURL error:nil];
        BOOL coverRemoved = [[NSFileManager defaultManager] removeItemAtURL:coverURL error:nil];

        if (audioRemoved && coverRemoved) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.audioFiles removeObjectAtIndex:indexPath.row];
                [[YTMOfflinePlayerManager sharedManager] updatePlaylist:self.audioFiles];
                [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
                [self maybeShowEmptyState];
            });
        }
    }
    actionTitle:LOC(@"DELETE")];
    alertView.title = @"YTMusicUltimate";
    alertView.subtitle = [NSString stringWithFormat:LOC(@"DELETE_MESSAGE"), [self.audioFiles[indexPath.row] stringByDeletingPathExtension]];
    [alertView show];
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        [[YTMOfflinePlayerManager sharedManager] playPlaylist:self.audioFiles startIndex:indexPath.row];
        [self.miniPlayerView updateState];

        YTMOfflinePlayerViewController *playerVC = [[YTMOfflinePlayerViewController alloc] init];
        playerVC.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:playerVC animated:YES completion:nil];
    }

    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            [self shareAll:indexPath];
        }

        if (indexPath.row == 1) {
            [self removeAll];
        }
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)shareAll:(NSIndexPath *)indexPath {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *audiosFolder = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];

    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:audiosFolder
                                                               includingPropertiesForKeys:@[NSURLNameKey, NSURLIsDirectoryKey]
                                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                    error:nil];

    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"pathExtension.lowercaseString == 'm4a' || pathExtension.lowercaseString == 'mp3'"];
    files = [files filteredArrayUsingPredicate:predicate];

    [self activityControllerWithObjects:files sender:[self.tableView cellForRowAtIndexPath:indexPath]];
}

- (void)removeAll {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *audiosFolder = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];

    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        BOOL audiosRemoved = [[NSFileManager defaultManager] removeItemAtURL:audiosFolder error:nil];

        if (audiosRemoved) {
            [self.audioFiles removeAllObjects];
            [[YTMOfflinePlayerManager sharedManager] updatePlaylist:self.audioFiles];
            self.imageView.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
            self.label.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
            });
        }
    }
    actionTitle:LOC(@"DELETE")];
    alertView.title = @"YTMusicUltimate";
    alertView.subtitle = [NSString stringWithFormat:LOC(@"DELETE_MESSAGE"), LOC(@"ALL_DOWNLOADS")];
    [alertView show];
}

- (void)activityControllerWithObjects:(NSArray<id> *)items sender:(UIView *)sender {
    if (items.count == 0) return;

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    activityVC.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    UIPopoverPresentationController *popover = activityVC.popoverPresentationController;
    if (popover && sender) {
        popover.sourceView = sender;
        popover.sourceRect = CGRectMake(CGRectGetWidth(sender.bounds) - 10.0, CGRectGetMidY(sender.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = UIPopoverArrowDirectionRight;
    }

    [self presentViewController:activityVC animated:YES completion:nil];
}

@end
