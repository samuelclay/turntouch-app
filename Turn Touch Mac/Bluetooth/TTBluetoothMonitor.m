
//  TTBluetoothMonitor.m
//  Turn Touch Remote
//
//  Created by Samuel Clay on 12/19/14.
//  Copyright (c) 2014 Turn Touch. All rights reserved.
//

#import "TTBluetoothMonitor.h"
#import "NSData+Conversion.h"
#import "CBPeripheral+Extras.h"
#import "TTDevice.h"
#import "Utility.h"

// Firmware rev. 10 - 19 = v1
#define DEVICE_V1_SERVICE_BATTERY_UUID                 @"180F"
#define DEVICE_V1_SERVICE_BUTTON_UUID                  @"88c3907a-dc4f-41b1-bb04-4e4deb81fadd"
#define DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID       @"2f850855-71c4-4543-bcd3-9bc29d435390"

#define DEVICE_V1_CHARACTERISTIC_BATTERY_LEVEL_UUID    @"2a19"
#define DEVICE_V1_CHARACTERISTIC_BUTTON_STATUS_UUID    @"47099164-4d08-4338-bedf-7fc043dbec5c"
#define DEVICE_V1_CHARACTERISTIC_INTERVAL_MIN_UUID     @"0a02cefb-f546-4a56-ad2b-4aeadca0da6e"
#define DEVICE_V1_CHARACTERISTIC_INTERVAL_MAX_UUID     @"50a71e79-f950-4973-9cbd-1ce5439603be"
#define DEVICE_V1_CHARACTERISTIC_CONN_LATENCY_UUID     @"3b6ef6e7-d9dc-4010-960a-a48bbe114935"
#define DEVICE_V1_CHARACTERISTIC_CONN_TIMEOUT_UUID     @"c6d87b9e-70c3-47ff-a534-e1ceb2bdf435"
#define DEVICE_V1_CHARACTERISTIC_MODE_DURATION_UUID    @"bc382b21-1617-48cc-9e93-f4104561f71d"
#define DEVICE_V1_CHARACTERISTIC_NICKNAME_UUID         @"6b8d8785-0b9b-4b13-bfe5-d71dd3b6ccc2"

// Firmware rev. 20+ = v2
#define DEVICE_V2_SERVICE_BATTERY_UUID                 @"180F"
#define DEVICE_V2_SERVICE_BUTTON_UUID                  @"99c31523-dc4f-41b1-bb04-4e4deb81fadd"
#define DEVICE_V2_CHARACTERISTIC_BATTERY_LEVEL_UUID    @"2a19"
#define DEVICE_V2_CHARACTERISTIC_BUTTON_STATUS_UUID    @"99c31525-dc4f-41b1-bb04-4e4deb81fadd"
#define DEVICE_V2_CHARACTERISTIC_NICKNAME_UUID         @"99c31526-dc4f-41b1-bb04-4e4deb81fadd"


const int BATTERY_LEVEL_READING_INTERVAL = 60; // every 6 hours

#define CLEAR_PAIRED_DEVICES 0
#define DEBUG_CONNECT

@interface TTBluetoothMonitor ()

@property (nonatomic, strong) NSTimer *batteryLevelTimer;

@property (nonatomic, strong) NSString *manufacturer;
@property (nonatomic, strong) NSMutableDictionary *characteristics;
@property (nonatomic) NSInteger connectionDelay;

@end

@implementation TTBluetoothMonitor

- (instancetype)init {
    if (self = [super init]) {
        self.manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        self.appDelegate = (TTAppDelegate *)[NSApp delegate];
        self.buttonTimer = [[TTButtonTimer alloc] init];
        self.batteryPct = [[NSNumber alloc] init];
        self.lastActionDate = [NSDate date];
        self.characteristics = [[NSMutableDictionary alloc] init];
        self.connectionDelay = 4;
        self.isPairing = NO;

        self.foundDevices = [[TTDeviceList alloc] init];
        self.nicknamedConnectedCount = [[NSNumber alloc] initWithInteger:0];
        self.pairedDevicesCount = [[NSNumber alloc] initWithInteger:0];
        self.unpairedDevicesCount = [[NSNumber alloc] initWithInteger:0];
        
        if (CLEAR_PAIRED_DEVICES) {
            NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
            [preferences setObject:nil forKey:@"TT:devices:paired"];
            [preferences synchronize];
        }
    }
    
    return self;
}

- (BOOL)isLECapableHardware {
    NSString * state = nil;
    
    switch ([self.manager state]) {
        case CBManagerStateUnsupported:
            state = @"The platform/hardware doesn't support Bluetooth Low Energy.";
            break;
        case CBManagerStateUnauthorized:
            state = @"The app is not authorized to use Bluetooth Low Energy.";
            break;
        case CBManagerStatePoweredOff:
            state = @"Bluetooth is currently powered off.";
            break;
        case CBManagerStatePoweredOn:
            return TRUE;
        case CBManagerStateUnknown:
            state = @"Bluetooth in unknown state.";
            break;
        case CBManagerStateResetting:
            state = @"Bluetooth in resetting state.";
            break;
        default:
            state = @"Bluetooth not in any state!";
            break;
    }
    
    NSLog(@"Central manager state: %@ - %@/%ld", state, self.manager, self.manager.state);
    
    return FALSE;
}

