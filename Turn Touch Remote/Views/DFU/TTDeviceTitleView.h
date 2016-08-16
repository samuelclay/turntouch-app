//
//  TTDeviceTitleView.h
//  Turn Touch Remote
//
//  Created by Samuel Clay on 11/5/15.
//  Copyright © 2015 Turn Touch. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "TTAppDelegate.h"
#import "TTChangeButtonView.h"

@interface TTDeviceTitleView : NSView <NSMenuDelegate> {
    TTAppDelegate *appDelegate;

    NSDictionary *titleAttributes;
    NSDictionary *stateAttributes;
    CGSize textSize;
    TTChangeButtonView *changeButton;
    NSInteger latestVersion;
    BOOL hoverActive;
    NSButton *settingsButton;
    BOOL isMenuVisible;
    NSMenu *settingsMenu;
}

@property (nonatomic) TTDevice *device;
@property (nonatomic) NSProgressIndicator *progress;

- (instancetype)initWithDevice:(TTDevice *)_device;
- (void)disableUpgrade;
- (void)enableUpgrade;

@end