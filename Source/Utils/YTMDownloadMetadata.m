#import "YTMDownloadMetadata.h"

@implementation YTMDownloadMetadata

+ (NSURL *)metadataFileURL {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate/metadata.json"];
}

+ (NSMutableDictionary *)loadAll {
    NSURL *fileURL = [self metadataFileURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
        return [NSMutableDictionary dictionary];
    }
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data) return [NSMutableDictionary dictionary];
    
    NSError *error = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error || ![dict isKindOfClass:[NSDictionary class]]) {
        return [NSMutableDictionary dictionary];
    }
    return [dict mutableCopy];
}

+ (void)saveAll:(NSDictionary *)metadataDict {
    NSURL *fileURL = [self metadataFileURL];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:metadataDict options:NSJSONWritingPrettyPrinted error:&error];
    if (data && !error) {
        [data writeToURL:fileURL atomically:YES];
    }
}

+ (void)saveMetadataForFileName:(NSString *)fileName videoId:(NSString *)videoId title:(NSString *)title author:(NSString *)author {
    if (!fileName || fileName.length == 0) return;
    
    NSMutableDictionary *all = [self loadAll];
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    if (videoId) item[@"videoId"] = videoId;
    if (title) item[@"title"] = title;
    if (author) item[@"author"] = author;
    
    all[fileName] = item;
    [self saveAll:all];
}

+ (NSDictionary *)metadataForFileName:(NSString *)fileName {
    if (!fileName) return nil;
    NSDictionary *all = [self loadAll];
    return all[fileName];
}

+ (NSString *)videoIdForFileName:(NSString *)fileName {
    NSDictionary *meta = [self metadataForFileName:fileName];
    return meta[@"videoId"];
}

+ (NSString *)fileNameForVideoId:(NSString *)targetVideoId {
    if (!targetVideoId) return nil;
    NSDictionary *all = [self loadAll];
    for (NSString *fileName in all) {
        NSDictionary *meta = all[fileName];
        if ([meta[@"videoId"] isEqualToString:targetVideoId]) {
            return fileName;
        }
    }
    return nil;
}

+ (void)removeMetadataForFileName:(NSString *)fileName {
    if (!fileName) return;
    NSMutableDictionary *all = [self loadAll];
    [all removeObjectForKey:fileName];
    [self saveAll:all];
}

+ (void)renameMetadataFrom:(NSString *)oldName to:(NSString *)newName {
    if (!oldName || !newName) return;
    NSMutableDictionary *all = [self loadAll];
    NSDictionary *oldMeta = all[oldName];
    if (oldMeta) {
        all[newName] = oldMeta;
        [all removeObjectForKey:oldName];
        [self saveAll:all];
    }
}

+ (NSDictionary *)allMetadata {
    return [self loadAll];
}

@end
