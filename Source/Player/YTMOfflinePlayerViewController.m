#import "YTMOfflinePlayerViewController.h"

@interface YTMOfflinePlayerViewController ()

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *shuffledIndices;
@property (nonatomic, assign) NSInteger currentShufflePosition;
@property (nonatomic, assign) BOOL isScrubbing;

// UI Elements
@property (nonatomic, strong) UIVisualEffectView *backgroundBlurView;
@property (nonatomic, strong) UIButton *dismissButton;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UIView *artworkShadowView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;

@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UILabel *currentTimeLabel;
@property (nonatomic, strong) UILabel *durationLabel;

@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) UIButton *queueButton;

@end

@implementation YTMOfflinePlayerViewController

+ (instancetype)sharedPlayerViewController {
    static YTMOfflinePlayerViewController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[YTMOfflinePlayerViewController alloc] init];
    });
    return sharedInstance;
}

- (instancetype)initWithPlaylist:(NSArray<NSString *> *)playlist initialIndex:(NSInteger)index {
    self = [super init];
    if (self) {
        _playlist = [playlist copy];
        _currentIndex = index;
        _repeatMode = YTMPlayerRepeatModeAll;
        _isShuffle = NO;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithRed:12.0/255.0 green:12.0/255.0 blue:12.0/255.0 alpha:1.0];

    [self setupAudioSession];
    [self setupRemoteCommandCenter];
    [self setupUI];

    if (self.playlist.count > 0) {
        [self loadTrackAtIndex:self.currentIndex autoPlay:YES];
    }
}

- (void)dealloc {
    [self removeCurrentItemObserver];
    if (self.timeObserver && self.player) {
        [self.player removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Audio Session & Remote Commands

- (void)setupAudioSession {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [audioSession setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (error) {
        NSLog(@"[YTMOfflinePlayer] Error setting AVAudioSession category: %@", error);
    }
    [audioSession setActive:YES error:&error];
    if (error) {
        NSLog(@"[YTMOfflinePlayer] Error activating AVAudioSession: %@", error);
    }
}

- (void)setupRemoteCommandCenter {
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];

    [commandCenter.playCommand removeTarget:nil];
    [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        [self play];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.pauseCommand removeTarget:nil];
    [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        [self pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.togglePlayPauseCommand removeTarget:nil];
    [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        [self togglePlayPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.nextTrackCommand removeTarget:nil];
    [commandCenter.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        [self playNextTrack];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.previousTrackCommand removeTarget:nil];
    [commandCenter.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        [self playPreviousTrack];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.changePlaybackPositionCommand removeTarget:nil];
    [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
        [self seekToTimeSeconds:positionEvent.positionTime];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

#pragma mark - Public API

- (void)playPlaylist:(NSArray<NSString *> *)playlist initialIndex:(NSInteger)index {
    self.playlist = playlist;
    self.currentIndex = index;
    if (self.isShuffle) {
        [self generateShuffledIndices];
    }
    [self loadTrackAtIndex:self.currentIndex autoPlay:YES];
}

#pragma mark - Playback Control Engine

- (void)loadTrackAtIndex:(NSInteger)index autoPlay:(BOOL)autoPlay {
    if (index < 0 || index >= self.playlist.count) {
        return;
    }

    self.currentIndex = index;
    NSString *fileName = self.playlist[index];

    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *audioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", fileName]];

    // Clean up previous item observer
    [self removeCurrentItemObserver];

    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:audioURL];

    if (!self.player) {
        self.player = [AVPlayer playerWithPlayerItem:playerItem];
        [self setupTimeObserver];
    } else {
        [self.player replaceCurrentItemWithPlayerItem:playerItem];
    }

    // Register completion listener for auto-advance!
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:playerItem];

    // Parse Title & Artist from filename ("Artist - Title.ext" or fallback)
    NSString *baseName = [fileName stringByDeletingPathExtension];
    NSString *songTitle = baseName;
    NSString *artistName = @"Offline Music";

    NSArray *components = [baseName componentsSeparatedByString:@" - "];
    if (components.count >= 2) {
        artistName = components[0];
        songTitle = [[components subarrayWithRange:NSMakeRange(1, components.count - 1)] componentsJoinedByString:@" - "];
    }

    self.titleLabel.text = songTitle;
    self.artistLabel.text = artistName;

    // Load Artwork Image
    NSString *imageName = [NSString stringWithFormat:@"%@.png", baseName];
    NSString *documentsDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *artworkPath = [[documentsDirectory stringByAppendingPathComponent:@"YTMusicUltimate"] stringByAppendingPathComponent:imageName];
    UIImage *artworkImage = [UIImage imageWithContentsOfFile:artworkPath];

    if (artworkImage) {
        self.artworkImageView.image = artworkImage;
    } else {
        self.artworkImageView.image = [UIImage systemImageNamed:@"music.note.list"];
    }

    // Reset scrubber
    self.progressSlider.value = 0.0;
    self.currentTimeLabel.text = @"0:00";
    self.durationLabel.text = @"0:00";

    if (autoPlay) {
        [self play];
    } else {
        [self updatePlayPauseButtonImage];
    }

    [self updateNowPlayingInfo];
}

- (void)removeCurrentItemObserver {
    if (self.player.currentItem) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:self.player.currentItem];
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.repeatMode == YTMPlayerRepeatModeOne) {
            [self seekToTimeSeconds:0];
            [self play];
        } else {
            [self playNextTrack];
        }
    });
}

- (void)play {
    [self.player play];
    [self updatePlayPauseButtonImage];
    [self updateNowPlayingInfo];
}

- (void)pause {
    [self.player pause];
    [self updatePlayPauseButtonImage];
    [self updateNowPlayingInfo];
}

- (void)togglePlayPause {
    if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
        [self pause];
    } else {
        [self play];
    }
}

