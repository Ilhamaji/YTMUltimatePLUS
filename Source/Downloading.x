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
    [request setValue:@"Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    
    NSDictionary *bodyDict = @{
        @"context": @{
            @"client": @{
                @"clientName": @"ANDROID",
                @"clientVersion": @"19.05.36",
                @"androidSdkVersion": @30,
                @"hl": @"en",
                @"gl": @"US"
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

static NSString *extractURLFromFormatDict(NSDictionary *fmt) {
    if (![fmt isKindOfClass:[NSDictionary class]]) return nil;
    
    NSString *url = fmt[@"url"];
    if ([url isKindOfClass:[NSString class]] && url.length > 0) return url;
    
    NSString *cipher = fmt[@"signatureCipher"] ?: fmt[@"cipher"];
    if ([cipher isKindOfClass:[NSString class]] && cipher.length > 0) {
        NSArray *components = [cipher componentsSeparatedByString:@"&"];
        for (NSString *comp in components) {
            if ([comp hasPrefix:@"url="]) {
                NSString *encodedURL = [comp substringFromIndex:4];
                NSString *decodedURL = [encodedURL stringByRemovingPercentEncoding];
                if (decodedURL.length > 0) return decodedURL;
            }
        }
    }
    
    return nil;
}

static NSString *extractAudioURLFromPlayerResponse(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    
    NSDictionary *streamingData = json[@"streamingData"];
    if (![streamingData isKindOfClass:[NSDictionary class]]) return nil;
    
    NSString *hls = streamingData[@"hlsManifestURL"];
    if ([hls isKindOfClass:[NSString class]] && hls.length > 0) {
        return hls;
    }
    
    NSArray *adaptiveFormats = streamingData[@"adaptiveFormats"];
    if ([adaptiveFormats isKindOfClass:[NSArray class]]) {
        NSString *bestAudioURL = nil;
        NSInteger highestBitrate = 0;
        
        for (NSDictionary *fmt in adaptiveFormats) {
            if (![fmt isKindOfClass:[NSDictionary class]]) continue;
            NSString *mime = fmt[@"mimeType"];
            NSString *urlStr = extractURLFromFormatDict(fmt);
            
            if ([mime isKindOfClass:[NSString class]] && [mime containsString:@"audio/"] && [urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
                NSInteger bitrate = [fmt[@"bitrate"] integerValue];
                if (bitrate > highestBitrate || !bestAudioURL) {
                    highestBitrate = bitrate;
                    bestAudioURL = urlStr;
                }
            }
        }
        
        if (bestAudioURL) return bestAudioURL;
    }
    
    NSArray *formats = streamingData[@"formats"];
    if ([formats isKindOfClass:[NSArray class]]) {
        for (NSDictionary *fmt in formats) {
            if (![fmt isKindOfClass:[NSDictionary class]]) continue;
            NSString *urlStr = extractURLFromFormatDict(fmt);
            if ([urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
                return urlStr;
            }
        }
    }
    
    return nil;
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

static void extractVideoIdAndTitleFromObject(id obj, NSString **outVideoId, NSString **outTitle) {
    if (!obj) return;
    
    NSString *vId = nil;
    NSString *tTitle = nil;
    
    if ([obj respondsToSelector:NSSelectorFromString(@"videoId")]) {
        id v = callObjectSelector(obj, NSSelectorFromString(@"videoId"));
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) vId = v;
    }
    
    for (NSString *epKey in @[@"watchEndpoint", @"navigationEndpoint", @"endpoint", @"command", @"serviceEndpoint"]) {
        if (!vId && [obj respondsToSelector:NSSelectorFromString(epKey)]) {
            id ep = callObjectSelector(obj, NSSelectorFromString(epKey));
            if (ep) {
                if ([ep respondsToSelector:NSSelectorFromString(@"videoId")]) {
                    id v = callObjectSelector(ep, NSSelectorFromString(@"videoId"));
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) vId = v;
                }
                if (!vId && [ep respondsToSelector:NSSelectorFromString(@"watchEndpoint")]) {
                    id wep = callObjectSelector(ep, NSSelectorFromString(@"watchEndpoint"));
                    if (wep && [wep respondsToSelector:NSSelectorFromString(@"videoId")]) {
                        id v = callObjectSelector(wep, NSSelectorFromString(@"videoId"));
                        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) vId = v;
                    }
                }
            }
        }
    }
    
    for (NSString *renKey in @[@"playlistPanelVideoRenderer", @"musicResponsiveListItemRenderer", @"musicTwoRowItemRenderer", @"compactVideoRenderer"]) {
        if (!vId && [obj respondsToSelector:NSSelectorFromString(renKey)]) {
            id ren = callObjectSelector(obj, NSSelectorFromString(renKey));
            if (ren) {
                extractVideoIdAndTitleFromObject(ren, &vId, &tTitle);
            }
        }
    }
    
    if (vId) {
        if ([obj respondsToSelector:NSSelectorFromString(@"title")]) {
            id tObj = callObjectSelector(obj, NSSelectorFromString(@"title"));
            if ([tObj isKindOfClass:[NSString class]]) {
                tTitle = tObj;
            } else if (tObj) {
                if ([tObj respondsToSelector:NSSelectorFromString(@"runs")]) {
                    NSArray *runs = callObjectSelector(tObj, NSSelectorFromString(@"runs"));
                    if ([runs isKindOfClass:[NSArray class]] && runs.count > 0) {
                        id firstRun = runs.firstObject;
                        if ([firstRun respondsToSelector:NSSelectorFromString(@"text")]) {
                            id txt = callObjectSelector(firstRun, NSSelectorFromString(@"text"));
                            if ([txt isKindOfClass:[NSString class]]) tTitle = txt;
                        }
                    }
                }
            }
        }
        
        *outVideoId = vId;
        if (tTitle && !*outTitle) *outTitle = tTitle;
    }
}

static void scanObjectForTracks(id obj, NSMutableArray *tracks, NSMutableSet *visited) {
    if (!obj) return;
    NSValue *ptrVal = [NSValue valueWithNonretainedObject:obj];
    if ([visited containsObject:ptrVal]) return;
    [visited addObject:ptrVal];
    
    if (visited.count > 1000) return;
    
    NSString *clsName = NSStringFromClass([obj class]);
    if ([clsName containsString:@"Carousel"] || [clsName containsString:@"Recom"]) return;
    
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            scanObjectForTracks(item, tracks, visited);
        }
        return;
    }
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id val in [(NSDictionary *)obj allValues]) {
            scanObjectForTracks(val, tracks, visited);
        }
        return;
    }
    
    NSString *vId = nil;
    NSString *tTitle = nil;
    extractVideoIdAndTitleFromObject(obj, &vId, &tTitle);
    if (vId && vId.length > 0) {
        BOOL exists = NO;
        for (NSDictionary *d in tracks) {
            if ([d[@"videoId"] isEqualToString:vId]) {
                exists = YES;
                break;
            }
        }
        if (!exists) {
            [tracks addObject:@{
                @"videoId": vId,
                @"title": tTitle ?: @"Track"
            }];
        }
    }
    
    if ([obj isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)obj;
        id ds = cv.dataSource;
        if (ds && ds != cv) scanObjectForTracks(ds, tracks, visited);
    } else if ([obj isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)obj;
        id ds = tv.dataSource;
        if (ds && ds != tv) scanObjectForTracks(ds, tracks, visited);
    }
    
    NSArray *selNames = @[
        @"contents", @"items", @"sections", @"renderers", @"model", @"entry",
        @"renderer", @"playlistPanel", @"watchNextResponse", @"sectionListRenderer",
        @"playlistPanelRenderer", @"singleColumnWatchNextResults", @"results",
        @"playlist", @"playlistVideoListRenderer", @"playlistPanelVideoRenderer",
        @"musicResponsiveListItemRenderer", @"content"
    ];
    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel]) {
            id child = callObjectSelector(obj, sel);
            if (child) scanObjectForTracks(child, tracks, visited);
        }
    }
    
    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        if (class_getInstanceVariable([v class], "_controller") != NULL) {
            id controller = [v valueForKey:@"_controller"];
            if (controller) scanObjectForTracks(controller, tracks, visited);
        }
        for (UIView *sub in v.subviews) {
            scanObjectForTracks(sub, tracks, visited);
        }
    } else if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        if (vc.view) scanObjectForTracks(vc.view, tracks, visited);
        for (UIViewController *child in vc.childViewControllers) {
            scanObjectForTracks(child, tracks, visited);
        }
        if (vc.presentedViewController) scanObjectForTracks(vc.presentedViewController, tracks, visited);
    }
}