- (NSArray *)knownPeripheralIdentifiers {
    NSMutableArray *identifiers = [NSMutableArray array];
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSMutableArray *pairedDevices = [[preferences objectForKey:@"TT:devices:paired"] mutableCopy];
    
    for (NSString *identifier in pairedDevices) {
        [identifiers addObject:[[NSUUID alloc] initWithUUIDString:identifier]];
    }
    
    return identifiers;
}

#pragma mark - Start/Stop Scan methods

- (void)scanKnown {
    BOOL knownDevicesStillDisconnected = NO;
    
    self.bluetoothState = BT_STATE_SCANNING_KNOWN;
#ifdef DEBUG_CONNECT
    NSLog(@" ---> (%X) Scanning known: %lu remotes", self.bluetoothState, (unsigned long)[[self knownPeripheralIdentifiers] count]);
#endif
    BOOL isActivelyConnecting = NO;
    
    NSArray *peripherals = [self.manager retrievePeripheralsWithIdentifiers:[self knownPeripheralIdentifiers]];
    for (CBPeripheral *peripheral in peripherals) {
        TTDevice *foundDevice = [self.foundDevices deviceForPeripheral:peripheral];
        if (!foundDevice) {
            foundDevice = [self.foundDevices addPeripheral:peripheral];
        } else if (foundDevice.state == TTDeviceStateConnecting) {
            isActivelyConnecting = YES;
        }
        if (peripheral.state != CBPeripheralStateDisconnected && foundDevice.state != TTDeviceStateSearching) {
#ifdef DEBUG_CONNECT
//            NSLog(@" ---> (%X) Already connected: %@", bluetoothState, foundDevice);
#endif
            continue;
        } else {
            knownDevicesStillDisconnected = YES;
        }
        
        self.bluetoothState = BT_STATE_CONNECTING_KNOWN;
#ifdef DEBUG_CONNECT
        NSLog(@" ---> (%X) Attempting connect to known: %@/%@", self.bluetoothState, [peripheral.tt_identifierString substringToIndex:8], foundDevice);
#endif
        NSDictionary *options = @{CBConnectPeripheralOptionNotifyOnDisconnectionKey: [NSNumber numberWithBool:YES],
                                  CBCentralManagerOptionShowPowerAlertKey: [NSNumber numberWithBool:YES]};
        if (self.bluetoothState != BT_STATE_CONNECTING_KNOWN) {
            [self.manager cancelPeripheralConnection:peripheral];
        }
        [self.manager connectPeripheral:peripheral options:options];
    }
    
    if (!knownDevicesStillDisconnected) {
        self.bluetoothState = BT_STATE_IDLE;
#ifdef DEBUG_CONNECT
        NSLog(@" ---> (%X) All done, no known devices left to connect.", self.bluetoothState);
#endif
    }

    if (![self knownPeripheralIdentifiers].count && !isActivelyConnecting) {
        [self scanUnknown:NO];
        return;
    }

    // Search for unpaired devices or paired devices that aren't responding to `connectPeripheral`
    static dispatch_once_t onceUnknownToken;
    dispatch_once(&onceUnknownToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            onceUnknownToken = 0;
            if (self.bluetoothState != BT_STATE_SCANNING_KNOWN && self.bluetoothState != BT_STATE_CONNECTING_KNOWN) {
#ifdef DEBUG_CONNECT
                NSLog(@" ---> (%X) Not scanning for unpaired, since not scanning known.", self.bluetoothState);
#endif
                return;
            }

#ifdef DEBUG_CONNECT
            NSLog(@" ---> (%X) Starting scan for all paired...", self.bluetoothState);
#endif
            [self stopScan];
            [self scanUnknown:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
#ifdef DEBUG_CONNECT
                NSLog(@" ---> (%X) Stopping scan for all paired", self.bluetoothState);
#endif
                [self stopScan];
                [self scanKnown];
            });
        });
    });
}

- (void)scanUnknown:(BOOL)isPaired {
    if (self.bluetoothState == BT_STATE_PAIRING_UNKNOWN) {
#ifdef DEBUG_CONNECT
        NSLog(@" ---> (%X) Not scanning unknown since in pairing state.", self.bluetoothState);
#endif
        return;
    }

    [self stopScan];
    if (isPaired) {
        self.bluetoothState = BT_STATE_SCANNING_ALL_PAIRED;
    } else {
        self.bluetoothState = BT_STATE_SCANNING_ALL_UNPAIRED;
    }
#ifdef DEBUG_CONNECT
    NSLog(@" ---> (%X) Scanning unknown: %@", self.bluetoothState, [self knownPeripheralIdentifiers]);
#endif
    
    [self.manager scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:DEVICE_V1_SERVICE_BUTTON_UUID],
                                              [CBUUID UUIDWithString:DEVICE_V2_SERVICE_BUTTON_UUID],
                                              [CBUUID UUIDWithString:@"1523"]]
                                    options:nil];
}

- (void) stopScan {
#ifdef DEBUG_CONNECT
    NSLog(@" ---> (%X) Stopping scan.", self.bluetoothState);
#endif
    [self.manager stopScan];
}


#pragma mark - CBCentralManager delegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSLog(@" ---> centralManagerDidUpdateState: %@/%@ - %ld vs %ld", central, self.manager, (long)central.state, (long)self.manager.state);
    self.manager = central;
    [self updateBluetoothState:NO];
}

