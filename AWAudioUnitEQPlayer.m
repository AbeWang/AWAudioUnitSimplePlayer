//
//  AWAudioUnitEQPlayer.m
//  AWAudioUnitEQPlayer
//
//  Created by Abe Wang on 2017/4/11.
//  Copyright © 2017年 AbeWang. All rights reserved.
//

#import "AWAudioUnitEQPlayer.h"

static void AWAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags);
static void AWAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions);
static OSStatus AWPlayerAURenderCallback(void * userData, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData);
static OSStatus AWPlayerConverterFiller(AudioConverterRef inAudioConverter, UInt32 * ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription** outDataPacketDescription, void * inUserData);

static const OSStatus AWAudioConverterCallbackError_NoData = 'awnd';

static AudioStreamBasicDescription AWSignedIntegerLinearPCMStreamDescription();

@interface AWAudioUnitEQPlayer ()
<NSURLSessionDelegate>
@property (nonatomic, strong) NSURLSession *URLSession;
@property (nonatomic, strong) NSMutableArray<NSData *> *packets;
- (double)packetsPerSecond;
@end

@implementation AWAudioUnitEQPlayer
{
	struct {
		BOOL stopped;
		BOOL loaded;
	} playerStatus;
	
	AUGraph audioGraph;
	AudioUnit mixerUnit;
	AudioUnit EQUnit;
	AudioUnit outputUnit;
	
	AudioFileStreamID audioFileStreamID;
	AudioStreamBasicDescription streamDescription;
	AudioConverterRef converter;
	AudioBufferList *renderBufferList;
	UInt32 renderBufferSize;
	
	size_t readHead;
}

- (void)dealloc
{
	AUGraphUninitialize(audioGraph);
	AUGraphClose(audioGraph);
	DisposeAUGraph(audioGraph);
	
	AudioFileStreamClose(audioFileStreamID);
	AudioConverterDispose(converter);
	
	free(renderBufferList->mBuffers[0].mData);
	free(renderBufferList);
	renderBufferList = NULL;
	
	[_URLSession invalidateAndCancel];
}

- (instancetype)initWithURL:(NSURL *)inURL
{
	if (self = [super init]) {
		self.packets = [NSMutableArray array];
		
		/*------------------------------------
		 第一步：
		 建立與設定 Audio Graph、Audio Units、Audio Parser，接著建立連線抓取音檔資料。
         Audio Converter 先不用建立，因為它需要先知道音檔的 Audio format，所以等 AudioParser parse 出格式後再建立。
		 ------------------------------------*/
		
		// 建立與設定 Audio Graph、Audio Units
		[self buildGraphAndUnits];
		
		// 建立 Audio Parser (AudioFileStreamID)
		OSStatus status = AudioFileStreamOpen((__bridge void *)self, AWAudioFileStreamPropertyListener, AWAudioFileStreamPacketsCallback, kAudioFileMP3Type, &audioFileStreamID);
		assert(status == noErr);
		
		// 建立連線並開始抓取音檔
		self.URLSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil];
		NSURLSessionDataTask *task = [self.URLSession dataTaskWithURL:inURL];
		[task resume];
		
		playerStatus.stopped = YES;
	}
	return self;
}

#pragma mark - Instance methods