static NSArray<NSDictionary *> *extractPlaylistTracks(UIView *sourceView) {
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    
    if (sourceView) {
        if ([sourceView respondsToSelector:@selector(_viewControllerForAncestor)]) {
            UIViewController *anc = [sourceView _viewControllerForAncestor];
            if (anc) {
                scanObjectForTracks(anc, tracks, visited);
            }
        }
        if (tracks.count == 0) {
            scanObjectForTracks(sourceView, tracks, visited);
        }
    }
    
    if (tracks.count == 0 && gActivePlayerVC) {
        scanObjectForTracks(gActivePlayerVC, tracks, visited);
    }
    
    if (tracks.count == 0) {
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (window && window.rootViewController) {
            UIViewController *topVC = window.rootViewController;
            while (topVC.presentedViewController) {
                topVC = topVC.presentedViewController;
            }
            scanObjectForTracks(topVC, tracks, visited);
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
        
        NSString *audioURL = extractAudioURLFromPlayerResponse(json);
        if (!audioURL || audioURL.length == 0) {
            if (completion) completion();
            return;
        }
        
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
        
        NSString *downloadURL = nil;
        if ([audioURL containsString:@"m3u8"] || [audioURL containsString:@"manifest"]) {
            downloadURL = [self getURLFromManifest:[NSURL URLWithString:audioURL]];
        } else {
            downloadURL = audioURL;
        }
        
        if (downloadURL.length > 0) {
            BOOL downloaded = [ffmpeg downloadAudioSynchronous:downloadURL];
            
            if (downloaded) {
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
