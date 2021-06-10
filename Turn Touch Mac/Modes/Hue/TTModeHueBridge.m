//
//  TTModeHueBridge.m
//  Turn Touch Remote
//
//  Created by Samuel Clay on 5/9/16.
//  Copyright © 2016 Turn Touch. All rights reserved.
//

#import "TTModeHueBridge.h"

@interface TTModeHueBridge ()

@property (nonatomic,strong) NSDictionary *bridgesFound;
@property (nonatomic,strong) NSArray *sortedBridgeKeys;

@property (nonatomic,weak) IBOutlet NSTableView *tableView;
@property (nonatomic,weak) IBOutlet NSButton *connectButton;
@property (nonatomic,weak) IBOutlet NSButton *searchButton;

@end

@implementation TTModeHueBridge

- (id)initWithNibName:(NSString *)nibNameOrNil
               bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        [self.connectButton setEnabled:NO];
    }
    return self;
}

- (void)setBridges:(NSDictionary *)foundBridges {
    self.bridgesFound = foundBridges;
    self.sortedBridgeKeys = [self.bridgesFound.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSLog(@"Bridges found: %@", self.bridgesFound);
    
    [self.tableView reloadData];
    
    if ([self.bridgesFound.allKeys count] == 1) {
        // Auto-select if there's a single bridge
        [self connectAtRow:0];
    }

}

- (IBAction)refreshButtonClicked:(id)sender {
    // remove this sheet
    [self.modeHue searchForBridgeLocal];
}

- (IBAction)connectButtonClicked:(id)sender{
    return [self connectAtRow:[self.tableView selectedRow]];
}


- (void)connectAtRow:(NSInteger)row {
    if (row > -1){
        /***************************************************
         The choice of bridge to use is made, store the bridge id
         and ip address for this bridge
         *****************************************************/
        
        // Get bridge id and ip address of selected bridge
        NSString *bridgeId = [self.sortedBridgeKeys objectAtIndex:row];
        NSString *ip = [self.bridgesFound objectForKey:bridgeId];
        
        // Inform delegate
        [self.modeHue bridgeSelectedWithIpAddress:ip andBridgeId:bridgeId];
    }
}

#pragma mark - Table view data source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [self.bridgesFound.allKeys count];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    
    // Get a new ViewCell
    NSTableCellView *cellView = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
    
    // Get mac address and ip address of selected bridge
    NSString *mac = [self.sortedBridgeKeys objectAtIndex:row];
    NSString *ip = [self.bridgesFound objectForKey:mac];
    
    if ([tableColumn.identifier isEqualToString:@"FirstColumn"]){
        cellView.textField.stringValue = mac;
    } else if ([tableColumn.identifier isEqualToString:@"SecondColumn"]){
        cellView.textField.stringValue = ip;
    }
    
    return cellView;
}

#pragma mark - Table view delegate

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification{
    if ([self.tableView selectedRow]>-1){
        [self.connectButton setEnabled:YES];
    } else {
        [self.connectButton setEnabled:NO];
    }
}

@end
