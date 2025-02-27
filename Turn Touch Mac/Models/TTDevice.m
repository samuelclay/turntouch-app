//
//  TTDevice.m
//  Turn Touch Remote
//
//  Created by Samuel Clay on 4/8/15.
//  Copyright (c) 2015 Turn Touch. All rights reserved.
//

#import "TTDevice.h"
#import "CBPeripheral+Extras.h"

@implementation TTDevice

- (id)initWithPeripheral:(CBPeripheral *)peripheral {
    if (self = [super init]) {
        self.peripheral = peripheral;
        self.uuid = peripheral.tt_identifierString;
        
        // Init with latest firmware version, correct later
        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        self.firmwareVersion = [[prefs objectForKey:@"TT:firmware:version"] integerValue];
        NSString *nicknameKey = [NSString stringWithFormat:@"TT:device:%@:nickname", self.uuid];
        self.nickname = [prefs stringForKey:nicknameKey];
        self.isFirmwareOld = NO;
    }
    
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ / %@ (%@-%@)",
            [self.uuid substringToIndex:8],
            self.nickname,
            self.state == TTDeviceStateConnected ? @"connected" : @"X",
            self.isPaired ? @"PAIRED" : @"unpaired"];
}

- (BOOL)isPairing {
    if (self.isPaired) return NO;
    if (self.state == TTDeviceStateConnected &&
        self.peripheral.state == CBPeripheralStateConnected) return YES;
    
    return NO;
}

- (NSString *)stateLabel {
    return self.state == TTDeviceStateConnected ? (self.isPaired ? @"connected" : @"pairing") :
    self.state == TTDeviceStateSearching ? @"searching" :
    self.state == TTDeviceStateConnecting ? @"connecting" : @"X";
}

- (void)setNicknameData:(NSData *)nicknameData {
    NSMutableData *fixedNickname = [[NSMutableData alloc] init];

    const char *bytes = [nicknameData bytes];
    int dataLength = 0;
    for (int i=0; i < [nicknameData length]; i++) {
        if ((unsigned char)bytes[i] != 0x00) {
            dataLength = i;
        } else {
            break;
        }
    }
    [fixedNickname appendBytes:bytes length:dataLength+1];

    self.nickname = [[NSString alloc] initWithData:fixedNickname encoding:NSUTF8StringEncoding];
}

- (void)setFirmwareVersion:(NSInteger)firmwareVersion {
    _firmwareVersion = firmwareVersion;

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSInteger latestVersion = [[prefs objectForKey:@"TT:firmware:version"] integerValue];

    if (self.firmwareVersion < latestVersion) {
        self.isFirmwareOld = YES;
    } else {
        self.isFirmwareOld = NO;
    }
}

- (void)setActionDate {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSString *lastActionDateKey = [NSString stringWithFormat:@"TT:device:%@:lastAction", self.uuid];
    self.lastActionDate = [prefs objectForKey:lastActionDateKey];
    
    if (!self.lastActionDate) {
        self.lastActionDate = [NSDate date];
        [prefs setObject:self.lastActionDate forKey:lastActionDateKey];
    }
}

- (void)updateLastAction {
    self.lastActionDate = [NSDate date];
    
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSString *lastActionDateKey = [NSString stringWithFormat:@"TT:device:%@:lastAction", self.uuid];
    [prefs setObject:self.lastActionDate forKey:lastActionDateKey];
    [prefs synchronize];
}

@end
