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
    handler.connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshClient)];
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

#pragma mark - AnderStore sign-in (runs inside the background Core process)

static Class<AnderCoreBridgeProtocol> AnderCoreBridge(void) {
    return (Class<AnderCoreBridgeProtocol>)NSClassFromString(@"AnderCoreBridge");
}

- (void)signInWithAppleID:(NSString*)appleID password:(NSString*)password {
    if(!handler) {
        return;
    }
    Class<AnderCoreBridgeProtocol> bridge = AnderCoreBridge();
    if(!bridge) {
        [handler.server signInFinished:@"AnderStore Core is unavailable" account:nil];
        return;
    }
    NSObject<RefreshServer>* server = handler.server;
    [bridge signInWithAppleID:appleID password:password codeRequester:^(NSString *prompt) {
        [server needsVerificationCode:prompt];
    } completion:^(NSString *error, NSString *signedInAppleID) {
        [server signInFinished:error account:signedInAppleID];
    }];
}

- (void)submitVerificationCode:(NSString*)code {
    [AnderCoreBridge() submitVerificationCode:code];
}

- (void)requestAccountStatus {
    if(!handler) {
        return;
    }
    Class<AnderCoreBridgeProtocol> bridge = AnderCoreBridge();
    NSObject<RefreshServer>* server = handler.server;
    if(!bridge) {
        [server accountStatusAppleID:nil team:nil];
        return;
    }
    [bridge accountStatusWithCompletion:^(NSString *appleID, NSString *team) {
        [server accountStatusAppleID:appleID team:team];
    }];
}

- (void)updateSelf {
    if(!handler) {
        return;
    }
    Class<AnderCoreBridgeProtocol> bridge = AnderCoreBridge();
    NSObject<RefreshServer>* server = handler.server;
    if(!bridge) {
        [server selfUpdateFinished:@"AnderStore Core is unavailable"];
        return;
    }
    [bridge updateSelfWithProgress:^(double value) {
        [server updateProgress:value];
    } completion:^(NSString *error) {
        [server selfUpdateFinished:error];
    }];
}

@end
