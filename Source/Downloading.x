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

@interface UIView (YTMAncestor)
- (UIViewController *)_viewControllerForAncestor;
@end

static __weak id gActivePlayerResponse = nil;
static __weak id gActivePlayerVC = nil;

%hook YTPlayerViewController
- (void)setPlayerResponse:(id)response {
    gActivePlayerResponse = response;
    gActivePlayerVC = self;
    %orig;
}
%end

%hook YTMWatchViewController
- (void)setPlayerResponse:(id)response {
    gActivePlayerResponse = response;
    %orig;
}
- (void)setPlayerViewController:(id)playerVC {
    gActivePlayerVC = playerVC;
    %orig;
}
%end

static id callObjectSelector(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    IMP imp = [target methodForSelector:sel];
    id (*func)(id, SEL) = (id (*)(id, SEL))imp;
    return func(target, sel);
}

static id findPlayerResponseInObject(id obj, NSMutableSet *visited) {
    if (!obj || [visited containsObject:obj]) return nil;
    [visited addObject:obj];
    
    for (NSString *selName in @[@"playerResponse", @"activePlayerResponse", @"playerData"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel]) {
            id res = callObjectSelector(obj, sel);
            if (res) return res;
        }
    }
    
    for (NSString *ivarName in @[@"_playerResponse", @"_playerData", @"_activePlayerResponse", @"_playerViewController"]) {
        if (class_getInstanceVariable([obj class], [ivarName UTF8String]) != NULL) {
            id res = [obj valueForKey:ivarName];
            if (res) {
                id found = findPlayerResponseInObject(res, visited);
                if (found) return found;
            }
        }
    }
    
    if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        if (vc.parentViewController) {
            id found = findPlayerResponseInObject(vc.parentViewController, visited);
            if (found) return found;
        }
        if (vc.presentedViewController) {
            id found = findPlayerResponseInObject(vc.presentedViewController, visited);
            if (found) return found;
        }
        for (UIViewController *child in vc.childViewControllers) {
            id found = findPlayerResponseInObject(child, visited);
            if (found) return found;
        }
    }
    
    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        if ([v respondsToSelector:@selector(_viewControllerForAncestor)]) {
            id ancestor = [v _viewControllerForAncestor];
            if (ancestor) {
                id found = findPlayerResponseInObject(ancestor, visited);
                if (found) return found;
            }
        }
        if (v.nextResponder) {
            id found = findPlayerResponseInObject(v.nextResponder, visited);
            if (found) return found;
        }
        for (UIView *sub in v.subviews) {
            id found = findPlayerResponseInObject(sub, visited);
            if (found) return found;
        }
    }
    
    return nil;
}

static YTPlayerResponse *findActivePlayerResponse(UIView *sourceView) {
    if (gActivePlayerResponse) {
        return (YTPlayerResponse *)gActivePlayerResponse;
    }
    
    NSMutableSet *visited = [NSMutableSet set];
    if (sourceView) {
        id resp = findPlayerResponseInObject(sourceView, visited);
        if (resp) return (YTPlayerResponse *)resp;
    }
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (window && window.rootViewController) {
        id resp = findPlayerResponseInObject(window.rootViewController, visited);
        if (resp) return (YTPlayerResponse *)resp;
    }
    
    return nil;
}

static NSString *getContentVideoIDFromHierarchy(UIView *sourceView) {
    if (gActivePlayerVC) {
        for (NSString *selName in @[@"contentVideoID", @"currentVideoID", @"videoId"]) {
            SEL sel = NSSelectorFromString(selName);
            id res = callObjectSelector(gActivePlayerVC, sel);
            if ([res isKindOfClass:[NSString class]] && [(NSString *)res length] > 0) {
                return (NSString *)res;
            }
        }
    }
    
    id playerResp = findActivePlayerResponse(sourceView);
    if (playerResp) {
        id playerData = [playerResp respondsToSelector:@selector(playerData)] ? callObjectSelector(playerResp, @selector(playerData)) : playerResp;
        id videoDetails = callObjectSelector(playerData, NSSelectorFromString(@"videoDetails"));
        if (videoDetails && [videoDetails respondsToSelector:NSSelectorFromString(@"videoId")]) {
            NSString *vId = callObjectSelector(videoDetails, NSSelectorFromString(@"videoId"));
            if ([vId isKindOfClass:[NSString class]] && vId.length > 0) return vId;
        }
    }
    
    return nil;
}

static CGFloat getTotalMediaTimeFromHierarchy(UIView *sourceView) {
    if (gActivePlayerVC && [gActivePlayerVC respondsToSelector:NSSelectorFromString(@"currentVideoTotalMediaTime")]) {
        SEL sel = NSSelectorFromString(@"currentVideoTotalMediaTime");
        IMP imp = [gActivePlayerVC methodForSelector:sel];
        CGFloat (*func)(id, SEL) = (CGFloat (*)(id, SEL))imp;
        return func(gActivePlayerVC, sel);
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

    BOOL isDownloadNode = [node.key containsString:@"download"] || [node.key containsString:@"offline"];
    if (!isDownloadNode) {
        return %orig;
    }

    UIView *tapView = tapRecognizer.view;
    UIViewController *presentingVC = [tapView respondsToSelector:@selector(_viewControllerForAncestor)] ? [tapView _viewControllerForAncestor] : nil;
    if (!presentingVC) {
        presentingVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    }

    YTPlayerResponse *playerResponse = findActivePlayerResponse(tapView);

    if (playerResponse) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapView;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        BOOL isPlaylistDownload = [node.key containsString:@"playlist"] || [node.key containsString:@"header"];
        if (isPlaylistDownload) {
            [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:@"Download All Playlist Tracks" iconImage:[%c(YTUIResources) downloadOutline] style:0 handler:^ {
                [self downloadPlaylistTracks:(id)tapView];
            }]];
        }

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:(id)tapView];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:(id)tapView];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
            [sheetController presentFromViewController:presentingVC animated:YES completion:nil];
        } else if (YTMU(@"downloadAudio")) {
            [self downloadAudio:(id)tapView];
        } else if (YTMU(@"downloadCoverImage")) {
            [self downloadCoverImage:(id)tapView];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadPlaylistTracks:(UIView *)sourceView {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.label.text = @"Downloading Playlist Tracks...";
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self downloadAudio:sourceView];
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];
        });
    });
}

%new
- (void)downloadAudio:(UIView *)sourceView {
    YTPlayerResponse *playerResponse = findActivePlayerResponse(sourceView);
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
    NSString *videoID = getContentVideoIDFromHierarchy(sourceView);

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = videoID;
    ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
    ffmpeg.videoId = videoID;
    ffmpeg.trackTitle = title;
    ffmpeg.trackAuthor = author;
    ffmpeg.duration = round(getTotalMediaTimeFromHierarchy(sourceView));

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
- (void)downloadCoverImage:(UIView *)sourceView {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        hud.mode = MBProgressHUDModeIndeterminate;
    });

    YTPlayerResponse *playerResponse = findActivePlayerResponse(sourceView);
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
