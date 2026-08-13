#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FFMpegDownloader.h"
#import "Utils/YTMDownloadMetadata.h"
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

static NSDictionary *fetchPlayerResponseForVideoId(NSString *videoId) {
    if (!videoId || videoId.length == 0) return nil;
    
    NSURL *url = [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    
    NSDictionary *bodyDict = @{
        @"context": @{
            @"client": @{
                @"clientName": @"WEB_REMIX",
                @"clientVersion": @"1.20231214.00.00"
            }
        },
        @"videoId": videoId
    };
    
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
    request.HTTPBody = bodyData;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSDictionary *resultDict = nil;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                resultDict = json;
            }
        }
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
    
    return resultDict;
}

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(id)sourceView;
- (void)downloadAudioInternal:(id)sourceView completion:(void (^)(void))completion;
- (void)downloadTrackWithVideoId:(NSString *)videoId title:(NSString *)suggestedTitle playlistName:(NSString *)playlistName completion:(void (^)(void))completion;
- (void)downloadCoverImage:(id)sourceView;
- (void)downloadPlaylistTracks:(id)sourceView;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
@end

static NSString *getPlaylistTitleFromHierarchy(UIView *sourceView) {
    UIViewController *topVC = [sourceView respondsToSelector:@selector(_viewControllerForAncestor)] ? [sourceView _viewControllerForAncestor] : nil;
    if (!topVC) {
        topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
    }
    
    if ([topVC respondsToSelector:@selector(title)] && topVC.title.length > 0) {
        return topVC.title;
    }
    
    NSMutableArray *queue = [NSMutableArray arrayWithObject:topVC.view ?: sourceView];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            if (lbl.text.length > 0 && lbl.font.pointSize >= 18) {
                return lbl.text;
            }
        }
        for (UIView *sub in v.subviews) {
            [queue addObject:sub];
        }
    }
    return @"Downloaded Playlist";
}

static NSArray<NSDictionary *> *extractPlaylistTracks(UIView *sourceView) {
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    
    UIViewController *topVC = [sourceView respondsToSelector:@selector(_viewControllerForAncestor)] ? [sourceView _viewControllerForAncestor] : nil;
    if (!topVC) {
        topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
    }
    
    UIView *mainView = topVC.view ?: sourceView;
    if (!mainView) return tracks;
    
    NSMutableArray *queue = [NSMutableArray arrayWithObject:mainView];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([visited containsObject:v]) continue;
        [visited addObject:v];
        
        id node = nil;
        if (class_getInstanceVariable([v class], "_controller") != NULL) {
            node = [v valueForKey:@"_controller"];
        }
        
        id target = node ?: v;
        for (NSString *key in @[@"model", @"entry", @"renderer", @"command", @"endpoint", @"watchEndpoint"]) {
            if ([target respondsToSelector:NSSelectorFromString(key)]) {
                id res = callObjectSelector(target, NSSelectorFromString(key));
                if (res) {
                    NSString *vId = nil;
                    if ([res respondsToSelector:NSSelectorFromString(@"videoId")]) {
                        vId = callObjectSelector(res, NSSelectorFromString(@"videoId"));
                    } else if ([res respondsToSelector:NSSelectorFromString(@"watchEndpoint")]) {
                        id wep = callObjectSelector(res, NSSelectorFromString(@"watchEndpoint"));
                        if (wep && [wep respondsToSelector:NSSelectorFromString(@"videoId")]) {
                            vId = callObjectSelector(wep, NSSelectorFromString(@"videoId"));
                        }
                    }
                    
                    if (vId && [vId isKindOfClass:[NSString class]] && vId.length > 0) {
                        BOOL exists = NO;
                        for (NSDictionary *d in tracks) {
                            if ([d[@"videoId"] isEqualToString:vId]) {
                                exists = YES;
                                break;
                            }
                        }
                        if (!exists) {
                            NSString *trackTitle = @"Track";
                            if ([res respondsToSelector:NSSelectorFromString(@"title")]) {
                                id t = callObjectSelector(res, NSSelectorFromString(@"title"));
                                if ([t isKindOfClass:[NSString class]]) trackTitle = t;
                            }
                            
                            [tracks addObject:@{
                                @"videoId": vId,
                                @"title": trackTitle,
                                @"sourceView": v
                            }];
                        }
                    }
                }
            }
        }
        
        for (UIView *sub in v.subviews) {
            [queue addObject:sub];
        }
    }
    
    return tracks;
}

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

    BOOL isPlaylistDownload = [node.key containsString:@"playlist"] || [node.key containsString:@"header"];
    if (isPlaylistDownload) {
        [self downloadPlaylistTracks:(id)tapView];
        return;
    }

    YTPlayerResponse *playerResponse = findActivePlayerResponse(tapView);

    if (playerResponse) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapView;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:@"Download All Playlist Tracks" iconImage:[%c(YTUIResources) downloadOutline] style:0 handler:^ {
            [self downloadPlaylistTracks:(id)tapView];
        }]];

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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self downloadPlaylistTracks:sourceView];
        });
        return;
    }
    
    NSArray<NSDictionary *> *tracks = extractPlaylistTracks(sourceView);
    NSString *playlistName = getPlaylistTitleFromHierarchy(sourceView);
    
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;
    
    if (tracks.count == 0) {
        hud.label.text = @"Downloading Track...";
        [self downloadAudio:sourceView];
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];
        });
        return;
    }
    
    [YTMDownloadMetadata createPlaylistNamed:playlistName];
    hud.label.text = [NSString stringWithFormat:@"Downloading Playlist (%lu tracks)...", (unsigned long)tracks.count];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger count = 0;
        for (NSDictionary *dict in tracks) {
            count++;
            NSString *vId = dict[@"videoId"];
            NSString *tTitle = dict[@"title"];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                hud.label.text = [NSString stringWithFormat:@"Downloading (%lu/%lu): %@", (unsigned long)count, (unsigned long)tracks.count, tTitle ?: @"Track"];
            });
            
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            [self downloadTrackWithVideoId:vId title:tTitle playlistName:playlistName completion:^{
                dispatch_semaphore_signal(sema);
            }];
            dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];
            
            YTAlertView *alertView = [%c(YTAlertView) infoDialog];
            alertView.title = @"Playlist Download Complete";
            alertView.subtitle = [NSString stringWithFormat:@"Downloaded %lu tracks to '%@'", (unsigned long)tracks.count, playlistName];
            [alertView show];
            
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];
        });
    });
}