- (void)buildGraphAndUnits
{
	// 建立 Audio Graph
	OSStatus status = NewAUGraph(&audioGraph);
	assert(status == noErr);
	status = AUGraphOpen(audioGraph);
	assert(status == noErr);

	// 在 audioGraph 中加入 Mixer Node
	AudioComponentDescription mixerUnitDescription;
	bzero(&mixerUnitDescription, sizeof(AudioComponentDescription));
	mixerUnitDescription.componentType = kAudioUnitType_Mixer;
	mixerUnitDescription.componentSubType = kAudioUnitSubType_MultiChannelMixer;
	mixerUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	mixerUnitDescription.componentFlags = 0;
	mixerUnitDescription.componentFlagsMask = 0;
	AUNode mixerNode;
	status = AUGraphAddNode(audioGraph, &mixerUnitDescription, &mixerNode);
	assert(status == noErr);

	// 在 audioGraph 中加入 EQ Node
	AudioComponentDescription EQUnitDescription;
	bzero(&EQUnitDescription, sizeof(AudioComponentDescription));
	EQUnitDescription.componentType = kAudioUnitType_Effect;
	EQUnitDescription.componentSubType = kAudioUnitSubType_AUiPodEQ;
	EQUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	EQUnitDescription.componentFlags = 0;
	EQUnitDescription.componentFlagsMask = 0;
	AUNode EQNode;
	status = AUGraphAddNode(audioGraph, &EQUnitDescription, &EQNode);
	assert(status == noErr);

	// 在 audioGraph 中加入 RemoteIO Node
	AudioComponentDescription outputUnitDescription;
	bzero(&outputUnitDescription, sizeof(AudioComponentDescription));
	outputUnitDescription.componentType = kAudioUnitType_Output;
	outputUnitDescription.componentSubType = kAudioUnitSubType_RemoteIO;
	outputUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	outputUnitDescription.componentFlags = 0;
	outputUnitDescription.componentFlagsMask = 0;
	AUNode outputNode;
	status = AUGraphAddNode(audioGraph, &outputUnitDescription, &outputNode);
	assert(status == noErr);
	
	// 串接 Nodes : 將 MixerNode 串接到 EQNode
	status = AUGraphConnectNodeInput(audioGraph, mixerNode, 0, EQNode, 0);
	assert(status == noErr);
	
	// 串接 Nodes : 再將 EQNode 串接到 OutputNode
	status = AUGraphConnectNodeInput(audioGraph, EQNode, 0, outputNode, 0);
	assert(status == noErr);

	// 取出三個 Node 的操作介面，也就是三個 Audio Unit
	
	// 取出 MixerNode 的 Audio Unit
	status = AUGraphNodeInfo(audioGraph, mixerNode, &mixerUnitDescription, &mixerUnit);
	assert(status == noErr);
	// 取出 EQNode 的 Audio Unit
	status = AUGraphNodeInfo(audioGraph, EQNode, &EQUnitDescription, &EQUnit);
	assert(status == noErr);
	// 取出 OutputNode 的 Audio Unit
	status = AUGraphNodeInfo(audioGraph, outputNode, &outputUnitDescription, &outputUnit);
	assert(status == noErr);
	
	// 設定三個 Audio Unit 的串流輸入與輸出格式
	
	// 設定 MixerUnit 的串流格式
    AudioStreamBasicDescription audioFormat = AWSignedIntegerLinearPCMStreamDescription();
    status = AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat));
    assert(status == noErr);
    status = AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioFormat, sizeof(audioFormat));
    assert(status == noErr);
    
	// 設定 EQUnit 的串流格式
    status = AudioUnitSetProperty(EQUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat));
    assert(status == noErr);
    status = AudioUnitSetProperty(EQUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioFormat, sizeof(audioFormat));
    assert(status == noErr);
    
	// 設定 OutputUnit 的串流格式
    // 由於送到 Remote IO 就會播放，我們就不用設定 Remote IO 的輸出格式了。
    status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat));
    assert(status == noErr);
    
	// 設定每個 AudioUnit 的最大 Frame Per Slice
    // 關於這項設定，要參考蘋果 Technical Q&A QA1606 這份重要的說明。Audio Unit API 是一種 pull model 的設計，不是我們主動把音訊資料推給 AUGraph，而是讓 AUGraph 透過 render callback function 跟我們索取資料，至於會跟我們要求多少資料，是由系統決定，而不是由我們決定。而 AUGraph 會跟我們要求多少資料會變動的，平常的時候，一次會跟我們要求 1024 個 frame，但是當 iOS 裝置在 lock screen 的時候，基於節電的理由，會變成一次跟我們要比較多的資料，變成 4096 個 frame，但每個 Audio Unit 預設可以通過的 frame 數量是 1156。所以，如果不調整設定，當裝置進入 lock screen 之後，就會因為中間串接的 Audio Unit 無法通過 4096 個 frame 而造成無法播放。因此我們要將每個 Audio Unit 可以通過的資料量設成 4096。
    UInt32 maxFPS = 4096;
    status = AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    assert(status == noErr);
    status = AudioUnitSetProperty(EQUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    assert(status == noErr);
    status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    assert(status == noErr);

    // 設定 render callback function
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    callbackStruct.inputProc = AWPlayerAURenderCallback;
    // 把 render callback 綁在 mixerNode input 上
    status = AUGraphSetNodeInputCallback(audioGraph, mixerNode, 0, &callbackStruct);
    assert(status == noErr);

    // AudioUnit 都設定完成後，把 audioGraph 作初始化
    status = AUGraphInitialize(audioGraph);
    assert(status == noErr);
    
    // 初始化 Audio Converter 要使用的 buffer list，converter 會將轉換完成的 LPCM 資料放入到此 bufferList 中
    // Audio Converter 的 buffer list 是用來放 LPCM 資料：
    // 4096: 讓 buffer 裡面可以塞到 4096 個 frame 大小。Audio Unit Render Callback 中要求多少資料量是會變動的(inNumberOfFrames)，平常一次會跟我們要求 1024 個 frame，但是當 iOS 裝置在 lock screen 的時候，會變成一次跟我們要比較多的資料，變成 4096 個 frame，所以 buffer size 至少要提供 4096 個 frame。
    // 4: 每個 frame 有四個 byte (一個 frame 裡有 2 channels，一個 channel 有 16 bits)
    UInt32 bufferSize = 4096 * 4;
    renderBufferSize = bufferSize;
    renderBufferList = (AudioBufferList *)calloc(1, sizeof(UInt32) + sizeof(AudioBuffer));
    renderBufferList->mNumberBuffers = 1;
    renderBufferList->mBuffers[0].mNumberChannels = 2;
    renderBufferList->mBuffers[0].mDataByteSize = bufferSize;
    renderBufferList->mBuffers[0].mData = calloc(1, bufferSize);
	
    // Print 出目前 audio graph 中的內部狀態資訊，ex. 有哪些 nodes 以及如何串接等
    CAShow(audioGraph);
}

