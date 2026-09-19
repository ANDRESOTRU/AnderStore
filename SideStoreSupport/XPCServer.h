//
//  XPCServer.h
//  LiveContainer
//
//  Created by s s on 2025/7/20.
//

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

__attribute__((swift_attr("@Sendable")))
@protocol RefreshServer
- (void)updateProgress:(double)value;
- (void)finish:(NSString*)error;
- (void)onConnection:(NSXPCConnection*)connection;
- (void)finishedLaunching;
- (void)addNotificationRequest:(UNNotificationRequest*)request;
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString*>*)identifiers;
// AnderStore: one command envelope for everything the interface asks Core to do.
// Payloads are property lists only (dictionary/array/string/number/date/data).
- (void)request:(NSString*)requestID didEmitEvent:(NSDictionary<NSString*, id>*)event
    NS_SWIFT_NAME(request(_:didEmitEvent:));
- (void)request:(NSString*)requestID didFinishWithResponse:(nullable NSDictionary<NSString*, id>*)response error:(nullable NSDictionary<NSString*, id>*)error
    NS_SWIFT_NAME(request(_:didFinishWithResponse:error:));
- (void)willShutdownWithReason:(NSString*)reason
    NS_SWIFT_NAME(willShutdown(reason:));
@end

@protocol RefreshClient
- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName;
// AnderStore: see RefreshServer above.
- (void)performRequest:(NSDictionary<NSString*, id>*)request requestID:(NSString*)requestID
    NS_SWIFT_NAME(performRequest(_:requestID:));
- (void)cancelRequestWithID:(NSString*)requestID
    NS_SWIFT_NAME(cancelRequest(id:));
- (void)shutdownWithReason:(NSString*)reason
    NS_SWIFT_NAME(shutdown(reason:));
@end

// Implemented in Core (AnderCoreBridge.swift), looked up at runtime with NSClassFromString
@protocol AnderCoreBridgeProtocol
+ (void)performRequest:(NSDictionary<NSString*, id>*)request
             requestID:(NSString*)requestID
               onEvent:(void (^)(NSDictionary<NSString*, id>* event))onEvent
            completion:(void (^)(NSDictionary<NSString*, id>* _Nullable response, NSDictionary<NSString*, id>* _Nullable error))completion;
+ (void)cancelRequestWithID:(NSString*)requestID;
+ (void)prepareForShutdownWithReason:(NSString*)reason completion:(void (^)(BOOL accepted))completion;
@end

@interface LiveProcessSideStoreHandler : NSObject
@property (class, readonly, strong) LiveProcessSideStoreHandler* shared;
@property NSXPCConnection* connection;
@property NSObject<RefreshServer>* server;

@end

NSXPCListener* startAnonymousListener(NSObject<RefreshServer>* reporter);
NSData* bookmarkForURL(NSURL* url);

// NSXPCInterface rejects nested collections unless they are allow-listed, and the envelope
// carries nothing but property lists. Both ends must configure their interface the same way.
// Inline so that every target using the protocols gets them without linking XPCServer.m.
static inline NSSet* anderPropertyListClasses(void) {
    return [NSSet setWithObjects:NSDictionary.class, NSMutableDictionary.class,
            NSArray.class, NSMutableArray.class, NSString.class, NSNumber.class,
            NSDate.class, NSData.class, NSNull.class, nil];
}

static inline void anderConfigureServerInterface(NSXPCInterface* iface) {
    NSSet* classes = anderPropertyListClasses();
    [iface setClasses:classes forSelector:@selector(request:didEmitEvent:) argumentIndex:1 ofReply:NO];
    [iface setClasses:classes forSelector:@selector(request:didFinishWithResponse:error:) argumentIndex:1 ofReply:NO];
    [iface setClasses:classes forSelector:@selector(request:didFinishWithResponse:error:) argumentIndex:2 ofReply:NO];
}

static inline void anderConfigureClientInterface(NSXPCInterface* iface) {
    [iface setClasses:anderPropertyListClasses() forSelector:@selector(performRequest:requestID:) argumentIndex:0 ofReply:NO];
}

void installSideStoreHooks(void);
void installSideStoreNotificationHooks(void);

@interface SideStoreClient : NSObject<RefreshClient>
@property (class, readonly) SideStoreClient* shared;
- (void) relaunchLC;
@end
