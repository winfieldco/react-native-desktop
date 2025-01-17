/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTUIManager.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "Layout.h"
#import "RCTAccessibilityManager.h"
#import "RCTAnimationType.h"
#import "RCTAssert.h"
#import "RCTBridge.h"
#import "RCTBridge+Private.h"
#import "RCTComponent.h"
#import "RCTComponentData.h"
#import "RCTConvert.h"
#import "RCTDefines.h"
#import "RCTEventDispatcher.h"
#import "RCTLog.h"
#import "RCTModuleData.h"
#import "RCTModuleMethod.h"
#import "RCTProfile.h"
#import "RCTRootView.h"
#import "RCTRootViewInternal.h"
#import "RCTScrollableProtocol.h"
#import "RCTShadowView.h"
#import "RCTUtils.h"
#import "RCTView.h"
#import "RCTViewManager.h"
#import "NSView+React.h"
#import "NSView+NSViewAnimationWithBlocks.h"
#import "UIImageUtils.h"

static void RCTTraverseViewNodes(id<RCTComponent> view, void (^block)(id<RCTComponent>))
{
  if (view.reactTag) {
    block(view);

    for (id<RCTComponent> subview in view.reactSubviews) {
      RCTTraverseViewNodes(subview, block);
    }
  }
}

NSString *const RCTUIManagerWillUpdateViewsDueToContentSizeMultiplierChangeNotification = @"RCTUIManagerWillUpdateViewsDueToContentSizeMultiplierChangeNotification";
NSString *const RCTUIManagerDidRegisterRootViewNotification = @"RCTUIManagerDidRegisterRootViewNotification";
NSString *const RCTUIManagerDidRemoveRootViewNotification = @"RCTUIManagerDidRemoveRootViewNotification";
NSString *const RCTUIManagerRootViewKey = @"RCTUIManagerRootViewKey";

@interface RCTAnimation : NSObject

@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSTimeInterval delay;
@property (nonatomic, readonly, copy) NSString *property;
@property (nonatomic, readonly) id fromValue;
@property (nonatomic, readonly) id toValue;
@property (nonatomic, readonly) CGFloat springDamping;
@property (nonatomic, readonly) CGFloat initialVelocity;
@property (nonatomic, readonly) RCTAnimationType animationType;

@end

@implementation RCTAnimation

static NSViewAnimationOptions NSViewAnimationOptionsFromRCTAnimationType(RCTAnimationType type)
{
  switch (type) {
    case RCTAnimationTypeLinear:
      return NSViewAnimationOptionCurveLinear;
    case RCTAnimationTypeEaseIn:
      return NSViewAnimationOptionCurveEaseIn;
    case RCTAnimationTypeEaseOut:
      return NSViewAnimationOptionCurveEaseOut;
    case RCTAnimationTypeEaseInEaseOut:
      return NSViewAnimationOptionCurveEaseInOut;
    case RCTAnimationTypeKeyboard:
      // http://stackoverflow.com/questions/18870447/how-to-use-the-default-ios7-uianimation-curve
      return (NSViewAnimationOptions)(7 << 16);
    default:
      RCTLogError(@"Unsupported animation type %zd", type);
      return NSViewAnimationOptionCurveEaseInOut;
  }
}

- (instancetype)initWithDuration:(NSTimeInterval)duration dictionary:(NSDictionary *)config
{
  if (!config) {
    return nil;
  }

  if ((self = [super init])) {
    _property = [RCTConvert NSString:config[@"property"]];

    _duration = [RCTConvert NSTimeInterval:config[@"duration"]] ?: duration;
    if (_duration > 0.0 && _duration < 0.01) {
      RCTLogError(@"RCTLayoutAnimation expects timings to be in ms, not seconds.");
      _duration = _duration * 1000.0;
    }

    _delay = [RCTConvert NSTimeInterval:config[@"delay"]];
    if (_delay > 0.0 && _delay < 0.01) {
      RCTLogError(@"RCTLayoutAnimation expects timings to be in ms, not seconds.");
      _delay = _delay * 1000.0;
    }

    _animationType = [RCTConvert RCTAnimationType:config[@"type"]];
    if (_animationType == RCTAnimationTypeSpring) {
      _springDamping = [RCTConvert CGFloat:config[@"springDamping"]];
      _initialVelocity = [RCTConvert CGFloat:config[@"initialVelocity"]];
    }
    _fromValue = config[@"fromValue"];
    _toValue = config[@"toValue"];
  }
  return self;
}

- (void)performAnimations:(void (^)(void))animations
      withCompletionBlock:(void (^)(BOOL completed))completionBlock
{

  // TODO: RCTAnimationTypeSpring (see https://github.com/facebook/pop/tree/master/pop)
    NSViewAnimationOptions options = NSViewAnimationOptionBeginFromCurrentState |
      NSViewAnimationOptionsFromRCTAnimationType(_animationType);

    [NSView animateWithDuration:_duration
                          delay:_delay
                        options:options
                     animations:animations
                     completion:completionBlock];
}

@end

@interface RCTLayoutAnimation : NSObject

@property (nonatomic, copy) NSDictionary *config;
@property (nonatomic, strong) RCTAnimation *createAnimation;
@property (nonatomic, strong) RCTAnimation *updateAnimation;
@property (nonatomic, strong) RCTAnimation *deleteAnimation;
@property (nonatomic, copy) RCTResponseSenderBlock callback;

@end

@implementation RCTLayoutAnimation

- (instancetype)initWithDictionary:(NSDictionary *)config callback:(RCTResponseSenderBlock)callback
{
  if (!config) {
    return nil;
  }

  if ((self = [super init])) {
    _config = [config copy];
    NSTimeInterval duration = [RCTConvert NSTimeInterval:config[@"duration"]];
    if (duration > 0.0 && duration < 0.01) {
      RCTLogError(@"RCTLayoutAnimation expects timings to be in ms, not seconds.");
      duration = duration * 1000.0;
    }

    _createAnimation = [[RCTAnimation alloc] initWithDuration:duration dictionary:config[@"create"]];
    _updateAnimation = [[RCTAnimation alloc] initWithDuration:duration dictionary:config[@"update"]];
    _deleteAnimation = [[RCTAnimation alloc] initWithDuration:duration dictionary:config[@"delete"]];
    _callback = callback;
  }
  return self;
}

@end