- (void)playNextTrack {
    if (self.playlist.count == 0) return;

    NSInteger nextIndex = 0;

    if (self.isShuffle) {
        if (self.shuffledIndices.count != self.playlist.count) {
            [self generateShuffledIndices];
        }
        self.currentShufflePosition++;
        if (self.currentShufflePosition >= self.shuffledIndices.count) {
            if (self.repeatMode == YTMPlayerRepeatModeAll) {
                self.currentShufflePosition = 0;
            } else {
                [self pause];
                return;
            }
        }
        nextIndex = [self.shuffledIndices[self.currentShufflePosition] integerValue];
    } else {
        nextIndex = self.currentIndex + 1;
        if (nextIndex >= self.playlist.count) {
            if (self.repeatMode == YTMPlayerRepeatModeAll) {
                nextIndex = 0;
            } else {
                [self pause];
                return;
            }
        }
    }

    [self loadTrackAtIndex:nextIndex autoPlay:YES];
}

- (void)playPreviousTrack {
    if (self.playlist.count == 0) return;

    // If played more than 3 seconds, restart current track
    CMTime currentTime = self.player.currentTime;
    Float64 seconds = CMTimeGetSeconds(currentTime);
    if (seconds > 3.0) {
        [self seekToTimeSeconds:0];
        return;
    }

    NSInteger prevIndex = 0;

    if (self.isShuffle) {
        if (self.shuffledIndices.count != self.playlist.count) {
            [self generateShuffledIndices];
        }
        self.currentShufflePosition--;
        if (self.currentShufflePosition < 0) {
            self.currentShufflePosition = self.shuffledIndices.count - 1;
        }
        prevIndex = [self.shuffledIndices[self.currentShufflePosition] integerValue];
    } else {
        prevIndex = self.currentIndex - 1;
        if (prevIndex < 0) {
            prevIndex = self.playlist.count - 1;
        }
    }

    [self loadTrackAtIndex:prevIndex autoPlay:YES];
}

- (void)toggleShuffle {
    self.isShuffle = !self.isShuffle;
    if (self.isShuffle) {
        [self generateShuffledIndices];
    }
    [self updateControlButtonsStyle];
}

- (void)toggleRepeat {
    if (self.repeatMode == YTMPlayerRepeatModeOff) {
        self.repeatMode = YTMPlayerRepeatModeAll;
    } else if (self.repeatMode == YTMPlayerRepeatModeAll) {
        self.repeatMode = YTMPlayerRepeatModeOne;
    } else {
        self.repeatMode = YTMPlayerRepeatModeOff;
    }
    [self updateControlButtonsStyle];
}