%new
- (void)downloadTrackWithVideoId:(NSString *)videoId title:(NSString *)suggestedTitle playlistName:(NSString *)playlistName completion:(void (^)(void))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *json = fetchPlayerResponseForVideoId(videoId);
        
        NSString *urlStr = json[@"streamingData"][@"hlsManifestURL"];
        NSDictionary *videoDetails = json[@"videoDetails"];
        
        NSString *rawTitle = videoDetails[@"title"] ?: suggestedTitle ?: @"Downloaded Track";
        NSString *rawAuthor = videoDetails[@"author"] ?: @"YouTube Music";
        
        NSString *title = [rawTitle stringByReplacingOccurrencesOfString:@"/" withString:@""];
        NSString *author = [rawAuthor stringByReplacingOccurrencesOfString:@"/" withString:@""];
        CGFloat duration = [videoDetails[@"lengthSeconds"] doubleValue];
        
        NSString *thumbnailURLStr = nil;
        NSArray *thumbnails = videoDetails[@"thumbnail"][@"thumbnails"];
        if ([thumbnails isKindOfClass:[NSArray class]] && thumbnails.count > 0) {
            thumbnailURLStr = [thumbnails lastObject][@"url"];
        }
        
        FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
        ffmpeg.tempName = videoId;
        ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
        ffmpeg.videoId = videoId;
        ffmpeg.trackTitle = title;
        ffmpeg.trackAuthor = author;
        ffmpeg.duration = round(duration);
        
        NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];
        if (extractedURL.length > 0) {
            [ffmpeg downloadAudio:extractedURL];
            
            if (thumbnailURLStr.length > 0) {
                NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnailURLStr]];
                if (imageData) {
                    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
                    NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@ - %@.png", author, title]];
                    [imageData writeToURL:coverURL atomically:YES];
                }
            }
            
            NSString *fileName = [NSString stringWithFormat:@"%@ - %@.m4a", author, title];
            if (playlistName.length > 0) {
                [YTMDownloadMetadata addTrack:fileName toPlaylist:playlistName];
            }
        }
        
        if (completion) {
            completion();
        }
    });
}

