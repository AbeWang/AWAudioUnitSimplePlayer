//
//  AWAudioUnitEQPlayer.h
//  AWAudioUnitEQPlayer
//
//  Created by Abe Wang on 2017/4/11.
//  Copyright © 2017年 AbeWang. All rights reserved.
//

@import Foundation;
@import AudioToolbox;

@interface AWAudioUnitEQPlayer : NSObject
- (instancetype)initWithURL:(NSURL *)inURL;
- (void)play;
- (void)pause;

- (void)selectEQPreset:(NSInteger)value;

@property (readonly, nonatomic) CFArrayRef iPodEQPresetsArray;
@end
