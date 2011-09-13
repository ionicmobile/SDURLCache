//
//  SDURLCache.m
//  SDURLCache
// Copyright (c) 2010-2011 Olivier Poitrey <rs@dailymotion.com>
// Modernized to use GCD by Peter Steinberger <steipete@gmail.com>
//
//  Created by Olivier Poitrey on 15/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import "SDURLCache.h"
#import <CommonCrypto/CommonDigest.h>

#define kAFURLCachePath @"AFNetworkingURLCache"
static NSTimeInterval const kAFURLCacheInfoDefaultMinCacheInterval = 5 * 60; // 5 minute
static NSString *const kAFURLCacheInfoFileName = @"cacheInfo.plist";
static NSString *const kAFURLCacheInfoDiskUsageKey = @"diskUsage";
static NSString *const kAFURLCacheInfoAccessesKey = @"accesses";
static NSString *const kAFURLCacheInfoSizesKey = @"sizes";
static float const kAFURLCacheLastModFraction = 0.1f; // 10% since Last-Modified suggested by RFC2616 section 13.2.4
static float const kAFURLCacheDefault = 3600; // Default cache expiration delay if none defined (1 hour)

static NSDateFormatter* CreateDateFormatter(NSString *format) {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"] autorelease]];
    [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];
    [dateFormatter setDateFormat:format];
    return dateFormatter;
}

@implementation NSCachedURLResponse(NSCoder)

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeDataObject:self.data];
    [coder encodeObject:self.response forKey:@"response"];
    [coder encodeObject:self.userInfo forKey:@"userInfo"];
    [coder encodeInt:self.storagePolicy forKey:@"storagePolicy"];
}

- (id)initWithCoder:(NSCoder *)coder {
    return [self initWithResponse:[coder decodeObjectForKey:@"response"]
                             data:[coder decodeDataObject]
                         userInfo:[coder decodeObjectForKey:@"userInfo"]
                    storagePolicy:[coder decodeIntForKey:@"storagePolicy"]];
}

@end

// deadlock-free variant of dispatch_sync
void dispatch_sync_afreentrant(dispatch_queue_t queue, dispatch_block_t block);
inline void dispatch_sync_afreentrant(dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_get_current_queue() == queue ? block() : dispatch_sync(queue, block);
}

void dispatch_async_afreentrant(dispatch_queue_t queue, dispatch_block_t block);
inline void dispatch_async_afreentrant(dispatch_queue_t queue, dispatch_block_t block) {
	dispatch_get_current_queue() == queue ? block() : dispatch_async(queue, block);
}

@interface SDURLCache ()
@property (nonatomic, retain) NSString *diskCachePath;
@property (nonatomic, retain) NSMutableDictionary *diskCacheInfo;
@property (nonatomic, retain) NSOperationQueue *ioQueue;
@property (retain) NSOperation *periodicMaintenanceOperation;
- (void)periodicMaintenance;
@end

@implementation SDURLCache

#pragma mark AFURLCache (tools)

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    NSString *string = request.URL.absoluteString;
    NSRange hash = [string rangeOfString:@"#"];
    if (hash.location == NSNotFound)
        return request;
    
    NSMutableURLRequest *copy = [[request mutableCopy] autorelease];
    copy.URL = [NSURL URLWithString:[string substringToIndex:hash.location]];
    return copy;
}

+ (NSString *)cacheKeyForURL:(NSURL *)url {
    const char *str = [url.absoluteString UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, strlen(str), r);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
}

#pragma mark AFURLCache (private)

- (dispatch_queue_t)dateFormatterQueue {
    static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_dateFormatterQueue = dispatch_queue_create("com.alamofire.disk-cache.dateformatter", NULL);
	});
	return _dateFormatterQueue;
}

/*
 * Parse HTTP Date: http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.3.1
 */
