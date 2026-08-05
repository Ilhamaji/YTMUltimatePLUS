#import "YTMDownloads.h"
#import "../Player/YTMOfflinePlayerManager.h"
#import "../Player/YTMOfflinePlayerViewController.h"
#import "../Utils/YTMDownloadMetadata.h"

@interface UIViewController (YTMNativePlayer)
+ (void)ytm_playVideoWithID:(NSString *)videoId fromSender:(id)sender;
@end

@implementation YTMDownloads

- (void)viewDidLoad {
    [super viewDidLoad];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor colorWithRed:3/255.0 green:3/255.0 blue:3/255.0 alpha:1.0];
    [self.view addSubview:self.tableView];

    // Segmented control for All Tracks vs Playlists
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"All Tracks", @"Playlists"]];
    self.segmentedControl.selectedSegmentIndex = 0;
    self.segmentedControl.selectedSegmentTintColor = [UIColor redColor];
    [self.segmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];
    [self.segmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [[UIColor whiteColor] colorWithAlphaComponent:0.7]} forState:UIControlStateNormal];
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 50)];
    self.segmentedControl.frame = CGRectMake(16, 8, self.view.frame.size.width - 32, 34);
    self.segmentedControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerView addSubview:self.segmentedControl];
    self.tableView.tableHeaderView = headerView;

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

- (void)segmentChanged:(UISegmentedControl *)sender {
    self.selectedPlaylistFilter = nil;
    [self refreshAudioFiles];
    [self.tableView reloadData];
}

