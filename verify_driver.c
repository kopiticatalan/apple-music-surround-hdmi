// Runs driver callbacks in-process; no HAL installation or system access needed.
#include "HDMILab.c"
#include <assert.h>
#include <stdio.h>
static OSStatus changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a) { return noErr; }
int main(void) {
    static AudioServerPlugInHostInterface host = {.PropertiesChanged=changed};
    gPlugIn_Host=&host;
    for(UInt32 i=0;i<sink_num_formats();i++) {
        AudioStreamBasicDescription f, found; sink_format_at(i,&f);
        assert(sink_find_format(&f,&found));
        assert(f.mFramesPerPacket==1);
        assert(f.mBytesPerFrame == f.mBytesPerPacket);
        if(f.mFormatID==kAudioFormatLinearPCM) {
            assert(f.mChannelsPerFrame==LAB_CHANNELS && f.mBitsPerChannel==32);
        } else {
            assert(f.mFormatID==kAudioFormat60958AC3 && f.mChannelsPerFrame==2 && f.mBitsPerChannel==16);
            assert(f.mFormatFlags & kAudioFormatFlagIsNonMixable);
        }
    }
    // Input enumeration contains PCM only, output includes encoded carriers.
    UInt32 n=0; AudioObjectPropertyAddress a={kAudioStreamPropertyAvailablePhysicalFormats,kAudioObjectPropertyScopeGlobal,0};
    assert(!BlackHole_GetStreamPropertyDataSize(gAudioServerPlugInDriverRef,kObjectID_Stream_Input,0,&a,0,NULL,&n));
    assert(n==kDevice_SampleRatesSize*sizeof(AudioStreamRangedDescription));
    // Explicit descriptions must identify every channel exactly once.
    a.mSelector=kAudioDevicePropertyPreferredChannelLayout;a.mScope=kAudioObjectPropertyScopeOutput;
    assert(!BlackHole_GetDevicePropertyDataSize(gAudioServerPlugInDriverRef,kObjectID_Device,0,&a,0,NULL,&n));
    AudioChannelLayout* layout=calloc(1,n);UInt32 actual=0;
    assert(!BlackHole_GetDevicePropertyData(gAudioServerPlugInDriverRef,kObjectID_Device,0,&a,0,NULL,n,&actual,layout));
    assert(layout->mChannelLayoutTag==kAudioChannelLayoutTag_UseChannelDescriptions);
    assert(layout->mNumberChannelDescriptions==LAB_CHANNELS);
    for(UInt32 i=0;i<LAB_CHANNELS;i++)for(UInt32 j=i+1;j<LAB_CHANNELS;j++)assert(layout->mChannelDescriptions[i].mChannelLabel!=layout->mChannelDescriptions[j].mChannelLabel);
    free(layout);
    // Test deferred format commit and the encoded -> float mirror mapping.
    gRingBuffer=calloc(kRing_Buffer_Frame_Size*LAB_CHANNELS,sizeof(Float32));
    SinkChange* change=malloc(sizeof(SinkChange));
    fill_encoded_format(&change->format,kAudioFormat60958AC3,192000);
    assert(!BlackHole_PerformDeviceConfigurationChange(gAudioServerPlugInDriverRef,kObjectID_Device,ChangeAction_SetOutputFormat,change));
    assert(gOutput_Encoded && gDevice_SampleRate==192000);
    enum { frames=64 };
    SInt16 carrier[frames*2]; Float32 input[frames*LAB_CHANNELS];
    for(UInt32 i=0;i<frames*2;i++) carrier[i]=(SInt16)(i*521-32768);
    AudioServerPlugInIOCycleInfo cycle={0};
    cycle.mOutputTime.mSampleTime=1000;cycle.mInputTime.mSampleTime=1000;
    assert(!BlackHole_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Output,0,kAudioServerPlugInIOOperationWriteMix,frames,&cycle,carrier,NULL));
    assert(!BlackHole_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device2,kObjectID_Stream_Input,0,kAudioServerPlugInIOOperationReadInput,frames,&cycle,input,NULL));
    for(UInt32 f=0;f<frames;f++)for(UInt32 c=0;c<LAB_CHANNELS;c++)assert(input[f*LAB_CHANNELS+c]==(c<2?(Float32)carrier[f*2+c]:0));
    // A PCM commit restores full width, without losing independent channels.
    change=malloc(sizeof(SinkChange));fill_lpcm_format(&change->format,48000);
    assert(!BlackHole_PerformDeviceConfigurationChange(gAudioServerPlugInDriverRef,kObjectID_Device,ChangeAction_SetOutputFormat,change));
    Float32 output[frames*LAB_CHANNELS];
    for(UInt32 f=0;f<frames;f++)for(UInt32 c=0;c<LAB_CHANNELS;c++)output[f*LAB_CHANNELS+c]=(Float32)(c+1)/32;
    cycle.mOutputTime.mSampleTime=2000;cycle.mInputTime.mSampleTime=2000;
    assert(!BlackHole_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Output,0,kAudioServerPlugInIOOperationWriteMix,frames,&cycle,output,NULL));
    assert(!BlackHole_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device2,kObjectID_Stream_Input,0,kAudioServerPlugInIOOperationReadInput,frames,&cycle,input,NULL));
    assert(!memcmp(output,input,sizeof(output)));
    free(gRingBuffer);
    printf("PASS %d-channel formats, HAL format commits, encoded word preservation and independent PCM channels\n",LAB_CHANNELS);
}