@implementation RCTUIManager
{
  dispatch_queue_t _shadowQueue;

  // Root views are only mutated on the shadow queue
  NSMutableSet<NSNumber *> *_rootViewTags;
  NSMutableArray<dispatch_block_t> *_pendingUIBlocks;

  // Animation
  RCTLayoutAnimation *_nextLayoutAnimation; // RCT thread only
  RCTLayoutAnimation *_layoutAnimation; // Main thread only

  NSMutableDictionary<NSNumber *, RCTShadowView *> *_shadowViewRegistry; // RCT thread only
  NSMutableDictionary<NSNumber *, NSView *> *_viewRegistry; // Main thread only

  // Keyed by viewName
  NSDictionary *_componentDataByName;

  NSMutableSet<id<RCTComponent>> *_bridgeTransactionListeners;
}

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE()

/**
 * Declared in RCTBridge.
 */
extern NSString *RCTBridgeModuleNameForClass(Class cls);

- (void)didReceiveNewContentSizeMultiplier
{
  __weak RCTUIManager *weakSelf = self;
  dispatch_async(self.methodQueue, ^{
    RCTUIManager *strongSelf = weakSelf;
    if (strongSelf) {
      [[NSNotificationCenter defaultCenter] postNotificationName:RCTUIManagerWillUpdateViewsDueToContentSizeMultiplierChangeNotification
                                                          object:strongSelf];
      [strongSelf batchDidComplete];
    }
  });
}

- (void)invalidate
{
  /**
   * Called on the JS Thread since all modules are invalidated on the JS thread
   */

  // This only accessed from the shadow queue
  _pendingUIBlocks = nil;

  dispatch_async(dispatch_get_main_queue(), ^{
    for (NSNumber *rootViewTag in _rootViewTags) {
      [(id<RCTInvalidating>)_viewRegistry[rootViewTag] invalidate];
    }

    _rootViewTags = nil;
    _shadowViewRegistry = nil;
    _viewRegistry = nil;
    _bridgeTransactionListeners = nil;
    _bridge = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
  });
}

- (NSMutableDictionary<NSNumber *, RCTShadowView *> *)shadowViewRegistry
{
  // NOTE: this method only exists so that it can be accessed by unit tests
  if (!_shadowViewRegistry) {
    _shadowViewRegistry = [NSMutableDictionary new];
  }
  return _shadowViewRegistry;
}

- (NSMutableDictionary<NSNumber *, NSView *> *)viewRegistry
{
  // NOTE: this method only exists so that it can be accessed by unit tests
  if (!_viewRegistry) {
    _viewRegistry = [NSMutableDictionary new];
  }
  return _viewRegistry;
}

- (void)setBridge:(RCTBridge *)bridge
{
  RCTAssert(_bridge == nil, @"Should not re-use same UIIManager instance");

  _bridge = bridge;

  _shadowViewRegistry = [NSMutableDictionary new];
  _viewRegistry = [NSMutableDictionary new];

  // Internal resources
  _pendingUIBlocks = [NSMutableArray new];
  _rootViewTags = [NSMutableSet new];

  _bridgeTransactionListeners = [NSMutableSet new];

  // Get view managers from bridge
  NSMutableDictionary *componentDataByName = [NSMutableDictionary new];
  for (Class moduleClass in _bridge.moduleClasses) {
    if ([moduleClass isSubclassOfClass:[RCTViewManager class]]) {
      RCTComponentData *componentData = [[RCTComponentData alloc] initWithManagerClass:moduleClass
                                                                                bridge:_bridge];
      componentDataByName[componentData.name] = componentData;
    }
  }

  _componentDataByName = [componentDataByName copy];

//  [[NSNotificationCenter defaultCenter] addObserver:self
//                                           selector:@selector(didReceiveNewContentSizeMultiplier)
//                                               name:RCTAccessibilityManagerDidUpdateMultiplierNotification
//                                             object:_bridge.accessibilityManager];
}