- (void)updateBluetoothState:(BOOL)renew {
    if (renew) {
        NSLog(@"Renewing CB manager. Old: %@/%ld", self.manager, (long)self.manager.state);
        if (self.manager) [self terminate];
        self.manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
    
    [self stopScan];
    if ([self isLECapableHardware]) {
        [self scanKnown];
    } else {
        [self countDevices];
        static dispatch_once_t onceReconnectToken;
        dispatch_once(&onceReconnectToken, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                onceReconnectToken = 0;
                [self reconnect:NO];
            });
        });
    }
}

- (void)reconnect:(BOOL)renew {
    // If not renew, then only force a reconnection if nothing is connected
    if (!renew) {
        for (TTDevice *device in self.foundDevices) {
            if (device.state == TTDeviceStateConnected) {
                return;
            }
        }
    }
    
    [self stopScan];
    [self terminate];
    [self updateBluetoothState:YES];
}

- (void) terminate {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (TTDevice *device in self.foundDevices) {
        NSLog(@"Terminating device: %@", device);
        if (device.state != TTDeviceStateConnected) {
            continue;
        }
        [identifiers addObject:[[NSUUID alloc] initWithUUIDString:device.uuid]];
    }
    
    NSArray *peripherals = [self.manager retrievePeripheralsWithIdentifiers:identifiers];
    for (CBPeripheral *peripheral in peripherals) {
        if (peripheral.state != CBPeripheralStateConnected) continue;
        [self.manager cancelPeripheralConnection:peripheral];
        TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
        [self.foundDevices removeDevice:device];
    }
    
    self.manager = nil;
    self.foundDevices = [[TTDeviceList alloc] init];
}

- (void)countDevices {
//    NSLog(@"Counting %d: %@", (int)foundDevices.count, foundDevices);
    
    [self.foundDevices ensureDevicesConnected];
    
    [self setValue:@([[self.foundDevices nicknamedConnected] count]) forKey:@"nicknamedConnectedCount"];
    [self setValue:@([self.foundDevices pairedConnectedCount]) forKey:@"pairedDevicesCount"];
    [self setValue:@([self.foundDevices unpairedCount]) forKey:@"unpairedDevicesCount"];
    [self setValue:@([self.foundDevices unpairedConnectedCount]) forKey:@"unpairedDevicesConnected"];
}

/*
 Invoked when the central discovers peripheral while scanning.
 */
- (void) centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
      advertisementData:(NSDictionary *)advertisementData
                   RSSI:(NSNumber *)RSSI
{
    TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
    if (!device) {
        device = [self.foundDevices addPeripheral:peripheral];
    }
    if (!device.isPaired && !self.isPairing) {
#ifdef DEBUG_CONNECT
            NSString *localName = [advertisementData objectForKey:CBAdvertisementDataLocalNameKey];
            NSLog(@" --> (%X) Found unknown bluetooth peripheral, not pairing, so disconnecting: %@/%@ (%@)", self.bluetoothState, localName, device, RSSI);
#endif
        [self.manager cancelPeripheralConnection:peripheral];
        return;
    }

    self.bluetoothState = BT_STATE_CONNECTING_UNKNOWN;
#ifdef DEBUG_CONNECT
    NSString *localName = [advertisementData objectForKey:CBAdvertisementDataLocalNameKey];
    NSLog(@" --> (%X) Found bluetooth peripheral, attempting connect: %@/%@ (%@)", self.bluetoothState, localName, device, RSSI);
#endif
//    [self stopScan];
    BOOL isAlreadyConnecting = NO;
    for (TTDevice *foundDevice in self.foundDevices) {
        if (foundDevice.peripheral == peripheral) continue;
        if (foundDevice.state == TTDeviceStateConnecting) {
#ifdef DEBUG_CONNECT
//            NSLog(@" ---> (%X) [Connecting to another] Canceling peripheral connection: have %@, canceling %@", bluetoothState, foundDevice, peripheral);
#endif
//            isAlreadyConnecting = YES;
        }
    }
    
    if (isAlreadyConnecting) {
        [self.manager cancelPeripheralConnection:peripheral];
    } else {
#ifdef DEBUG_CONNECT
        NSString *localName = [advertisementData objectForKey:CBAdvertisementDataLocalNameKey];
        NSLog(@" --> (%X) Attempting connect: %@/%@ (%@)", self.bluetoothState, localName, device, RSSI);
#endif
        [self.manager connectPeripheral:peripheral
                           options:@{CBConnectPeripheralOptionNotifyOnDisconnectionKey: [NSNumber numberWithBool:YES],
                                     CBCentralManagerOptionShowPowerAlertKey: [NSNumber numberWithBool:YES]}];
    }
}

/*
 Invoked whenever a connection is succesfully created with the peripheral.
 Discover available services on the peripheral.
 */
- (void) centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
    
    for (TTDevice *foundDevice in self.foundDevices) {
        if (foundDevice.state == TTDeviceStateConnecting && foundDevice.peripheral == peripheral) {
#ifdef DEBUG_CONNECT
//            NSLog(@" ---> (%X) [Connected another] Canceling peripheral connection: %@ (connecting to %@)", bluetoothState, device, foundDevice);
#endif
//            [manager cancelPeripheralConnection:peripheral];
//            return;
        }
    }
    [peripheral setDelegate:self];

#ifdef DEBUG_CONNECT
    NSLog(@" ---> (%X) Connected bluetooth peripheral: %@", self.bluetoothState, device);