- (void)maybeShowEmptyState {
    if (self.audioFiles.count == 0 && self.segmentedControl.selectedSegmentIndex == 0) {
        if (!self.imageView) {
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
        self.imageView.hidden = NO;
        self.label.hidden = NO;
    } else {
        self.imageView.hidden = YES;
        self.label.hidden = YES;
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
        return;
    }

    NSPredicate *m4aPredicate = [NSPredicate predicateWithFormat:@"SELF ENDSWITH[c] '.m4a'"];
    NSPredicate *mp3Predicate = [NSPredicate predicateWithFormat:@"SELF ENDSWITH[c] '.mp3'"];
    NSPredicate *predicate = [NSCompoundPredicate orPredicateWithSubpredicates:@[m4aPredicate, mp3Predicate]];

    NSArray *filtered = [allFiles filteredArrayUsingPredicate:predicate];

    if (self.selectedPlaylistFilter) {
        NSArray *playlistTracks = [YTMDownloadMetadata tracksForPlaylist:self.selectedPlaylistFilter];
        NSMutableArray *matched = [NSMutableArray array];
        for (NSString *track in playlistTracks) {
            if ([filtered containsObject:track]) {
                [matched addObject:track];
            }
        }
        self.audioFiles = matched;
    } else {
        self.audioFiles = [NSMutableArray arrayWithArray:filtered];
    }

    [self maybeShowEmptyState];
}

#pragma mark - Table view stuff

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.segmentedControl.selectedSegmentIndex == 0) {
        if (self.selectedPlaylistFilter) {
            return [NSString stringWithFormat:@"Playlist: %@", self.selectedPlaylistFilter];
        }
        return @"\n";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.segmentedControl.selectedSegmentIndex == 0) {
        if (indexPath.section == 1 && self.audioFiles.count == 0) {
            return 0;
        }
    }
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.segmentedControl.selectedSegmentIndex == 0) {
        if (section == 0) return self.audioFiles.count;
        return (self.selectedPlaylistFilter != nil) ? 1 : 2;
    } else {
        if (section == 0) return 1; // Create Playlist
        return [YTMDownloadMetadata allPlaylists].count;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    }

    cell.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:1.0];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (self.segmentedControl.selectedSegmentIndex == 0) {
        // Tracks view
        if (indexPath.section == 0) {
            NSString *fileName = self.audioFiles[indexPath.row];
            NSString *cleanName = [fileName stringByDeletingPathExtension];
            NSArray *components = [cleanName componentsSeparatedByString:@" - "];

            if (components.count >= 2) {
                cell.textLabel.text = [[components subarrayWithRange:NSMakeRange(1, components.count - 1)] componentsJoinedByString:@" - "];
                cell.detailTextLabel.text = components[0];
            } else {
                cell.textLabel.text = cleanName;
                cell.detailTextLabel.text = @"Offline Track";
            }

            UIImage *artwork = [[YTMOfflinePlayerManager sharedManager] artworkForAudioName:fileName];
            cell.imageView.image = artwork;
            cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
            cell.imageView.clipsToBounds = YES;
            cell.imageView.layer.cornerRadius = 6;

            YTMOfflinePlayerManager *manager = [YTMOfflinePlayerManager sharedManager];
            if ([manager.currentFileName isEqualToString:fileName]) {
                cell.textLabel.textColor = [UIColor redColor];
            }
        }

        if (indexPath.section == 1) {
            cell.imageView.image = nil;
            if (self.selectedPlaylistFilter != nil) {
                cell.textLabel.text = @"Show All Downloads";
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.detailTextLabel.text = nil;
            } else {
                if (indexPath.row == 0) {
                    cell.textLabel.text = LOC(@"SHARE_ALL");
                    cell.textLabel.textColor = [UIColor systemBlueColor];
                    cell.detailTextLabel.text = nil;
                } else if (indexPath.row == 1) {
                    cell.textLabel.text = LOC(@"DELETE_ALL");
                    cell.textLabel.textColor = [UIColor systemRedColor];
                    cell.detailTextLabel.text = nil;
                }
            }
        }
    } else {
        // Playlists view
        if (indexPath.section == 0) {
            cell.textLabel.text = @"+ Create New Playlist";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.detailTextLabel.text = nil;
            cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
            cell.imageView.tintColor = [UIColor systemBlueColor];
        } else {
            NSArray *playlists = [YTMDownloadMetadata allPlaylists];
            if (indexPath.row < playlists.count) {
                NSString *pName = playlists[indexPath.row];
                NSArray *tracks = [YTMDownloadMetadata tracksForPlaylist:pName];
                cell.textLabel.text = pName;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu tracks", (unsigned long)tracks.count];
                cell.imageView.image = [UIImage systemImageNamed:@"music.note.list"];
                cell.imageView.tintColor = [UIColor redColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.segmentedControl.selectedSegmentIndex == 0) {
        if (indexPath.section == 0) {
            if (indexPath.row >= self.audioFiles.count) return;

            [[YTMOfflinePlayerManager sharedManager] playPlaylist:self.audioFiles startIndex:indexPath.row];
            if (self.miniPlayerView) {
                [self.miniPlayerView updateState];
            }

            YTMOfflinePlayerViewController *playerVC = [[YTMOfflinePlayerViewController alloc] init];
            playerVC.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:playerVC animated:YES completion:nil];
        }

        if (indexPath.section == 1) {
            if (self.selectedPlaylistFilter != nil) {
                self.selectedPlaylistFilter = nil;
                [self refreshAudioFiles];
                [self.tableView reloadData];
            } else {
                if (indexPath.row == 0) {
                    [self shareAll:indexPath];
                } else if (indexPath.row == 1) {
                    [self removeAll];
                }
            }
        }
    } else {
        // Playlists section tap
        if (indexPath.section == 0) {
            [self promptCreatePlaylist];
        } else {
            NSArray *playlists = [YTMDownloadMetadata allPlaylists];
            if (indexPath.row < playlists.count) {
                NSString *pName = playlists[indexPath.row];
                [self showPlaylistActionSheetForName:pName];
            }
        }
    }
}

#pragma mark - Context Actions & Swipe

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0) return nil;

    if (self.segmentedControl.selectedSegmentIndex == 0) {
        NSString *fileName = self.audioFiles[indexPath.row];

        UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:LOC(@"DELETE") handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            [self showDeleteAlertForFile:fileName indexPath:indexPath];
            completionHandler(YES);
        }];

        UIContextualAction *addPlaylistAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"+ Playlist" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
            [self showAddToPlaylistSheetForFile:fileName];
            completionHandler(YES);
        }];
        addPlaylistAction.backgroundColor = [UIColor systemBlueColor];

        return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, addPlaylistAction]];
    } else {
        NSArray *playlists = [YTMDownloadMetadata allPlaylists];
        if (indexPath.row < playlists.count) {
            NSString *pName = playlists[indexPath.row];
            UIContextualAction *deleteP = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:LOC(@"DELETE") handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
                [YTMDownloadMetadata deletePlaylistNamed:pName];
                [self.tableView reloadData];
                completionHandler(YES);
            }];
            return [UISwipeActionsConfiguration configurationWithActions:@[deleteP]];
        }
    }

    return nil;
}

#pragma mark - Playlist Management Helpers

