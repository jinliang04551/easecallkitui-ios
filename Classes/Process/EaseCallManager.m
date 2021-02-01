//
//  EaseCallManager.m
//  EMiOSDemo
//
//  Created by lixiaoming on 2020/11/18.
//  Copyright © 2020 lixiaoming. All rights reserved.
//

#import "EaseCallManager.h"
#import "EaseCallSingleViewController.h"
#import "EaseCallMultiViewController.h"
#import "EaseCallManager+Private.h"
#import "EaseCallHttpRequest.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Masonry/Masonry.h>
#import "EaseCallModal.h"

static NSString* kAction = @"action";
static NSString* kChannelName = @"channelName";
static NSString* kCallType = @"type";
static NSString* kCallerDevId = @"callerDevId";
static NSString* kCallId = @"callId";
static NSString* kTs = @"ts";
static NSString* kMsgType = @"msgType";
static NSString* kCalleeDevId = @"calleeDevId";
static NSString* kCallStatus = @"status";
static NSString* kCallResult = @"result";
static NSString* kInviteAction = @"invite";
static NSString* kAlertAction = @"alert";
static NSString* kConfirmRingAction = @"confirmRing";
static NSString* kCancelCallAction = @"cancelCall";
static NSString* kAnswerCallAction = @"answerCall";
static NSString* kConfirmCalleeAction = @"confirmCallee";
static NSString* kVideoToVoice = @"videoToVoice";
static NSString* kBusyResult = @"busy";
static NSString* kAcceptResult = @"accept";
static NSString* kRefuseresult = @"refuse";
static NSString* kMsgTypeValue = @"rtcCallWithAgora";
static NSString* kAppId = @"15cb0d28b87b425ea613fc46f7c9f974";

@interface EaseCallManager ()<EMChatManagerDelegate,AgoraRtcEngineDelegate,EaseCallModalDelegate>
@property (nonatomic) EaseCallConfig* config;
@property (nonatomic,weak) id<EaseCallDelegate> delegate;
@property (nonatomic) dispatch_queue_t workQueue;
@property (nonatomic,strong) AVAudioPlayer* audioPlayer;
@property (nonatomic) EaseCallModal* modal;
// 定义 agoraKit 变量
@property (strong, nonatomic) AgoraRtcEngineKit *agoraKit;
// 呼叫方Timer
@property (nonatomic) NSMutableDictionary* callTimerDic;
// 接听方Timer
@property (nonatomic) NSMutableDictionary* alertTimerDic;
@property (nonatomic,weak) NSTimer* confirmTimer;
@property (nonatomic,weak) NSTimer* ringTimer;
@property (nonatomic) EaseCallBaseViewController*callVC;
@property (nonatomic) BOOL bNeedSwitchToVoice;
@end

@implementation EaseCallManager
static EaseCallManager *easeCallManager = nil;

+ (instancetype)sharedManager
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        easeCallManager = [[EaseCallManager alloc] init];
        easeCallManager.delegate = nil;
        [[EMClient sharedClient].chatManager addDelegate:easeCallManager delegateQueue:nil];
        easeCallManager.agoraKit = [AgoraRtcEngineKit sharedEngineWithAppId:kAppId delegate:easeCallManager];
        easeCallManager.modal = [[EaseCallModal alloc] initWithDelegate:easeCallManager];
    });
    return easeCallManager;
}

- (void)initWithConfig:(EaseCallConfig*)aConfig delegate:(id<EaseCallDelegate>)aDelegate
{
    self.delegate= aDelegate;
    _workQueue = dispatch_queue_create("EaseCallManager.WorkQ", DISPATCH_QUEUE_SERIAL);
    if(aConfig) {
        self.config = aConfig;
    }else{
        self.config = [[EaseCallConfig alloc] init];
    }
    self.modal.curUserAccount = [[EMClient sharedClient] currentUsername];
}

- (EaseCallConfig*)getEaseCallConfig
{
    return self.config;
}

- (NSMutableDictionary*)callTimerDic
{
    if(!_callTimerDic)
        _callTimerDic = [NSMutableDictionary dictionary];
    return _callTimerDic;
}

- (NSMutableDictionary*)alertTimerDic
{
    if(!_alertTimerDic)
        _alertTimerDic = [NSMutableDictionary dictionary];
    return _alertTimerDic;
}

- (void)startInviteUsers:(NSArray<NSString*>*)aUsers  completion:(void (^)(NSString* callId,EaseCallError*))aCompletionBlock{
    if([aUsers count] == 0){
        NSLog(@"InviteUsers faild!!remoteUid is empty");
        if(aCompletionBlock)
        {
            EaseCallError* error = [EaseCallError errorWithType:EaseCallErrorTypeProcess code:EaseCallProcessErrorCodeInvalidParams description:@"Require remoteUid"];
            aCompletionBlock(nil,error);
        }else{
            [self callBackError:EaseCallErrorTypeProcess code:EaseCallProcessErrorCodeInvalidParams description:@"Require remoteUid"];
        }
        return;
    }
    __weak typeof(self) weakself = self;
    dispatch_async(weakself.workQueue, ^{
        if(weakself.modal.currentCall && weakself.callVC) {
            NSLog(@"inviteUsers in group");
            for(NSString* uId in aUsers) {
                if([weakself.modal.currentCall.remoteUserAccounts containsObject:uId])
                    continue;
                [weakself sendInviteMsgToCallee:uId type:weakself.modal.currentCall.callType callId:weakself.modal.currentCall.callId channelName:weakself.modal.currentCall.channelName];
                [weakself _startCallTimer:uId];
            }
            if(aCompletionBlock)
                aCompletionBlock(weakself.modal.currentCall.callId,nil);
        }else{
            weakself.modal.currentCall = [[ECCall alloc] init];
            weakself.modal.currentCall.channelName = [[NSUUID UUID] UUIDString];
            weakself.modal.currentCall.callType = EaseCallTypeMulti;
            weakself.modal.currentCall.callId = [[NSUUID UUID] UUIDString];
            weakself.modal.state = EaseCallState_Answering;
            weakself.modal.currentCall.isCaller = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                for(NSString* uId in aUsers) {
                    [weakself sendInviteMsgToCallee:uId type:weakself.modal.currentCall.callType callId:weakself.modal.currentCall.callId channelName:weakself.modal.currentCall.channelName];
                    [weakself _startCallTimer:uId];
                }
                if(aCompletionBlock)
                    aCompletionBlock(weakself.modal.currentCall.callId,nil);
            });
        }
    });
}