#endif

    if (device.isPaired) {
        // Seen device before, connect and discover services

        device.state = TTDeviceStateConnecting;
        device.needsReconnection = NO;

        [self countDevices];

        self.bluetoothState = BT_STATE_DISCOVER_SERVICES;
    } else {
        // Never seen device before, start the pairing process

        self.bluetoothState = BT_STATE_PAIRING_UNKNOWN;
        
        device.state = TTDeviceStateConnecting;
        device.needsReconnection = NO;

        [self.buttonTimer resetPairingState];
        [self countDevices];

        BOOL noPairedDevices = ![self.foundDevices totalPairedCount];
        if (noPairedDevices) {
            [self.appDelegate.panelController openModal:MODAL_PAIRING_INTRO];
        }
    }

    [peripheral discoverServices:@[[CBUUID UUIDWithString:DEVICE_V1_SERVICE_BUTTON_UUID],
                                   [CBUUID UUIDWithString:DEVICE_V1_SERVICE_BATTERY_UUID],
                                   [CBUUID UUIDWithString:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID],
                                   [CBUUID UUIDWithString:DEVICE_V2_SERVICE_BUTTON_UUID],
                                   [CBUUID UUIDWithString:DEVICE_V2_SERVICE_BATTERY_UUID],
                                   [CBUUID UUIDWithString:dfuServiceUUIDString]
                                   ]];
    
    
    // Should put in a timer to ensure that scanknown is called in 10 seconds, just in case
//    [self scanKnown];
}

/*
 Invoked whenever an existing connection with the peripheral is torn down.
 */
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
#ifdef DEBUG_CONNECT
    TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
    NSLog(@" ---> (%X) Disconnected device: %@", self.bluetoothState, device);
#endif
    self.connectionDelay = 4;
    [self.foundDevices removePeripheral:peripheral];
    [self countDevices];

    static dispatch_once_t onceKnownToken;
    dispatch_once(&onceKnownToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            onceKnownToken = 0;
            [self scanKnown];
        });
    });
    
    [self.appDelegate.hudController releaseToastActiveAction];
    [self.appDelegate.hudController releaseToastActiveMode];
}

/*
 Invoked whenever the central manager fails to create a connection with the peripheral.
 */
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (error.code == 10) {
//        NSLog(@"Ignoring error: %@ (should be reached max conn)", [error localizedDescription]);
        return;
    }
    
#ifdef DEBUG_CONNECT
    NSLog(@" ---> (%X) Fail to connect to peripheral: %@ (%@) with error = %@", self.bluetoothState,
          peripheral.name, [peripheral.tt_identifierString substringToIndex:8], [error localizedDescription]);
#endif
    
    [self.foundDevices removePeripheral:peripheral];
    [self countDevices];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self stopScan];
        [self scanKnown];
    });
}

#pragma mark - CBPeripheral delegate methods

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    self.bluetoothState = BT_STATE_DISCOVER_CHARACTERISTICS;
    TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];

    for (CBService *service in peripheral.services) {
#ifdef DEBUG_CONNECT
//        NSLog(@" ---> (%X) Service found with UUID: %@", bluetoothState, service.UUID);
#endif
        
        if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_SERVICE_BUTTON_UUID]]) {
            device.firmwareVersion = 1;
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_BUTTON_STATUS_UUID]]
                                     forService:service];
        }

        if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID]]) {
            device.firmwareVersion = 1;
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_INTERVAL_MIN_UUID],
                                                  [CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_INTERVAL_MAX_UUID],
                                                  [CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_MODE_DURATION_UUID],
                                                  [CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_NICKNAME_UUID]]
                                     forService:service];
        }
                
        if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_SERVICE_BUTTON_UUID]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_BUTTON_STATUS_UUID],
                                                  [CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_NICKNAME_UUID]]
                                     forService:service];
        }
        
        if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_SERVICE_BATTERY_UUID]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_BATTERY_LEVEL_UUID]]
                                     forService:service];
        }
        
        if ([service.UUID isEqual:[CBUUID UUIDWithString:dfuServiceUUIDString]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:dfuVersionCharacteritsicUUIDString]]
                                     forService:service];
        }
        
        /* Device Information Service */
        if ([service.UUID isEqual:[CBUUID UUIDWithString:@"180A"]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:@"2A29"]]
                                     forService:service];
        }
        
        /* GAP (Generic Access Profile) for Device Name */
        if ([service.UUID isEqual:[CBUUID UUIDWithString:@"1800"]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:@"2A00"]]
                                     forService:service];
        }
    }
}

- (void) peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    self.bluetoothState = BT_STATE_CHAR_NOTIFICATION;
#ifdef DEBUG_CONNECT
//    NSLog(@" ---> (%X) Characteristic found with UUID: %@", bluetoothState, service.UUID);
#endif
    
    if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_SERVICE_BUTTON_UUID]]) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_BUTTON_STATUS_UUID]]) {
                [peripheral setNotifyValue:YES forCharacteristic:aChar];
            }
        }
    }
    
    if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_SERVICE_BUTTON_UUID]]) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_BUTTON_STATUS_UUID]]) {
                [peripheral setNotifyValue:YES forCharacteristic:aChar];
            } else if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_NICKNAME_UUID]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
        }
    }
    
    if ([service.UUID isEqual:[CBUUID UUIDWithString:dfuServiceUUIDString]]) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:dfuVersionCharacteritsicUUIDString]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
        }
    }

    if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID]]) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_INTERVAL_MIN_UUID]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_INTERVAL_MAX_UUID]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_MODE_DURATION_UUID]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_NICKNAME_UUID]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
