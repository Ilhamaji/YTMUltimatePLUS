#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

typedef NS_ENUM(NSInteger, YTMPlayerRepeatMode) {
    YTMPlayerRepeatModeOff = 0,
    YTMPlayerRepeatModeAll = 1,
    YTMPlayerRepeatModeOne = 2
};

@interface YTMOfflinePlayerViewController : UIViewController

@property (nonatomic, strong) NSArray<NSString *> *playlist;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) BOOL isShuffle;
@property (nonatomic, assign) YTMPlayerRepeatMode repeatMode;

- (instancetype)initWithPlaylist:(NSArray<NSString *> *)playlist initialIndex:(NSInteger)index;
- (void)playPlaylist:(NSArray<NSString *> *)playlist initialIndex:(NSInteger)index;

+ (instancetype)sharedPlayerViewController;

@end