- (void)promptCreatePlaylist {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Playlist" message:@"Enter a name for the new playlist:" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Playlist Name";
    }];
    
    UIAlertAction *create = [UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *tf = alert.textFields.firstObject;
        NSString *name = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length > 0) {
            [YTMDownloadMetadata createPlaylistNamed:name];
            [self.tableView reloadData];
        }
    }];
    
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancel];
    [alert addAction:create];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAddToPlaylistSheetForFile:(NSString *)fileName {
    NSArray *playlists = [YTMDownloadMetadata allPlaylists];
    if (playlists.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Playlists" message:@"Create a playlist first from the Playlists tab." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Add to Playlist" message:[fileName stringByDeletingPathExtension] preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *pName in playlists) {
        [sheet addAction:[UIAlertAction actionWithTitle:pName style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [YTMDownloadMetadata addTrack:fileName toPlaylist:pName];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showPlaylistActionSheetForName:(NSString *)pName {
    NSArray *tracks = [YTMDownloadMetadata tracksForPlaylist:pName];
    
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:pName message:[NSString stringWithFormat:@"%lu tracks", (unsigned long)tracks.count] preferredStyle:UIAlertControllerStyleActionSheet];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Play Playlist" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (tracks.count > 0) {
            [YTMOfflinePlayerManager sharedManager].isShuffleEnabled = NO;
            [[YTMOfflinePlayerManager sharedManager] playPlaylist:tracks startIndex:0];
            if (self.miniPlayerView) [self.miniPlayerView updateState];
            
            YTMOfflinePlayerViewController *playerVC = [[YTMOfflinePlayerViewController alloc] init];
            playerVC.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:playerVC animated:YES completion:nil];
        }
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Shuffle Playlist" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (tracks.count > 0) {
            [YTMOfflinePlayerManager sharedManager].isShuffleEnabled = YES;
            [[YTMOfflinePlayerManager sharedManager] playPlaylist:tracks startIndex:0];
            if (self.miniPlayerView) [self.miniPlayerView updateState];
            
            YTMOfflinePlayerViewController *playerVC = [[YTMOfflinePlayerViewController alloc] init];
            playerVC.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:playerVC animated:YES completion:nil];
        }
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"View Tracks" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.selectedPlaylistFilter = pName;
        self.segmentedControl.selectedSegmentIndex = 0;
        [self refreshAudioFiles];
        [self.tableView reloadData];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete Playlist" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [YTMDownloadMetadata deletePlaylistNamed:pName];
        [self.tableView reloadData];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Delete & Share Alerts

- (void)showDeleteAlertForFile:(NSString *)fileName indexPath:(NSIndexPath *)indexPath {
    void (^deleteBlock)(void) = ^{
        NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
        NSURL *fileURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", fileName]];
        NSURL *artworkURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@.png", [fileName stringByDeletingPathExtension]]];

        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:artworkURL error:nil];

        [YTMDownloadMetadata removeMetadataForFileName:fileName];

        if (indexPath.row < self.audioFiles.count) {
            [self.audioFiles removeObjectAtIndex:indexPath.row];
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        } else {
            [self refreshAudioFiles];
            [self.tableView reloadData];
        }
        [self maybeShowEmptyState];
    };

    Class alertClass = NSClassFromString(@"YTAlertView");
    if (alertClass && [alertClass respondsToSelector:@selector(confirmationDialogWithActionHandler:actionTitle:)]) {
        SEL sel = @selector(confirmationDialogWithActionHandler:actionTitle:);
        IMP imp = [alertClass methodForSelector:sel];
        id (*func)(id, SEL, id, id) = (id (*)(id, SEL, id, id))imp;
        YTAlertView *alertView = func(alertClass, sel, deleteBlock, LOC(@"DELETE"));
        alertView.title = @"YTMusicUltimate";
        alertView.subtitle = [NSString stringWithFormat:LOC(@"DELETE_MESSAGE"), [fileName stringByDeletingPathExtension]];
        [alertView show];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete File" message:[fileName stringByDeletingPathExtension] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DELETE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            deleteBlock();
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)shareAll:(NSIndexPath *)indexPath {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSMutableArray *fileURLs = [NSMutableArray array];

    for (NSString *fileName in self.audioFiles) {
        NSURL *fileURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", fileName]];
        [fileURLs addObject:fileURL];
    }

    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:fileURLs applicationActivities:nil];
    [self presentViewController:activityViewController animated:YES completion:nil];
}

- (void)removeAll {
    void (^removeAllBlock)(void) = ^{
        NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
        NSURL *downloadsURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];

        NSError *error;
        NSArray *allFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:downloadsURL.path error:&error];

        for (NSString *fileName in allFiles) {
            NSURL *fileURL = [downloadsURL URLByAppendingPathComponent:fileName];
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            [YTMDownloadMetadata removeMetadataForFileName:fileName];
        }

        [self.audioFiles removeAllObjects];
        [self.tableView reloadData];
        [self maybeShowEmptyState];
    };

    Class alertClass = NSClassFromString(@"YTAlertView");
    if (alertClass && [alertClass respondsToSelector:@selector(confirmationDialogWithActionHandler:actionTitle:)]) {
        SEL sel = @selector(confirmationDialogWithActionHandler:actionTitle:);
        IMP imp = [alertClass methodForSelector:sel];
        id (*func)(id, SEL, id, id) = (id (*)(id, SEL, id, id))imp;
        YTAlertView *alertView = func(alertClass, sel, removeAllBlock, LOC(@"DELETE_ALL"));
        alertView.title = @"YTMusicUltimate";
        alertView.subtitle = LOC(@"DELETE_ALL_MESSAGE");
        [alertView show];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete All" message:@"Are you sure you want to delete all downloaded files?" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DELETE_ALL") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            removeAllBlock();
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