- (void)startSingleCallWithUId:(NSString*)uId type:(EaseCallType)aType completion:(void (^)(NSString* callId,EaseCallError*))aCompletionBlock {
    if([uId length] == 0) {
        NSLog(@"makeCall faild!!remoteUid is empty");
        if(aCompletionBlock)
        {
            EaseCallError* error = [EaseCallError errorWithType:EaseCallErrorTypeProcess code:EaseCallProcessErrorCodeInvalidParams description:@"Require remoteUid"];
            aCompletionBlock(nil,error);
        }else{
            [self callBackError:EaseCallErrorTypeProcess code:EaseCallProcessErrorCodeInvalidParams description:@"Require remoteUid"];
        }
        return;
    }
    __weak typeof(self) weakself = self;
    dispatch_async(weakself.workQueue, ^{
        EaseCallError * error = nil;
        if([self isBusy]) {
            NSLog(@"makeCall faild!!current is busy");
            if(aCompletionBlock) {
                error = [EaseCallError errorWithType:EaseCallErrorTypeProcess code:EaseCallProcessErrorCodeBusy description:@"current is busy"];
                aCompletionBlock(nil,error);
            }else{
                [self callBackError:EaseCallErrorTypeProcess code:EaseCallProcessErrorCodeBusy description:@"current is busy"];
            }
        }else{
            weakself.modal.currentCall = [[ECCall alloc] init];
            weakself.modal.currentCall.channelName = [[NSUUID UUID] UUIDString];
            weakself.modal.currentCall.remoteUserAccount = uId;
            weakself.modal.currentCall.callType = (EaseCallType)aType;
            weakself.modal.currentCall.callId = [[NSUUID UUID] UUIDString];
            weakself.modal.currentCall.isCaller = YES;
            weakself.modal.state = EaseCallState_Outgoing;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakself sendInviteMsgToCallee:uId type:weakself.modal.currentCall.callType callId:weakself.modal.currentCall.callId channelName:weakself.modal.currentCall.channelName];
                [weakself _startCallTimer:uId];
                if(aCompletionBlock)
                    aCompletionBlock(weakself.modal.currentCall.callId,error);
            });
        }
    });
}

// 是否处于忙碌状态
- (BOOL)isBusy
{
    if(self.modal.currentCall && self.modal.state != EaseCallState_Idle)
        return YES;
    return NO;
}

- (void)clearRes
{
    NSLog(@"cleraRes");
    if(self.modal.currentCall)
    {
        if(self.modal.currentCall.callType != EaseCallType1v1Audio)
        {
            [self.agoraKit stopPreview];
            [self.agoraKit disableVideo];
        }
        [self.agoraKit leaveChannel:^(AgoraChannelStats * _Nonnull stat) {
                NSLog(@"leaveChannel,stat:%@",stat);
                }];
    }
    if(self.callVC) {
        [self.callVC dismissViewControllerAnimated:NO completion:^{
            self.callVC = nil;
        }];
    }
    NSLog(@"invite timer count:%ld",self.callTimerDic.count);
    NSArray* timers = [self.callTimerDic allValues];
    for (NSTimer* tm in timers) {
        if(tm) {
            [tm invalidate];
        }
    }
    [self.callTimerDic removeAllObjects];
    NSArray* alertTimers = [self.alertTimerDic allValues];
    for (NSTimer* tm in alertTimers) {
        if(tm) {
            [tm invalidate];
        }
    }
    if(self.confirmTimer) {
        [self.confirmTimer invalidate];
        self.confirmTimer = nil;
    }
    if(self.ringTimer) {
        [self.ringTimer invalidate];
        self.ringTimer = nil;
    }
    self.modal.currentCall = nil;
    [self.modal.recvCalls removeAllObjects];
    self.bNeedSwitchToVoice = NO;
}

- (void)refreshUIOutgoing
{
    if(self.modal.currentCall) {
        
        if(!self.callVC)
            self.callVC = [[EaseCallSingleViewController alloc] initWithisCaller:self.modal.currentCall.isCaller type:self.modal.currentCall.callType remoteName:self.modal.currentCall.remoteUserAccount];
        self.callVC.modalPresentationStyle = UIModalPresentationFullScreen;
        __weak typeof(self) weakself = self;
        UIViewController* rootVC = [[UIApplication sharedApplication].delegate window].rootViewController;
        [rootVC presentViewController:self.callVC animated:NO completion:^{
            if(weakself.modal.currentCall.callType == EaseCallType1v1Video)
                [weakself setupLocalVideo];
            [weakself joinChannel];
        }];
    }
}

- (void)refreshUIAnswering
{
    if(self.modal.currentCall) {
        if(self.modal.currentCall.callType == EaseCallTypeMulti && self.modal.currentCall.isCaller) {
            self.callVC = [[EaseCallMultiViewController alloc] init];
            self.callVC.modalPresentationStyle = UIModalPresentationFullScreen;
            UIViewController* rootVC = [[UIApplication sharedApplication].delegate window].rootViewController;
            __weak typeof(self) weakself = self;
            [rootVC presentViewController:self.callVC animated:NO completion:^{
                [weakself setupLocalVideo];
                [weakself joinChannel];
            }];
        }
        [self _stopRingTimer];
        [self stopSound];
    }
}

- (void)refreshUIAlerting
{
    if(self.modal.currentCall) {
        if(self.delegate && [self.delegate respondsToSelector:@selector(callDidReceive:inviter:)]) {
            [self.delegate callDidReceive:self.modal.currentCall.callType inviter:self.modal.currentCall.remoteUserAccount];
        }
        [self playSound];
        if(self.modal.currentCall.callType == EaseCallTypeMulti) {
            self.callVC = [[EaseCallMultiViewController alloc] init];
            [self getMultiVC].inviterId = self.modal.currentCall.remoteUserAccount;
            self.callVC.modalPresentationStyle = UIModalPresentationFullScreen;
            UIViewController* rootVC = [[UIApplication sharedApplication].delegate window].rootViewController;
            if(rootVC.presentationController && rootVC.presentationController.presentedViewController)
                [rootVC.presentationController.presentedViewController dismissViewControllerAnimated:NO completion:nil];
                
            [rootVC presentViewController:self.callVC animated:NO completion:^{
                
            }];
        }else{
            self.callVC = [[EaseCallSingleViewController alloc] initWithisCaller:NO type:self.modal.currentCall.callType remoteName:self.modal.currentCall.remoteUserAccount];
            self.callVC.modalPresentationStyle = UIModalPresentationFullScreen;
            UIViewController* rootVC = [[UIApplication sharedApplication].delegate window].rootViewController;
            if(rootVC.presentationController && rootVC.presentationController.presentedViewController)
                [rootVC.presentationController.presentedViewController dismissViewControllerAnimated:NO completion:nil];
            [rootVC presentViewController:self.callVC animated:NO completion:^{
                
            }];
        }
        [self _startRingTimer:self.modal.currentCall.callId];
    }
}

