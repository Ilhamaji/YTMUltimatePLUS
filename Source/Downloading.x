#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

static id callObjectSelector(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    IMP imp = [target methodForSelector:sel];
    id (*func)(id, SEL) = (id (*)(id, SEL))imp;
    return func(target, sel);
}

static YTPlayerResponse *findPlayerResponseInHierarchy(UIViewController *playingVC) {
    if (!playingVC) return nil;
    
    NSMutableArray *candidates = [NSMutableArray array];
    if (playingVC) [candidates addObject:playingVC];
    if (playingVC.parentViewController) [candidates addObject:playingVC.parentViewController];
    
    for (UIViewController *vc in @[playingVC, playingVC.parentViewController ?: (id)[NSNull null]]) {
        if ([vc isKindOfClass:[NSNull class]]) continue;
        
        id pvc1 = callObjectSelector(vc, NSSelectorFromString(@"playerViewController"));
        if (pvc1) [candidates addObject:pvc1];
        
        if (class_getInstanceVariable([vc class], "_playerViewController") != NULL) {
            id pvc2 = [vc valueForKey:@"_playerViewController"];
            if (pvc2) [candidates addObject:pvc2];
        }
    }
    
    for (id obj in candidates) {
        if ([obj isKindOfClass:[NSNull class]]) continue;
        
        for (NSString *selName in @[@"playerResponse", @"activePlayerResponse", @"playerData"]) {
            SEL sel = NSSelectorFromString(selName);
            id result = callObjectSelector(obj, sel);
            if (result) return (YTPlayerResponse *)result;
        }
        
        for (NSString *ivarName in @[@"_playerResponse", @"_playerData", @"_activePlayerResponse"]) {
            if (class_getInstanceVariable([obj class], [ivarName UTF8String]) != NULL) {
                id result = [obj valueForKey:ivarName];
                if (result) return (YTPlayerResponse *)result;
            }
        }
    }
    
    return nil;
}

static NSString *getContentVideoIDFromHierarchy(UIViewController *playingVC) {
    if (!playingVC) return nil;
    
    NSMutableArray *candidates = [NSMutableArray array];
    if (playingVC) [candidates addObject:playingVC];
    if (playingVC.parentViewController) [candidates addObject:playingVC.parentViewController];
    
    for (UIViewController *vc in @[playingVC, playingVC.parentViewController ?: (id)[NSNull null]]) {
        if ([vc isKindOfClass:[NSNull class]]) continue;
        
        id pvc1 = callObjectSelector(vc, NSSelectorFromString(@"playerViewController"));
        if (pvc1) [candidates addObject:pvc1];
        
        if (class_getInstanceVariable([vc class], "_playerViewController") != NULL) {
            id pvc2 = [vc valueForKey:@"_playerViewController"];
            if (pvc2) [candidates addObject:pvc2];
        }
    }
    
    for (id obj in candidates) {
        if ([obj isKindOfClass:[NSNull class]]) continue;
        
        for (NSString *selName in @[@"contentVideoID", @"currentVideoID", @"videoId"]) {
            SEL sel = NSSelectorFromString(selName);
            id result = callObjectSelector(obj, sel);
            if ([result isKindOfClass:[NSString class]] && [(NSString *)result length] > 0) {
                return (NSString *)result;
            }
        }
        
        for (NSString *ivarName in @[@"_contentVideoID", @"_videoID", @"_currentVideoID"]) {
            if (class_getInstanceVariable([obj class], [ivarName UTF8String]) != NULL) {
                id result = [obj valueForKey:ivarName];
                if ([result isKindOfClass:[NSString class]] && [(NSString *)result length] > 0) {
                    return (NSString *)result;
                }
            }
        }
    }
    
    return nil;
}