- (void)generateShuffledIndices {
    NSMutableArray *indices = [NSMutableArray array];
    for (NSInteger i = 0; i < self.playlist.count; i++) {
        [indices addObject:@(i)];
    }

    // Fisher-Yates shuffle
    for (NSUInteger i = indices.count; i > 1; i--) {
        [indices exchangeObjectAtIndex:(i - 1) withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    }

    self.shuffledIndices = indices;

    // Align currentShufflePosition with currentIndex
    NSUInteger pos = [indices indexOfObject:@(self.currentIndex)];
    self.currentShufflePosition = (pos != NSNotFound) ? pos : 0;
}

#pragma mark - Scrubber & Time Observers

- (void)setupTimeObserver {
    __weak typeof(self) weakSelf = self;
    CMTime interval = CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC);

    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:interval
                                                                   queue:dispatch_get_main_queue()
                                                              usingBlock:^(CMTime time) {
        [weakSelf handleTimeUpdate:time];
    }];
}

- (void)handleTimeUpdate:(CMTime)time {
    if (self.isScrubbing) return;

    AVPlayerItem *currentItem = self.player.currentItem;
    if (!currentItem) return;

    Float64 duration = CMTimeGetSeconds(currentItem.duration);
    Float64 current = CMTimeGetSeconds(time);

    if (isnan(duration) || duration <= 0) return;

    self.progressSlider.maximumValue = duration;
    self.progressSlider.value = current;

    self.currentTimeLabel.text = [self formatTimeString:current];
    self.durationLabel.text = [NSString stringWithFormat:@"-%@", [self formatTimeString:(duration - current)]];

    [self updateNowPlayingInfo];
}

- (void)seekToTimeSeconds:(Float64)seconds {
    CMTime targetTime = CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC);
    [self.player seekToTime:targetTime completionHandler:^(BOOL finished) {
        [self updateNowPlayingInfo];
    }];
}

- (NSString *)formatTimeString:(Float64)totalSeconds {
    if (isnan(totalSeconds) || totalSeconds < 0) return @"0:00";
    NSInteger minutes = (NSInteger)totalSeconds / 60;
    NSInteger seconds = (NSInteger)totalSeconds % 60;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

#pragma mark - Scrubber Controls

- (void)sliderTouchBegan:(UISlider *)slider {
    self.isScrubbing = YES;
}

- (void)sliderValueChanged:(UISlider *)slider {
    self.currentTimeLabel.text = [self formatTimeString:slider.value];
}

- (void)sliderTouchEnded:(UISlider *)slider {
    self.isScrubbing = NO;
    [self seekToTimeSeconds:slider.value];
}

#pragma mark - Lock Screen / Control Center Sync

- (void)updateNowPlayingInfo {
    NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];

    AVPlayerItem *currentItem = self.player.currentItem;
    if (currentItem) {
        Float64 duration = CMTimeGetSeconds(currentItem.duration);
        Float64 elapsed = CMTimeGetSeconds(self.player.currentTime);

        if (!isnan(duration) && duration > 0) {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = @(duration);
        }
        if (!isnan(elapsed) && elapsed >= 0) {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
        }
    }

    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player.rate);
    nowPlayingInfo[MPMediaItemPropertyTitle] = self.titleLabel.text ?: @"Offline Song";
    nowPlayingInfo[MPMediaItemPropertyArtist] = self.artistLabel.text ?: @"YTMusicUltimate";

    if (self.artworkImageView.image) {
        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:self.artworkImageView.image.size
                                                                        requestHandler:^UIImage * _Nonnull(CGSize size) {
            return self.artworkImageView.image;
        }];
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork;
    }

    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nowPlayingInfo;
}

#pragma mark - UI Setup