- (dispatch_queue_t)methodQueue
{
  if (!_shadowQueue) {
    const char *queueName = "com.facebook.React.ShadowQueue";

    if ([NSOperation instancesRespondToSelector:@selector(qualityOfService)]) {
      dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
      _shadowQueue = dispatch_queue_create(queueName, attr);
    } else {
      _shadowQueue = dispatch_queue_create(queueName, DISPATCH_QUEUE_SERIAL);
      dispatch_set_target_queue(_shadowQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    }
  }
  return _shadowQueue;
}

- (void)registerRootView:(NSView *)rootView
{
  RCTAssertMainThread();

  NSNumber *reactTag = rootView.reactTag;
  RCTAssert(RCTIsReactRootView(reactTag),
            @"View %@ with tag #%@ is not a root view", rootView, reactTag);

  NSView *existingView = _viewRegistry[reactTag];
  RCTAssert(existingView == nil || existingView == rootView,
            @"Expect all root views to have unique tag. Added %@ twice", reactTag);

  // Register view
  _viewRegistry[reactTag] = rootView;
  CGRect frame = rootView.frame;

  // Register shadow view
  __weak RCTUIManager *weakSelf = self;
  dispatch_async(_shadowQueue, ^{
    RCTUIManager *strongSelf = weakSelf;
    if (!_viewRegistry) {
      return;
    }
    RCTShadowView *shadowView = [RCTShadowView new];
    shadowView.reactTag = reactTag;
    shadowView.frame = frame;
    //shadowView.backgroundColor = rootView.backgroundColor;
    shadowView.viewName = NSStringFromClass([rootView class]);
    strongSelf->_shadowViewRegistry[shadowView.reactTag] = shadowView;
    [strongSelf->_rootViewTags addObject:reactTag];
  });

  [[NSNotificationCenter defaultCenter] postNotificationName:RCTUIManagerDidRegisterRootViewNotification
                                                      object:self
                                                    userInfo:@{RCTUIManagerRootViewKey: rootView}];
}

- (NSView *)viewForReactTag:(NSNumber *)reactTag
{
  RCTAssertMainThread();
  return _viewRegistry[reactTag];
}

- (void)setFrame:(CGRect)frame forView:(NSView *)view
{
  RCTAssertMainThread();

  // The following variable has no meaning if the view is not a react root view
  RCTRootViewSizeFlexibility sizeFlexibility = RCTRootViewSizeFlexibilityNone;

  if (RCTIsReactRootView(view.reactTag)) {
    RCTRootView *rootView = (RCTRootView *)[view superview];
    if (rootView != nil) {
      sizeFlexibility = rootView.sizeFlexibility;
    }
  }

  NSNumber *reactTag = view.reactTag;
  dispatch_async(_shadowQueue, ^{
    RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
    RCTAssert(shadowView != nil, @"Could not locate shadow view with tag #%@", reactTag);

    BOOL dirtyLayout = NO;

    if (!CGRectEqualToRect(frame, shadowView.frame)) {
      shadowView.frame = frame;
      dirtyLayout = YES;
    }

    // Trigger re-layout when size flexibility changes, as the root view might grow or
    // shrink in the flexible dimensions.
    if (RCTIsReactRootView(reactTag) && shadowView.sizeFlexibility != sizeFlexibility) {
      shadowView.sizeFlexibility = sizeFlexibility;
      dirtyLayout = YES;
    }

    if (dirtyLayout) {
      [shadowView dirtyLayout];
      [self batchDidComplete];
    }
  });
}

- (void)setIntrinsicContentSize:(CGSize)size forView:(NSView *)view
{
  RCTAssertMainThread();

  NSNumber *reactTag = view.reactTag;
  dispatch_async(_shadowQueue, ^{
    RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
    RCTAssert(shadowView != nil, @"Could not locate root view with tag #%@", reactTag);

    shadowView.intrinsicContentSize = size;

    [self batchDidComplete];
  });
}

- (void)setBackgroundColor:(NSColor *)color forRootView:(NSView *)rootView
{
  RCTAssertMainThread();

  NSNumber *reactTag = rootView.reactTag;
  RCTAssert(RCTIsReactRootView(reactTag), @"Specified view %@ is not a root view", reactTag);

  __weak RCTUIManager *weakSelf = self;
  dispatch_async(_shadowQueue, ^{
    RCTUIManager *strongSelf = weakSelf;
    if (!_viewRegistry) {
      return;
    }
    RCTShadowView *rootShadowView = strongSelf->_shadowViewRegistry[reactTag];
    RCTAssert(rootShadowView != nil, @"Could not locate root view with tag #%@", reactTag);
    rootShadowView.backgroundColor = color;
    [self _amendPendingUIBlocksWithStylePropagationUpdateForRootView:rootShadowView];
    [self flushUIBlocks];
  });
}

/**
 * Unregisters views from registries
 */
- (void)_purgeChildren:(NSArray<id<RCTComponent>> *)children
          fromRegistry:(NSMutableDictionary<NSNumber *, id<RCTComponent>> *)registry
{
  for (id<RCTComponent> child in children) {
    RCTTraverseViewNodes(registry[child.reactTag], ^(id<RCTComponent> subview) {
      RCTAssert(![subview isReactRootView], @"Root views should not be unregistered");
      if ([subview conformsToProtocol:@protocol(RCTInvalidating)]) {
        [(id<RCTInvalidating>)subview invalidate];
      }
      [registry removeObjectForKey:subview.reactTag];

      if (registry == (NSMutableDictionary<NSNumber *, id<RCTComponent>> *)_viewRegistry) {
        [_bridgeTransactionListeners removeObject:subview];
      }
    });
  }
}

- (void)addUIBlock:(RCTViewManagerUIBlock)block
{
  RCTAssertThread(_shadowQueue,
                  @"-[RCTUIManager addUIBlock:] should only be called from the "
                  "UIManager's _shadowQueue (it may be accessed via `bridge.uiManager.methodQueue`)");

  if (!block) {
    return;
  }

  if (!_viewRegistry) {
    return;
  }

  __weak RCTUIManager *weakViewManager = self;
  dispatch_block_t outerBlock = ^{
    RCTUIManager *strongViewManager = weakViewManager;
    if (strongViewManager && strongViewManager->_viewRegistry) {
      block(strongViewManager, strongViewManager->_viewRegistry);
    }
  };

  [_pendingUIBlocks addObject:outerBlock];
}

- (RCTViewManagerUIBlock)uiBlockWithLayoutUpdateForRootView:(RCTShadowView *)rootShadowView
{
  RCTAssert(![NSThread isMainThread], @"Should be called on shadow thread");

  // This is nuanced. In the JS thread, we create a new update buffer
  // `frameTags`/`frames` that is created/mutated in the JS thread. We access
  // these structures in the UI-thread block. `NSMutableArray` is not thread
  // safe so we rely on the fact that we never mutate it after it's passed to
  // the main thread.
  NSSet<RCTShadowView *> *viewsWithNewFrames = [rootShadowView collectRootUpdatedFrames];

  if (!viewsWithNewFrames.count) {
    // no frame change results in no UI update block
    return nil;
  }

  // Parallel arrays are built and then handed off to main thread
  NSMutableArray<NSNumber *> *frameReactTags =
    [NSMutableArray arrayWithCapacity:viewsWithNewFrames.count];
  NSMutableArray<NSValue *> *frames =
    [NSMutableArray arrayWithCapacity:viewsWithNewFrames.count];
  NSMutableArray<NSNumber *> *areNew =
    [NSMutableArray arrayWithCapacity:viewsWithNewFrames.count];
  NSMutableArray<NSNumber *> *parentsAreNew =
    [NSMutableArray arrayWithCapacity:viewsWithNewFrames.count];
  NSMutableDictionary<NSNumber *, RCTViewManagerUIBlock> *updateBlocks =
    [NSMutableDictionary new];

  for (RCTShadowView *shadowView in viewsWithNewFrames) {
    [frameReactTags addObject:shadowView.reactTag];
    [frames addObject:[NSValue valueWithRect:shadowView.frame]];

    [areNew addObject:@(shadowView.isNewView)];
    [parentsAreNew addObject:@(shadowView.superview.isNewView)];
  }

  for (RCTShadowView *shadowView in viewsWithNewFrames) {
    // We have to do this after we build the parentsAreNew array.
    shadowView.newView = NO;
  }

  // These are blocks to be executed on each view, immediately after
  // reactSetFrame: has been called. Note that if reactSetFrame: is not called,
  // these won't be called either, so this is not a suitable place to update
  // properties that aren't related to layout.
  for (RCTShadowView *shadowView in viewsWithNewFrames) {
    RCTViewManager *manager = [_componentDataByName[shadowView.viewName] manager];
    RCTViewManagerUIBlock block = [manager uiBlockToAmendWithShadowView:shadowView];
    if (block) {
      updateBlocks[shadowView.reactTag] = block;
    }

    if (shadowView.onLayout) {
      CGRect frame = shadowView.frame;
      shadowView.onLayout(@{
        @"layout": @{
          @"x": @(frame.origin.x),
          @"y": @(frame.origin.y),
          @"width": @(frame.size.width),
          @"height": @(frame.size.height),
        },
      });
    }

    if (RCTIsReactRootView(shadowView.reactTag)) {
      NSNumber *reactTag = shadowView.reactTag;
      CGSize contentSize = shadowView.frame.size;

      dispatch_async(dispatch_get_main_queue(), ^{
        NSView *view = _viewRegistry[reactTag];
        RCTAssert(view != nil, @"view (for ID %@) not found", reactTag);

        RCTRootView *rootView = (RCTRootView *)[view superview];
        rootView.intrinsicSize = contentSize;
      });
    }
  }

  // Perform layout (possibly animated)
  return ^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    RCTResponseSenderBlock callback = self->_layoutAnimation.callback;

    // It's unsafe to call this callback more than once, so we nil it out here
    // to make sure that doesn't happen.
    _layoutAnimation.callback = nil;

    __block NSUInteger completionsCalled = 0;
    for (NSUInteger ii = 0; ii < frames.count; ii++) {
      NSNumber *reactTag = frameReactTags[ii];
      NSView *view = viewRegistry[reactTag];
      CGRect frame = [[frames objectAtIndex:ii] rectValue];
      BOOL isNew = [areNew[ii] boolValue];

      RCTAnimation *updateAnimation = isNew ? nil : _layoutAnimation.updateAnimation;
      BOOL shouldAnimateCreation = isNew && ![parentsAreNew[ii] boolValue];
      RCTAnimation *createAnimation = shouldAnimateCreation ? _layoutAnimation.createAnimation : nil;

      void (^completion)(BOOL) = ^(BOOL finished) {
        completionsCalled++;
        if (callback && completionsCalled == frames.count) {
          callback(@[@(finished)]);
        }
      };

      // Animate view creation
      if (createAnimation) {
        [view reactSetFrame:frame];

        CATransform3D finalTransform = view.layer.transform;
        CGFloat finalOpacity = view.layer.opacity;
        if ([createAnimation.property isEqualToString:@"scaleXY"]) {
          view.layer.transform = CATransform3DMakeScale(0, 0, 0);
        } else if ([createAnimation.property isEqualToString:@"opacity"]) {
          view.layer.opacity = 0.0;
        }

        [createAnimation performAnimations:^{
          if ([createAnimation.property isEqual:@"scaleXY"]) {
            view.layer.transform = finalTransform;
          } else if ([createAnimation.property isEqual:@"opacity"]) {
            view.layer.opacity = finalOpacity;
          } else {
            RCTLogError(@"Unsupported layout animation createConfig property %@",
                        createAnimation.property);
          }

          RCTViewManagerUIBlock updateBlock = updateBlocks[reactTag];
          if (updateBlock) {
            updateBlock(self, _viewRegistry);
          }
        } withCompletionBlock:completion];

      // Animate view update
      } else if (updateAnimation) {
        [updateAnimation performAnimations:^{
          [[view animator] setFrame:frame];
          [view reactSetFrame:frame];

          RCTViewManagerUIBlock updateBlock = updateBlocks[reactTag];
          if (updateBlock) {
            updateBlock(self, _viewRegistry);
          }
        } withCompletionBlock:completion];

      // Update without animation
      } else {
        [view reactSetFrame:frame];

        RCTViewManagerUIBlock updateBlock = updateBlocks[reactTag];
        if (updateBlock) {
          updateBlock(self, _viewRegistry);
        }
        completion(YES);
      }
    }
  };
}

