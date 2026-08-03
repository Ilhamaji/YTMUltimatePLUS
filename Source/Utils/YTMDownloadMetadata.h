#import <Foundation/Foundation.h>

@interface YTMDownloadMetadata : NSObject

+ (void)saveMetadataForFileName:(NSString *)fileName videoId:(NSString *)videoId title:(NSString *)title author:(NSString *)author;
+ (NSDictionary *)metadataForFileName:(NSString *)fileName;
+ (NSString *)videoIdForFileName:(NSString *)fileName;
+ (NSString *)fileNameForVideoId:(NSString *)videoId;
+ (void)removeMetadataForFileName:(NSString *)fileName;
+ (void)renameMetadataFrom:(NSString *)oldName to:(NSString *)newName;
+ (NSDictionary *)allMetadata;

@end