//            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_CONN_LATENCY_UUID]]) {
//                [peripheral readValueForCharacteristic:aChar];
//            }
//            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_CONN_TIMEOUT_UUID]]) {
//                [peripheral readValueForCharacteristic:aChar];
//            }
        }
    }
    
    if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_SERVICE_BATTERY_UUID]]) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_BATTERY_LEVEL_UUID]]) {
                [peripheral readValueForCharacteristic:aChar];
                [self delayBatteryLevelReading];
            }
        }
    }
    
    if ([service.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_SERVICE_BATTERY_UUID]]) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_BATTERY_LEVEL_UUID]]) {
                [peripheral readValueForCharacteristic:aChar];
                [self delayBatteryLevelReading];
            }
        }
    }
    
    if ( [service.UUID isEqual:[CBUUID UUIDWithString:@"1800"]] ) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:@"2A00"]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
        }
    }
    
    if ([service.UUID isEqual:[CBUUID UUIDWithString:@"180A"]]) {
        for (CBCharacteristic *aChar in service.characteristics) {
            if ([aChar.UUID isEqual:[CBUUID UUIDWithString:@"2A29"]]) {
                [peripheral readValueForCharacteristic:aChar];
            }
        }
    }
}

/*
 Invoked upon completion of a -[setNotifyValue:] request
 */
- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_BUTTON_STATUS_UUID]] ||
        [characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_BUTTON_STATUS_UUID]]) {
#ifdef DEBUG_CONNECT
        NSLog(@" ---> (%X) Subscribed to button status notifications: %@", self.bluetoothState,
              [peripheral.tt_identifierString substringToIndex:8]);
#endif
        
        TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
        device.isNotified = YES;
        device.state = TTDeviceStateConnected;
        [device setActionDate];
        [self countDevices];
        
        self.bluetoothState = BT_STATE_IDLE;
        [self scanKnown];
//        [appDelegate.hudController toastActiveMode];
    } else {
        NSLog(@"ERROR: Subscribed to notifications: %@/%@", peripheral.tt_identifierString, characteristic.UUID.UUIDString);
    }
}

/*
 Invoked upon completion of a -[readValueForCharacteristic:] request or on the reception of a notification/indication.
 */
- (void) peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
              error:(NSError *)error {
    TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];

    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_BUTTON_STATUS_UUID]] ||
        [characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_BUTTON_STATUS_UUID]]) {
        if( (characteristic.value)  || !error ) {
//            NSLog(@"Characteristic value: %@", [characteristic.value hexadecimalString]);
            if (device.isPaired) {
                [self.buttonTimer readBluetoothData:characteristic.value];
            } else {
                [self.buttonTimer readBluetoothDataDuringPairing:characteristic.value];
                if ([self.buttonTimer isDevicePaired]) {
                    [self pairDeviceSuccess:peripheral];
                }
            }
            [device updateLastAction];
            [self setValue:[NSDate date] forKey:@"lastActionDate"];
        } else {
            NSLog(@"Characteristic error: %@ / %@", characteristic.value, error);
        }
    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_BATTERY_LEVEL_UUID]] ||
               [characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_BATTERY_LEVEL_UUID]]) {
        if( (characteristic.value)  || !error ) {
            const uint8_t *bytes = [characteristic.value bytes]; // pointer to the bytes in data
            uint16_t value = bytes[0]; // first byte
//            NSLog(@"Battery level: %d%%", value);
//            device.lastActionDate = [NSDate date];
            device.batteryPct = @(value);
            device.uuid = peripheral.tt_identifierString;
            [self setValue:@(value) forKey:@"batteryPct"];
//            [self setValue:[NSDate date] forKey:@"lastActionDate"];
        }
    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_INTERVAL_MIN_UUID]]) {
        [self.characteristics setObject:characteristic forKey:@"interval_min"];
        [self device:peripheral sentFirmwareSettings:FIRMWARE_INTERVAL_MIN];
    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_INTERVAL_MAX_UUID]]) {
        [self.characteristics setObject:characteristic forKey:@"interval_max"];
        [self device:peripheral sentFirmwareSettings:FIRMWARE_INTERVAL_MAX];
//    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_CONN_LATENCY_UUID]]) {
//        [characteristics setObject:characteristic forKey:@"conn_latency"];
//        [self device:peripheral sentFirmwareSettings:FIRMWARE_CONN_LATENCY];
//    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_CONN_TIMEOUT_UUID]]) {
//        [characteristics setObject:characteristic forKey:@"conn_timeout"];
//        [self device:peripheral sentFirmwareSettings:FIRMWARE_CONN_TIMEOUT];
    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V1_CHARACTERISTIC_NICKNAME_UUID]] ||
               [characteristic.UUID isEqual:[CBUUID UUIDWithString:DEVICE_V2_CHARACTERISTIC_NICKNAME_UUID]]) {
        if (!characteristic || !characteristic.value || !characteristic.value.length) {
#ifdef DEBUG_CONNECT
            NSLog(@" ---> !!! %@ has no nickname", peripheral);
#endif
        }
        TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
        [device setNicknameData:characteristic.value];
        
        [self countDevices];
        NSLog(@" ---> (%X) Hello %@", self.bluetoothState, device);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self ensureNicknameOnDevice:device];
        });
    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:@"2A00"]]) {
        NSString * deviceName = [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];
        NSLog(@"Device Name = %@", deviceName);
    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:@"2A29"]]) {
        self.manufacturer = [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];
        NSLog(@"Manufacturer Name = %@", self.manufacturer);
    } else if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:dfuVersionCharacteritsicUUIDString]]) {
        int firmwareVersion;
        [characteristic.value getBytes:&firmwareVersion length:2];
//#ifdef DEBUG_CONNECT
        NSLog(@" ---> Firmware version of %@: %d", device, firmwareVersion);
//#endif
        device.firmwareVersion = firmwareVersion;
        [self countDevices];
    } else {
        NSLog(@"Unidentified characteristic: %@", characteristic);
    }
}