%new
- (void)downloadAudio:(UIView *)sourceView {
    [self downloadAudioInternal:sourceView completion:nil];
}

%new
- (void)downloadAudioInternal:(UIView *)sourceView completion:(void (^)(void))completion {
    __block YTPlayerResponse *playerResponse = nil;
    __block NSString *title = @"Downloaded Track";
    __block NSString *author = @"YouTube Music";
    __block NSString *urlStr = nil;
    __block NSString *videoID = nil;
    __block CGFloat duration = 0;
    __block NSString *thumbnailURLStr = nil;

    void (^extractMetadataBlock)(void) = ^{
        playerResponse = findActivePlayerResponse(sourceView);
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
        
        title = [rawTitle stringByReplacingOccurrencesOfString:@"/" withString:@""];
        author = [rawAuthor stringByReplacingOccurrencesOfString:@"/" withString:@""];
        urlStr = [streamingData respondsToSelector:@selector(hlsManifestURL)] ? streamingData.hlsManifestURL : nil;
        videoID = getContentVideoIDFromHierarchy(sourceView);
        duration = getTotalMediaTimeFromHierarchy(sourceView);

        if ([videoDetails respondsToSelector:@selector(thumbnail)]) {
            YTIThumbnailDetails *thumbnailDetails = videoDetails.thumbnail;
            if ([thumbnailDetails respondsToSelector:@selector(thumbnailsArray)]) {
                NSMutableArray *thumbnailsArray = [thumbnailDetails performSelector:@selector(thumbnailsArray)];
                YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
                if (thumbnail && thumbnail.URL) {
                    thumbnailURLStr = thumbnail.URL;
                }
            }
        }
    };

    if ([NSThread isMainThread]) {
        extractMetadataBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), extractMetadataBlock);
    }

    if (!playerResponse) {
        if (completion) completion();
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
        ffmpeg.tempName = videoID;
        ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
        ffmpeg.videoId = videoID;
        ffmpeg.trackTitle = title;
        ffmpeg.trackAuthor = author;
        ffmpeg.duration = round(duration);

        NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];
        
        if (extractedURL.length > 0) {
            [ffmpeg downloadAudio:extractedURL];

            if (thumbnailURLStr.length > 0) {
                NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnailURLStr]];
                if (imageData) {
                    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
                    NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@ - %@.png", author, title]];
                    [imageData writeToURL:coverURL atomically:YES];
                }
            }
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                YTAlertView *alertView = [%c(YTAlertView) infoDialog];
                alertView.title = LOC(@"OOPS");
                alertView.subtitle = LOC(@"LINK_NOT_FOUND");
                [alertView show];
            });
        }
        
        if (completion) {
            completion();
        }
    });
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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self downloadCoverImage:sourceView];
        });
        return;
    }
    
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;

    YTPlayerResponse *playerResponse = findActivePlayerResponse(sourceView);
    if (!playerResponse) {
        [hud hideAnimated:YES];
        return;
    }

    YTIPlayerResponse *playerData = nil;
    if ([playerResponse respondsToSelector:@selector(playerData)]) {
        playerData = callObjectSelector(playerResponse, @selector(playerData));
    } else {
        playerData = (id)playerResponse;
    }
    
    YTIVideoDetails *videoDetails = callObjectSelector(playerData, NSSelectorFromString(@"videoDetails"));

    NSString *thumbnailURL = nil;
    if ([videoDetails respondsToSelector:@selector(thumbnail)]) {
        YTIThumbnailDetails *thumbnailDetails = videoDetails.thumbnail;
        if ([thumbnailDetails respondsToSelector:@selector(thumbnailsArray)]) {
            NSMutableArray *thumbnailsArray = [thumbnailDetails performSelector:@selector(thumbnailsArray)];
            YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
            if (thumbnail && thumbnail.URL) {
                thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];
            }
        }
    }

    if (thumbnailURL.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
            [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [hud hideAnimated:YES];
            });
        });
    } else {
        [hud hideAnimated:YES];
    }
}
%end
