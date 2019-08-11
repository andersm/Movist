//
//  Movist
//
//  Copyright 2006 ~ 2008 Yong-Hoe Kim, Cheol Ju. All rights reserved.
//      Yong-Hoe Kim  <cocoable@gmail.com>
//      Cheol Ju      <moosoy@gmail.com>
//
//  This file is part of Movist.
//
//  Movist is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  Movist is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "FFTrack.h"
#import "MMovie_FFMPEG.h"
#import <libavutil/mathematics.h>
#import <libavutil/opt.h>

/*
@interface AUCallbackInfo : NSObject
{
    MMovie_FFmpeg* _movie;
    int _streamId;
}
@end
*/

@interface AudioDataQueue : NSObject
{
    int _bitRate;
    UInt8* _data;
    NSRecursiveLock* _mutex;
    double _time;
    unsigned int _capacity;
    unsigned int _front;
    unsigned int _rear;
}
@end

@implementation AudioDataQueue

- (id)initWithCapacity:(unsigned int)capacity
{
    //TRACE(@"%s %d", __PRETTY_FUNCTION__, capacity);
    self = [super init];
    if (self) {
        _data = malloc(sizeof(UInt8) * capacity);
        _mutex = [[NSRecursiveLock alloc] init];
        _capacity = capacity;
        _front = 0;
        _rear = 0;
    }
    return self;
}

- (void)dealloc
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    free(_data);
    [_mutex release];
    [super dealloc];
}

- (void)clear
{
    [_mutex lock];
    _rear = _front;
    [_mutex unlock];
}

- (BOOL)isEmpty { return (_front == _rear); }
- (BOOL)isFull { return (_front == (_rear + 1) % _capacity); }
- (int)bitRate { return _bitRate; }

- (int)dataSize
{
    [_mutex lock];
    int size = (_capacity + _rear - _front) % _capacity;
    [_mutex unlock];
    return size;
}

- (int)freeSize
{
    return _capacity - 1 - [self dataSize];
}

- (void)setBitRate:(int)bitRate
{
    _bitRate = bitRate;
}

- (BOOL)putData:(UInt8*)data size:(int)size time:(double)time
{
    [_mutex lock];
    if ([self freeSize] < size) {
        [_mutex unlock];
        return FALSE;
    }
    int i;
    int rear = _rear;
    for (i = 0; i < size; i++) {
        _data[rear] = data[i];
        rear = (rear + 1) % _capacity;
    }
    _time = time + 1. * size / _bitRate;
    _rear = rear;
    [_mutex unlock];
    return TRUE;
}

- (BOOL)getData:(UInt8*)data size:(int)size time:(double*)time
{
    [_mutex lock];
    if ([self dataSize] < size) {
        [_mutex unlock];
        return FALSE;
    }
    *time = _time -  1. * ([self dataSize] - size)/ _bitRate;
    int i;
    for (i = 0; i < size; i++) {
        data[i] = _data[_front];
        _front = (_front + 1) % _capacity;
    }
    [_mutex unlock];
    return TRUE;
}

- (void)removeDataDuring:(double)dt channelNumber:(int)channelNumber time:(double*)time
{
    int size = dt * _bitRate;
    int sizeUnit = channelNumber * sizeof(_data[0]);
    size = size / sizeUnit * sizeUnit;
    [_mutex lock];
    int dataSize = [self dataSize];
    if (dataSize < size) {
        size = dataSize;
    }
    _front = (_front + size) % _capacity;
    *time = _time - 1. * ([self dataSize] - size) / _bitRate;
    [_mutex unlock];
    //TRACE(@"data removed %f", dt);
}

- (void)getFirstTime:(double*)time
{
    [_mutex lock];
    *time = _time - 1. * [self dataSize] / _bitRate;
    [_mutex unlock];
}

- (double)lastTime
{
    return _time;
}
@end

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

static OSStatus audioProc(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags,
                          const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber,
                          UInt32 inNumberFrames, AudioBufferList* ioData);

@implementation FFAudioTrack (Analog)