/*
 Invoked upon completion of a -[writeValue:forCharacteristic:type:] request
 */
- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    uint16_t value;
    [characteristic.value getBytes:&value length:2];
    
    NSLog(@"Did write value. Old: %d/%@ - %@", value, characteristic.value, error);
    
    TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
    if (device.needsReconnection) {
#ifdef DEBUG_CONNECT
        NSLog(@" ---> (%X) [Needs reconnections] Canceling peripheral connection: %@", self.bluetoothState, peripheral);
#endif
        [self.manager cancelPeripheralConnection:device.peripheral];
    }
}


#pragma mark - Connection Attributes Firmware Updates

- (void)device:(CBPeripheral *)peripheral sentFirmwareSettings:(FirmwareSetting)setting {
//    NSLog(@"Device sent firmware settings: %d", setting);
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    uint16_t firmwareIntervalMin = [[prefs objectForKey:@"TT:firmware:interval_min"] intValue];
    uint16_t firmwareIntervalMax = [[prefs objectForKey:@"TT:firmware:interval_max"] intValue];
    uint16_t firmwareConnLatency = [[prefs objectForKey:@"TT:firmware:conn_latency"] intValue];
    uint16_t firmwareConnTimeout = [[prefs objectForKey:@"TT:firmware:conn_timeout"] intValue];
    uint16_t firmwareModeDuration = [[prefs objectForKey:@"TT:firmware:mode_duration"] intValue];
    
    if (setting == FIRMWARE_INTERVAL_MIN) {
        CBCharacteristic *characteristic = [self characteristicInPeripheral:peripheral
                                                             andServiceUUID:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID
                                                      andCharacteristicUUID:DEVICE_V1_CHARACTERISTIC_INTERVAL_MIN_UUID];
        if (!characteristic.value) return;
        uint16_t value;
        [characteristic.value getBytes:&value length:2];
        if (firmwareIntervalMin != value) {
            NSLog(@"Server %d, remote %d", firmwareIntervalMin, value);
            NSData *data = [NSData dataWithBytes:(void*)&firmwareIntervalMin length:2];
            [peripheral writeValue:data forCharacteristic:characteristic
                              type:CBCharacteristicWriteWithResponse];
        }
    } else if (setting == FIRMWARE_INTERVAL_MAX) {
        CBCharacteristic *characteristic = [self characteristicInPeripheral:peripheral
                                                             andServiceUUID:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID
                                                      andCharacteristicUUID:DEVICE_V1_CHARACTERISTIC_INTERVAL_MAX_UUID];
        if (!characteristic.value) return;
        uint16_t value;
        [characteristic.value getBytes:&value length:2];
        if (firmwareIntervalMax != value) {
            NSLog(@"Server %d, remote %d", firmwareIntervalMax, value);
            NSData *data = [NSData dataWithBytes:(void*)&firmwareIntervalMax length:2];
            [peripheral writeValue:data forCharacteristic:characteristic
                              type:CBCharacteristicWriteWithResponse];
        }
    } else if (setting == FIRMWARE_CONN_LATENCY) {
        CBCharacteristic *characteristic = [self characteristicInPeripheral:peripheral
                                                             andServiceUUID:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID
                                                      andCharacteristicUUID:DEVICE_V1_CHARACTERISTIC_CONN_LATENCY_UUID];
        if (!characteristic.value) return;
        uint16_t value;
        [characteristic.value getBytes:&value length:2];
        if (firmwareConnLatency != value) {
            NSLog(@"Server %d, remote %d", firmwareConnLatency, value);
            NSData *data = [NSData dataWithBytes:(void*)&firmwareConnLatency length:2];
            [peripheral writeValue:data forCharacteristic:characteristic
                              type:CBCharacteristicWriteWithResponse];
        }
    } else if (setting == FIRMWARE_CONN_TIMEOUT) {
        CBCharacteristic *characteristic = [self characteristicInPeripheral:peripheral
                                                             andServiceUUID:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID
                                                      andCharacteristicUUID:DEVICE_V1_CHARACTERISTIC_CONN_TIMEOUT_UUID];
        if (!characteristic.value) return;
        uint16_t value;
        [characteristic.value getBytes:&value length:2];
        if (firmwareConnTimeout != value) {
            NSLog(@"Server %d, remote %d", firmwareConnTimeout, value);
            NSData *data = [NSData dataWithBytes:(void*)&firmwareConnTimeout length:2];
            [peripheral writeValue:data forCharacteristic:characteristic
                              type:CBCharacteristicWriteWithResponse];
        }
    } else if (setting == FIRMWARE_MODE_DURATION) {
        CBCharacteristic *characteristic = [self characteristicInPeripheral:peripheral
                                                             andServiceUUID:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID
                                                      andCharacteristicUUID:DEVICE_V1_CHARACTERISTIC_MODE_DURATION_UUID];
        if (!characteristic.value) return;
        uint16_t value;
        [characteristic.value getBytes:&value length:2];
        if (firmwareModeDuration != value) {
            NSLog(@"Server %d, remote %d", firmwareModeDuration, value);
            NSData *data = [NSData dataWithBytes:(void*)&firmwareModeDuration length:2];
            [peripheral writeValue:data forCharacteristic:characteristic
                              type:CBCharacteristicWriteWithResponse];
        }
    }
}

