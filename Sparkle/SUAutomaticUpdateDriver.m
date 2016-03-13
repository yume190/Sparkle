//
//  SUAutomaticUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 5/6/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUAutomaticUpdateDriver.h"
#import "SULocalizations.h"
#import "SUUpdaterDelegate.h"
#import "SUHost.h"
#import "SUConstants.h"
#import "SUErrors.h"
#import "SUAppcastItem.h"
#import "SULog.h"
#import "SUStatusCompletionResults.h"
#import "SUUserDriver.h"

#ifdef _APPKITDEFINES_H
#error This is a "core" class and should NOT import AppKit
#endif

// If the user hasn't quit in a week, ask them if they want to relaunch to get the latest bits. It doesn't matter that this measure of "one day" is imprecise.
static const NSTimeInterval SUAutomaticUpdatePromptImpatienceTimer = 60 * 60 * 24 * 7;

@interface SUUpdateDriver ()

@property (getter=isInterruptible) BOOL interruptible;

@end

@interface SUAutomaticUpdateDriver ()

@property (assign) BOOL postponingInstallation;
@property (assign) BOOL showErrors;
@property (assign) BOOL willUpdateOnTermination;
@property (strong) NSTimer *showUpdateAlertTimer;

@end

@implementation SUAutomaticUpdateDriver

@synthesize postponingInstallation;
@synthesize showErrors;
@synthesize willUpdateOnTermination;
@synthesize showUpdateAlertTimer;

- (void)showUpdateAlert
{
    self.interruptible = NO;
    
    [self.userDriver showAutomaticUpdateFoundWithAppcastItem:self.updateItem reply:^(SUUpdateAlertChoice choice) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self automaticUpdateAlertFinishedWithChoice:choice];
        });
    }];
}

- (void)installUpdateWithTerminationStatus:(NSNumber *)terminationStatus
{
    switch ((SUApplicationTerminationStatus)(terminationStatus.unsignedIntegerValue)) {
        case SUApplicationStoppedObservingTermination:
            if (self.willUpdateOnTermination) {
                [self abortUpdate];
            }
            break;
        case SUApplicationWillTerminate:
            if (self.willUpdateOnTermination) {
                [self installWithToolAndRelaunch:NO];
                
                // We could finish successfully or abort the update due to an error, so make sure we tell the user driver
                // to terminate in both cases since they are waiting on us to signal termination
                [self.userDriver terminateApplication];
            }
            break;
    }
}

// Overridden to do nothing: see -installUpdateWithTerminationStatus: as to why
- (void)terminateApp { }

- (void)installerIsReadyForRelaunch
{
    [self.userDriver registerApplicationTermination:^(SUApplicationTerminationStatus terminationStatus) {
        // We use -performSelectorOnMainThread:withObject:waitUntilDone: rather than GCD because if we are on the main thread already,
        // we don't want to run the operation asynchronously. It's also possible we aren't on the main thread (say due to IPC through a XPC service).
        // Anyway, if we're on the main thread in a single process without the app delegate delaying termination,
        // we could be terminating *really soon* - so we want to install the update quickly
        [self performSelectorOnMainThread:@selector(installUpdateWithTerminationStatus:) withObject:@(terminationStatus) waitUntilDone:YES];
    }];
    
    // At first, it may seem like we should register for system power off ourselves rather than the user driver
    // This is a bad idea for a couple reasons. One is it may require linkage to AppKit, or some complex IOKit code
    // Another is that we would be making the assumption that the user driver is on the same system as the updater,
    // which is something we would be better off not assuming!
    [self.userDriver registerSystemPowerOff:^(SUSystemPowerOffStatus systemPowerOffStatus) {
        // See above for why we use -performSelectorOnMainThread:withObject:waitUntilDone:
        [self performSelectorOnMainThread:@selector(systemWillPowerOff:) withObject:@(systemPowerOffStatus) waitUntilDone:YES];
    }];

    self.willUpdateOnTermination = YES;

    if ([self.updaterDelegate respondsToSelector:@selector(updater:willInstallUpdateOnQuit:immediateInstallationInvocation:)])
    {
        BOOL relaunch = YES;
        BOOL showUI = NO;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[self class] instanceMethodSignatureForSelector:@selector(installWithToolAndRelaunch:displayingUserInterface:)]];
        [invocation setSelector:@selector(installWithToolAndRelaunch:displayingUserInterface:)];
        [invocation setArgument:&relaunch atIndex:2];
        [invocation setArgument:&showUI atIndex:3];
        [invocation setTarget:self];

        [self.updaterDelegate updater:self.updater willInstallUpdateOnQuit:self.updateItem immediateInstallationInvocation:invocation];
    }

    // If this is marked as a critical update, we'll prompt the user to install it right away.
    if ([self.updateItem isCriticalUpdate])
    {
        [self showUpdateAlert];
    }
    else
    {
        self.showUpdateAlertTimer = [NSTimer scheduledTimerWithTimeInterval:SUAutomaticUpdatePromptImpatienceTimer target:self selector:@selector(showUpdateAlert) userInfo:nil repeats:NO];

        // At this point the driver is idle, allow it to be interrupted for user-initiated update checks.
        self.interruptible = YES;
    }
}

