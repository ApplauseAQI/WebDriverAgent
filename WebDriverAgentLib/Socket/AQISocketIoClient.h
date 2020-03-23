
#import <Foundation/Foundation.h>
@import SocketIO;

@interface AQISocketIoClient : NSObject

- (instancetype)init;
- (void)connect;
- (void)disconnect;
- (void)setupHandlers;
- (void)startScreenshotStreaming;

@end