- (NSDate *)dateFromHttpDateString:(NSString *)httpDate {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _FC1123DateFormatter = CreateDateFormatter(@"EEE, dd MMM yyyy HH:mm:ss z");
        _ANSICDateFormatter = CreateDateFormatter(@"EEE MMM d HH:mm:ss yyyy");
        _RFC850DateFormatter = CreateDateFormatter(@"EEEE, dd-MMM-yy HH:mm:ss z");
    });
    
    __block NSDate *date = nil;
    
    dispatch_sync([self dateFormatterQueue], ^{
        date = [_FC1123DateFormatter dateFromString:httpDate];
        if (!date) {
            // ANSI C date format - Sun Nov  6 08:49:37 1994
            date = [_ANSICDateFormatter dateFromString:httpDate];
            if (!date) {
                // RFC 850 date format - Sunday, 06-Nov-94 08:49:37 GMT
                date = [_RFC850DateFormatter dateFromString:httpDate];
            }
        }        
    });
    
    return date;
}

/*
 * This method tries to determine the expiration date based on a response headers dictionary.
 */
- (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status {
    if (status != 200 && status != 203 && status != 300 && status != 301 && status != 302 && status != 307 && status != 410) {
        // Uncacheable response status code
        return nil;
    }
    
    // Check Pragma: no-cache
    NSString *pragma = [headers objectForKey:@"Pragma"];
    if (pragma && [pragma isEqualToString:@"no-cache"]) {
        // Uncacheable response
        return nil;
    }
    
    // Define "now" based on the request
    NSString *date = [headers objectForKey:@"Date"];
    NSDate *now;
    if (date)
    {
        now = [self dateFromHttpDateString:date];
    }
    else {
        // If no Date: header, define now from local clock
        now = [NSDate date];
    }
    
    // Look at info from the Cache-Control: max-age=n header
    NSString *cacheControl = [headers objectForKey:@"Cache-Control"];
    if (cacheControl) {
        NSRange foundRange = [cacheControl rangeOfString:@"no-store"];
        if (foundRange.length > 0) {
            // Can't be cached
            return nil;
        }
        
        NSInteger maxAge;
        foundRange = [cacheControl rangeOfString:@"max-age="];
        if (foundRange.length > 0) {
            NSScanner *cacheControlScanner = [NSScanner scannerWithString:cacheControl];
            [cacheControlScanner setScanLocation:foundRange.location + foundRange.length];
            if ([cacheControlScanner scanInteger:&maxAge]) {
                return maxAge > 0 ? [NSDate dateWithTimeInterval:maxAge sinceDate:now] : nil;
            }
        }
    }
    
    // If not Cache-Control found, look at the Expires header
    NSString *expires = [headers objectForKey:@"Expires"];
    if (expires) {
        NSTimeInterval expirationInterval = 0;
        NSDate *expirationDate = [self dateFromHttpDateString:expires];
        if (expirationDate) {
            expirationInterval = [expirationDate timeIntervalSinceDate:now];
        }
        if (expirationInterval > 0) {
            // Convert remote expiration date to local expiration date
            return [NSDate dateWithTimeIntervalSinceNow:expirationInterval];
        }
        else {
            // If the Expires header can't be parsed or is expired, do not cache
            return nil;
        }
    }
    
    if (status == 302 || status == 307) {
        // If not explict cache control defined, do not cache those status
        return nil;
    }
    
    // If no cache control defined, try some heristic to determine an expiration date
    NSString *lastModified = [headers objectForKey:@"Last-Modified"];
    if (lastModified) {
        NSTimeInterval age = 0;
        NSDate *lastModifiedDate = [self dateFromHttpDateString:lastModified];
        if (lastModifiedDate) {
            // Define the age of the document by comparing the Date header with the Last-Modified header
            age = [now timeIntervalSinceDate:lastModifiedDate];
        }
        return age > 0 ? [NSDate dateWithTimeIntervalSinceNow:(age * kAFURLCacheLastModFraction)] : nil;
    }
    
    // If nothing permitted to define the cache expiration delay nor to restrict its cacheability, use a default cache expiration delay
    return [[[NSDate alloc] initWithTimeInterval:kAFURLCacheDefault sinceDate:now] autorelease];
}


- (dispatch_queue_t)diskCacheQueue {
    static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_diskCacheQueue = dispatch_queue_create("com.alamofire.disk-cache.processing", NULL);
	});
	return _diskCacheQueue;
}