- (void)_amendPendingUIBlocksWithStylePropagationUpdateForRootView:(RCTShadowView *)topView
{
  NSMutableSet<RCTApplierBlock> *applierBlocks = [NSMutableSet setWithCapacity:1];
  [topView collectUpdatedProperties:applierBlocks parentProperties:@{}];

  if (applierBlocks.count) {
    [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
      for (RCTApplierBlock block in applierBlocks) {
        block(viewRegistry);
      }
    }];
  }
}

/**
 * A method to be called from JS, which takes a container ID and then releases
 * all subviews for that container upon receipt.
 */
RCT_EXPORT_METHOD(removeSubviewsFromContainerWithID:(nonnull NSNumber *)containerID)
{
  id<RCTComponent> container = _shadowViewRegistry[containerID];
  RCTAssert(container != nil, @"container view (for ID %@) not found", containerID);

  NSUInteger subviewsCount = [container reactSubviews].count;
  NSMutableArray<NSNumber *> *indices = [[NSMutableArray alloc] initWithCapacity:subviewsCount];
  for (NSUInteger childIndex = 0; childIndex < subviewsCount; childIndex++) {
    [indices addObject:@(childIndex)];
  }

  [self manageChildren:containerID
       moveFromIndices:nil
         moveToIndices:nil
     addChildReactTags:nil
          addAtIndices:nil
       removeAtIndices:indices];
}

/**
 * Disassociates children from container. Doesn't remove from registries.
 * TODO: use [NSArray getObjects:buffer] to reuse same fast buffer each time.
 *
 * @returns Array of removed items.
 */
- (NSArray<id<RCTComponent>> *)_childrenToRemoveFromContainer:(id<RCTComponent>)container
                                                    atIndices:(NSArray<NSNumber *> *)atIndices
{
  // If there are no indices to move or the container has no subviews don't bother
  // We support parents with nil subviews so long as they're all nil so this allows for this behavior
  if (atIndices.count == 0 || [container reactSubviews].count == 0) {
    return nil;
  }
  // Construction of removed children must be done "up front", before indices are disturbed by removals.
  NSMutableArray<id<RCTComponent>> *removedChildren = [NSMutableArray arrayWithCapacity:atIndices.count];
  RCTAssert(container != nil, @"container view (for ID %@) not found", container);
  for (NSNumber *indexNumber in atIndices) {
    NSUInteger index = indexNumber.unsignedIntegerValue;
    if (index < [container reactSubviews].count) {
      [removedChildren addObject:[container reactSubviews][index]];
    }
  }
  if (removedChildren.count != atIndices.count) {
    NSString *message = [NSString stringWithFormat:@"removedChildren count (%tu) was not what we expected (%tu)",
                         removedChildren.count, atIndices.count];
    RCTFatal(RCTErrorWithMessage(message));
  }
  return removedChildren;
}

- (void)_removeChildren:(NSArray<id<RCTComponent>> *)children
          fromContainer:(id<RCTComponent>)container
{
  for (id<RCTComponent> removedChild in children) {
    [container removeReactSubview:removedChild];
  }
}

RCT_EXPORT_METHOD(removeRootView:(nonnull NSNumber *)rootReactTag)
{
  RCTShadowView *rootShadowView = _shadowViewRegistry[rootReactTag];
  RCTAssert(rootShadowView.superview == nil, @"root view cannot have superview (ID %@)", rootReactTag);
  [self _purgeChildren:(NSArray<id<RCTComponent>> *)rootShadowView.reactSubviews
          fromRegistry:(NSMutableDictionary<NSNumber *, id<RCTComponent>> *)_shadowViewRegistry];
  [_shadowViewRegistry removeObjectForKey:rootReactTag];
  [_rootViewTags removeObject:rootReactTag];

  [self addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry){
    RCTAssertMainThread();

    NSView *rootView = viewRegistry[rootReactTag];
    [uiManager _purgeChildren:(NSArray<id<RCTComponent>> *)rootView.reactSubviews
                 fromRegistry:(NSMutableDictionary<NSNumber *, id<RCTComponent>> *)viewRegistry];
    [(NSMutableDictionary<NSNumber *, NSView *> *)viewRegistry removeObjectForKey:rootReactTag];

    [[NSNotificationCenter defaultCenter] postNotificationName:RCTUIManagerDidRemoveRootViewNotification
                                                        object:uiManager
                                                      userInfo:@{RCTUIManagerRootViewKey: rootView}];
  }];
}