- (void)stopUpdatingOnTermination
{
    if (self.willUpdateOnTermination)
    {
        self.willUpdateOnTermination = NO;
        
        [self.userDriver unregisterApplicationTermination];
        [self.userDriver unregisterSystemPowerOff];
        
        if ([self.updaterDelegate respondsToSelector:@selector(updater:didCancelInstallUpdateOnQuit:)])
            [self.updaterDelegate updater:self.updater didCancelInstallUpdateOnQuit:self.updateItem];
    }
}

- (void)invalidateShowUpdateAlertTimer
{
    [self.showUpdateAlertTimer invalidate];
    self.showUpdateAlertTimer = nil;
}

- (void)dealloc
{
    [self stopUpdatingOnTermination];
    [self invalidateShowUpdateAlertTimer];
}

- (void)abortUpdate
{
    [self stopUpdatingOnTermination];
    [self invalidateShowUpdateAlertTimer];
    
    [super abortUpdate];
}

- (void)automaticUpdateAlertFinishedWithChoice:(SUUpdateAlertChoice)choice
{
	switch (choice)
	{
        case SUInstallUpdateChoice:
            [self stopUpdatingOnTermination];
            [self installWithToolAndRelaunch:YES];
            break;

        case SUInstallLaterChoice:
            self.postponingInstallation = YES;
            // We're already waiting on quit, just indicate that we're idle.
            self.interruptible = YES;
            break;

        case SUSkipThisVersionChoice:
            [self.host setObject:[self.updateItem versionString] forUserDefaultsKey:SUSkippedVersionKey];
            [self abortUpdate];
            break;
    }
}


- (void)installWithToolAndRelaunch:(BOOL)relaunch displayingUserInterface:(BOOL)showUI
{
    if (relaunch) {
        [self stopUpdatingOnTermination];
    }

    self.showErrors = YES;
    [super installWithToolAndRelaunch:relaunch displayingUserInterface:showUI];
}

- (void)systemWillPowerOff:(NSNumber *)systemPowerOffStatus
{
    if (self.willUpdateOnTermination) {
        switch ((SUSystemPowerOffStatus)(systemPowerOffStatus.unsignedIntegerValue)) {
            case SUStoppedObservingSystemPowerOff:
                [self abortUpdate];
                break;
            case SUSystemWillPowerOff:
                [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUSystemPowerOffError userInfo:@{
                    NSLocalizedDescriptionKey: SULocalizedString(@"The update will not be installed because the user requested for the system to power off", nil) }]];
                break;
        }
    }
}

- (void)abortUpdateWithError:(NSError *)error
{
    if (self.showErrors) {
        [super abortUpdateWithError:error];
    } else {
        // Call delegate separately here because otherwise it won't know we stopped.
        // Normally this gets called by the superclass
        if ([self.updaterDelegate respondsToSelector:@selector(updater:didAbortWithError:)]) {
            [self.updaterDelegate updater:self.updater didAbortWithError:error];
        }

        [self abortUpdate];
    }
}

@end
