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
// AnderStore: sign-in without showing the Core interface
- (void)needsVerificationCode:(NSString*)prompt NS_SWIFT_NAME(needsVerificationCode(_:));
- (void)signInFinished:(nullable NSString*)error account:(nullable NSString*)appleID NS_SWIFT_NAME(signInFinished(_:account:));
- (void)accountStatusAppleID:(nullable NSString*)appleID team:(nullable NSString*)team NS_SWIFT_NAME(accountStatus(appleID:team:));
@end

@protocol RefreshClient
- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName;
// AnderStore: sign-in without showing the Core interface
- (void)signInWithAppleID:(NSString*)appleID password:(NSString*)password NS_SWIFT_NAME(signIn(appleID:password:));
- (void)submitVerificationCode:(NSString*)code NS_SWIFT_NAME(submitVerificationCode(_:));
- (void)requestAccountStatus NS_SWIFT_NAME(requestAccountStatus());
@end

// Implemented in Core (AnderCoreBridge.swift), looked up at runtime with NSClassFromString
@protocol AnderCoreBridgeProtocol
+ (void)signInWithAppleID:(NSString*)appleID
                 password:(NSString*)password
            codeRequester:(void (^)(NSString* prompt))codeRequester
               completion:(void (^)(NSString* _Nullable error, NSString* _Nullable appleID))completion;
+ (void)submitVerificationCode:(NSString*)code;
+ (void)accountStatusWithCompletion:(void (^)(NSString* _Nullable appleID, NSString* _Nullable team))completion;
@end

@interface LiveProcessSideStoreHandler : NSObject
@property (class, readonly, strong) LiveProcessSideStoreHandler* shared;
@property NSXPCConnection* connection;
@property NSObject<RefreshServer>* server;

@end

NSXPCListener* startAnonymousListener(NSObject<RefreshServer>* reporter);
NSData* bookmarkForURL(NSURL* url);

void installSideStoreHooks(void);
void installSideStoreNotificationHooks(void);

@interface SideStoreClient : NSObject<RefreshClient>
@property (class, readonly) SideStoreClient* shared;
- (void) relaunchLC;
@end