RCT_EXPORT_METHOD(replaceExistingNonRootView:(nonnull NSNumber *)reactTag
                  withView:(nonnull NSNumber *)newReactTag)
{
  RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
  RCTAssert(shadowView != nil, @"shadowView (for ID %@) not found", reactTag);

  RCTShadowView *superShadowView = shadowView.superview;
  RCTAssert(superShadowView != nil, @"shadowView super (of ID %@) not found", reactTag);

  NSUInteger indexOfView = [superShadowView.reactSubviews indexOfObject:shadowView];
  RCTAssert(indexOfView != NSNotFound, @"View's superview doesn't claim it as subview (id %@)", reactTag);
  NSArray<NSNumber *> *removeAtIndices = @[@(indexOfView)];
  NSArray<NSNumber *> *addTags = @[newReactTag];
  [self manageChildren:superShadowView.reactTag
        moveFromIndices:nil
          moveToIndices:nil
      addChildReactTags:addTags
          addAtIndices:removeAtIndices
        removeAtIndices:removeAtIndices];
}

RCT_EXPORT_METHOD(setChildren:(nonnull NSNumber *)containerTag
                  reactTags:(NSArray<NSNumber *> *)reactTags)
{
  RCTSetChildren(containerTag, reactTags,
                 (NSDictionary<NSNumber *, id<RCTComponent>> *)_shadowViewRegistry);

  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry){

    RCTSetChildren(containerTag, reactTags,
                   (NSDictionary<NSNumber *, id<RCTComponent>> *)viewRegistry);
  }];
}

static void RCTSetChildren(NSNumber *containerTag,
                           NSArray<NSNumber *> *reactTags,
                           NSDictionary<NSNumber *, id<RCTComponent>> *registry)
{
  id<RCTComponent> container = registry[containerTag];
  NSInteger index = 0;
  for (NSNumber *reactTag in reactTags) {
    id<RCTComponent> view = registry[reactTag];
    if (view) {
      [container insertReactSubview:view atIndex:index++];
    }
  }
}

RCT_EXPORT_METHOD(manageChildren:(nonnull NSNumber *)containerReactTag
                  moveFromIndices:(NSArray<NSNumber *> *)moveFromIndices
                  moveToIndices:(NSArray<NSNumber *> *)moveToIndices
                  addChildReactTags:(NSArray<NSNumber *> *)addChildReactTags
                  addAtIndices:(NSArray<NSNumber *> *)addAtIndices
                  removeAtIndices:(NSArray<NSNumber *> *)removeAtIndices)
{
  [self _manageChildren:containerReactTag
        moveFromIndices:moveFromIndices
          moveToIndices:moveToIndices
      addChildReactTags:addChildReactTags
           addAtIndices:addAtIndices
        removeAtIndices:removeAtIndices
               registry:(NSMutableDictionary<NSNumber *, id<RCTComponent>> *)_shadowViewRegistry];

  [self addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry){
    [uiManager _manageChildren:containerReactTag
               moveFromIndices:moveFromIndices
                 moveToIndices:moveToIndices
             addChildReactTags:addChildReactTags
                  addAtIndices:addAtIndices
               removeAtIndices:removeAtIndices
                      registry:(NSMutableDictionary<NSNumber *, id<RCTComponent>> *)viewRegistry];
  }];
}

- (void)_manageChildren:(NSNumber *)containerReactTag
        moveFromIndices:(NSArray<NSNumber *> *)moveFromIndices
          moveToIndices:(NSArray<NSNumber *> *)moveToIndices
      addChildReactTags:(NSArray<NSNumber *> *)addChildReactTags
           addAtIndices:(NSArray<NSNumber *> *)addAtIndices
        removeAtIndices:(NSArray<NSNumber *> *)removeAtIndices
               registry:(NSMutableDictionary<NSNumber *, id<RCTComponent>> *)registry
{
  id<RCTComponent> container = registry[containerReactTag];
   RCTAssert(moveFromIndices.count == moveToIndices.count, @"moveFromIndices had size %tu, moveToIndices had size %tu", moveFromIndices.count, moveToIndices.count);
  RCTAssert(addChildReactTags.count == addAtIndices.count, @"there should be at least one React child to add");

  // Removes (both permanent and temporary moves) are using "before" indices
  NSArray<id<RCTComponent>> *permanentlyRemovedChildren =
    [self _childrenToRemoveFromContainer:container atIndices:removeAtIndices];
  NSArray<id<RCTComponent>> *temporarilyRemovedChildren =
    [self _childrenToRemoveFromContainer:container atIndices:moveFromIndices];
  [self _removeChildren:permanentlyRemovedChildren fromContainer:container];
  [self _removeChildren:temporarilyRemovedChildren fromContainer:container];

  [self _purgeChildren:permanentlyRemovedChildren fromRegistry:registry];

  // TODO (#5906496): optimize all these loops - constantly calling array.count is not efficient

  // Figure out what to insert - merge temporary inserts and adds
  NSMutableDictionary *destinationsToChildrenToAdd = [NSMutableDictionary dictionary];
  for (NSInteger index = 0, length = temporarilyRemovedChildren.count; index < length; index++) {
    destinationsToChildrenToAdd[moveToIndices[index]] = temporarilyRemovedChildren[index];
  }
  for (NSInteger index = 0, length = addAtIndices.count; index < length; index++) {
    id<RCTComponent> view = registry[addChildReactTags[index]];
    if (view) {
      destinationsToChildrenToAdd[addAtIndices[index]] = view;
    }
  }

  NSArray<NSNumber *> *sortedIndices =
    [destinationsToChildrenToAdd.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSNumber *reactIndex in sortedIndices) {
    [container insertReactSubview:destinationsToChildrenToAdd[reactIndex]
                          atIndex:reactIndex.integerValue];
  }
}

