#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Headers/YTICommand.h"
#import "Headers/YTPlayerResponse.h"
#import "Utils/YTMDownloadMetadata.h"

@interface YTIVideoDetails (YTM)
@property (nonatomic, copy, readwrite) NSString *videoId;
@end

@interface YTPlayerResponse (YTM)
- (NSString *)contentVideoID;
@end

@interface YTIWatchEndpoint : NSObject
@property (nonatomic, copy, readwrite) NSString *videoId;
@property (nonatomic, copy, readwrite) NSString *playlistId;
@property (nonatomic, assign, readwrite) unsigned int index;
@end

@interface YTICommand (Watch)
@property (nonatomic, readwrite, strong) YTIWatchEndpoint *watchEndpoint;
@end

@interface UIViewController (YTCommand)
- (void)handleCommand:(YTICommand *)command sender:(id)sender;
- (void)handleCommand:(YTICommand *)command;
@end

@interface YTIMusicAppViewController : UIViewController
- (void)handleCommand:(YTICommand *)command sender:(id)sender;
@end

@implementation UIViewController (YTMNativePlayer)

+ (void)ytm_playVideoWithID:(NSString *)videoId fromSender:(id)sender {
    if (!videoId || videoId.length == 0) return;
    
    YTIWatchEndpoint *watchEndpoint = [%c(YTIWatchEndpoint) new];
    watchEndpoint.videoId = videoId;
    
    YTICommand *command = [%c(YTICommand) new];
    command.watchEndpoint = watchEndpoint;
    
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    
    if ([topVC respondsToSelector:@selector(handleCommand:sender:)]) {
        [topVC handleCommand:command sender:sender];
    } else if ([topVC respondsToSelector:@selector(handleCommand:)]) {
        [topVC handleCommand:command];
    } else {
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIViewController *rootVC = window.rootViewController;
        if ([rootVC respondsToSelector:@selector(handleCommand:sender:)]) {
            [(id)rootVC handleCommand:command sender:sender];
        } else if ([rootVC respondsToSelector:@selector(handleCommand:)]) {
            [(id)rootVC handleCommand:command];
        }
    }
}

@end

%hook YTPlayerResponse
- (YTIStreamingData *)streamingData {
    YTIStreamingData *sd = %orig;
    
    NSString *vId = nil;
    if ([self respondsToSelector:@selector(videoDetails)]) {
        vId = self.playerData.videoDetails.videoId;
    }
    if (!vId && [self respondsToSelector:@selector(contentVideoID)]) {
        vId = [(id)self contentVideoID];
    }
    
    if (vId) {
        NSString *localFileName = [YTMDownloadMetadata fileNameForVideoId:vId];
        if (!localFileName) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *directURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", vId]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:directURL.path]) {
                localFileName = vId;
            }
        }
        
        if (localFileName) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *localAudioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", localFileName]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:localAudioURL.path]) {
                sd.hlsManifestURL = localAudioURL.absoluteString;
            }
        }
    }
    
    return sd;
}
%end

%hook YTPlayerViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_pauseOnlinePlayer) name:@"YTMU_PauseOnlinePlayerNotification" object:nil];
}
%new
- (void)ytmu_pauseOnlinePlayer {
    dispatch_async(dispatch_get_main_queue(), ^{
        id playerObj = (id)self;
        if ([playerObj respondsToSelector:@selector(pause)]) {
            [playerObj performSelector:@selector(pause)];
        } else if ([playerObj respondsToSelector:@selector(pauseVideo)]) {
            [playerObj performSelector:@selector(pauseVideo)];
        }
    });
}
%end