- (void)setupVideo {
    [self.agoraKit enableVideo];
    // Default mode is disableVideo
    
    // Set up the configuration such as dimension, frame rate, bit rate and orientation
    AgoraVideoEncoderConfiguration *encoderConfiguration =
    [[AgoraVideoEncoderConfiguration alloc] initWithSize:AgoraVideoDimension640x360
                                               frameRate:AgoraVideoFrameRateFps15
                                                 bitrate:AgoraVideoBitrateStandard
                                         orientationMode:AgoraVideoOutputOrientationModeAdaptative];
    [self.agoraKit setVideoEncoderConfiguration:encoderConfiguration];
}

- (EaseCallSingleViewController*)getSingleVC
{
    return (EaseCallSingleViewController*)self.callVC;
}

- (EaseCallMultiViewController*)getMultiVC
{
    return (EaseCallMultiViewController*)self.callVC;
}

#pragma mark - EaseCallModalDelegate
- (void)callStateWillChangeTo:(EaseCallState)newState from:(EaseCallState)preState
{
    NSLog(@"callState will chageto:%ld from:%ld",newState,preState);
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (newState) {
            case EaseCallState_Idle:
                [weakself clearRes];
                break;
            case EaseCallState_Outgoing:
                [weakself refreshUIOutgoing];
                break;
            case EaseCallState_Alerting:
                [weakself refreshUIAlerting];
                break;
            case EaseCallState_Answering:
                [weakself refreshUIAnswering];
                break;
            default:
                break;
        }
    });
    
}

#pragma mark - EMChatManagerDelegate
- (void)messagesDidReceive:(NSArray *)aMessages
{
    __weak typeof(self) weakself = self;
    dispatch_async(weakself.workQueue, ^{
        for (EMMessage *msg in aMessages) {
            [weakself _parseMsg:msg];
        }
    });
}

- (void)cmdMessagesDidReceive:(NSArray *)aCmdMessages
{
    __weak typeof(self) weakself = self;
    dispatch_async(weakself.workQueue, ^{
        for (EMMessage *msg in aCmdMessages) {
            [weakself _parseMsg:msg];
        }
    });
}

#pragma mark - sendMessage

//发送呼叫邀请消息
- (void)sendInviteMsgToCallee:(NSString*)aUid type:(EaseCallType)aType callId:(NSString*)aCallId channelName:(NSString*)aChannelName
{
    if([aUid length] == 0 || [aCallId length] == 0 || [aChannelName length] == 0)
        return;
    NSString* strType = @"语音";
    if(aType == EaseCallTypeMulti)
        strType = @"多人视频";
    if(aType == EaseCallType1v1Video)
        strType = @"视频";
    EMTextMessageBody* msgBody = [[EMTextMessageBody alloc] initWithText:[NSString stringWithFormat: @"邀请您进行%@通话",strType]];
    NSDictionary* ext = @{kMsgType:kMsgTypeValue,kAction:kInviteAction,kCallId:aCallId,kCallType:[NSNumber numberWithInt:(int)aType],kCallerDevId:self.modal.curDevId,kChannelName:aChannelName,kTs:[self getTs]};
    EMMessage* msg = [[EMMessage alloc] initWithConversationID:aUid from:self.modal.curUserAccount to:aUid body:msgBody ext:ext];
    __weak typeof(self) weakself = self;
    [[[EMClient sharedClient] chatManager] sendMessage:msg progress:nil completion:^(EMMessage *message, EMError *error) {
        if(error) {
            [weakself callBackError:EaseCallErrorTypeIM code:error.code description:error.errorDescription];
        }
    }];
}

// 发送alert消息
- (void)sendAlertMsgToCaller:(NSString*)aCallerUid callId:(NSString*)aCallId devId:(NSString*)aDevId
{
    if([aCallerUid length] == 0 || [aCallId length] == 0 || [aDevId length] == 0)
        return;
    EMCmdMessageBody* msgBody = [[EMCmdMessageBody alloc] initWithAction:@"rtcCall"];
    msgBody.isDeliverOnlineOnly = YES;
    NSDictionary* ext = @{kMsgType:kMsgTypeValue,kAction:kAlertAction,kCallId:aCallId,kCalleeDevId:self.modal.curDevId,kCallerDevId:aDevId,kTs:[self getTs]};
    EMMessage* msg = [[EMMessage alloc] initWithConversationID:aCallerUid from:self.modal.curUserAccount to:aCallerUid body:msgBody ext:ext];
    __weak typeof(self) weakself = self;
    [[[EMClient sharedClient] chatManager] sendMessage:msg progress:nil completion:^(EMMessage *message, EMError *error) {
        if(error) {
            [weakself callBackError:EaseCallErrorTypeIM code:error.code description:error.errorDescription];
        }
    }];
}

// 发送消息有效确认消息
- (void)sendComfirmRingMsgToCallee:(NSString*)aUid callId:(NSString*)aCallId isValid:(BOOL)aIsCallValid calleeDevId:(NSString*)aCalleeDevId
{
    if([aUid length] == 0 || [aCallId length] == 0 )
        return;
    EMCmdMessageBody* msgBody = [[EMCmdMessageBody alloc] initWithAction:@"rtcCall"];
    msgBody.isDeliverOnlineOnly = YES;
    NSDictionary* ext = @{kMsgType:kMsgTypeValue,kAction:kConfirmRingAction,kCallId:aCallId,kCallerDevId:self.modal.curDevId,kCallStatus:[NSNumber numberWithBool:aIsCallValid],kTs:[self getTs],kCalleeDevId:aCalleeDevId};
    EMMessage* msg = [[EMMessage alloc] initWithConversationID:aUid from:self.modal.curUserAccount to:aUid body:msgBody ext:ext];
    __weak typeof(self) weakself = self;
    [[[EMClient sharedClient] chatManager] sendMessage:msg progress:nil completion:^(EMMessage *message, EMError *error) {
        if(error) {
            [weakself callBackError:EaseCallErrorTypeIM code:error.code description:error.errorDescription];
        }
    }];
}