RCT_EXPORT_METHOD(createView:(nonnull NSNumber *)reactTag
                  viewName:(NSString *)viewName
                  rootTag:(__unused NSNumber *)rootTag
                  props:(NSDictionary *)props)
{
  RCTComponentData *componentData = _componentDataByName[viewName];
  if (componentData == nil) {
    RCTLogError(@"No component found for view with name \"%@\"", viewName);
  }

  // Register shadow view
  RCTShadowView *shadowView = [componentData createShadowViewWithTag:reactTag];
  if (shadowView) {
    [componentData setProps:props forShadowView:shadowView];
    _shadowViewRegistry[reactTag] = shadowView;
  }

  // Shadow view is the source of truth for background color this is a little
  // bit counter-intuitive if people try to set background color when setting up
  // the view, but it's the only way that makes sense given our threading model
  NSColor *backgroundColor = shadowView.backgroundColor;

  [self addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry){
    NSView *view = [componentData createViewWithTag:reactTag];
    if (view) {
      if ([view respondsToSelector:@selector(layer)]) {
        ((NSView *)view).layer.backgroundColor = [backgroundColor CGColor];
      }
      [componentData setProps:props forView:view];
      if ([view respondsToSelector:@selector(reactBridgeDidFinishTransaction)]) {
        [uiManager->_bridgeTransactionListeners addObject:view];
      }
      ((NSMutableDictionary<NSNumber *, NSView *> *)viewRegistry)[reactTag] = view;
    }
  }];
}

RCT_EXPORT_METHOD(updateView:(nonnull NSNumber *)reactTag
                  viewName:(NSString *)viewName // not always reliable, use shadowView.viewName if available
                  props:(NSDictionary *)props)
{
  RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
  RCTComponentData *componentData = _componentDataByName[shadowView.viewName ?: viewName];
  [componentData setProps:props forShadowView:shadowView];

  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    NSView *view = viewRegistry[reactTag];
    [componentData setProps:props forView:view];
  }];
}

RCT_EXPORT_METHOD(focus:(nonnull NSNumber *)reactTag)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    NSView *newResponder = viewRegistry[reactTag];
    [newResponder reactWillMakeFirstResponder];
    [newResponder becomeFirstResponder];
    [newResponder reactDidMakeFirstResponder];
  }];
}

RCT_EXPORT_METHOD(blur:(nonnull NSNumber *)reactTag)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry){
    NSView *currentResponder = viewRegistry[reactTag];
    [currentResponder resignFirstResponder];
  }];
}

RCT_EXPORT_METHOD(findSubviewIn:(nonnull NSNumber *)reactTag atPoint:(CGPoint)point callback:(RCTResponseSenderBlock)callback)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    NSLog(@"findSubViewin is not implemented");
//    NSView *view = viewRegistry[reactTag];
//    NSView *target = [view hitTest:point withEvent:nil];
//    CGRect frame = [target convertRect:target.bounds toView:view];
//
//    while (target.reactTag == nil && target.superview != nil) {
//      target = target.superview;
//    }
//
//    callback(@[
//      RCTNullIfNil(target.reactTag),
//      @(frame.origin.x),
//      @(frame.origin.y),
//      @(frame.size.width),
//      @(frame.size.height),
//    ]);
  }];
}

RCT_EXPORT_METHOD(dispatchViewManagerCommand:(nonnull NSNumber *)reactTag
                  commandID:(NSInteger)commandID
                  commandArgs:(NSArray<id> *)commandArgs)
{
  RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
  RCTComponentData *componentData = _componentDataByName[shadowView.viewName];
  Class managerClass = componentData.managerClass;
  RCTModuleData *moduleData = [_bridge moduleDataForName:RCTBridgeModuleNameForClass(managerClass)];
  id<RCTBridgeMethod> method = moduleData.methods[commandID];

  NSArray *args = [@[reactTag] arrayByAddingObjectsFromArray:commandArgs];
  [method invokeWithBridge:_bridge module:componentData.manager arguments:args];
}

- (void)partialBatchDidFlush
{
  if (self.unsafeFlushUIChangesBeforeBatchEnds) {
    [self flushUIBlocks];
  }
}

- (void)batchDidComplete
{
  [self _layoutAndMount];
}

/**
 * Sets up animations, computes layout, creates UI mounting blocks for computed layout,
 * runs these blocks and all other already existing blocks.
 */
- (void)_layoutAndMount
{
  // Gather blocks to be executed now that all view hierarchy manipulations have
  // been completed (note that these may still take place before layout has finished)
  for (RCTComponentData *componentData in _componentDataByName.allValues) {
    RCTViewManagerUIBlock uiBlock = [componentData uiBlockToAmendWithShadowViewRegistry:_shadowViewRegistry];
    [self addUIBlock:uiBlock];
  }

  // Set up next layout animation
  if (_nextLayoutAnimation) {
    RCTLayoutAnimation *layoutAnimation = _nextLayoutAnimation;
    [self addUIBlock:^(RCTUIManager *uiManager, __unused NSDictionary<NSNumber *, NSView *> *viewRegistry) {
      uiManager->_layoutAnimation = layoutAnimation;
    }];
  }

  // Perform layout
  for (NSNumber *reactTag in _rootViewTags) {
    RCTShadowView *rootView = _shadowViewRegistry[reactTag];
    [self addUIBlock:[self uiBlockWithLayoutUpdateForRootView:rootView]];
    [self _amendPendingUIBlocksWithStylePropagationUpdateForRootView:rootView];
  }

  // Clear layout animations
  if (_nextLayoutAnimation) {
    [self addUIBlock:^(RCTUIManager *uiManager, __unused NSDictionary<NSNumber *, NSView *> *viewRegistry) {
      uiManager->_layoutAnimation = nil;
    }];
    _nextLayoutAnimation = nil;
  }

  [self addUIBlock:^(RCTUIManager *uiManager, __unused NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    /**
     * TODO(tadeu): Remove it once and for all
     */
    for (id<RCTComponent> node in uiManager->_bridgeTransactionListeners) {
      [node reactBridgeDidFinishTransaction];
    }
  }];

  [self flushUIBlocks];
}

- (void)flushUIBlocks
{
  RCTAssertThread(_shadowQueue, @"flushUIBlocks can only be called from the shadow queue");

  // First copy the previous blocks into a temporary variable, then reset the
  // pending blocks to a new array. This guards against mutation while
  // processing the pending blocks in another thread.
  NSArray<dispatch_block_t> *previousPendingUIBlocks = _pendingUIBlocks;
  _pendingUIBlocks = [NSMutableArray new];

  if (previousPendingUIBlocks.count) {
    // Execute the previously queued UI blocks
    RCTProfileBeginFlowEvent();
    dispatch_async(dispatch_get_main_queue(), ^{
      RCTProfileEndFlowEvent();
      RCT_PROFILE_BEGIN_EVENT(0, @"UIManager flushUIBlocks", nil);
      @try {
        for (dispatch_block_t block in previousPendingUIBlocks) {
          block();
        }
      }
      @catch (NSException *exception) {
        RCTLogError(@"Exception thrown while executing UI block: %@", exception);
      }
      RCT_PROFILE_END_EVENT(0, @"objc_call", @{
        @"count": @(previousPendingUIBlocks.count),
      });
    });
  }
}

