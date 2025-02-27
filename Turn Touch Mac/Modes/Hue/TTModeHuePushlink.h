//
//  TTModeHuePushlink.h
//  Turn Touch Remote
//
//  Created by Samuel Clay on 1/9/15.
//  Copyright (c) 2015 Turn Touch. All rights reserved.
//

#import "TTOptionsDetailViewController.h"


@interface TTModeHuePushlink : TTOptionsDetailViewController

@property (nonatomic, strong) TTModeHue *modeHue;
@property (nonatomic, strong) IBOutlet NSProgressIndicator *progressView;

- (void)setProgress:(NSNumber *)progressPercentage;

@end