// 发送取消呼叫消息
- (void)sendCancelCallMsgToCallee:(NSString*)aUid callId:(NSString*)aCallId
{
    if([aUid length] == 0 || [aCallId length] == 0 )
        return;
    EMCmdMessageBody* msgBody = [[EMCmdMessageBody alloc] initWithAction:@"rtcCall"];
    NSDictionary* ext = @{kMsgType:kMsgTypeValue,kAction:kCancelCallAction,kCallId:aCallId,kCallerDevId:self.modal.curDevId,kTs:[self getTs]};
    EMMessage* msg = [[EMMessage alloc] initWithConversationID:aUid from:self.modal.curUserAccount to:aUid body:msgBody ext:ext];
    __weak typeof(self) weakself = self;
    [[[EMClient sharedClient] chatManager] sendMessage:msg progress:nil completion:^(EMMessage *message, EMError *error) {
        if(error) {
            [weakself callBackError:EaseCallErrorTypeIM code:error.code description:error.errorDescription];
        }
    }];
}

// 发送Answer消息
- (void)sendAnswerMsg:(NSString*)aCallerUid callId:(NSString*)aCallId result:(NSString*)aResult devId:(NSString*)aDevId
{
    if([aCallerUid length] == 0 || [aCallId length] == 0 || [aResult length] == 0 || [aDevId length] == 0)
        return;
    EMCmdMessageBody* msgBody = [[EMCmdMessageBody alloc] initWithAction:@"rtcCall"];
    msgBody.isDeliverOnlineOnly = YES;
    NSMutableDictionary* ext = [@{kMsgType:kMsgTypeValue,kAction:kAnswerCallAction,kCallId:aCallId,kCalleeDevId:self.modal.curDevId,kCallerDevId:aDevId,kCallResult:aResult,kTs:[self getTs]} mutableCopy];
    if(self.modal.currentCall.callType == EaseCallType1v1Audio && self.bNeedSwitchToVoice)
        [ext setObject:[NSNumber numberWithBool:YES] forKey:kVideoToVoice];
    EMMessage* msg = [[EMMessage alloc] initWithConversationID:aCallerUid from:self.modal.curUserAccount to:aCallerUid body:msgBody ext:ext];
    __weak typeof(self) weakself = self;
    [[[EMClient sharedClient] chatManager] sendMessage:msg progress:nil completion:^(EMMessage *message, EMError *error) {
        if(error) {
            [weakself callBackError:EaseCallErrorTypeIM code:error.code description:error.errorDescription];
        }
    }];
    [self _startConfirmTimer:aCallId];
}

// 发送仲裁消息
- (void)sendConfirmAnswerMsgToCallee:(NSString*)aUid callId:(NSString*)aCallId result:(NSString*)aResult devId:(NSString*)aDevId
{
    if([aUid length] == 0 || [aCallId length] == 0 || [aResult length] == 0 || [aDevId length] == 0)
        return;
    EMCmdMessageBody* msgBody = [[EMCmdMessageBody alloc] initWithAction:@"rtcCall"];
    msgBody.isDeliverOnlineOnly = YES;
    NSDictionary* ext = @{kMsgType:kMsgTypeValue,kAction:kConfirmCalleeAction,kCallId:aCallId,kCallerDevId:self.modal.curDevId,kCalleeDevId:aDevId,kCallResult:aResult,kTs:[self getTs]};
    EMMessage* msg = [[EMMessage alloc] initWithConversationID:aUid from:self.modal.curUserAccount to:aUid body:msgBody ext:ext];
    __weak typeof(self) weakself = self;
    [[[EMClient sharedClient] chatManager] sendMessage:msg progress:nil completion:^(EMMessage *message, EMError *error) {
        if(error) {
            [weakself callBackError:EaseCallErrorTypeIM code:error.code description:error.errorDescription];
        }
    }];
    if([aResult isEqualToString:kAcceptResult]) {
        self.modal.state = EaseCallState_Answering;
    }
}

// 发送视频转音频消息
- (void)sendVideoToVoiceMsg:(NSString*)aUid callId:(NSString*)aCallId
{
    if([aUid length] == 0 || [aCallId length] == 0)
        return;
    EMCmdMessageBody* msgBody = [[EMCmdMessageBody alloc] initWithAction:@"rtcCall"];
    NSDictionary* ext = @{kMsgType:kMsgTypeValue,kAction:kVideoToVoice,kCallId:aCallId,kTs:[self getTs]};
    EMMessage* msg = [[EMMessage alloc] initWithConversationID:aUid from:self.modal.curUserAccount to:aUid body:msgBody ext:ext];
    __weak typeof(self) weakself = self;
    [[[EMClient sharedClient] chatManager] sendMessage:msg progress:nil completion:^(EMMessage *message, EMError *error) {
        if(error) {
            [weakself callBackError:EaseCallErrorTypeIM code:error.code description:error.errorDescription];
        }
    }];
}

- (NSNumber*)getTs
{
    return [NSNumber numberWithLongLong:([[NSDate date] timeIntervalSince1970] * 1000)];
}

#pragma mark - 解析消息信令

