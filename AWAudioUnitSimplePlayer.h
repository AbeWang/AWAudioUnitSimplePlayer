//
//  AWAudioUnitSimplePlayer.h
//  AWAudioUnitSimplePlayer
//
//  Created by Abe Wang on 2017/4/5.
//  Copyright © 2017年 AbeWang. All rights reserved.
//

@import Foundation;
@import AudioToolbox;

@interface AWAudioUnitSimplePlayer : NSObject
- (instancetype)initWithURL:(NSURL *)inURL;
- (void)play;
- (void)pause;
@property (readonly, getter=isStopped) BOOL stopped;
@end