- (void)setNeedsLayout
{
  // If there is an active batch layout will happen when batch finished, so we will wait for that.
  // Otherwise we immidiately trigger layout.
  if (![_bridge isBatchActive]) {
    [self _layoutAndMount];
  }
}

RCT_EXPORT_METHOD(measure:(nonnull NSNumber *)reactTag
                  callback:(RCTResponseSenderBlock)callback)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    NSView *view = viewRegistry[reactTag];
    if (!view) {
      // this view was probably collapsed out
      RCTLogWarn(@"measure cannot find view with tag #%@", reactTag);
      callback(@[]);
      return;
    }

    NSView *rootView = view;
    while (rootView && ![rootView isReactRootView]) {
      rootView = rootView.superview;
    }

    // TODO: this doesn't work because sometimes view is inside a modal window
    RCTAssert([rootView isReactRootView], @"React view is not inside a React root view");

    // By convention, all coordinates, whether they be touch coordinates, or
    // measurement coordinates are with respect to the root view.
    CGRect frame = view.frame;
    CGPoint pagePoint = [view.superview convertPoint:frame.origin toView:rootView];

    callback(@[
      @(frame.origin.x),
      @(frame.origin.y),
      @(frame.size.width),
      @(frame.size.height),
      @(pagePoint.x),
      @(pagePoint.y)
    ]);
  }];
}

RCT_EXPORT_METHOD(measureInWindow:(nonnull NSNumber *)reactTag
                  callback:(RCTResponseSenderBlock)callback)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    NSView *view = viewRegistry[reactTag];
    if (!view) {
      // this view was probably collapsed out
      RCTLogWarn(@"measure cannot find view with tag #%@", reactTag);
      callback(@[]);
      return;
    }

    // Return frame coordinates in window
    CGRect windowFrame = [view.window convertRectFromScreen:view.frame];
    callback(@[
      @(windowFrame.origin.x),
      @(windowFrame.origin.y),
      @(windowFrame.size.width),
      @(windowFrame.size.height),
    ]);
  }];
}

static void RCTMeasureLayout(RCTShadowView *view,
                             RCTShadowView *ancestor,
                             RCTResponseSenderBlock callback)
{
  if (!view) {
    return;
  }
  if (!ancestor) {
    return;
  }
  CGRect result = [view measureLayoutRelativeToAncestor:ancestor];
  if (CGRectIsNull(result)) {
    RCTLogError(@"view %@ (tag #%@) is not a decendant of %@ (tag #%@)",
                view, view.reactTag, ancestor, ancestor.reactTag);
    return;
  }
  CGFloat leftOffset = result.origin.x;
  CGFloat topOffset = result.origin.y;
  CGFloat width = result.size.width;
  CGFloat height = result.size.height;
  if (isnan(leftOffset) || isnan(topOffset) || isnan(width) || isnan(height)) {
    RCTLogError(@"Attempted to measure layout but offset or dimensions were NaN");
    return;
  }
  callback(@[@(leftOffset), @(topOffset), @(width), @(height)]);
}

/**
 * Returns the computed recursive offset layout in a dictionary form. The
 * returned values are relative to the `ancestor` shadow view. Returns `nil`, if
 * the `ancestor` shadow view is not actually an `ancestor`. Does not touch
 * anything on the main UI thread. Invokes supplied callback with (x, y, width,
 * height).
 */
RCT_EXPORT_METHOD(measureLayout:(nonnull NSNumber *)reactTag
                  relativeTo:(nonnull NSNumber *)ancestorReactTag
                  errorCallback:(__unused RCTResponseSenderBlock)errorCallback
                  callback:(RCTResponseSenderBlock)callback)
{
  RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
  RCTShadowView *ancestorShadowView = _shadowViewRegistry[ancestorReactTag];
  RCTMeasureLayout(shadowView, ancestorShadowView, callback);
}

/**
 * Returns the computed recursive offset layout in a dictionary form. The
 * returned values are relative to the `ancestor` shadow view. Returns `nil`, if
 * the `ancestor` shadow view is not actually an `ancestor`. Does not touch
 * anything on the main UI thread. Invokes supplied callback with (x, y, width,
 * height).
 */
RCT_EXPORT_METHOD(measureLayoutRelativeToParent:(nonnull NSNumber *)reactTag
                  errorCallback:(__unused RCTResponseSenderBlock)errorCallback
                  callback:(RCTResponseSenderBlock)callback)
{
  RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
  RCTMeasureLayout(shadowView, shadowView.reactSuperview, callback);
}

/**
 * Returns an array of computed offset layouts in a dictionary form. The layouts are of any React subviews
 * that are immediate descendants to the parent view found within a specified rect. The dictionary result
 * contains left, top, width, height and an index. The index specifies the position among the other subviews.
 * Only layouts for views that are within the rect passed in are returned. Invokes the error callback if the
 * passed in parent view does not exist. Invokes the supplied callback with the array of computed layouts.
 */
RCT_EXPORT_METHOD(measureViewsInRect:(CGRect)rect
                  parentView:(nonnull NSNumber *)reactTag
                  errorCallback:(__unused RCTResponseSenderBlock)errorCallback
                  callback:(RCTResponseSenderBlock)callback)
{
  RCTShadowView *shadowView = _shadowViewRegistry[reactTag];
  if (!shadowView) {
    RCTLogError(@"Attempting to measure view that does not exist (tag #%@)", reactTag);
    return;
  }
  NSArray<RCTShadowView *> *childShadowViews = [shadowView reactSubviews];
  NSMutableArray<NSDictionary *> *results =
    [[NSMutableArray alloc] initWithCapacity:childShadowViews.count];

  [childShadowViews enumerateObjectsUsingBlock:
   ^(RCTShadowView *childShadowView, NSUInteger idx, __unused BOOL *stop) {
    CGRect childLayout = [childShadowView measureLayoutRelativeToAncestor:shadowView];
    if (CGRectIsNull(childLayout)) {
      RCTLogError(@"View %@ (tag #%@) is not a decendant of %@ (tag #%@)",
                  childShadowView, childShadowView.reactTag, shadowView, shadowView.reactTag);
      return;
    }

    CGFloat leftOffset = childLayout.origin.x;
    CGFloat topOffset = childLayout.origin.y;
    CGFloat width = childLayout.size.width;
    CGFloat height = childLayout.size.height;

    if (leftOffset <= rect.origin.x + rect.size.width &&
        leftOffset + width >= rect.origin.x &&
        topOffset <= rect.origin.y + rect.size.height &&
        topOffset + height >= rect.origin.y) {

      // This view is within the layout rect
      NSDictionary *result = @{@"index": @(idx),
                               @"left": @(leftOffset),
                               @"top": @(topOffset),
                               @"width": @(width),
                               @"height": @(height)};

      [results addObject:result];
    }
  }];
  callback(@[results]);
}