- (void)_parseMsg:(EMMessage*)aMsg
{
    if(![aMsg.to isEqualToString:[EMClient sharedClient].currentUsername])
        return;
    NSDictionary* ext = aMsg.ext;
    NSString* from = aMsg.from;
    NSString* msgType = [ext objectForKey:kMsgType];
    if([msgType length] == 0)
        return;
    NSString* callId = [ext objectForKey:kCallId];
    NSString* result = [ext objectForKey:kCallResult];
    NSString* callerDevId = [ext objectForKey:kCallerDevId];
    NSString* calleeDevId = [ext objectForKey:kCalleeDevId];
    NSString* channelname = [ext objectForKey:kChannelName];
    NSNumber* isValid = [ext objectForKey:kCallStatus];
    NSNumber* callType = [ext objectForKey:kCallType];
    NSNumber* isVideoToVoice = [ext objectForKey:kVideoToVoice];
    __weak typeof(self) weakself = self;
    
    void (^parseInviteMsgExt)(NSDictionary*) = ^void (NSDictionary* ext) {
        NSLog(@"parseInviteMsgExt");
        if(weakself.modal.currentCall && [weakself.modal.currentCall.callId isEqualToString:callId])
        {
            return;
        }
        if([weakself.alertTimerDic objectForKey:callId])
            return;
        if([weakself isBusy])
            [weakself sendAnswerMsg:from callId:callId result:kBusyResult devId:callerDevId];
        else
        {
            ECCall* call = [[ECCall alloc] init];
            call.callId = callId;
            call.isCaller = NO;
            call.callType = (EaseCallType)[callType intValue];
            call.remoteCallDevId = callerDevId;
            call.channelName = channelname;
            call.remoteUserAccount = from;
            [weakself.modal.recvCalls setObject:call forKey:callId];
            [weakself sendAlertMsgToCaller:call.remoteUserAccount callId:callId devId:call.remoteCallDevId];
            [weakself _startAlertTimer:callId];
        }
    };
    void (^parseAlertMsgExt)(NSDictionary*) = ^void (NSDictionary* ext) {
        NSLog(@"parseAlertMsgExt currentCallId:%@,state:%ld",weakself.modal.currentCall.callId,weakself.modal.state);
        // 判断devId
        if([weakself.modal.curDevId isEqualToString:callerDevId]) {
            // 判断有效
            if(weakself.modal.currentCall && [weakself.modal.currentCall.callId isEqualToString:callId] && [weakself.callTimerDic objectForKey:from]) {
                [weakself sendComfirmRingMsgToCallee:from callId:callId isValid:YES calleeDevId:calleeDevId];
            }else{
                [weakself sendComfirmRingMsgToCallee:from callId:callId isValid:NO calleeDevId:calleeDevId];
            }
        }
    };
    void (^parseCancelCallMsgExt)(NSDictionary*) = ^void (NSDictionary* ext) {
        NSLog(@"parseCancelCallMsgExt currentCallId:%@,state:%ld",weakself.modal.currentCall.callId,weakself.modal.state);
        if(weakself.modal.currentCall && [weakself.modal.currentCall.callId isEqualToString:callId]) {
            [weakself _stopConfirmTimer:callId];
            [weakself _stopAlertTimer:callId];
            [weakself callBackCallEnd:EaseCallEndReasonRemoteCancel];
            weakself.modal.state = EaseCallState_Idle;
            [weakself stopSound];
        }else{
            [weakself.modal.recvCalls removeObjectForKey:callId];
            [weakself _stopAlertTimer:callId];
        }
    };
    void (^parseAnswerMsgExt)(NSDictionary*) = ^void (NSDictionary* ext) {
        NSLog(@"parseAnswerMsgExt currentCallId:%@,state:%ld",weakself.modal.currentCall.callId,weakself.modal.state);
        if(weakself.modal.currentCall && [weakself.modal.currentCall.callId isEqualToString:callId] && [weakself.modal.curDevId isEqualToString:callerDevId]) {
            if(weakself.modal.currentCall.callType == EaseCallTypeMulti) {
                NSTimer* timer = [self.callTimerDic objectForKey:from];
                if(timer) {
                    [self sendConfirmAnswerMsgToCallee:from callId:callId result:result devId:calleeDevId];
                    [timer invalidate];
                    timer = nil;
                    [self.callTimerDic removeObjectForKey:from];
                }
            }else{
                if(weakself.modal.state == EaseCallState_Outgoing) {
                    if([result isEqualToString:kAcceptResult]) {
                        
                            if(isVideoToVoice && isVideoToVoice.boolValue) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                [weakself switchToVoice];
                                });
                            }
                            weakself.modal.state = EaseCallState_Answering;
                    }else
                    {
                        if([result isEqualToString:kRefuseresult])
                            [weakself callBackCallEnd:EaseCallEndReasonRefuse];
                        if([result isEqualToString:kBusyResult]){
                            [weakself callBackCallEnd:EaseCallEndReasonBusy];
                        }
                        weakself.modal.state = EaseCallState_Idle;
                    }
                    [weakself sendConfirmAnswerMsgToCallee:from callId:callId result:result devId:calleeDevId];
                }
            }
        }
    };
    void (^parseConfirmRingMsgExt)(NSDictionary*) = ^void (NSDictionary* ext) {
        NSLog(@"parseConfirmRingMsgExt currentCallId:%@,state:%ld",weakself.modal.currentCall.callId,weakself.modal.state);
        if([weakself.alertTimerDic objectForKey:callId] && [calleeDevId isEqualToString:weakself.modal.curDevId]) {
            [weakself _stopAlertTimer:callId];
            if([weakself isBusy])
            {
                [weakself sendAnswerMsg:from callId:callId result:kBusyResult devId:callerDevId];
                return;
            }
            ECCall* call = [weakself.modal.recvCalls objectForKey:callId];
            if(call) {
                if([isValid boolValue])
                {
                    weakself.modal.currentCall = call;
                    [weakself.modal.recvCalls removeAllObjects];
                    [weakself _stopAllAlertTimer];
                    weakself.modal.state = EaseCallState_Alerting;
                }
                [weakself.modal.recvCalls removeObjectForKey:callId];
            }
            
        }
    };
    void (^parseConfirmCalleeMsgExt)(NSDictionary*) = ^void (NSDictionary* ext) {
        NSLog(@"parseConfirmCalleeMsgExt currentCallId:%@,state:%ld",weakself.modal.currentCall.callId,weakself.modal.state);
        if (weakself.modal.state == EaseCallState_Alerting && [weakself.modal.currentCall.callId isEqualToString:callId]) {
            [weakself _stopConfirmTimer:callId];
            if([weakself.modal.curDevId isEqualToString:calleeDevId])
            {
                // 仲裁为自己
                if([result isEqualToString:kAcceptResult]) {
                    weakself.modal.state = EaseCallState_Answering;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        
                        if(weakself.modal.currentCall.callType != EaseCallType1v1Audio)
                            [weakself setupLocalVideo];
                        [weakself joinChannel];
                    });
                }
            }else{
                // 已在其他端处理
                [weakself callBackCallEnd:EaseCallEndReasonHandleOnOtherDevice];
                weakself.modal.state = EaseCallState_Idle;
                [weakself stopSound];
            }
        }
    };
    void (^parseVideoToVoiceMsg)(NSDictionary*) = ^void (NSDictionary* ext){
        if(weakself.modal.currentCall && [weakself.modal.currentCall.callId isEqualToString:callId]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakself switchToVoice];
            });
            
        }
    };
    if([msgType isEqualToString:kMsgTypeValue]) {
        NSString* action = [ext objectForKey:kAction];
        if([action isEqualToString:kInviteAction]) {
            parseInviteMsgExt(ext);
        }
        if([action isEqualToString:kAlertAction]) {
            parseAlertMsgExt(ext);
        }
        if([action isEqualToString:kConfirmRingAction]) {
            parseConfirmRingMsgExt(ext);
        }
        if([action isEqualToString:kCancelCallAction]) {
            parseCancelCallMsgExt(ext);
        }
        if([action isEqualToString:kConfirmCalleeAction]) {
            parseConfirmCalleeMsgExt(ext);
        }
        if([action isEqualToString:kAnswerCallAction]) {
            parseAnswerMsgExt(ext);
        }
        if([action isEqualToString:kVideoToVoice]) {
            parseVideoToVoiceMsg(ext);
        }
    }
}