- (double)packetsPerSecond
{
	if (streamDescription.mFramesPerPacket) {
		return streamDescription.mSampleRate / streamDescription.mFramesPerPacket;
	}
	return 44100.0 / 1152.0;
}

- (void)play
{
    if (!playerStatus.stopped) {
        return;
    }
    
    OSStatus status = AUGraphStart(audioGraph);
    assert(status == noErr);

    playerStatus.stopped = NO;
}

- (void)pause
{
    OSStatus status = AUGraphStop(audioGraph);
    assert(status == noErr);

    playerStatus.stopped = YES;
}

- (void)selectEQPreset:(NSInteger)value
{
    AUPreset *preset = (AUPreset *)CFArrayGetValueAtIndex(self.iPodEQPresetsArray, value);
    OSStatus status = AudioUnitSetProperty(EQUnit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, preset, sizeof(AUPreset));
    assert(status == noErr);
}

#pragma mark - 

- (void)_createAudioConverterWithAudioStreamDescription:(AudioStreamBasicDescription *)audioStreamBasicDescription
{
	// 先把 Parser parse 出來的 audio format 資訊也存一份到自己身上的 streamDescription 中
	memcpy(&streamDescription, audioStreamBasicDescription, sizeof(AudioStreamBasicDescription));

	// 建立 Audio Converter
	AudioStreamBasicDescription destFormat = AWSignedIntegerLinearPCMStreamDescription();
	OSStatus status = AudioConverterNew(&streamDescription, &destFormat, &converter);
	assert(status == noErr);
}

- (void)_storePacketsWithNumberOfPackets:(UInt32)inNumberPackets inputData:(const void *)inInputData packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions
{
	// 把拿到的 Packets 先儲存起來
	for (int i = 0; i < inNumberPackets; i++) {
		SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
		UInt32 packetSize = inPacketDescriptions[i].mDataByteSize;
		assert(packetSize > 0);
		NSData *packet = [NSData dataWithBytes:inInputData + packetOffset length:packetSize];
		[self.packets addObject:packet];
	}
	
	NSLog(@"Current total packets: %lu", (unsigned long)self.packets.count);
	
	/*------------------------------------
	 第五步：
	 檢查目前儲存的 packets 總量，若緩衝量已經足夠播放 3 秒，則可以開始播放
	 ------------------------------------*/
	
	if (readHead == 0 && self.packets.count > [self packetsPerSecond] * 3) {
		if (playerStatus.stopped) {
			NSLog(@"Start playing");
			[self play];
		}
	}
}