- (void)setupUI {
    // Background View
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.backgroundBlurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.backgroundBlurView.frame = self.view.bounds;
    self.backgroundBlurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.backgroundBlurView];

    // Dismiss Chevron Button
    self.dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *chevronImg = [UIImage systemImageNamed:@"chevron.down"];
    [self.dismissButton setImage:chevronImg forState:UIControlStateNormal];
    self.dismissButton.tintColor = [UIColor whiteColor];
    self.dismissButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dismissButton addTarget:self action:@selector(dismissPlayer) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.dismissButton];

    // Header Title
    self.headerTitleLabel = [[UILabel alloc] init];
    self.headerTitleLabel.text = @"PLAYING FROM DOWNLOADS";
    self.headerTitleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    self.headerTitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    self.headerTitleLabel.textAlignment = NSTextAlignmentCenter;
    self.headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.headerTitleLabel];

    // Artwork Container with Shadow
    self.artworkShadowView = [[UIView alloc] init];
    self.artworkShadowView.backgroundColor = [UIColor clearColor];
    self.artworkShadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.artworkShadowView.layer.shadowOffset = CGSizeMake(0, 12);
    self.artworkShadowView.layer.shadowOpacity = 0.5;
    self.artworkShadowView.layer.shadowRadius = 16.0;
    self.artworkShadowView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.artworkShadowView];

    self.artworkImageView = [[UIImageView alloc] init];
    self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkImageView.layer.cornerRadius = 16.0;
    self.artworkImageView.layer.masksToBounds = YES;
    self.artworkImageView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.artworkImageView.tintColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.artworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.artworkShadowView addSubview:self.artworkImageView];

    // Song Title Label
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.textAlignment = NSTextAlignmentLeft;
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.8;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];

    // Artist Name Label
    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.artistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    self.artistLabel.textAlignment = NSTextAlignmentLeft;
    self.artistLabel.numberOfLines = 1;
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.artistLabel];

    // Progress Slider
    self.progressSlider = [[UISlider alloc] init];
    self.progressSlider.minimumTrackTintColor = [UIColor redColor];
    self.progressSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    self.progressSlider.thumbTintColor = [UIColor redColor];
    [self.progressSlider setThumbImage:[self createThumbImageWithSize:CGSizeMake(12, 12) color:[UIColor redColor]] forState:UIControlStateNormal];
    self.progressSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.progressSlider addTarget:self action:@selector(sliderTouchBegan:) forControlEvents:UIControlEventTouchDown];
    [self.progressSlider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [self.progressSlider addTarget:self action:@selector(sliderTouchEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.view addSubview:self.progressSlider];

    // Time Labels
    self.currentTimeLabel = [[UILabel alloc] init];
    self.currentTimeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.currentTimeLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    self.currentTimeLabel.text = @"0:00";
    self.currentTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.currentTimeLabel];

    self.durationLabel = [[UILabel alloc] init];
    self.durationLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.durationLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    self.durationLabel.text = @"0:00";
    self.durationLabel.textAlignment = NSTextAlignmentRight;
    self.durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.durationLabel];

    // Control Buttons
    self.shuffleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shuffleButton setImage:[UIImage systemImageNamed:@"shuffle"] forState:UIControlStateNormal];
    self.shuffleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shuffleButton addTarget:self action:@selector(toggleShuffle) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.shuffleButton];

    self.prevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.prevButton setImage:[UIImage systemImageNamed:@"backward.fill"] forState:UIControlStateNormal];
    self.prevButton.tintColor = [UIColor whiteColor];
    self.prevButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.prevButton addTarget:self action:@selector(playPreviousTrack) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.prevButton];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playPauseButton.backgroundColor = [UIColor whiteColor];
    self.playPauseButton.tintColor = [UIColor blackColor];
    self.playPauseButton.layer.cornerRadius = 32.0;
    self.playPauseButton.layer.masksToBounds = YES;
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.playPauseButton addTarget:self action:@selector(togglePlayPause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.playPauseButton];

    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.nextButton setImage:[UIImage systemImageNamed:@"forward.fill"] forState:UIControlStateNormal];
    self.nextButton.tintColor = [UIColor whiteColor];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.nextButton addTarget:self action:@selector(playNextTrack) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.nextButton];

    self.repeatButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat"] forState:UIControlStateNormal];
    self.repeatButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.repeatButton addTarget:self action:@selector(toggleRepeat) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.repeatButton];

    [self updateControlButtonsStyle];
    [self updatePlayPauseButtonImage];
    [self setupConstraints];
}

- (UIImage *)createThumbImageWithSize:(CGSize)size color:(UIColor *)color {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(0, 0, size.width, size.height));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)updatePlayPauseButtonImage {
    BOOL isPlaying = (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying);
    NSString *symbolName = isPlaying ? @"pause.fill" : @"play.fill";
    UIImage *img = [UIImage systemImageNamed:symbolName];
    [self.playPauseButton setImage:img forState:UIControlStateNormal];
}