- (BOOL)initAudioUnit
{
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
	AudioComponent component = AudioComponentFindNext(0, &desc);
    if (!component) {
        TRACE(@"AudioComponentFindNext() failed");
        return FALSE;
    }
	OSStatus err = AudioComponentInstanceNew(component, &_audioUnit);
    if (!component) {
        TRACE(@"AudioComponentInstanceNew() failed : %ld\n", err);
        return FALSE;
    }

    AURenderCallbackStruct input;
    input.inputProc = audioProc;
    input.inputProcRefCon = self;
    err = AudioUnitSetProperty(_audioUnit,
                               kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input,
                               0, &input, sizeof(input));
    if (err != noErr) {
        TRACE(@"AudioUnitSetProperty(callback) failed : %ld\n", err);
        return FALSE;
    }

    AVCodecContext* context = _stream->codec;

    UInt32 formatFlags =  kAudioFormatFlagsNativeFloatPacked
                        | kAudioFormatFlagIsNonInterleaved;
    UInt32 bytesPerPacket = 4;
    UInt32 bytesPerFrame = 4;
    UInt32 bitsPerChannel = 32;

    AudioStreamBasicDescription streamFormat;
    streamFormat.mSampleRate = context->sample_rate;
    streamFormat.mFormatID = kAudioFormatLinearPCM;
    streamFormat.mFormatFlags = formatFlags;
    streamFormat.mBytesPerPacket = bytesPerPacket;
    streamFormat.mFramesPerPacket = 1;
    streamFormat.mBytesPerFrame = bytesPerFrame;
    streamFormat.mChannelsPerFrame = context->channels;
    streamFormat.mBitsPerChannel = bitsPerChannel;
    err = AudioUnitSetProperty(_audioUnit,
                               kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input,
                               0, &streamFormat, sizeof(streamFormat));
    if (err != noErr) {
        TRACE(@"AudioUnitSetProperty(streamFormat) failed : %ld\n", err);
        return FALSE;
    }

    // Initialize unit
    err = AudioUnitInitialize(_audioUnit);
    if (err) {
        TRACE(@"AudioUnitInitialize=%ld", err);
        return FALSE;
    }

    Float64 outSampleRate;
    UInt32 size = sizeof(Float64);
    err = AudioUnitGetProperty(_audioUnit,
                               kAudioUnitProperty_SampleRate,
                               kAudioUnitScope_Output,
                               0, &outSampleRate, &size);
    if (err) {
        TRACE(@"AudioUnitSetProperty-GF=%4.4s, %ld", (char*)&err, err);
        return FALSE;
    }
    return TRUE;
}

-(BOOL)initResampleContext
{
    int averr;
    _resampleContext = avresample_alloc_context();

    if (!_resampleContext) {
        return FALSE;
    }

    AVCodecContext* context = _stream->codec;

    // Hack if there is no channel layout
    uint64_t channel_layout = context->channel_layout;
    if (channel_layout == 0) {
        switch (context->channels) {
            case 1:
                channel_layout = AV_CH_LAYOUT_MONO;
                break;
            case 2:
                channel_layout = AV_CH_LAYOUT_STEREO;
                break;
            default:
                break;
        }
    }

    av_opt_set_int(_resampleContext, "in_channel_layout", channel_layout, 0);
    av_opt_set_int(_resampleContext, "in_sample_fmt", context->sample_fmt, 0);
    av_opt_set_int(_resampleContext, "in_sample_rate", context->sample_rate, 0);
    av_opt_set_int(_resampleContext, "out_channel_layout", channel_layout, 0);
    av_opt_set_int(_resampleContext, "out_sample_fmt", AV_SAMPLE_FMT_S16, 0);
    av_opt_set_int(_resampleContext, "out_sample_rate", context->sample_rate, 0);

    averr = avresample_open(_resampleContext);

    if (averr) {
        TRACE(@"avresample_open=%ld", averr);
        return FALSE;
    }

    return TRUE;
}

- (BOOL)initAnalogAudio:(int*)errorCode
{
    // create audio unit
    if (![self initAudioUnit]) {
        *errorCode = ERROR_FFMPEG_AUDIO_UNIT_CREATE_FAILED;
        return FALSE;
    }

    if (![self initResampleContext]) {
        *errorCode = ERROR_LIBRESAMPLE_CONTEXT_CREATE_FAILED;
        return FALSE;
    }

    _volume = DEFAULT_VOLUME;
    _speakerCount = 2;

    // init playback
    unsigned int queueCapacity = AVCODEC_MAX_AUDIO_FRAME_SIZE * 20 * 5;
    _dataQueue = [[AudioDataQueue alloc] initWithCapacity:queueCapacity];
    AVCodecContext* context = _stream->codec;
    [_dataQueue setBitRate:sizeof(int16_t) * context->sample_rate * context->channels];
    _nextDecodedTime = 0;
    _nextAudioPts = 0;

    return TRUE;
}

- (void)cleanupAnalogAudio
{
    if (_audioUnit) {
        //[self stopAudio];
        while (AudioUnitUninitialize(_audioUnit) != 0) {
            assert(FALSE);
        }
		while (AudioComponentInstanceDispose(_audioUnit) != 0) {
            assert(FALSE);
        }
        _audioUnit = 0;
    }
    [_dataQueue clear];
    [_dataQueue release];
    _dataQueue = 0;

    if (_resampleContext) {
        avresample_free(&_resampleContext);
        _resampleContext = 0;
    }
    _running = FALSE;
}