- (NSMutableDictionary *)diskCacheInfo {
    if (!_diskCacheInfo) {
        dispatch_sync_afreentrant([self diskCacheQueue], ^{
            if (!_diskCacheInfo) { // Check again, maybe another thread created it while waiting for the mutex
                _diskCacheInfo = [[NSMutableDictionary alloc] initWithContentsOfFile:[_diskCachePath stringByAppendingPathComponent:kAFURLCacheInfoFileName]];
                if (!_diskCacheInfo) {
                    _diskCacheInfo = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                      [NSNumber numberWithUnsignedInt:0], kAFURLCacheInfoDiskUsageKey,
                                      [NSMutableDictionary dictionary], kAFURLCacheInfoAccessesKey,
                                      [NSMutableDictionary dictionary], kAFURLCacheInfoSizesKey,
                                      nil];
                }
                _diskCacheInfoDirty = NO;
                _diskCacheUsage = [[_diskCacheInfo objectForKey:kAFURLCacheInfoDiskUsageKey] unsignedIntValue];
                
                _periodicMaintenanceTimer = [NSTimer scheduledTimerWithTimeInterval:5
                                                                             target:self
                                                                           selector:@selector(periodicMaintenance)
                                                                           userInfo:nil
                                                                            repeats:YES];
            }
        });
    }
    
    return _diskCacheInfo;
}

- (void)createDiskCachePath {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        if (![fileManager fileExistsAtPath:_diskCachePath]) {
            [fileManager createDirectoryAtPath:_diskCachePath
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:NULL];
        }
        [fileManager release];
    });
}

- (void)saveCacheInfo {
    [self createDiskCachePath];
    dispatch_async_afreentrant([self diskCacheQueue], ^{
        NSData *data = [NSPropertyListSerialization dataFromPropertyList:self.diskCacheInfo format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
        if (data) {
            [data writeToFile:[_diskCachePath stringByAppendingPathComponent:kAFURLCacheInfoFileName] atomically:YES];
        }
        
        _diskCacheInfoDirty = NO;
    });
}

- (void)removeCachedResponseForCachedKeys:(NSArray *)cacheKeys {
    dispatch_async_afreentrant([self diskCacheQueue], ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        
        NSEnumerator *enumerator = [cacheKeys objectEnumerator];
        NSString *cacheKey;
        
        NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kAFURLCacheInfoAccessesKey];
        NSMutableDictionary *sizes = [self.diskCacheInfo objectForKey:kAFURLCacheInfoSizesKey];
        NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];
        
        while ((cacheKey = [enumerator nextObject])) {
            NSUInteger cacheItemSize = [[sizes objectForKey:cacheKey] unsignedIntegerValue];
            [accesses removeObjectForKey:cacheKey];
            [sizes removeObjectForKey:cacheKey];
            [fileManager removeItemAtPath:[_diskCachePath stringByAppendingPathComponent:cacheKey] error:NULL];
            
            _diskCacheUsage -= cacheItemSize;
            [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:_diskCacheUsage] forKey:kAFURLCacheInfoDiskUsageKey];
        }
        
        [pool drain];
    });
}

- (void)balanceDiskUsage {
    if (_diskCacheUsage < self.diskCapacity) {
        return; // Already done
    }
    
    dispatch_async_afreentrant([self diskCacheQueue], ^{
        NSMutableArray *keysToRemove = [NSMutableArray array];
        
        // Apply LRU cache eviction algorithm while disk usage outreach capacity
        NSDictionary *sizes = [self.diskCacheInfo objectForKey:kAFURLCacheInfoSizesKey];
        
        NSInteger capacityToSave = _diskCacheUsage - self.diskCapacity;
        NSArray *sortedKeys = [[self.diskCacheInfo objectForKey:kAFURLCacheInfoAccessesKey] keysSortedByValueUsingSelector:@selector(compare:)];
        NSEnumerator *enumerator = [sortedKeys objectEnumerator];
        NSString *cacheKey;
        
        while (capacityToSave > 0 && (cacheKey = [enumerator nextObject])) {
            [keysToRemove addObject:cacheKey];
            capacityToSave -= [(NSNumber *)[sizes objectForKey:cacheKey] unsignedIntegerValue];
        }
        
        [self removeCachedResponseForCachedKeys:keysToRemove];
        [self saveCacheInfo];
    });
}