- (OSStatus)_fillAudioDataWithNumberOfFrames:(UInt32)inNumberOfFrames ioData:(AudioBufferList *)inIOData
{
    @synchronized (self) {
        if (readHead < self.packets.count) {
            @autoreleasepool {
                /*------------------------------------
                 第七步：
                 呼叫 Converter 來將 Packets 一個一個轉換成 LPCM 資料
                 ------------------------------------*/
                
                // Mixer Unit render callback 他要的 frames 數量，就是 packets 的數量。因為 LPCM 的一個 frame 就是一個 packet
                UInt32 packetSize = inNumberOfFrames;
                // 呼叫 AudioConverterFillComplexBuffer 來將 packet 轉換成 LPCM，轉好的資料會放入到我們提供的 renderBufferList 中。
                // AudioConverterFillComplexBuffer 中的 ioOutputDataPacketSize 參數是表示要轉出多少的 packet 數量
                OSStatus status = AudioConverterFillComplexBuffer(converter, AWPlayerConverterFiller, (__bridge void *)self, &packetSize, renderBufferList, NULL);
                
                if (status != noErr && status != AWAudioConverterCallbackError_NoData) {
                    [self pause];
                    return -1;
                }
                else if (!packetSize) {
                    inIOData->mNumberBuffers = 0;
                }
                else {
                    // Converter 成功把 packets 轉換成 LPCM，資料被放在 renderBufferList->mBuffers[0].mData 中
                    // 如果想要產生一些效果，在這邊可以去改變 renderBufferList->mBuffers[0].mData
                    
                    // 把轉換好的 LPCM 資料從 renderBufferList 搬到 render callback 的 ioData 中
                    inIOData->mNumberBuffers = 1;
                    inIOData->mBuffers[0].mNumberChannels = 2;
                    inIOData->mBuffers[0].mDataByteSize = renderBufferList->mBuffers[0].mDataByteSize;
                    inIOData->mBuffers[0].mData = renderBufferList->mBuffers[0].mData;
                    // Reset renderBufferList size
                    renderBufferList->mBuffers[0].mDataByteSize = renderBufferSize;
                }
            }
        }
        else {
            inIOData->mNumberBuffers = 0;
            return -1;
        }
    }
    return noErr;
}

- (OSStatus)_fillConverterBufferWithBufferList:(AudioBufferList *)ioData packetDescription:(AudioStreamPacketDescription **)outDataPacketDescription
{
    if (readHead >= self.packets.count) {
        NSLog(@"No Data");
        // 已把目前所有 packets 都轉換完了
        return AWAudioConverterCallbackError_NoData;
    }

    NSLog(@"Current readHead: %zu", readHead);

    // 一次把一個 Packet 的量放到 Converter callback 的 ioData 中，之後讓 Converter 轉換成 LPCM
    NSData *packet = self.packets[readHead];
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = (void *)packet.bytes;
    ioData->mBuffers[0].mDataByteSize = (UInt32)packet.length;

    // 也準備一份這個 packet 的 packet description 給 converter
    // 這裡一定得用 static
    static AudioStreamPacketDescription aspdesc;
    aspdesc.mDataByteSize = (UInt32)packet.length;
    aspdesc.mStartOffset = 0;
    aspdesc.mVariableFramesInPacket = 1;
    *outDataPacketDescription = &aspdesc;
    
    readHead++;
    return 0;
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        if ([(NSHTTPURLResponse *)response statusCode] != 200) {
            NSLog(@"HTTP Code: %ld", [(NSHTTPURLResponse *)response statusCode]);
            [session invalidateAndCancel];
            playerStatus.stopped = YES;
            completionHandler(NSURLSessionResponseCancel);
        }
        else {
            completionHandler(NSURLSessionResponseAllow);
        }
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    /*------------------------------------
     第二步：
     開始抓到一點一點的檔案，把拿到的 data 交由 Audio Parser (AudioFileStreamID) 開始去 Parse 出 data stream 中的 Packets 以及 Audio Format
     ------------------------------------*/

    OSStatus status = AudioFileStreamParseBytes(audioFileStreamID, (UInt32)data.length, data.bytes, 0);
    assert(status == noErr);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error) {
        NSLog(@"Failed to load data: %@", error.localizedDescription);
        playerStatus.stopped = YES;
        [self pause];
    }
    else {
        NSLog(@"Complete loading data");
        playerStatus.loaded = YES;
    }
}

#pragma mark - Properties

- (BOOL)isStopped
{
	return playerStatus.stopped;
}

- (CFArrayRef)iPodEQPresetsArray
{
    CFArrayRef presets;
    UInt32 size = sizeof(presets);
    OSStatus status = AudioUnitGetProperty(EQUnit, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &presets, &size);
    assert(status == noErr);
    return presets;
}

@end

static AudioStreamBasicDescription AWSignedIntegerLinearPCMStreamDescription()
{
	AudioStreamBasicDescription description;
	bzero(&description, sizeof(AudioStreamBasicDescription));
	description.mSampleRate = 44100.0;
	description.mFormatID = kAudioFormatLinearPCM;
	description.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
	description.mFramesPerPacket = 1;
	description.mBytesPerPacket = 4;
	description.mBytesPerFrame = 4;
	description.mChannelsPerFrame = 2;
	description.mBitsPerChannel = 16;
	description.mReserved = 0;
	return description;
}