#pragma mark - Timer Manager
- (void)_startCallTimer:(NSString*)aRemoteUser
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if([weakself.callTimerDic objectForKey:aRemoteUser])
            return;
        NSLog(@"_startCallTimer,user:%@",aRemoteUser);
        NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:self.config.callTimeOut target:weakself selector:@selector(_timeoutCall:) userInfo:aRemoteUser repeats:NO];
        if(!timer)
            NSLog(@"create callout Timer failed");
        [weakself.callTimerDic setObject:timer forKey:aRemoteUser];
    });
}

- (void)_stopCallTimer:(NSString*)aRemoteUser
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"stopCallTimer:%@",aRemoteUser);
        NSTimer* tm = [weakself.callTimerDic objectForKey:aRemoteUser];
        if(tm) {
            [tm invalidate];
            tm = nil;
            [weakself.callTimerDic removeObjectForKey:aRemoteUser];
        }
    });
}

- (void)_timeoutCall:(NSTimer*)timer
{
    NSString* aRemoteUser = (NSString*)[timer userInfo];
    NSLog(@"_timeoutCall,user:%@",aRemoteUser);
    [self.callTimerDic removeObjectForKey:aRemoteUser];
    [self sendCancelCallMsgToCallee:aRemoteUser callId:self.modal.currentCall.callId];
    if(self.modal.currentCall.callType != EaseCallTypeMulti) {
        [self callBackCallEnd:EaseCallEndReasonRemoteNoResponse];
        self.modal.state = EaseCallState_Idle;
        
    }
}

- (void)_startAlertTimer:(NSString*)callId
{
    NSLog(@"_startAlertTimer,callId:%@",callId);
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer* tm = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(_timeoutAlert:) userInfo:callId repeats:NO];
        [weakself.alertTimerDic setObject:tm forKey:callId];
    });
}

- (void)_stopAlertTimer:(NSString*)callId
{
    NSLog(@"_stopAlertTimer,callId:%@",callId);
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer* tm = [weakself.alertTimerDic objectForKey:callId];
        if(tm) {
            [tm invalidate];
            tm = nil;
            [weakself.alertTimerDic removeObjectForKey:callId];
        }
    });
}

- (void)_stopAllAlertTimer
{
    NSLog(@"_stopAllAlertTimer");
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray*tms = [weakself.alertTimerDic allValues];
        for (NSTimer* tm in tms) {
            if(tm) {
                [tm invalidate];
            }
        }
        [weakself.alertTimerDic removeAllObjects];
    });
}

- (void)_timeoutAlert:(NSTimer*)tm
{
    NSString* callId = (NSString*)[tm userInfo];
    NSLog(@"_timeoutAlert,callId:%@",callId);
    [self.alertTimerDic removeObjectForKey:callId];
}

- (void)_startConfirmTimer:(NSString*)callId
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(weakself.confirmTimer) {
            [weakself.confirmTimer invalidate];
        }
        weakself.confirmTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(_timeoutConfirm:) userInfo:callId repeats:NO];
    });
}

- (void)_stopConfirmTimer:(NSString*)callId
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(weakself.confirmTimer) {
            [weakself.confirmTimer invalidate];
            weakself.confirmTimer = nil;
        }
    });
    
}

- (void)_timeoutConfirm:(NSTimer*)tm
{
    NSString* callId = (NSString*)[tm userInfo];
    NSLog(@"_timeoutConfirm,callId:%@",callId);
    if(self.modal.currentCall && [self.modal.currentCall.callId isEqualToString:callId]) {
        [self callBackCallEnd:EaseCallEndReasonRemoteNoResponse];
        self.modal.state = EaseCallState_Idle;
    }
}

- (void)_startRingTimer:(NSString*)callId
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(weakself.ringTimer) {
            [weakself.ringTimer invalidate];
        }
        weakself.ringTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(_timeoutRing:) userInfo:callId repeats:NO];
    });
}

- (void)_stopRingTimer
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(weakself.ringTimer) {
            [weakself.ringTimer invalidate];
            weakself.ringTimer = nil;
        }
    });
    
}

- (void)_timeoutRing:(NSTimer*)tm
{
    NSString* callId = (NSString*)[tm userInfo];
    NSLog(@"_timeoutConfirm,callId:%@",callId);
    [self stopSound];
    if(self.modal.currentCall && [self.modal.currentCall.callId isEqualToString:callId]) {
        [self callBackCallEnd:EaseCallEndReasonNoResponse];
        self.modal.state = EaseCallState_Idle;
    }
}

#pragma mark - 铃声控制

- (AVAudioPlayer*)audioPlayer
{
    if(!_audioPlayer) {
        _audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:_config.ringFileUrl error:nil];
        _audioPlayer.numberOfLoops = -1;
        [_audioPlayer prepareToPlay];
    }
    return _audioPlayer;
}

// 播放铃声
- (void)playSound
{
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    
    AVAudioSession*session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
    [session setActive:YES error:nil];
    
    [self.audioPlayer play];
}

// 停止播放铃声
- (void)stopSound
{
    if(self.audioPlayer.isPlaying)
        [self.audioPlayer stop];
}

#pragma mark - AgoraRtcEngineKitDelegate
- (void)rtcEngine:(AgoraRtcEngineKit *)engine didOccurError:(AgoraErrorCode)errorCode
{
    NSLog(@"rtcEngine didOccurError:%ld",errorCode);
    if(errorCode == AgoraErrorCodeTokenExpired || errorCode == AgoraErrorCodeInvalidToken) {
        // 重新获取token
        [self fetchToken];
    }else{
        if(errorCode != AgoraErrorCodeNoError) {
            [self callBackError:EaseCallErrorTypeRTC code:errorCode description:@"RTC Error"];
        }
    }
}

// 远程音频质量数据
- (void)rtcEngine:(AgoraRtcEngineKit *)engine remoteAudioStats:(AgoraRtcRemoteAudioStats *)stats
{
    
}

// 加入频道成功
- (void)rtcEngine:(AgoraRtcEngineKit *)engine didJoinChannel:(NSString *)channel withUid:(NSUInteger)uid elapsed:(NSInteger)elapsed
{
    NSLog(@"join channel success!!! channel:%@,uid:%ld",channel,uid);
}

// 注册账户成功
- (void)rtcEngine:(AgoraRtcEngineKit *)engine didRegisteredLocalUser:(NSString *)userAccount withUid:(NSUInteger)uid
{
    
}