- (void)storeToDisk:(NSDictionary *)context {
    NSURLRequest *request = [context objectForKey:@"request"];
    NSCachedURLResponse *cachedResponse = [context objectForKey:@"cachedResponse"];
    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
    NSString *cacheFilePath = [diskCachePath stringByAppendingPathComponent:cacheKey];
    [self createDiskCachePath];
    
    // Archive the cached response on disk
    if (![NSKeyedArchiver archiveRootObject:cachedResponse toFile:cacheFilePath]) {
        // Caching failed for some reason
        return;
    }
    
    // Update disk usage info
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSNumber *cacheItemSize = [[fileManager attributesOfItemAtPath:cacheFilePath error:NULL] objectForKey:NSFileSize];
    [fileManager release];
    
    dispatch_async_afreentrant([self diskCacheQueue], ^{
        _diskCacheUsage += [cacheItemSize unsignedIntegerValue];
        [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:_diskCacheUsage] forKey:kAFURLCacheInfoDiskUsageKey];
        
        
        // Update cache info for the stored item
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kAFURLCacheInfoAccessesKey] setObject:[NSDate date] forKey:cacheKey];
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kAFURLCacheInfoSizesKey] setObject:cacheItemSize forKey:cacheKey];
        
        [self saveCacheInfo];
    });
}

- (void)periodicMaintenance {
    if (_diskCacheUsage > self.diskCapacity) {
        self.periodicMaintenanceOperation = [[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(balanceDiskUsage) object:nil] autorelease];
        [_ioQueue addOperation:_periodicMaintenanceOperation];
    }
    else if (_diskCacheInfoDirty) {
        self.periodicMaintenanceOperation = [[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(saveCacheInfo) object:nil] autorelease];
        [_ioQueue addOperation:_periodicMaintenanceOperation];
    }
}

#pragma mark AFURLCache

+ (NSString *)defaultCachePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:kAFURLCachePath];
}

#pragma mark NSURLCache

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString *)path {
    if ((self = [super initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:path])) {
        self.minCacheInterval = kAFURLCacheInfoDefaultMinCacheInterval;
        self.diskCachePath = path;
        
        // Init the operation queue
        self.ioQueue = [[[NSOperationQueue alloc] init] autorelease];
        _ioQueue.maxConcurrentOperationCount = 1; // used to streamline operations in a separate thread
        
        self.ignoreMemoryOnlyStoragePolicy = NO;
	}
    
    return self;
}

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    request = [SDURLCache canonicalRequestForRequest:request];

    if (request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringLocalAndRemoteCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringCacheData) {
        // When cache is ignored for read, it's a good idea not to store the result as well as this option
        // have big chance to be used every times in the future for the same request.
        // NOTE: This is a change regarding default URLCache behavior
        return;
    }
    
    [super storeCachedResponse:cachedResponse forRequest:request];
    
    NSURLCacheStoragePolicy storagePolicy = cachedResponse.storagePolicy;
    if ((storagePolicy == NSURLCacheStorageAllowed || (storagePolicy == NSURLCacheStorageAllowedInMemoryOnly && _ignoreMemoryOnlyStoragePolicy))
        && [cachedResponse.response isKindOfClass:[NSHTTPURLResponse self]]
        && cachedResponse.data.length < self.diskCapacity) {
        NSDictionary *headers = [(NSHTTPURLResponse *)cachedResponse.response allHeaderFields];
        // RFC 2616 section 13.3.4 says clients MUST use Etag in any cache-conditional request if provided by server
        if (![headers objectForKey:@"Etag"]) {
            NSDate *expirationDate = [self expirationDateFromHeaders:headers
                                                      withStatusCode:((NSHTTPURLResponse *)cachedResponse.response).statusCode];
            if (!expirationDate || [expirationDate timeIntervalSinceNow] - _minCacheInterval <= 0) {
                // This response is not cacheable, headers said
                return;
            }
        }
        
        [_ioQueue addOperation:[[[NSInvocationOperation alloc] initWithTarget:self
                                                                     selector:@selector(storeToDisk:)
                                                                       object:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                               cachedResponse, @"cachedResponse",
                                                                               request, @"request",
                                                                               nil]] autorelease]];
    }
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    request = [SDURLCache canonicalRequestForRequest:request];

    NSCachedURLResponse *memoryResponse = [super cachedResponseForRequest:request];
    if (memoryResponse) {
        return memoryResponse;
    }

    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];

    // NOTE: We don't handle expiration here as even staled cache data is necessary for NSURLConnection to handle cache revalidation.
    //       Staled cache data is also needed for cachePolicies which force the use of the cache.
    __block NSCachedURLResponse *response = nil;
    dispatch_sync_afreentrant([self diskCacheQueue], ^{
        NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kAFURLCacheInfoAccessesKey];
        if ([accesses objectForKey:cacheKey]) { // OPTI: Check for cache-hit in a in-memory dictionnary before to hit the FS
            NSCachedURLResponse *diskResponse = [NSKeyedUnarchiver unarchiveObjectWithFile:[_diskCachePath stringByAppendingPathComponent:cacheKey]];
            if (diskResponse) {
                // OPTI: Log the entry last access time for LRU cache eviction algorithm but don't save the dictionary
                //       on disk now in order to save IO and time
                [accesses setObject:[NSDate date] forKey:cacheKey];
                _diskCacheInfoDirty = YES;
                
                // OPTI: Store the response to memory cache for potential future requests
                [super storeCachedResponse:diskResponse forRequest:request];
                
                response = [[diskResponse retain] autorelease];
            }
        }
    });
    
    return response;
}