RCT_EXPORT_METHOD(takeSnapshot:(id /* NSString or NSNumber */)target
                  withOptions:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {

    // Get view
    NSView *view;
    if (target == nil || [target isEqual:@"window"]) {
      view = RCTKeyWindow();
    } else if ([target isKindOfClass:[NSNumber class]]) {
      view = viewRegistry[target];
      if (!view) {
        RCTLogError(@"No view found with reactTag: %@", target);
        return;
      }
    }

    // Get options
    CGSize size = [RCTConvert CGSize:options];
    NSString *format = [RCTConvert NSString:options[@"format"] ?: @"png"];

    // Capture image
    if (size.width < 0.1 || size.height < 0.1) {
      size = view.bounds.size;
    }
    NSImage *image =[[NSImage alloc] initWithData:[view dataWithPDFInsideRect:[view bounds]]];
    if (!image) {
      reject(RCTErrorUnspecified, @"Failed to capture view snapshot.", nil);
      return;
    }

    // Convert image to data (on a background thread)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

      NSData *data;
      if ([format isEqualToString:@"png"]) {
        data = UIImagePNGRepresentation(image);
      } else if ([format isEqualToString:@"jpeg"]) {
        CGFloat quality = [RCTConvert CGFloat:options[@"quality"] ?: @1];
        data = UIImageJPEGRepresentation(image, quality);
      } else {
        RCTLogError(@"Unsupported image format: %@", format);
        return;
      }

      // Save to a temp file
      NSError *error = nil;
      NSString *tempFilePath = RCTTempFilePath(format, &error);
      if (tempFilePath) {
        if ([data writeToFile:tempFilePath options:(NSDataWritingOptions)0 error:&error]) {
          resolve(tempFilePath);
          return;
        }
      }

      // If we reached here, something went wrong
      reject(RCTErrorUnspecified, error.localizedDescription, error);
    });
  }];
}

/**
 * JS sets what *it* considers to be the responder. Later, scroll views can use
 * this in order to determine if scrolling is appropriate.
 */
RCT_EXPORT_METHOD(setJSResponder:(nonnull NSNumber *)reactTag
                  blockNativeResponder:(__unused BOOL)blockNativeResponder)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    _jsResponder = viewRegistry[reactTag];
    if (!_jsResponder) {
      RCTLogError(@"Invalid view set to be the JS responder - tag %zd", reactTag);
    }
  }];
}

RCT_EXPORT_METHOD(clearJSResponder)
{
  [self addUIBlock:^(__unused RCTUIManager *uiManager, __unused NSDictionary<NSNumber *, NSView *> *viewRegistry) {
    _jsResponder = nil;
  }];
}

- (NSDictionary<NSString *, id> *)constantsToExport
{
  NSMutableDictionary<NSString *, NSDictionary *> *allJSConstants = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSDictionary *> *directEvents = [NSMutableDictionary new];
  NSMutableDictionary<NSString *, NSDictionary *> *bubblingEvents = [NSMutableDictionary new];

  [_componentDataByName enumerateKeysAndObjectsUsingBlock:
   ^(NSString *name, RCTComponentData *componentData, __unused BOOL *stop) {

     NSMutableDictionary<NSString *, id> *constantsNamespace =
       [NSMutableDictionary dictionaryWithDictionary:allJSConstants[name]];

     // Add manager class
     constantsNamespace[@"Manager"] = RCTBridgeModuleNameForClass(componentData.managerClass);

     // Add native props
     NSDictionary<NSString *, id> *viewConfig = [componentData viewConfig];
     constantsNamespace[@"NativeProps"] = viewConfig[@"propTypes"];

     // Add direct events
     for (NSString *eventName in viewConfig[@"directEvents"]) {
       if (!directEvents[eventName]) {
         directEvents[eventName] = @{
           @"registrationName": [eventName stringByReplacingCharactersInRange:(NSRange){0, 3} withString:@"on"],
         };
       }
       if (RCT_DEBUG && bubblingEvents[eventName]) {
         RCTLogError(@"Component '%@' re-registered bubbling event '%@' as a "
                     "direct event", componentData.name, eventName);
       }
     }

     // Add bubbling events
     for (NSString *eventName in viewConfig[@"bubblingEvents"]) {
       if (!bubblingEvents[eventName]) {
         NSString *bubbleName = [eventName stringByReplacingCharactersInRange:(NSRange){0, 3} withString:@"on"];
         bubblingEvents[eventName] = @{
           @"phasedRegistrationNames": @{
             @"bubbled": bubbleName,
             @"captured": [bubbleName stringByAppendingString:@"Capture"],
           }
         };
       }
       if (RCT_DEBUG && directEvents[eventName]) {
         RCTLogError(@"Component '%@' re-registered direct event '%@' as a "
                     "bubbling event", componentData.name, eventName);
       }
     }

     allJSConstants[name] = constantsNamespace;
  }];

  [allJSConstants addEntriesFromDictionary:@{
    @"customBubblingEventTypes": bubblingEvents,
    @"customDirectEventTypes": directEvents,
    @"Dimensions": @{
      @"window": @{
        @"width": @(RCTScreenSize().width),
        @"height": @(RCTScreenSize().height),
        @"scale": @(RCTScreenScale()),
      },
    },
  }];

  return allJSConstants;
}

RCT_EXPORT_METHOD(configureNextLayoutAnimation:(NSDictionary *)config
                  withCallback:(RCTResponseSenderBlock)callback
                  errorCallback:(__unused RCTResponseSenderBlock)errorCallback)
{
  if (_nextLayoutAnimation && ![config isEqualToDictionary:_nextLayoutAnimation.config]) {
    RCTLogWarn(@"Warning: Overriding previous layout animation with new one before the first began:\n%@ -> %@.", _nextLayoutAnimation.config, config);
  }
  if (config[@"delete"] != nil) {
    RCTLogError(@"LayoutAnimation only supports create and update right now. Config: %@", config);
  }
  _nextLayoutAnimation = [[RCTLayoutAnimation alloc] initWithDictionary:config
                                                               callback:callback];
}

static NSView *_jsResponder;

+ (NSView *)JSResponder
{
  return _jsResponder;
}

@end

@implementation RCTBridge (RCTUIManager)

- (RCTUIManager *)uiManager
{
  return [self moduleForClass:[RCTUIManager class]];
}

@end