static void AWAudioFileStreamPropertyListener(void * inClientData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags)
{
	if (inPropertyID == kAudioFileStreamProperty_DataFormat) {
		/*------------------------------------
		 第三步：
		 Audio Parser 已經成功 Parse 出 audio format，我們要根據檔案格式來建立 Audio Converter
		 ------------------------------------*/

		AWAudioUnitEQPlayer *self = (__bridge AWAudioUnitEQPlayer *)(inClientData);

		// 從 Parser 取出 parse 出來的 audio format
		UInt32 dataSize = 0;
		Boolean writable = false;
		AudioStreamBasicDescription audioStreamDescription;
		// 先取得屬性的資訊：如 size 等
		OSStatus status = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &writable);
		assert(status == noErr);
		// 再取得屬性內容，並將內容寫入到自己的 audioStreamDescription 中
		status = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &audioStreamDescription);
		assert(status == noErr);

		NSLog(@"mSampleRate: %f", audioStreamDescription.mSampleRate);
		NSLog(@"mFormatID: %u", audioStreamDescription.mFormatID);
		NSLog(@"mFormatFlags: %u", audioStreamDescription.mFormatFlags);
		NSLog(@"mBytesPerPacket: %u", audioStreamDescription.mBytesPerPacket);
		NSLog(@"mFramesPerPacket: %u", audioStreamDescription.mFramesPerPacket);
		NSLog(@"mBytesPerFrame: %u", audioStreamDescription.mBytesPerFrame);
		NSLog(@"mChannelsPerFrame: %u", audioStreamDescription.mChannelsPerFrame);
		NSLog(@"mBitsPerChannel: %u", audioStreamDescription.mBitsPerChannel);
		NSLog(@"mReserved: %u", audioStreamDescription.mReserved);
		
		// 有了音檔的 audio format 後，我們就可以來建立 audio converter
		[self _createAudioConverterWithAudioStreamDescription:&audioStreamDescription];
	}
}

static void AWAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions)
{
	/*------------------------------------
	 第四步：
	 Audio Parser 成功 parse 出 packets，我們先將這些 packets 儲存起來
	 ------------------------------------*/
	
	AWAudioUnitEQPlayer *self = (__bridge AWAudioUnitEQPlayer *)(inClientData);
	[self _storePacketsWithNumberOfPackets:inNumberPackets inputData:inInputData packetDescriptions:inPacketDescriptions];
}

static OSStatus AWPlayerAURenderCallback(void * userData, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    /*------------------------------------
     第六步：
     當開始播放後(Audio Graph Start 後)，便會透過此 render callback 來和我們拿資料去做播放。
     inNumberFrames 會告訴我們 audio graph 現在需要多少的資料量，然後我們要做的事情就是透過 converter 幫忙把 packets 一個一個拿去轉換成 LPCM 資料，最後把轉換好的 LPCM 資料放入到 ioData 中。
     ------------------------------------*/
    
    AWAudioUnitEQPlayer *self = (__bridge AWAudioUnitEQPlayer *)(userData);
    // 把 inNumberFrames 的資料量塞入到 ioData 中
    OSStatus status = [self _fillAudioDataWithNumberOfFrames:inNumberFrames ioData:ioData];
    
    if (status != noErr) {
        ioData->mNumberBuffers = 0;
        // 有錯誤發生的話，可以透過 ioActionFlags 來告訴 audio unit 先停止播放
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return status;
}

static OSStatus AWPlayerConverterFiller(AudioConverterRef inAudioConverter, UInt32 * ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription** outDataPacketDescription, void * inUserData)
{
    /*------------------------------------
     第八步：
     當 Converter 開始要把 Packet 轉換成 LPCM 資料時，會呼叫此 callback function
     這時候要把一個一個的 Packet 丟給 Converter 的 ioData 中，讓它轉換
     ------------------------------------*/
    
    AWAudioUnitEQPlayer *self = (__bridge AWAudioUnitEQPlayer *)(inUserData);
    
    OSStatus status = [self _fillConverterBufferWithBufferList:ioData packetDescription:outDataPacketDescription];
    if (status == noErr) {
        // 告訴 Converter，我們一次只處理一個 packet 的數量
        *ioNumberDataPackets = 1;
    }
    else {
        // 如果有錯誤，告訴 Converter 我們沒有放 packet 資料
        *ioNumberDataPackets = 0;
    }
    return status;
}