- (NSUInteger)currentDiskUsage {
    if (!_diskCacheInfo) {
        [self diskCacheInfo];
    }
    return _diskCacheUsage;
}

- (void)removeCachedResponseForRequest:(NSURLRequest *)request
{
    request = [SDURLCache canonicalRequestForRequest:request];
    [super removeCachedResponseForRequest:request];
    [self removeCachedResponseForCachedKeys:[NSArray arrayWithObject:[SDURLCache cacheKeyForURL:request.URL]]];
    [self saveCacheInfo];
}

- (void)removeAllCachedResponses {
    [super removeAllCachedResponses];
    NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];
    [fileManager removeItemAtPath:_diskCachePath error:NULL];
    dispatch_async_afreentrant([self diskCacheQueue], ^{
        self.diskCacheInfo = nil;
    });
}

- (BOOL)isCached:(NSURL *)url {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    request = [SDURLCache canonicalRequestForRequest:request];

    if ([super cachedResponseForRequest:request]) {
        return YES;
    }
    NSString *cacheKey = [SDURLCache cacheKeyForURL:url];
    NSString *cacheFile = [diskCachePath stringByAppendingPathComponent:cacheKey];
    
    BOOL isCached = [[[[NSFileManager alloc] init] autorelease] fileExistsAtPath:cacheFile];
    return isCached;
}

#pragma mark NSObject

- (void)dealloc {
    [_periodicMaintenanceTimer invalidate];
    dispatch_release(_diskCacheQueue);
    dispatch_release(_dateFormatterQueue);
    dispatch_release(_diskIOQueue);
    [_diskCachePath release], _diskCachePath = nil;
    [_diskCacheInfo release], _diskCacheInfo = nil;
    [_ioQueue release], _ioQueue = nil;
    [_FC1123DateFormatter release];
    [_ANSICDateFormatter release];
    [_RFC850DateFormatter release];    
    [super dealloc];
}

@synthesize minCacheInterval = _minCacheInterval;
@synthesize ignoreMemoryOnlyStoragePolicy = _ignoreMemoryOnlyStoragePolicy;
@synthesize diskCachePath = _diskCachePath;
@synthesize periodicMaintenanceOperation = _periodicMaintenanceOperation;
@synthesize ioQueue = _ioQueue;
@synthesize diskCacheInfo = _diskCacheInfo;

@end