//token即将过期
- (void)rtcEngine:(AgoraRtcEngineKit *)engine tokenPrivilegeWillExpire:(NSString *)token
{
    // token即将过期，需要重新获取
}

// token 已过期
- (void)rtcEngineRequestToken:(AgoraRtcEngineKit * _Nonnull)engine
{
    
}

// 对方退出频道
- (void)rtcEngine:(AgoraRtcEngineKit *)engine didOfflineOfUid:(NSUInteger)uid reason:(AgoraUserOfflineReason)reason
{
    {
        if(self.modal.currentCall.callType == EaseCallTypeMulti) {
            [[self getMultiVC] removeRemoteViewForUser:[NSNumber numberWithUnsignedInteger:uid]];
            AgoraUserInfo* usrInfo = [self.modal.currentCall.remoteUsers objectForKey:[NSNumber numberWithUnsignedInteger:uid]];
            if(usrInfo) {
                [self.modal.currentCall.remoteUserAccounts removeObject:usrInfo.userAccount];
            }
        }else{
            [self callBackCallEnd:EaseCallEndReasonHangup];
            self.modal.state = EaseCallState_Idle;
        }
    }
}

// 对方加入频道
- (void)rtcEngine:(AgoraRtcEngineKit * _Nonnull)engine didJoinedOfUid:(NSUInteger)uid elapsed:(NSInteger)elapsed
{
    NSLog(@"didJoinedOfUid:%ld",uid);
    if(self.modal.currentCall.callType == EaseCallTypeMulti) {
        UIView *view = [UIView new];
        [[self getMultiVC] addRemoteView:view member:[NSNumber numberWithUnsignedInteger:uid] enableVideo:YES];
        AgoraUserInfo*userInfo = [self.modal.currentCall.remoteUsers objectForKey:[NSNumber numberWithUnsignedInteger:uid]];
        if(userInfo) {
            if([self.callTimerDic objectForKey:userInfo.userAccount])
                [self _stopCallTimer:userInfo.userAccount];
            [[self getMultiVC] setRemoteViewNickname:[self getNicknameFromUid:userInfo.userAccount] headImage:[self getHeadImageFromUid:userInfo.userAccount] uId:[NSNumber numberWithUnsignedInteger:uid]];
        }
    }else{
        [self getSingleVC].isConnected = YES;
    }
}

// 对方关闭/打开视频
- (void)rtcEngine:(AgoraRtcEngineKit *)engine didVideoMuted:(BOOL)muted byUid:(NSUInteger)uid
{
    if(self.modal.currentCall.callType == EaseCallTypeMulti) {
        [[self getMultiVC] setRemoteEnableVideo:!muted uId:[NSNumber numberWithUnsignedInteger:uid]];
    }
}

// 对方打开/关闭音频
- (void)rtcEngine:(AgoraRtcEngineKit * _Nonnull)engine didAudioMuted:(BOOL)muted byUid:(NSUInteger)uid
{
    if(self.modal.currentCall.callType == EaseCallTypeMulti) {
        [[self getMultiVC] setRemoteMute:muted uid:[NSNumber numberWithUnsignedInteger:uid]];
    }else{
        [[self getSingleVC] setRemoteMute:muted];
    }
}

// 对方发视频流
- (void)rtcEngine:(AgoraRtcEngineKit *)engine firstRemoteVideoDecodedOfUid:(NSUInteger)uid size:(CGSize)size elapsed:(NSInteger)elapsed
{
    [self setupRemoteVideoView:uid];
}

- (void)rtcEngine:(AgoraRtcEngineKit *)engine firstRemoteAudioFrameOfUid:(NSUInteger)uid elapsed:(NSInteger)elapsed
{
    NSLog(@"firstRemoteAudioFrameOfUid:%ld",uid);
}

- (void)rtcEngine:(AgoraRtcEngineKit *)engine remoteVideoStateChangedOfUid:(NSUInteger)uid state:(AgoraVideoRemoteState)state reason:(AgoraVideoRemoteStateReason)reason elapsed:(NSInteger)elapsed
{
    if(reason == AgoraVideoRemoteStateReasonRemoteMuted && self.modal.currentCall.callType == EaseCallType1v1Video) {
        __weak typeof(self) weakself = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakself switchToVoice];
        });
    }
}

// 对方account更新
- (void)rtcEngine:(AgoraRtcEngineKit * _Nonnull)engine didUpdatedUserInfo:(AgoraUserInfo * _Nonnull)userInfo withUid:(NSUInteger)uid;
{
    NSLog(@"didUpdatedUserInfo uid:%ld,account:%@",uid,userInfo.userAccount);
    if(self.modal.currentCall.callType == EaseCallTypeMulti) {
//        if([[self getMultiVC].streamViewsDic objectForKey:[NSNumber numberWithUnsignedInteger:uid]]) {
//            [self _stopCallTimer:userInfo.userAccount];
//        }
        [self.modal.currentCall.remoteUsers setObject:userInfo forKey:[NSNumber numberWithUnsignedInteger:uid]];
        [self.modal.currentCall.remoteUserAccounts addObject:userInfo.userAccount];
        [[self getMultiVC] setRemoteViewNickname:[self getNicknameFromUid:userInfo.userAccount] headImage:[self getHeadImageFromUid:userInfo.userAccount] uId:[NSNumber numberWithUnsignedInteger:uid]];
    }else{
        [self _stopCallTimer:userInfo.userAccount];
        self.modal.currentCall.remoteUserInfo = userInfo;
        self.modal.currentCall.remoteUserAccount = userInfo.userAccount;
    }
}



- (void)callBackCallEnd:(EaseCallEndReason)reason
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(weakself.delegate && [weakself.delegate respondsToSelector:@selector(callDidEnd:reason:time:type:)]) {
            [weakself.delegate callDidEnd:weakself.modal.currentCall.channelName reason:reason time:weakself.callVC.timeLength type:weakself.modal.currentCall.callType];
        }
    });
}

- (void)callBackError:(EaseCallErrorType)aErrorType code:(NSInteger)aCode description:(NSString*)aDescription
{
    __weak typeof(self) weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(weakself.delegate && [weakself.delegate respondsToSelector:@selector(callDidOccurError:)]) {
            EaseCallError* error = [EaseCallError errorWithType:aErrorType code:aCode description:aDescription];
            [weakself.delegate callDidOccurError:error];
        }
    });
}