static CGFloat getTotalMediaTimeFromHierarchy(UIViewController *playingVC) {
    if (!playingVC) return 0;
    
    NSMutableArray *candidates = [NSMutableArray array];
    if (playingVC) [candidates addObject:playingVC];
    if (playingVC.parentViewController) [candidates addObject:playingVC.parentViewController];
    
    for (id obj in candidates) {
        if ([obj respondsToSelector:NSSelectorFromString(@"currentVideoTotalMediaTime")]) {
            SEL sel = NSSelectorFromString(@"currentVideoTotalMediaTime");
            IMP imp = [obj methodForSelector:sel];
            CGFloat (*func)(id, SEL) = (CGFloat (*)(id, SEL))imp;
            return func(obj, sel);
        }
    }
    return 0;
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerResponse;
- (void)downloadCoverImage:(YTPlayerViewController *)playerResponse;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {

    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }

    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    if (![node.key isEqualToString:@"music_download_badge_1"]) {
        return %orig;
    }

    if (![tapRecognizer.view._viewControllerForAncestor isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)tapRecognizer.view._viewControllerForAncestor;
    YTMWatchViewController *watchVC = (YTMWatchViewController *)playingVC.parentViewController;
    YTPlayerViewController *playerVC = watchVC ? watchVC.playerViewController : nil;
    
    YTPlayerResponse *playerResponse = findPlayerResponseInHierarchy(playingVC);

    if (playerResponse) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapRecognizer.view;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:playerVC ? playerVC : (id)playingVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:playerVC ? playerVC : (id)playingVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
            [sheetController presentFromViewController:playingVC animated:YES completion:nil];
        } else if (YTMU(@"downloadAudio")) {
            [self downloadAudio:playerVC ? playerVC : (id)playingVC];
        } else if (YTMU(@"downloadCoverImage")) {
            [self downloadCoverImage:playerVC ? playerVC : (id)playingVC];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    YTPlayerResponse *playerResponse = findPlayerResponseInHierarchy((id)playerVC);
    if (!playerResponse) return;

    YTIPlayerResponse *playerData = nil;
    if ([playerResponse respondsToSelector:@selector(playerData)]) {
        playerData = callObjectSelector(playerResponse, @selector(playerData));
    } else {
        playerData = (id)playerResponse;
    }
    
    YTIVideoDetails *videoDetails = callObjectSelector(playerData, NSSelectorFromString(@"videoDetails"));
    YTIStreamingData *streamingData = callObjectSelector(playerData, NSSelectorFromString(@"streamingData"));
    
    NSString *rawTitle = [videoDetails respondsToSelector:@selector(title)] ? videoDetails.title : @"Downloaded Track";
    NSString *rawAuthor = [videoDetails respondsToSelector:@selector(author)] ? videoDetails.author : @"YouTube Music";
    
    NSString *title = [rawTitle stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *author = [rawAuthor stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *urlStr = [streamingData respondsToSelector:@selector(hlsManifestURL)] ? streamingData.hlsManifestURL : nil;
    NSString *videoID = getContentVideoIDFromHierarchy((id)playerVC);

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = videoID;
    ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
    ffmpeg.videoId = videoID;
    ffmpeg.trackTitle = title;
    ffmpeg.trackAuthor = author;
    ffmpeg.duration = round(getTotalMediaTimeFromHierarchy((id)playerVC));

    NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];
    
    if (extractedURL.length > 0) {
        [ffmpeg downloadAudio:extractedURL];

        if ([videoDetails respondsToSelector:@selector(thumbnail)]) {
            YTIThumbnailDetails *thumbnailDetails = videoDetails.thumbnail;
            if ([thumbnailDetails respondsToSelector:@selector(thumbnailsArray)]) {
                NSMutableArray *thumbnailsArray = [thumbnailDetails performSelector:@selector(thumbnailsArray)];
                YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
                if (thumbnail && thumbnail.URL) {
                    NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnail.URL]];
                    if (imageData) {
                        NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
                        NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@ - %@.png", author, title]];
                        [imageData writeToURL:coverURL atomically:YES];
                    }
                }
            }
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
    }
}

%new
- (NSString *)getURLFromManifest:(NSURL *)manifest {
    NSData *manifestData = [NSData dataWithContentsOfURL:manifest];
    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    NSArray *groupIDS = @[@"234", @"233"]; // Our priority to find group id 234
    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];

                if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        hud.mode = MBProgressHUDModeIndeterminate;
    });

    YTPlayerResponse *playerResponse = findPlayerResponseInHierarchy((id)playerVC);
    if (!playerResponse) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];
        });
        return;
    }

    YTIPlayerResponse *playerData = nil;
    if ([playerResponse respondsToSelector:@selector(playerData)]) {
        playerData = callObjectSelector(playerResponse, @selector(playerData));
    } else {
        playerData = (id)playerResponse;
    }
    
    YTIVideoDetails *videoDetails = callObjectSelector(playerData, NSSelectorFromString(@"videoDetails"));

    if ([videoDetails respondsToSelector:@selector(thumbnail)]) {
        YTIThumbnailDetails *thumbnailDetails = videoDetails.thumbnail;
        if ([thumbnailDetails respondsToSelector:@selector(thumbnailsArray)]) {
            NSMutableArray *thumbnailsArray = [thumbnailDetails performSelector:@selector(thumbnailsArray)];
            YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
            if (thumbnail && thumbnail.URL) {
                NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];

                FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
                [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];
            }
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [hud hideAnimated:YES];
    });
}
%end