- (void)setDeviceLatency:(NSInteger)latency {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    uint16_t minLatency = round((CGFloat)latency * 0.7f);
    uint16_t maxLatency = latency;
    
    [prefs setObject:@(minLatency) forKey:@"TT:firmware:interval_min"];
    [prefs setObject:@(maxLatency) forKey:@"TT:firmware:interval_max"];
    [prefs synchronize];
    
    for (TTDevice *device in self.foundDevices) {
        if (!device.isPaired) continue;
        [self device:device.peripheral sentFirmwareSettings:FIRMWARE_INTERVAL_MIN];
        [self device:device.peripheral sentFirmwareSettings:FIRMWARE_INTERVAL_MAX];
        device.needsReconnection = YES;
    }
}

- (void)setModeDuration:(NSInteger)duration {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    uint16_t modeDuration = duration;
    
    [prefs setObject:@(modeDuration) forKey:@"TT:firmware:mode_duration"];
    [prefs synchronize];
    
    for (TTDevice *device in self.foundDevices) {
        if (!device.isPaired) continue;
        [self device:device.peripheral sentFirmwareSettings:FIRMWARE_MODE_DURATION];
    }
}

- (void)ensureNicknameOnDevice:(TTDevice *)device {
//    if (!device.isPaired) return; // I guess unpaired remotes can still get a nickname forced on them

    NSString *newNickname;
    NSMutableData *emptyNickname = [NSMutableData dataWithLength:32];
    NSData *deviceNicknameData = [device.nickname dataUsingEncoding:NSUTF8StringEncoding];
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSString *nicknameKey = [NSString stringWithFormat:@"TT:device:%@:nickname", device.uuid];
    NSString *existingNickname = [prefs objectForKey:nicknameKey];
    
    BOOL hasDeviceNickname = ![deviceNicknameData isEqualToData:emptyNickname] && [device.nickname stringByTrimmingCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].length;
    BOOL force = YES;
    force = NO;
    
    if (!existingNickname && hasDeviceNickname) {
        [prefs setObject:device.nickname forKey:nicknameKey];
        [prefs synchronize];
    }
    
    if (!hasDeviceNickname || force) {
        if (existingNickname && existingNickname.length) {
            newNickname = existingNickname;
        } else {
            NSArray *emoji = @[@"🐱", @"🐼", @"🐶", @"🐨", @"🐙", @"🐝", @"🐠", @"🐳", @"⛄️",
                               @"⚽️", @"🎻", @"🎱", @"🌀", @"📚", @"🔮", @"📡", @"⛵️", @"🚲",
                               @"☀️", @"🌎", @"🌵", @"🌴", @"🎋", @"🍉", @"🍒", @"🌻", @"🌸",
                               @"🏺", @"🚀", @"🔭", @"🔬", @"🗿", @"🏮", @"💎", @"🎵", @"🍄"];
            NSString *randomEmoji = [emoji objectAtIndex:arc4random_uniform((uint32_t)emoji.count)];
            newNickname = [NSString stringWithFormat:@"%@ Turn Touch Remote", randomEmoji];
        }
        
        NSLog(@"Generating emoji nickname: %@", newNickname);

        [self writeNickname:newNickname toDevice:device];
    }
}

