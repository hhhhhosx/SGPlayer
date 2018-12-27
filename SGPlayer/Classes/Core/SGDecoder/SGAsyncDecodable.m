//
//  SGAsyncDecodable.m
//  SGPlayer
//
//  Created by Single on 2018/1/19.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGAsyncDecodable.h"
#import "SGObjectQueue.h"
#import "SGMacro.h"
#import "SGLock.h"

@interface SGAsyncDecodable ()

{
    struct {
        BOOL needsFlush;
        SGAsyncDecodableState state;
    } _flags;
}

@property (nonatomic, copy, readonly) Class decodableClass;
@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, strong, readonly) NSCondition *wakeup;
@property (nonatomic, strong, readonly) SGCapacity *capacity;
@property (nonatomic, strong, readonly) NSOperationQueue *operationQueue;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSNumber *, NSValue *> *timeStamps;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSNumber *, id<SGDecodable>> *decodables;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSNumber *, SGObjectQueue *> *packetQueues;

@end

@implementation SGAsyncDecodable

static SGPacket *gFlushPacket = nil;
static SGPacket *gFinishPacket = nil;

- (instancetype)initWithDecodableClass:(Class)decodableClass
{
    if (self = [super init]) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            gFlushPacket = [[SGPacket alloc] init];
            [gFlushPacket lock];
            gFinishPacket = [[SGPacket alloc] init];
            [gFinishPacket lock];
        });
        self->_decodableClass = decodableClass;
        self->_lock = [[NSLock alloc] init];
        self->_wakeup = [[NSCondition alloc] init];
        self->_timeStamps = [[NSMutableDictionary alloc] init];
        self->_decodables = [[NSMutableDictionary alloc] init];
        self->_packetQueues = [[NSMutableDictionary alloc] init];
        self->_operationQueue = [[NSOperationQueue alloc] init];
        self->_operationQueue.maxConcurrentOperationCount = 1;
        self->_operationQueue.qualityOfService = NSQualityOfServiceUserInteractive;
    }
    return self;
}

- (void)dealloc
{
    SGLockCondEXE10(self->_lock, ^BOOL {
        return self->_flags.state != SGAsyncDecodableStateClosed;
    }, ^SGBlock {
        [self setState:SGAsyncDecodableStateClosed];
        for (SGObjectQueue *obj in self->_packetQueues.allValues) {
            [obj destroy];
        }
        [self->_operationQueue cancelAllOperations];
        [self->_operationQueue waitUntilAllOperationsAreFinished];
        return nil;
    });
}

#pragma mark - Setter & Getter

- (SGBlock)setState:(SGAsyncDecodableState)state
{
    if (self->_flags.state == state) {
        return ^{};
    }
    SGAsyncDecodableState previous = self->_flags.state;
    self->_flags.state = state;
    if (previous == SGAsyncDecodableStatePaused ||
        previous == SGAsyncDecodableStateStalled) {
        [self->_wakeup lock];
        [self->_wakeup broadcast];
        [self->_wakeup unlock];
    }
    return ^{
        [self->_delegate decoder:self didChangeState:state];
    };
}

- (SGAsyncDecodableState)state
{
    __block SGAsyncDecodableState ret = SGAsyncDecodableStateNone;
    SGLockEXE00(self->_lock, ^{
        ret = self->_flags.state;
    });
    return ret;
}

- (SGBlock)setCapacityIfNeeded
{
    SGCapacity *capacity = [[SGCapacity alloc] init];
    for (SGObjectQueue *obj in self->_packetQueues.allValues) {
        capacity = [capacity maximum:obj.capacity];
    }
    if ([self->_capacity isEqualToCapacity:capacity]) {
        return ^{};
    }
    self->_capacity = [capacity copy];
    return ^{
        [self->_delegate decoder:self didChangeCapacity:capacity];
    };
}

#pragma mark - Interface

- (BOOL)open
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_flags.state == SGAsyncDecodableStateNone;
    }, ^SGBlock {
        return [self setState:SGAsyncDecodableStateDecoding];
    }, ^BOOL(SGBlock block) {
        block();
        NSOperation *operation = [[NSInvocationOperation alloc] initWithTarget:self selector:@selector(runningThread) object:nil];
        self->_operationQueue = [[NSOperationQueue alloc] init];
        self->_operationQueue.qualityOfService = NSQualityOfServiceUserInteractive;
        [self->_operationQueue addOperation:operation];
        return YES;
    });
}

- (BOOL)close
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_flags.state != SGAsyncDecodableStateClosed;
    }, ^SGBlock {
        return [self setState:SGAsyncDecodableStateClosed];
    }, ^BOOL(SGBlock block) {
        block();
        for (SGObjectQueue *obj in self->_packetQueues.allValues) {
            [obj destroy];
        }
        [self->_operationQueue cancelAllOperations];
        [self->_operationQueue waitUntilAllOperationsAreFinished];
        return YES;
    });
}

- (BOOL)pause
{
    return SGLockCondEXE10(self->_lock, ^BOOL {
        return self->_flags.state == SGAsyncDecodableStateDecoding;
    }, ^SGBlock {
        return [self setState:SGAsyncDecodableStatePaused];
    });
}

- (BOOL)resume
{
    return SGLockCondEXE10(self->_lock, ^BOOL {
        return self->_flags.state == SGAsyncDecodableStatePaused;
    }, ^SGBlock {
        return [self setState:SGAsyncDecodableStateDecoding];
    });
}