#pragma mark - 获取token
- (NSString*)fetchToken {
    __weak typeof(self) weakself = self;
    NSDictionary*parameters = @{@"AppId":kAppId,@"account":[EMClient sharedClient].currentUsername,@"channelName":self.modal.currentCall.channelName};
    return [EaseCallHttpRequest requestWithUrl:@"http://120.25.226.186:32812/login?username=123&pwd=123" parameters:parameters token:[EMClient sharedClient].accessUserToken timeOutInterval:30 failCallback:^(NSData * _Nonnull resBody) {
        [weakself callBackError:EaseCallErrorTypeProcess code:EaseCallProcessErrorCodeFetchTokenFail description:[[NSString alloc] initWithData:resBody encoding:NSUTF8StringEncoding]];
    }];
}
@end


@implementation EaseCallManager (Private)

- (void)hangupAction
{
    NSLog(@"hangupAction,curState:%ld",self.modal.state);
    if(self.modal.state == EaseCallState_Answering) {
        // 正常挂断
        if(self.modal.currentCall.callType == EaseCallTypeMulti)
        {
            if(self.callTimerDic.count > 0) {
                NSArray* tmArray = [self.callTimerDic allValues];
                for(NSTimer * tm in tmArray) {
                    if(tm) {
                        [tm fire];
                    }
                 }
                [self.callTimerDic removeAllObjects];
            }
        }
        
        [self callBackCallEnd:EaseCallEndReasonHangup];
        self.modal.state = EaseCallState_Idle;
    }else{
        if(self.modal.state == EaseCallState_Outgoing) {
            // 取消呼叫
            [self _stopCallTimer:self.modal.currentCall.remoteUserAccount];
            [self sendCancelCallMsgToCallee:self.modal.currentCall.remoteUserAccount callId:self.modal.currentCall.callId];
            [self callBackCallEnd:EaseCallEndReasonCancel];
            self.modal.state = EaseCallState_Idle;
        }else if(self.modal.state == EaseCallState_Alerting){
            // 拒绝
            [self stopSound];
            [self sendAnswerMsg:self.modal.currentCall.remoteUserAccount callId:self.modal.currentCall.callId result:kRefuseresult devId:self.modal.currentCall.remoteCallDevId];
            [self callBackCallEnd:EaseCallEndReasonRefuse];
            self.modal.state = EaseCallState_Idle;
        }
    }
}

-(void) acceptAction
{
    [self stopSound];
    [self sendAnswerMsg:self.modal.currentCall.remoteUserAccount callId:self.modal.currentCall.callId result:kAcceptResult devId:self.modal.currentCall.remoteCallDevId];
}
-(void) switchCameraAction
{
    [self.agoraKit switchCamera];
}

-(void) inviteAction
{
    if(self.delegate && [self.delegate respondsToSelector:@selector(multiCallDidInvitingWithCurVC:excludeUsers:)]){
        NSMutableArray* array = self.modal.currentCall.remoteUserAccounts;
        NSArray* invitingMems = [self.callTimerDic allKeys];
        [array addObjectsFromArray:invitingMems];
        [self.delegate multiCallDidInvitingWithCurVC:self.callVC excludeUsers:array];
    }
}

-(void) enableVideo:(BOOL)aEnable
{
    [self.agoraKit muteLocalVideoStream:!aEnable];
}
-(void) muteAudio:(BOOL)aMuted
{
    [self.agoraKit muteLocalAudioStream:aMuted];
}
-(void) speakeOut:(BOOL)aEnable
{
    [self.agoraKit setEnableSpeakerphone:aEnable];
}
-(NSString*) getNicknameFromUid:(NSString*)uId
{
    if([uId length] > 0){
        EaseCallUser*user = [self.config.users objectForKey:uId];
        if(user) {
            return user.nickName;
        }
    }
    return uId;
}
-(NSURL*) getHeadImageFromUid:(NSString *)uId
{
    if([uId length] > 0){
        EaseCallUser*user = [self.config.users objectForKey:uId];
        if(user) {
            return user.headImage;
        }
    }
    return self.config.defaultHeadImage;
}


- (void)setupRemoteVideoView:(NSUInteger)uid
{
    AgoraRtcVideoCanvas* canvas = [[AgoraRtcVideoCanvas alloc] init];
    canvas.uid = uid;
    canvas.renderMode = AgoraVideoRenderModeHidden;
    if(self.modal.currentCall.callType == EaseCallTypeMulti) {
        canvas.view = [[self getMultiVC] getViewByUid:[NSNumber numberWithUnsignedInteger:uid]];
    }else{
        canvas.view = [self getSingleVC].remoteView.displayView;
    }
    [self.agoraKit setupRemoteVideo:canvas];
}

- (void)setupLocalVideo
{
    AgoraCameraCapturerConfiguration* cameraConfig = [[AgoraCameraCapturerConfiguration alloc] init];
    cameraConfig.cameraDirection = AgoraCameraDirectionFront;
    [self.agoraKit setCameraCapturerConfiguration:cameraConfig];
    [self setupVideo];
    AgoraRtcVideoCanvas*canvas = [[AgoraRtcVideoCanvas alloc] init];
    canvas.uid = 0;
    canvas.renderMode = AgoraVideoRenderModeHidden;
    if(self.modal.currentCall.callType == EaseCallTypeMulti) {
        canvas.view = [self getMultiVC].localView.displayView;
    }else{
        canvas.view = [self getSingleVC].localView.displayView;
    }
    [self.agoraKit setupLocalVideo:canvas];
    [self.agoraKit startPreview];
    
}

- (void)joinChannel
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.agoraKit joinChannelByUserAccount:self.modal.curUserAccount token:self.modal.agoraRTCToken channelId:self.modal.currentCall.channelName joinSuccess:^(NSString * _Nonnull channel, NSUInteger uid, NSInteger elapsed){
            NSLog(@"joinChannel Success!! channel:%@",channel);
        }];
        [self speakeOut:YES];
    });
    
}

-(void) switchToVoice
{
    if(self.modal.currentCall && self.modal.currentCall.callType == EaseCallType1v1Video) {
        self.bNeedSwitchToVoice = YES;
        self.modal.currentCall.callType = EaseCallType1v1Audio;
        [[self getSingleVC] updateToVoice];
        [self.agoraKit stopPreview];
        [self.agoraKit disableVideo];
        [self.agoraKit muteLocalVideoStream:YES];
        
    }
    if(self.modal.currentCall.isCaller || self.modal.state == EaseCallState_Answering) {
        [self.agoraKit stopPreview];
        [self.agoraKit disableVideo];
        [self.agoraKit muteLocalVideoStream:YES];
    }
}

- (void)sendVideoToVoiceMsg
{
    [self sendVideoToVoiceMsg:self.modal.currentCall.remoteUserAccount callId:self.modal.currentCall.callId];
}
@end