- (void)writeNickname:(NSString *)newNickname toDevice:(TTDevice *)device {
    NSMutableData *data = [NSMutableData dataWithData:[newNickname dataUsingEncoding:NSUTF8StringEncoding]];
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    // Clear out the NULL \0 bytes that accumulate
    [self clearDataOfNullBytes:data];

    // Must have a 32 byte string to overwrite old nicknames that were longer.
    if (data.length > 32) {
        NSString *dataString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dataString = [dataString substringToIndex:32];
        NSUInteger maxLength = MIN(32, dataString.length);
        while (maxLength > 0) {
            NSInteger encodedLength = [dataString lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (encodedLength > 32 || !encodedLength) {
                --maxLength;
                dataString = [dataString substringToIndex:maxLength];
            } else {
                break;
            }
        }
        [dataString substringToIndex:maxLength];
        data = [NSMutableData dataWithData:[dataString dataUsingEncoding:NSUTF8StringEncoding]];
    } else {
        [data increaseLengthBy:(32-data.length)];
    }

    CBCharacteristic *characteristic;
    
    if (device.firmwareVersion <= 1) {
        // BlueGiga's BLE112
        characteristic = [self characteristicInPeripheral:device.peripheral
                                           andServiceUUID:DEVICE_V1_SERVICE_FIRMWARE_SETTINGS_UUID
                                    andCharacteristicUUID:DEVICE_V1_CHARACTERISTIC_NICKNAME_UUID];
    } else if (device.firmwareVersion >= 2) {
        // Nordic's nRF51
        characteristic = [self characteristicInPeripheral:device.peripheral
                                           andServiceUUID:DEVICE_V2_SERVICE_BUTTON_UUID
                                    andCharacteristicUUID:DEVICE_V2_CHARACTERISTIC_NICKNAME_UUID];
    }
    
    if (!characteristic) {
        NSLog(@" ***> Problem! No valid nickname characteristic: v%ld", (long)device.firmwareVersion);
        [self.manager cancelPeripheralConnection:device.peripheral];
        return;
    }

    NSLog(@"New Nickname: => %@ (%@)", newNickname, data);
    
    [device.peripheral writeValue:data forCharacteristic:characteristic
                             type:CBCharacteristicWriteWithResponse];
    
    // Clear it again since it was padded out
    [self clearDataOfNullBytes:data];

    [device setNicknameData:data];
    
    [prefs setObject:newNickname forKey:[NSString stringWithFormat:@"TT:device:%@:nickname", device.uuid]];
    [prefs synchronize];

    [self countDevices];
}

- (void)clearDataOfNullBytes:(NSMutableData *)data {
    NSInteger i = MIN(32, data.length);
    char nullBytes[] = "\0";
    NSData *emptyData = [NSData dataWithBytes:nullBytes length:1];
    while (i--) {
        NSRange range = NSMakeRange(i, 1);
        NSData *dataAtByte = [data subdataWithRange:range];
        if ([dataAtByte isEqualToData:emptyData]) {
            [data replaceBytesInRange:range withBytes:NULL length:0];
        }
    }
}

#pragma mark - Battery level

- (void)delayBatteryLevelReading {
    if (self.batteryLevelTimer) {
        [self.batteryLevelTimer invalidate];
        self.batteryLevelTimer = nil;
    }
    NSDate *fireDate = [NSDate dateWithTimeIntervalSinceNow:BATTERY_LEVEL_READING_INTERVAL];
    self.batteryLevelTimer = [[NSTimer alloc]
                         initWithFireDate:fireDate
                         interval:0
                         target:self
                         selector:@selector(updateBatteryLevel:)
                         userInfo:nil
                         repeats:NO];
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    [runLoop addTimer:self.batteryLevelTimer forMode:NSDefaultRunLoopMode];
}

- (void)updateBatteryLevel:(NSTimer *)timer {
    for (TTDevice *device in self.foundDevices) {
        CBCharacteristic *characteristic = [self characteristicInPeripheral:device.peripheral
                                                             andServiceUUID:DEVICE_V1_SERVICE_BATTERY_UUID
                                                      andCharacteristicUUID:DEVICE_V1_CHARACTERISTIC_BATTERY_LEVEL_UUID];
        if (!characteristic) return;
        [device.peripheral readValueForCharacteristic:characteristic];
    }
    
    [self delayBatteryLevelReading];
}

#pragma mark - Pairing

- (void)pairDeviceSuccess:(CBPeripheral *)peripheral {
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSMutableArray *pairedDevices = [[preferences objectForKey:@"TT:devices:paired"] mutableCopy];
    if (!pairedDevices) {
        pairedDevices = [[NSMutableArray alloc] init];
    }
    [pairedDevices addObject:peripheral.tt_identifierString];
    [preferences setObject:pairedDevices forKey:@"TT:devices:paired"];
    [preferences synchronize];
    
    TTDevice *device = [self.foundDevices deviceForPeripheral:peripheral];
    device.isPaired = [self.foundDevices isDevicePaired:device];
    
    [self.buttonTimer resetPairingState];
    [self countDevices];
    [self.appDelegate.modeMap setActiveModeDirection:NO_DIRECTION];
    [self.appDelegate.panelController.backgroundView switchPanelModalPairing:MODAL_PAIRING_SUCCESS];

#ifdef DEBUG_CONNECT
//    NSLog(@" ---> (%X) [Pairing success] Canceling peripheral connection: %@", bluetoothState, foundDevice);
#endif
//    [manager cancelPeripheralConnection:peripheral];
}

- (void)forgetDevice:(TTDevice *)device {
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSArray *pairedDevices = [preferences arrayForKey:@"TT:devices:paired"];
    NSMutableArray *remainingPairedDevices = [NSMutableArray array];
    for (NSString *identifier in pairedDevices) {
        if (![identifier isEqual:device.uuid]) {
            [remainingPairedDevices addObject:identifier];
        } else {
            NSLog(@" ---> Forgetting %@", device);
        }
    }
    [preferences setObject:remainingPairedDevices forKey:@"TT:devices:paired"];
    [preferences synchronize];
    
    [self disconnectDevice:device];
}

- (void)disconnectDevice:(TTDevice *)device {
    NSLog(@" ---> Disconnecting %@", device);
    [self.manager cancelPeripheralConnection:device.peripheral];
    [self.foundDevices removeDevice:device];
    [self countDevices];
}

- (void)disconnectUnpairedDevices {
    NSMutableArray *devicesToDisconnect = [NSMutableArray array];
    for (TTDevice *device in self.foundDevices) {
        if (!device.isPaired) {
#ifdef DEBUG_CONNECT
            NSLog(@" ---> (%X) [Disconnecting] Canceling peripheral connection: %@", self.bluetoothState, device);
#endif
            [devicesToDisconnect addObject:device];
//            [manager cancelPeripheralConnection:device.peripheral];
        }
    }

    for (TTDevice *device in devicesToDisconnect) {
        [self disconnectDevice:device];
    }
    
    [self stopScan];
}

- (BOOL)noKnownDevices {
    return [self knownPeripheralIdentifiers].count == 0;
}

#pragma mark - Convenience methods

- (CBCharacteristic *)characteristicInPeripheral:(CBPeripheral *)peripheral
                                  andServiceUUID:(NSString *)serviceUUID
                           andCharacteristicUUID:(NSString *)characteristicUUID {
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:serviceUUID]]) {
            for (CBCharacteristic *characteristic in service.characteristics) {
                if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:characteristicUUID]]) {
                    return characteristic;
                }
            }
        }
    }
    
    return nil;
}

@end