- (void)updateControlButtonsStyle {
    // Shuffle Button Tint
    self.shuffleButton.tintColor = self.isShuffle ? [UIColor redColor] : [UIColor colorWithWhite:1.0 alpha:0.5];

    // Repeat Button Tint & Icon
    if (self.repeatMode == YTMPlayerRepeatModeOff) {
        [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat"] forState:UIControlStateNormal];
        self.repeatButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    } else if (self.repeatMode == YTMPlayerRepeatModeAll) {
        [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat"] forState:UIControlStateNormal];
        self.repeatButton.tintColor = [UIColor redColor];
    } else if (self.repeatMode == YTMPlayerRepeatModeOne) {
        [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat.1"] forState:UIControlStateNormal];
        self.repeatButton.tintColor = [UIColor redColor];
    }
}

- (void)setupConstraints {
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        // Dismiss Button
        [self.dismissButton.topAnchor constraintEqualToAnchor:guide.topAnchor constant:12],
        [self.dismissButton.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [self.dismissButton.widthAnchor constraintEqualToConstant:32],
        [self.dismissButton.heightAnchor constraintEqualToConstant:32],

        // Header Label
        [self.headerTitleLabel.centerYAnchor constraintEqualToAnchor:self.dismissButton.centerYAnchor],
        [self.headerTitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        // Artwork Container
        [self.artworkShadowView.topAnchor constraintEqualToAnchor:self.dismissButton.bottomAnchor constant:24],
        [self.artworkShadowView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.artworkShadowView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8],
        [self.artworkShadowView.heightAnchor constraintEqualToAnchor:self.artworkShadowView.widthAnchor],

        [self.artworkImageView.topAnchor constraintEqualToAnchor:self.artworkShadowView.topAnchor],
        [self.artworkImageView.bottomAnchor constraintEqualToAnchor:self.artworkShadowView.bottomAnchor],
        [self.artworkImageView.leadingAnchor constraintEqualToAnchor:self.artworkShadowView.leadingAnchor],
        [self.artworkImageView.trailingAnchor constraintEqualToAnchor:self.artworkShadowView.trailingAnchor],

        // Song Title
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkShadowView.bottomAnchor constant:36],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24],

        // Artist Name
        [self.artistLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        // Progress Slider
        [self.progressSlider.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:24],
        [self.progressSlider.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
        [self.progressSlider.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24],

        // Current Time Label
        [self.currentTimeLabel.topAnchor constraintEqualToAnchor:self.progressSlider.bottomAnchor constant:6],
        [self.currentTimeLabel.leadingAnchor constraintEqualToAnchor:self.progressSlider.leadingAnchor],

        // Duration Label
        [self.durationLabel.topAnchor constraintEqualToAnchor:self.progressSlider.bottomAnchor constant:6],
        [self.durationLabel.trailingAnchor constraintEqualToAnchor:self.progressSlider.trailingAnchor],

        // Play/Pause Button
        [self.playPauseButton.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-40],
        [self.playPauseButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.playPauseButton.widthAnchor constraintEqualToConstant:64],
        [self.playPauseButton.heightAnchor constraintEqualToConstant:64],

        // Previous Button
        [self.prevButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.prevButton.trailingAnchor constraintEqualToAnchor:self.playPauseButton.leadingAnchor constant:-32],
        [self.prevButton.widthAnchor constraintEqualToConstant:36],
        [self.prevButton.heightAnchor constraintEqualToConstant:36],

        // Next Button
        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.nextButton.leadingAnchor constraintEqualToAnchor:self.playPauseButton.trailingAnchor constant:32],
        [self.nextButton.widthAnchor constraintEqualToConstant:36],
        [self.nextButton.heightAnchor constraintEqualToConstant:36],

        // Shuffle Button
        [self.shuffleButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.shuffleButton.trailingAnchor constraintEqualToAnchor:self.prevButton.leadingAnchor constant:-28],
        [self.shuffleButton.widthAnchor constraintEqualToConstant:28],
        [self.shuffleButton.heightAnchor constraintEqualToConstant:28],

        // Repeat Button
        [self.repeatButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.repeatButton.leadingAnchor constraintEqualToAnchor:self.nextButton.trailingAnchor constant:28],
        [self.repeatButton.widthAnchor constraintEqualToConstant:28],
        [self.repeatButton.heightAnchor constraintEqualToConstant:28],
    ]];
}

- (void)dismissPlayer {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