- (BOOL)flush
{
    return SGLockCondEXE10(self->_lock, ^BOOL {
        return self->_flags.state != SGAsyncDecodableStateClosed;
    }, ^SGBlock {
        self->_flags.needsFlush = YES;
        for (SGObjectQueue *obj in self->_packetQueues.allValues) {
            [obj flush];
            [obj putObjectSync:gFlushPacket];
        }
        [self->_timeStamps removeAllObjects];
        SGBlock b1 = ^{};
        SGBlock b2 = [self setCapacityIfNeeded];
        if (self->_flags.state == SGAsyncDecodableStateStalled) {
            b1 = [self setState:SGAsyncDecodableStateDecoding];
        }
        return ^{
            b1(); b2();
        };
    });
}

- (BOOL)finish:(NSArray<SGTrack *> *)tracks
{
    return SGLockCondEXE10(self->_lock, ^BOOL {
        return self->_flags.state != SGAsyncDecodableStateClosed;
    }, ^SGBlock {
        for (SGTrack *obj in tracks) {
            [self->_packetQueues[@(obj.index)] putObjectSync:gFinishPacket];
        }
        SGBlock b1 = ^{};
        SGBlock b2 = [self setCapacityIfNeeded];
        if (self->_flags.state == SGAsyncDecodableStateStalled) {
            b1 = [self setState:SGAsyncDecodableStateDecoding];
        }
        return ^{
            b1(); b2();
        };
    });
}

- (BOOL)putPacket:(SGPacket *)packet
{
    return SGLockCondEXE10(self->_lock, ^BOOL {
        return self->_flags.state != SGAsyncDecodableStateClosed;
    }, ^SGBlock {
        SGObjectQueue *queue = [self->_packetQueues objectForKey:@(packet.track.index)];
        if (!queue) {
            queue = [[SGObjectQueue alloc] init];
            [self->_decodables setObject:[[self->_decodableClass alloc] init] forKey:@(packet.track.index)];
            [self->_packetQueues setObject:queue forKey:@(packet.track.index)];
        }
        [queue putObjectSync:packet];
        SGBlock b1 = ^{};
        SGBlock b2 = [self setCapacityIfNeeded];
        if (self->_flags.state == SGAsyncDecodableStateStalled) {
            b1 = [self setState:SGAsyncDecodableStateDecoding];
        }
        return ^{
            b1(); b2();
        };
    });
}

#pragma mark - Thread

- (void)runningThread
{
    while (YES) {
        @autoreleasepool {
            [self->_lock lock];
            if (self->_flags.state == SGAsyncDecodableStateNone ||
                self->_flags.state == SGAsyncDecodableStateClosed) {
                [self->_lock unlock];
                break;
            } else if (self->_flags.state == SGAsyncDecodableStatePaused ||
                       self->_flags.state == SGAsyncDecodableStateStalled) {
                [self->_wakeup lock];
                [self->_lock unlock];
                [self->_wakeup wait];
                [self->_wakeup unlock];
                continue;
            } else if (self->_flags.state == SGAsyncDecodableStateDecoding) {
                NSNumber *index = nil;
                CMTime minimum = kCMTimePositiveInfinity;
                for (NSNumber *key in self->_packetQueues.allKeys) {
                    SGObjectQueue *obj = [self->_packetQueues objectForKey:key];
                    if (obj.capacity.count == 0) {
                        continue;
                    }
                    NSValue *value = [self->_timeStamps objectForKey:key];
                    if (!value) {
                        index = key;
                        break;
                    }
                    CMTime dts = kCMTimeZero;
                    [value getValue:&dts];
                    if (CMTimeCompare(dts, minimum) < 0) {
                        minimum = dts;
                        index = key;
                        continue;
                    }
                }
                if (!index) {
                    self->_flags.state = SGAsyncDecodableStateStalled;
                    [self->_lock unlock];
                    continue;
                }
                SGObjectQueue *queue = [self->_packetQueues objectForKey:index];
                id<SGDecodable> decodable = [self->_decodables objectForKey:index];
                SGPacket *packet = nil;
                [queue getObjectAsync:&packet];
                NSAssert(packet, @"Invalid Packet.");
                if (packet == gFlushPacket) {
                    [self->_lock unlock];
                    [decodable flush];
                    [self->_lock lock];
                    self->_flags.needsFlush = NO;
                } else {
                    NSArray *objs = nil;
                    if (packet == gFinishPacket) {
                        [self->_lock unlock];
                        objs = [decodable finish];
                    } else {
                        CMTime dts = packet.decodeTimeStamp;
                        [self->_timeStamps setObject:[NSValue value:&dts withObjCType:@encode(CMTime)] forKey:index];
                        [self->_lock unlock];
                        objs = [decodable decode:packet];
                    }
                    [self->_lock lock];
                    if (self->_flags.needsFlush) {
                        for (SGFrame *obj in objs) {
                            [obj unlock];
                        }
                    } else {
                        [self->_lock unlock];
                        for (SGFrame *obj in objs) {
                            [self->_delegate decoder:self didOutputFrame:obj];
                            [obj unlock];
                        }
                        [self->_lock lock];
                    }
                }
                SGBlock b1 = [self setCapacityIfNeeded];
                [self->_lock unlock];
                [packet unlock];
                b1();
                continue;
            }
        }
    }
}

@end