- (void)startAnalogAudio
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    _running = TRUE;
    while (AudioOutputUnitStart(_audioUnit) != 0) {
        assert(FALSE);
        //[NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
}

- (void)stopAnalogAudio
{
    while (AudioOutputUnitStop(_audioUnit) != 0) {
        //assert(FALSE);
        [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }   
}

- (void)decodePacket:(AVPacket*)packet
{
    AVCodecContext* context = _stream->codec;
    if (packet->data == s_flushPacket.data) {
        avcodec_flush_buffers(context);
        return;
    }

    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

    UInt8* packetPtr = packet->data;
    int packetSize = packet->size;
    int dataSize, decodedSize;
    int64_t pts, nextPts = 0;
    double decodedTime;
    BOOL newPacket = true;
	int got_frame = 0;

    //TRACE(@"dts = %lld * %lf = %lf", packet->dts, PTS_TO_SEC, 1. * packet->dts * PTS_TO_SEC);
    while (0 < packetSize) {
		decodedSize = avcodec_decode_audio4(context, _decodedFrame, &got_frame, packet);
        if (decodedSize < 0) { 
            TRACE(@"decodedSize < 0");
            break;
        }
        packetPtr  += decodedSize;
        packetSize -= decodedSize;
        if (newPacket) {
            newPacket = FALSE;
            if (packet->dts != AV_NOPTS_VALUE) {
                pts = packet->dts;
                nextPts = pts;
            }
            else {
                //TRACE(@"packet.dts == AV_NOPTS_VALUE");
                pts = _nextAudioPts;
                //assert(FALSE);
            }
        }
		dataSize = _decodedFrame->nb_samples * _stream->codec->request_channels * av_get_bytes_per_sample(_stream->codec->sample_fmt);
        if (dataSize > 0) {
            nextPts = pts +  1. * dataSize / [_dataQueue bitRate] / PTS_TO_SEC;
        }
        decodedTime = 1. * pts * PTS_TO_SEC - _startTime;
        pts = nextPts;
        if (0 < dataSize) {
            if (AVCODEC_MAX_AUDIO_FRAME_SIZE < dataSize) {
                TRACE(@"AVCODEC_MAX_AUDIO_FRAME_SIZE < dataSize");
                assert(FALSE);
            }

            int sample_rate = _stream->codec->sample_rate;
            int out_linesize;
            uint8_t *resample_buffer;
            int out_samples = avresample_available(_resampleContext) + av_rescale_rnd(avresample_get_delay(_resampleContext) +
                                                                                      _decodedFrame->nb_samples, sample_rate, sample_rate, AV_ROUND_UP);
            av_samples_alloc(&resample_buffer, &out_linesize, _stream->codec->channels, out_samples, AV_SAMPLE_FMT_S16, 0);
            out_samples = avresample_convert(_resampleContext, &resample_buffer, out_linesize, out_samples, &_decodedFrame->data[0], _decodedFrame->linesize[0], _decodedFrame->nb_samples);
            int resampled_size = out_samples * _stream->codec->channels * av_get_bytes_per_sample(AV_SAMPLE_FMT_S16);

            while (![_movie quitRequested] && [_dataQueue freeSize] < resampled_size) {
                if ([_movie reservedCommand] == COMMAND_SEEK || ![self isEnabled]) {
                    break;
                }
                [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            [_dataQueue putData:resample_buffer size:resampled_size time:decodedTime];

            av_freep(&resample_buffer);
            _nextAudioPts = nextPts;
        }
    }

    if (packet->data) {
        av_free_packet(packet);
    }

    [pool release];
}

- (void)clearAnalogDataQueue
{
    [_dataQueue clear];
    [self decodePacket:&s_flushPacket];
    _nextDecodedTime = 0;
}

#define AUDIO_DATA_TYPE float

- (void)makeEmpty:(AUDIO_DATA_TYPE**)buf channelNumber:(int)channelNumber bufSize:(int)bufSize
{
    int i;
    for (i = 0; i < channelNumber; i++) {
        memset(buf[i], 0, bufSize * sizeof(AUDIO_DATA_TYPE));
    }
}

- (void)nextAudio:(const AudioTimeStamp*)timeStamp busNumber:(UInt32)busNumber
      frameNumber:(UInt32)frameNumber audioData:(AudioBufferList*)ioData
{
    const int MAX_AUDIO_CHANNEL_SIZE = 8;
    const int AUDIO_BUF_SIZE = 44000 * MAX_AUDIO_CHANNEL_SIZE / 10;

    int i, j;
    int frameSize = sizeof(int16_t);  // int16
    int channelNumber = ioData->mNumberBuffers;
    int requestSize = frameNumber * frameSize * channelNumber;
    if (AUDIO_BUF_SIZE < requestSize) {
        TRACE(@"AUDIO_BUF_SIZE(%d) < requestSize(%d)", AUDIO_BUF_SIZE, requestSize);
        return;
        //assert(requestSize < AUDIO_BUF_SIZE);
    }

    AUDIO_DATA_TYPE* dst[MAX_AUDIO_CHANNEL_SIZE];
    for (i = 0; i < channelNumber; i++) {
        dst[i] = ioData->mBuffers[i].mData;
        assert(ioData->mBuffers[i].mDataByteSize == 4 * frameNumber);
        assert(ioData->mBuffers[i].mNumberChannels == 1);
    }
    _dataPoppingStarted = TRUE;
    if (![self isEnabled] ||
        [_movie quitRequested] ||
        [_movie reservedCommand] != COMMAND_NONE ||
        [_movie isPlayLocked] ||
        [_movie command] != COMMAND_PLAY ||
        0 == [_movie hostTime0point] ||
        [_dataQueue dataSize] < requestSize) {
        [self makeEmpty:dst channelNumber:channelNumber bufSize:frameNumber];
        [_dataQueue getFirstTime:&_nextDecodedTime];
        [_movie audioTrack:self avFineTuningTime:0];
        //double hostTime = 1. * timeStamp->mHostTime / [_movie hostTimeFreq];
        //double currentTime = hostTime - [_movie hostTime0point];
        //TRACE(@"currentTime(%f) audioTime %f make empty", currentTime, _nextDecodedTime);
        _dataPoppingStarted = FALSE;
        return;
    }
    
    double hostTime = 1. * timeStamp->mHostTime / [_movie hostTimeFreq];
    double currentTime = hostTime - [_movie hostTime0point];
    [_dataQueue getFirstTime:&_nextDecodedTime];
    
    double dt = _nextDecodedTime - currentTime;
    if (dt < -0.2 || 0.2 < dt) {
        if (dt < 0) {
            [_dataQueue removeDataDuring:-dt channelNumber:channelNumber time:&_nextDecodedTime];
            //TRACE(@"remove dt:%f", dt);
            if ([_dataQueue dataSize] < requestSize) {
                [self makeEmpty:dst channelNumber:channelNumber bufSize:frameNumber];
                [_movie audioTrack:self avFineTuningTime:0];
                //TRACE(@"currentTime(%f) audioTime %f dt:%f", currentTime, _nextDecodedTime, dt);
                _dataPoppingStarted = FALSE;
                return;
            }
            dt = 0;
        }
        else {
            [self makeEmpty:dst channelNumber:channelNumber bufSize:frameNumber];
            [_movie audioTrack:self avFineTuningTime:0];
            //TRACE(@"currentTime(%f) audioTime %f dt:%f", currentTime, _nextDecodedTime, dt);
            _dataPoppingStarted = FALSE;
            return;
        }
    }
    else if (-0.01 < dt && dt < 0.01) {
        dt = 0;
    }
    [_movie audioTrack:self avFineTuningTime:dt];
    //TRACE(@"currentTime(%f) audioTime %f", currentTime, _nextDecodedTime);
    
    int16_t audioBuf[AUDIO_BUF_SIZE];
    [_dataQueue getData:(UInt8*)audioBuf size:requestSize time:&_nextDecodedTime];
    float volume = [_movie muted] ? 0 : _volume;
    for (i = 0; i < frameNumber; i++) { 
        for (j = 0; j < channelNumber; j++) {
            dst[j][i] = 1. * volume * audioBuf[channelNumber * i + j] / INT16_MAX;
        }
    }
    if (_speakerCount == 2 && channelNumber == 6) {
        for (i = 0; i < frameNumber; i++) {
            dst[0][i] += dst[4][i] + (dst[2][i] + dst[3][i]) / 2;
            dst[1][i] = 0;;
            //dst[1][i] += dst[5][i] + (dst[2][i] + dst[3][i]) / 2;
        }
    }
    _dataPoppingStarted = FALSE;
}

@end

static OSStatus audioProc(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags,
                          const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber,
                          UInt32 inNumberFrames, AudioBufferList* ioData)
{
    [(FFAudioTrack*)inRefCon nextAudio:inTimeStamp busNumber:inBusNumber
                           frameNumber:inNumberFrames audioData:ioData];
    return noErr;
}
