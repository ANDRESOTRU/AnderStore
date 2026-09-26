//
//  XPCClient.m
//  AltStore
//
//  Created by s s on 2025/7/20.
//  Copyright © 2025 SideStore. All rights reserved.
//
#include "XPCServer.h"
#include "../LiveContainer/utils.h"
#include "../LiveContainer/LCSharedUtils.h"
@import UIKit;
@import UserNotifications;

// In LiveProcess these selectors contain the original implementations after
// SideStoreHooks swizzles them. Use the real center, not its synthetic permission
// settings or forwarding through a host that iOS may already have terminated.
@interface UNUserNotificationCenter (AnderUpdateDelivery)
- (void)lc_addNotificationRequest:(UNNotificationRequest *)request
            withCompletionHandler:(void (^)(NSError *))completion;
@end

@interface SideStoreClient(Swift)
- (void)performRefreshForRealWithIdentifier:(NSString*)identifier
                            mangledTypeName:(NSString*)mangledTypeName
                                     server:(id <RefreshServer> _Nonnull)server;

@end

static LiveProcessSideStoreHandler* handler = nil;
void installSideStoreHooks(void);

@implementation SideStoreClient

+ (SideStoreClient*)shared {
    static SideStoreClient* sharedClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedClient = [SideStoreClient new];
    });

    return sharedClient;
}

+ (void)load {
    if(!NSUserDefaults.isSideStore) return;

    installSideStoreHooks();

    if(!NSUserDefaults.isLiveProcess) return;

    handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    installSideStoreNotificationHooks();
    NSXPCInterface* clientInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshClient)];
    anderConfigureClientInterface(clientInterface);
    handler.connection.exportedInterface = clientInterface;
    handler.connection.exportedObject = SideStoreClient.shared;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidFinishLaunching:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
}

// Implement the callback method
+ (void)appDidFinishLaunching:(NSNotification *)notification {
    NSDictionary *launchOptions = notification.userInfo;
    [handler.server finishedLaunching];
}

- (void) relaunchLC {
    [LCSharedUtils launchToGuestAppWithClassicMode:0];
}

- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName {
    if(!handler) {
        return;
    }
    [self performRefreshForRealWithIdentifier:identifier mangledTypeName:mangledTypeName server:handler.server];
}

#pragma mark - AnderStore command envelope (runs inside the background Core process)

static Class<AnderCoreBridgeProtocol> AnderCoreBridge(void) {
    return (Class<AnderCoreBridgeProtocol>)NSClassFromString(@"AnderCoreBridge");
}

static NSDictionary* AnderError(NSString* kind, NSString* message) {
    return @{@"kind": kind, @"message": message};
}

/// Ends the LiveProcess request and exits. Mirrors the termination path in LCBootstrap.m.
static void AnderTerminateCore(void) {
    NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
    [context completeRequestReturningItems:@[] completionHandler:nil];
    exit(0);
}

- (void)performRequest:(NSDictionary*)request requestID:(NSString*)requestID {
    if(!handler) {
        return;
    }
    NSObject<RefreshServer>* server = handler.server;
    Class<AnderCoreBridgeProtocol> bridge = AnderCoreBridge();
    if(!bridge) {
        [server request:requestID
  didFinishWithResponse:nil
                  error:AnderError(@"coreUnavailable", @"AnderStore Core is unavailable")];
        return;
    }
    [bridge performRequest:request requestID:requestID onEvent:^(NSDictionary *event) {
        [server request:requestID didEmitEvent:event];
    } completion:^(NSDictionary *response, NSDictionary *error) {
        [server request:requestID didFinishWithResponse:response error:error];
        if ([request[@"cmd"] isEqual:@"self.update"] && !error && [response[@"reopen"] boolValue]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                __block BOOL finished = NO;
                void (^finishLaunch)(BOOL) = ^(BOOL opened) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (finished) return;
                        finished = YES;
                        [bridge performRequest:@{@"cmd": @"update.launchResult", @"opened": @(opened),
                                                 @"operationID": response[@"operationID"] ?: @""}
                                     requestID:NSUUID.UUID.UUIDString onEvent:^(NSDictionary *event) {}
                                    completion:^(NSDictionary *result, NSDictionary *failure) {
                            if ([result[@"notify"] boolValue] && [response[@"notificationsAllowed"] boolValue]) {
                                UNMutableNotificationContent *content = [UNMutableNotificationContent new];
                                content.title = response[@"notificationTitle"] ?: @"AnderStore";
                                content.body = response[@"notificationBody"] ?: @"";
                                content.sound = UNNotificationSound.defaultSound;
                                UNNotificationRequest *notice = [UNNotificationRequest requestWithIdentifier:@"anderstore.update.open"
                                                                                                     content:content trigger:nil];
                                [UNUserNotificationCenter.currentNotificationCenter lc_addNotificationRequest:notice
                                                                                       withCompletionHandler:nil];
                            }
                        }];
                    });
                };
                [LCSharedUtils openUpdatedAnderStoreWithBundleIdentifier:request[@"hostBundleIdentifier"] completion:finishLaunch];
                // Some iOS versions never invoke the private opener's completion.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    finishLaunch(NO);
                });
            });
        }
    }];
}

- (void)cancelRequestWithID:(NSString*)requestID {
    [AnderCoreBridge() cancelRequestWithID:requestID];
}

- (void)shutdownWithReason:(NSString*)reason {
    NSObject<RefreshServer>* server = handler.server;
    Class<AnderCoreBridgeProtocol> bridge = AnderCoreBridge();
    if(!bridge) {
        [server willShutdownWithReason:reason];
        AnderTerminateCore();
        return;
    }
    [bridge prepareForShutdownWithReason:reason completion:^(BOOL accepted) {
        if(!accepted) {
            // Core is in the middle of an operation; the host keeps it running.
            return;
        }
        [server willShutdownWithReason:reason];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            AnderTerminateCore();
        });
    }];
}

@end
