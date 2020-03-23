/**
 * Applause Labs
 */

#import <mach/mach_time.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "AQISocketIoClient.h"
#import "FBLogger.h"
#import "FBApplication.h"
#import "FBConfiguration.h"
#import "FBSession.h"
#import "FBImageIOScaler.h"
#import "FBOrientationCommands.h"
#import "AQISourceCommands.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCTestManager_ManagerInterface-Protocol.h"
#import "XCUIElement+FBUtilities.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIScreen.h"

@import SocketIO;

static const NSTimeInterval SCREENSHOT_TIMEOUT = 0.5;
static const NSUInteger MAX_FPS = 60;

static const char *QUEUE_NAME = "Socket Screenshots Provider Queue";

@interface AQISocketIoClient()

@property (nonatomic, readonly) BOOL canStreamScreenshots;
@property (nonatomic) BOOL screenshotsActive;
@property (nonatomic, readonly) SocketManager *manager;
@property (nonatomic, readonly) SocketIOClient *socket;

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) mach_timebase_info_data_t timebaseInfo;
@property (nonatomic, readonly) FBImageIOScaler *imageScaler;

@end

@implementation AQISocketIoClient

- (instancetype)init {
  if ((self = [super init])) {
    NSURL* url = [[NSURL alloc] initWithString:[FBConfiguration socketIoHost]];
    [FBLogger log:[NSString stringWithFormat:@"Connecting to socketIO server at: %@", url]];
    _manager = [[SocketManager alloc] initWithSocketURL:url config:@{@"log": @NO, @"compress": @YES}];
    _socket = self.manager.defaultSocket;
    _screenshotsActive = NO;
    _canStreamScreenshots = [[self class] testStreamScreenshots];

    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    _backgroundQueue = dispatch_queue_create(QUEUE_NAME, queueAttributes);
    mach_timebase_info(&_timebaseInfo);
    _imageScaler = [[FBImageIOScaler alloc] init];
  }

  return self;
}

/**
* validate if device is capable of streaming screenshots
*/
+ (BOOL)testStreamScreenshots
{
  static dispatch_once_t onceCanStream;
  static BOOL result;
  dispatch_once(&onceCanStream, ^{
    result = [(NSObject *)[FBXCTestDaemonsProxy testRunnerProxy] respondsToSelector:@selector(_XCT_requestScreenshotOfScreenWithID:withRect:uti:compressionQuality:withReply:)];
  });
  return result;
}

/**
* set up client's SocketIO message handlers
*/
- (void)setupHandlers
{
  [self.socket on:@"connected" callback:^(NSArray* data, SocketAckEmitter* ack) {
    // join device queue automatically on connection for broadcasting data
    [self.socket emit:@"join"
                 with:@[@{ @"type": @"device" }]];
  }];

  [self.socket on:@"setScreenshots" callback:^(NSArray * data, SocketAckEmitter * ack) {
    [FBLogger log:[data description]];
    NSNumber *active = data[0];
    self.screenshotsActive = [active isEqual:(@1)];
    [FBLogger log:self.screenshotsActive ? @"YES" : @"NO"];
  }];

  [self.socket on:@"getSource" callback:^(NSArray* data, SocketAckEmitter* ack) {

    NSString *source = [AQISourceCommands socketGetSourceCommand];
    [self.socket emit:@"setResponse"
                 with:@[@{
                   @"type": @"source",
                   @"data": source
                 }]];
  }];

  [self.socket on:@"getOrientation" callback:^(NSArray * data, SocketAckEmitter * ack) {

    NSString *orientation = [FBOrientationCommands socketGetOrientation];

    [self.socket emit:@"setResponse"
                 with:@[@{
                          @"type": @"orientation",
                          @"data": orientation
                 }]];
  }];
}

- (void)connect
{
  [self.socket connect];
}

- (void)disconnect
{
  [self.socket disconnect];
}

- (void)startScreenshotStreaming
{
  dispatch_async(self.backgroundQueue, ^{
    [self streamScreenshot];
  });
}

- (void)streamScreenshot
{
  if (!self.canStreamScreenshots) {
    [FBLogger log:@"cannot start because the current iOS version is not supported"];
    return;
  }

  NSUInteger framerate = FBConfiguration.mjpegServerFramerate;
  uint64_t timerInterval = (uint64_t)(1.0 / ((0 == framerate || framerate > MAX_FPS) ? MAX_FPS : framerate) * NSEC_PER_SEC);
  uint64_t timeStarted = mach_absolute_time();
  if (!self.screenshotsActive) {
    [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
    return;
  }

  __block NSData *screenshotData = nil;

  CGFloat scalingFactor = [FBConfiguration mjpegScalingFactor] / 100.0f;
  BOOL usesScaling = fabs(FBMaxScalingFactor - scalingFactor) > DBL_EPSILON;

  CGFloat compressionQuality = FBConfiguration.mjpegServerScreenshotQuality / 100.0f;
  // If scaling is applied we perform another JPEG compression after scaling
  // To get the desired compressionQuality we need to do a lossless compression here
  CGFloat screenshotCompressionQuality = usesScaling ? FBMaxCompressionQuality : compressionQuality;

  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [proxy _XCT_requestScreenshotOfScreenWithID:[[XCUIScreen mainScreen] displayID]
                                       withRect:CGRectNull
                                            uti:(__bridge id)kUTTypeJPEG
                             compressionQuality:screenshotCompressionQuality
                                      withReply:^(NSData *data, NSError *error) {
    if (error != nil) {
      [FBLogger logFmt:@"Error taking screenshot: %@", [error description]];
    }
    screenshotData = data;
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SCREENSHOT_TIMEOUT * NSEC_PER_SEC)));
  if (nil == screenshotData) {
    [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
    return;
  }

  if (usesScaling) {
    [self.imageScaler submitImage:screenshotData
                    scalingFactor:scalingFactor
               compressionQuality:compressionQuality
                completionHandler:^(NSData * _Nonnull scaled) {
                  [self sendScreenshot:scaled];
                }];
  } else {
    [self sendScreenshot:screenshotData];
  }

  [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
}

- (void)scheduleNextScreenshotWithInterval:(uint64_t)timerInterval timeStarted:(uint64_t)timeStarted
{
  uint64_t timeElapsed = mach_absolute_time() - timeStarted;
  int64_t nextTickDelta = timerInterval - timeElapsed * self.timebaseInfo.numer / self.timebaseInfo.denom;
  if (nextTickDelta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nextTickDelta), self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  } else {
    // Try to do our best to keep the FPS at a decent level
    dispatch_async(self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  }
}

- (void)sendScreenshot:(NSData *)screenshotData
{
  NSString *base64 = [screenshotData base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
  [self.socket emit:@"screenshotUpdate"
               with:@[@{ @"data": base64 }]];
}

@end
