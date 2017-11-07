//
//  ZIKViewRouter.m
//  ZIKRouter
//
//  Created by zuik on 2017/3/2.
//  Copyright © 2017 zuik. All rights reserved.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "ZIKViewRouter.h"
#import "ZIKRouterInternal.h"
#import "ZIKViewRouterInternal.h"
#import "ZIKViewRouterPrivate.h"
#import "ZIKViewRouteError.h"
#import <objc/runtime.h>
#import "ZIKRouterRuntimeHelper.h"
#import "UIViewController+ZIKViewRouter.h"
#import "UIView+ZIKViewRouter.h"
#import "ZIKPresentationState.h"
#import "UIView+ZIKViewRouterPrivate.h"
#import "UIViewController+ZIKViewRouterPrivate.h"
#import "UIStoryboardSegue+ZIKViewRouterPrivate.h"
#import "ZIKViewRouteConfiguration+Private.h"

NSNotificationName kZIKViewRouterRegisterCompleteNotification = @"kZIKViewRouterRegisterCompleteNotification";
NSNotificationName kZIKViewRouteWillPerformRouteNotification = @"kZIKViewRouteWillPerformRouteNotification";
NSNotificationName kZIKViewRouteDidPerformRouteNotification = @"kZIKViewRouteDidPerformRouteNotification";
NSNotificationName kZIKViewRouteWillRemoveRouteNotification = @"kZIKViewRouteWillRemoveRouteNotification";
NSNotificationName kZIKViewRouteDidRemoveRouteNotification = @"kZIKViewRouteDidRemoveRouteNotification";
NSNotificationName kZIKViewRouteRemoveRouteCanceledNotification = @"kZIKViewRouteRemoveRouteCanceledNotification";

static BOOL _isLoadFinished = NO;
static CFMutableDictionaryRef g_viewProtocolToRouterMap;
static CFMutableDictionaryRef g_configProtocolToRouterMap;
static CFMutableDictionaryRef g_viewToRoutersMap;
static CFMutableDictionaryRef g_viewToDefaultRouterMap;
static CFMutableDictionaryRef g_viewToExclusiveRouterMap;
#if ZIKVIEWROUTER_CHECK
static CFMutableDictionaryRef _check_routerToViewsMap;
#endif

static ZIKViewRouteGlobalErrorHandler g_globalErrorHandler;
static dispatch_semaphore_t g_globalErrorSema;
static NSMutableArray *g_preparingUIViewRouters;

@interface ZIKViewRouter ()<ZIKRouterProtocol>
@property (nonatomic, assign) BOOL routingFromInternal;
@property (nonatomic, assign) ZIKViewRouteRealType realRouteType;
///Destination prepared. Only for UIView destination
@property (nonatomic, assign) BOOL prepared;
@property (nonatomic, strong, nullable) ZIKPresentationState *stateBeforeRoute;
@property (nonatomic, weak, nullable) UIViewController<ZIKViewRouteContainer> *container;
@property (nonatomic, strong, nullable) ZIKViewRouter *retainedSelf;
@end

@implementation ZIKViewRouter

@dynamic configuration;
@dynamic original_configuration;
@dynamic original_removeConfiguration;

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZIKRouter_replaceMethodWithMethod([UIApplication class], @selector(setDelegate:),
                                          self, @selector(ZIKViewRouter_hook_setDelegate:));
        ZIKRouter_replaceMethodWithMethodType([UIStoryboard class], @selector(storyboardWithName:bundle:), true, self, @selector(ZIKViewRouter_hook_storyboardWithName:bundle:), true);
    });
}

+ (void)setup {
    NSAssert([NSThread isMainThread], @"Setup in main thread");
    static BOOL onceToken = NO;
    if (onceToken == NO) {
        onceToken = YES;
        _initializeZIKViewRouter();
    }
}

+ (void)ZIKViewRouter_hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    [ZIKViewRouter setup];
    [self ZIKViewRouter_hook_setDelegate:delegate];
}

+ (UIStoryboard *)ZIKViewRouter_hook_storyboardWithName:(NSString *)name bundle:(nullable NSBundle *)storyboardBundleOrNil {
    [ZIKViewRouter setup];
    return [self ZIKViewRouter_hook_storyboardWithName:name bundle:storyboardBundleOrNil];
}

static void _initializeZIKViewRouter(void) {
    if (!g_viewProtocolToRouterMap) {
        g_viewProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (!g_configProtocolToRouterMap) {
        g_configProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    g_globalErrorSema = dispatch_semaphore_create(1);
    
    g_preparingUIViewRouters = [NSMutableArray array];
#if ZIKVIEWROUTER_CHECK
    NSMutableSet *routableViews = [NSMutableSet set];
    if (!_check_routerToViewsMap) {
        _check_routerToViewsMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    }
#endif
    
    Class ZIKViewRouterClass = [ZIKViewRouter class];
    Class UIResponderClass = [UIResponder class];
    Class UIViewControllerClass = [UIViewController class];
    Class UIStoryboardSegueClass = [UIStoryboardSegue class];
    
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(willMoveToParentViewController:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_willMoveToParentViewController:));
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(didMoveToParentViewController:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_didMoveToParentViewController:));
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(viewWillAppear:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_viewWillAppear:));
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(viewDidAppear:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_viewDidAppear:));
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(viewWillDisappear:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_viewWillDisappear:));
    if (NSClassFromString(@"SLComposeServiceViewController")) {
        //fix SLComposeServiceViewController doesn't call -[super viewWillDisappear:]
        ZIKRouter_replaceMethodWithMethod(NSClassFromString(@"SLComposeServiceViewController"), @selector(viewWillDisappear:),
                                          ZIKViewRouterClass, @selector(ZIKViewRouter_hook_viewWillDisappear:));
    }
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(viewDidDisappear:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_viewDidDisappear:));
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(viewDidLoad),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_viewDidLoad));
    
    ZIKRouter_replaceMethodWithMethod([UIView class], @selector(willMoveToSuperview:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_willMoveToSuperview:));
    ZIKRouter_replaceMethodWithMethod([UIView class], @selector(didMoveToSuperview),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_didMoveToSuperview));
    ZIKRouter_replaceMethodWithMethod([UIView class], @selector(willMoveToWindow:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_willMoveToWindow:));
    ZIKRouter_replaceMethodWithMethod([UIView class], @selector(didMoveToWindow),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_didMoveToWindow));
    
    ZIKRouter_replaceMethodWithMethod(UIViewControllerClass, @selector(prepareForSegue:sender:),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_prepareForSegue:sender:));
    ZIKRouter_replaceMethodWithMethod(UIStoryboardSegueClass, @selector(perform),
                                      ZIKViewRouterClass, @selector(ZIKViewRouter_hook_seguePerform));
    ZIKRouter_replaceMethodWithMethod([UIStoryboard class], @selector(instantiateInitialViewController), ZIKViewRouterClass, @selector(ZIKViewRouter_hook_instantiateInitialViewController));
    
    ZIKRouter_enumerateClassList(^(__unsafe_unretained Class class) {
        if (ZIKRouter_classIsSubclassOfClass(class, UIResponderClass)) {
#if ZIKVIEWROUTER_CHECK
            if (class_conformsToProtocol(class, @protocol(ZIKRoutableView))) {
                NSCAssert([class isSubclassOfClass:[UIView class]] || [class isSubclassOfClass:UIViewControllerClass], @"ZIKRoutableView only suppourt UIView and UIViewController");
                [routableViews addObject:class];
            }
#endif
            if (ZIKRouter_classIsSubclassOfClass(class, UIViewControllerClass)) {
                //hook all UIViewController's -prepareForSegue:sender:
                ZIKRouter_replaceMethodWithMethod(class, @selector(prepareForSegue:sender:),
                                                  ZIKViewRouterClass, @selector(ZIKViewRouter_hook_prepareForSegue:sender:));
            }
        } else if (ZIKRouter_classIsSubclassOfClass(class,UIStoryboardSegueClass)) {//hook all UIStoryboardSegue's -perform
            ZIKRouter_replaceMethodWithMethod(class, @selector(perform),
                                              ZIKViewRouterClass, @selector(ZIKViewRouter_hook_seguePerform));
        } else if (ZIKRouter_classIsSubclassOfClass(class, ZIKViewRouterClass)) {
            IMP registerIMP = class_getMethodImplementation(objc_getMetaClass(class_getName(class)), @selector(registerRoutableDestination));
            NSCAssert2(registerIMP, @"Router(%@) must implement +registerRoutableDestination to register destination with %@",class,class);
            void(*registerFunc)(Class, SEL) = (void(*)(Class,SEL))registerIMP;
            if (registerFunc) {
                registerFunc(class,@selector(registerRoutableDestination));
            }
#if ZIKVIEWROUTER_CHECK
            CFMutableSetRef views = (CFMutableSetRef)CFDictionaryGetValue(_check_routerToViewsMap, (__bridge const void *)(class));
            NSSet *viewSet = (__bridge NSSet *)(views);
            NSCAssert3(viewSet.count > 0 || ZIKRouter_classIsSubclassOfClass(class, NSClassFromString(@"ZIKViewRouteAdapter")) || class == NSClassFromString(@"ZIKViewRouteAdapter"), @"This router class(%@) was not resgistered with any view class. Use +[%@ registerView:] to register view in Router(%@)'s +registerRoutableDestination.",class,class,class);
#endif
        }

    });
    
#if ZIKVIEWROUTER_CHECK
    for (Class viewClass in routableViews) {
        NSCAssert1(CFDictionaryGetValue(g_viewToDefaultRouterMap, (__bridge const void *)(viewClass)) != NULL, @"Routable view(%@) is not registered with any view router.",viewClass);
    }
    ZIKRouter_enumerateProtocolList(^(Protocol *protocol) {
        if (protocol_conformsToProtocol(protocol, @protocol(ZIKViewRoutable)) &&
            protocol != @protocol(ZIKViewRoutable)) {
            Class routerClass = (Class)CFDictionaryGetValue(g_viewProtocolToRouterMap, (__bridge const void *)(protocol));
            NSCAssert1(routerClass, @"Declared view protocol(%@) is not registered with any router class!",NSStringFromProtocol(protocol));
            
            CFSetRef viewsRef = CFDictionaryGetValue(_check_routerToViewsMap, (__bridge const void *)(routerClass));
            NSSet *views = (__bridge NSSet *)(viewsRef);
            NSCAssert1(views.count > 0, @"Router(%@) didn't registered with any viewClass", routerClass);
            for (Class viewClass in views) {
                NSCAssert3([viewClass conformsToProtocol:protocol], @"Router(%@)'s viewClass(%@) should conform to registered protocol(%@)",routerClass, viewClass, NSStringFromProtocol(protocol));
            }
        } else if (protocol_conformsToProtocol(protocol, @protocol(ZIKViewModuleRoutable)) &&
                   protocol != @protocol(ZIKViewModuleRoutable)) {
            Class routerClass = (Class)CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(protocol));
            NSCAssert1(routerClass, @"Declared routable config protocol(%@) is not registered with any router class!",NSStringFromProtocol(protocol));
            ZIKViewRouteConfiguration *config = [routerClass defaultRouteConfiguration];
            NSCAssert3([config conformsToProtocol:protocol], @"Router(%@)'s default ZIKViewRouteConfiguration(%@) should conform to registered config protocol(%@)",routerClass, [config class], NSStringFromProtocol(protocol));
        }
    });
#endif
    _isLoadFinished = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouterRegisterCompleteNotification object:nil];
}

#pragma mark Dynamic Discover

void EnumerateRoutersForViewClass(Class viewClass,void(^handler)(Class routerClass)) {
    NSCParameterAssert([viewClass conformsToProtocol:@protocol(ZIKRoutableView)]);
    NSCParameterAssert(handler);
    if (!viewClass) {
        return;
    }
    Class UIViewControllerSuperclass = [UIViewController superclass];
    while (viewClass != UIViewControllerSuperclass) {
        
        if ([viewClass conformsToProtocol:@protocol(ZIKRoutableView)]) {
            CFMutableSetRef routers = (CFMutableSetRef)CFDictionaryGetValue(g_viewToRoutersMap, (__bridge const void *)(viewClass));
            NSSet *routerClasses = (__bridge NSSet *)(routers);
            for (Class class in routerClasses) {
                if (handler) {
                    handler(class);
                }
            }
        } else {
            break;
        }
        viewClass = class_getSuperclass(viewClass);
    }
}

static _Nullable Class ZIKViewRouterToRegisteredView(Class viewClass) {
    NSCParameterAssert([viewClass isSubclassOfClass:[UIView class]] ||
                       [viewClass isSubclassOfClass:[UIViewController class]]);
    NSCParameterAssert([viewClass conformsToProtocol:@protocol(ZIKRoutableView)]);
    NSCAssert(_isLoadFinished, @"Only get router after app did finish launch.");
    NSCAssert(g_viewToDefaultRouterMap, @"Didn't register any viewClass yet.");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_viewToDefaultRouterMap) {
            g_viewToDefaultRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    
    while (viewClass) {
        if (![viewClass conformsToProtocol:@protocol(ZIKRoutableView)]) {
            break;
        }
        Class routerClass = CFDictionaryGetValue(g_viewToDefaultRouterMap, (__bridge const void *)(viewClass));
        if (routerClass) {
            return routerClass;
        } else {
            viewClass = class_getSuperclass(viewClass);
        }
    }
    
    NSCAssert1(NO, @"Didn't register any routerClass for viewClass (%@).",viewClass);
    return nil;
}

_Nullable Class _ZIKViewRouterToView(Protocol *viewProtocol) {
    NSCParameterAssert(viewProtocol);
    NSCAssert(g_viewProtocolToRouterMap, @"Didn't register any protocol yet.");
    NSCAssert(_isLoadFinished, @"Only get router after app did finish launch.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_viewProtocolToRouterMap) {
            g_viewProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    if (!viewProtocol) {
        [ZIKViewRouter _callbackError_invalidProtocolWithAction:@selector(toView) errorDescription:@"ZIKViewRouter.toView() viewProtocol is nil"];
        return nil;
    }
    
    Class routerClass = CFDictionaryGetValue(g_viewProtocolToRouterMap, (__bridge const void *)(viewProtocol));
    if (routerClass) {
        return routerClass;
    }
    [ZIKViewRouter _callbackError_invalidProtocolWithAction:@selector(toView)
                                             errorDescription:@"Didn't find view router for view protocol: %@, this protocol was not registered.",viewProtocol];
    NSCAssert1(NO, @"Didn't find view router for view protocol: %@, this protocol was not registered.",viewProtocol);
    return nil;
}

_Nullable Class _ZIKViewRouterToModule(Protocol *configProtocol) {
    NSCParameterAssert(configProtocol);
    NSCAssert(g_configProtocolToRouterMap, @"Didn't register any protocol yet.");
    NSCAssert(_isLoadFinished, @"Only get router after app did finish launch.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_configProtocolToRouterMap) {
            g_configProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    if (!configProtocol) {
        [ZIKViewRouter _callbackError_invalidProtocolWithAction:@selector(toModule) errorDescription:@"ZIKViewRouter.toModule() configProtocol is nil"];
        return nil;
    }
    
    Class routerClass = CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol));
    if (routerClass) {
        return routerClass;
    }
    
    [ZIKViewRouter _callbackError_invalidProtocolWithAction:@selector(toModule)
                                             errorDescription:@"Didn't find view router for config protocol: %@, this protocol was not registered.",configProtocol];
    NSCAssert1(NO, @"Didn't find view router for config protocol: %@, this protocol was not registered.",configProtocol);
    return nil;
}

#pragma mark Initialize

- (nullable instancetype)initWithConfiguration:(__kindof ZIKViewRouteConfiguration *)configuration removeConfiguration:(nullable __kindof ZIKViewRemoveConfiguration *)removeConfiguration {
    NSParameterAssert([configuration isKindOfClass:[ZIKViewRouteConfiguration class]]);
    
    if (!removeConfiguration) {
        removeConfiguration = [[self class] defaultRemoveConfiguration];
    }
    if (self = [super initWithConfiguration:configuration removeConfiguration:removeConfiguration]) {
        if (![[self class] _validateRouteTypeInConfiguration:configuration]) {
            [self _callbackError_unsupportTypeWithAction:@selector(init)
                                          errorDescription:@"%@ doesn't support routeType:%ld, supported types: %ld",[self class],configuration.routeType,[[self class] supportedRouteTypes]];
            NSAssert(NO, @"%@ doesn't support routeType:%ld, supported types: %ld",[self class],(long)configuration.routeType,(long)[[self class] supportedRouteTypes]);
            return nil;
        } else if (![[self class] _validateRouteSourceNotMissedInConfiguration:configuration] ||
                   ![[self class] _validateRouteSourceClassInConfiguration:configuration]) {
            [self _callbackError_invalidSourceWithAction:@selector(init)
                                          errorDescription:@"Source: (%@) is invalid for configuration: (%@)",configuration.source,configuration];
            NSAssert(NO, @"Source: (%@) is invalid for configuration: (%@)",configuration.source,configuration);
            return nil;
        } else {
            ZIKViewRouteType type = configuration.routeType;
            if (type == ZIKViewRouteTypePerformSegue) {
                if (![[self class] _validateSegueInConfiguration:configuration]) {
                    [self _callbackError_invalidConfigurationWithAction:@selector(performRoute)
                                                         errorDescription:@"SegueConfiguration : (%@) was invalid",configuration.segueConfiguration];
                    NSAssert(NO, @"SegueConfiguration : (%@) was invalid",configuration.segueConfiguration);
                    return nil;
                }
            } else if (type == ZIKViewRouteTypePresentAsPopover) {
                if (![[self class] _validatePopoverInConfiguration:configuration]) {
                    [self _callbackError_invalidConfigurationWithAction:@selector(performRoute)
                                                         errorDescription:@"PopoverConfiguration : (%@) was invalid",configuration.popoverConfiguration];
                    NSAssert(NO, @"PopoverConfiguration : (%@) was invalid",configuration.popoverConfiguration);
                    return nil;
                }
            } else if (type == ZIKViewRouteTypeCustom) {
                BOOL valid = YES;
                if ([[self class] respondsToSelector:@selector(validateCustomRouteConfiguration:removeConfiguration:)]) {
                    valid = [[self class] validateCustomRouteConfiguration:configuration removeConfiguration:removeConfiguration];
                }
                if (!valid) {
                    [self _callbackError_invalidConfigurationWithAction:@selector(performRoute)
                                                         errorDescription:@"Configuration : (%@) was invalid for ZIKViewRouteTypeCustom",configuration];
                    NSAssert(NO, @"Configuration : (%@) was invalid for ZIKViewRouteTypeCustom",configuration);
                    return nil;
                }
            }
        }
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleWillPerformRouteNotification:) name:kZIKViewRouteWillPerformRouteNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleDidPerformRouteNotification:) name:kZIKViewRouteDidPerformRouteNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleWillRemoveRouteNotification:) name:kZIKViewRouteWillRemoveRouteNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleDidRemoveRouteNotification:) name:kZIKViewRouteDidRemoveRouteNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleRemoveRouteCanceledNotification:) name:kZIKViewRouteRemoveRouteCanceledNotification object:nil];
    }
    return self;
}

+ (instancetype)routerFromView:(UIView *)destination source:(UIView *)source {
    NSParameterAssert(destination);
    NSParameterAssert(source);
    if (!destination || !source) {
        return nil;
    }
    NSAssert([self _validateSupportedRouteTypesForUIView], @"Router for UIView only suppourts ZIKViewRouteTypeAddAsSubview, ZIKViewRouteTypeGetDestination and ZIKViewRouteTypeCustom, override +supportedRouteTypes in your router.");
    
    ZIKViewRouteConfiguration *configuration = [self defaultRouteConfiguration];
    configuration.autoCreated = YES;
    configuration.routeType = ZIKViewRouteTypeAddAsSubview;
    configuration.source = source;
    ZIKViewRouter *router = [[self alloc] initWithConfiguration:configuration removeConfiguration:nil];
    [router attachDestination:destination];
    
    return router;
}

+ (instancetype)routerFromSegueIdentifier:(NSString *)identifier sender:(nullable id)sender destination:(UIViewController *)destination source:(UIViewController *)source {
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    
    ZIKViewRouteConfiguration *configuration = [self defaultRouteConfiguration];
    configuration.autoCreated = YES;
    configuration.routeType = ZIKViewRouteTypePerformSegue;
    configuration.source = source;
    configuration.configureSegue(^(ZIKViewRouteSegueConfiguration * _Nonnull segueConfig) {
        segueConfig.identifier = identifier;
        segueConfig.sender = sender;
    });
    
    ZIKViewRouter *router = [[self alloc] initWithConfiguration:configuration removeConfiguration:nil];
    [router attachDestination:destination];
    return router;

}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark

- (void)notifyRouteState:(ZIKRouterState)state {
    if (state == ZIKRouterStateRemoved) {
        self.realRouteType = ZIKViewRouteRealTypeUnknown;
        self.prepared = NO;
    }
    [super notifyRouteState:state];
}

#pragma mark ZIKViewRouterProtocol

+ (void)registerRoutableDestination {
    NSAssert2(NO, @"subclass(%@) must implement +registerRoutableDestination to register destination with %@",self,self);
}

+ (ZIKViewRouteTypeMask)supportedRouteTypes {
    return ZIKViewRouteTypeMaskUIViewControllerDefault;
}

- (id)destinationWithConfiguration:(__kindof ZIKViewRouteConfiguration *)configuration {
    NSAssert(NO, @"Router: %@ not conforms to ZIKViewRouterProtocol！",[self class]);
    return nil;
}

+ (BOOL)destinationPrepared:(id)destination {
    NSAssert(self != [ZIKViewRouter class], @"Check destination prepared with it's router.");
    return YES;
}

- (void)prepareDestination:(id)destination configuration:(__kindof ZIKViewRouteConfiguration *)configuration {
    NSAssert(self != [ZIKViewRouter class], @"Prepare destination with it's router.");
}

- (void)didFinishPrepareDestination:(id)destination configuration:(nonnull __kindof ZIKViewRouteConfiguration *)configuration {
    NSAssert([self class] != [ZIKViewRouter class] ||
             configuration.routeType == ZIKViewRouteTypePerformSegue,
             @"Only ZIKViewRouteTypePerformSegue can use ZIKViewRouter class to perform route, otherwise, use a subclass of ZIKViewRouter for destination.");
}

+ (ZIKViewRouteConfiguration *)defaultRouteConfiguration {
    return [ZIKViewRouteConfiguration new];
}

+ (__kindof ZIKViewRemoveConfiguration *)defaultRemoveConfiguration {
    return [ZIKViewRemoveConfiguration new];
}

+ (BOOL)completeSynchronously {
    return YES;
}

#pragma mark Perform Route

- (BOOL)canPerformCustomRoute {
    return NO;
}

- (BOOL)_canPerformWithErrorMessage:(NSString **)message {
    ZIKRouterState state = self.state;
    if (state == ZIKRouterStateRouting) {
        if (message) {
            *message = @"Router is routing.";
        }
        return NO;
    }
    if (state == ZIKRouterStateRemoving) {
        if (message) {
            *message = @"Router is removing.";
        }
        return NO;
    }
    if (state == ZIKRouterStateRouted) {
        if (message) {
            *message = @"Router is routed, can't perform route after remove.";
        }
        return NO;
    }
    
    ZIKViewRouteType type = self.original_configuration.routeType;
    if (type == ZIKViewRouteTypeCustom) {
        BOOL canPerform = [self canPerformCustomRoute];
        if (canPerform && message) {
            *message = @"Can't perform custom route.";
        }
        return canPerform;
    }
    id source = self.original_configuration.source;
    if (!source) {
        if (type != ZIKViewRouteTypeGetDestination) {
            if (message) {
                *message = @"Source was dealloced.";
            }
            return NO;
        }
    }
    
    id destination = self.destination;
    switch (type) {
        case ZIKViewRouteTypePush: {
            if (![[self class] _validateSourceInNavigationStack:source]) {
                if (message) {
                    *message = [NSString stringWithFormat:@"Source (%@) is not in any navigation stack now, can't push.",source];
                }
                return NO;
            }
            if (destination && ![[self class] _validateDestination:destination notInNavigationStackOfSource:source]) {
                if (message) {
                    *message = [NSString stringWithFormat:@"Destination (%@) is already in source (%@)'s navigation stack, can't push.",destination,source];
                }
                return NO;
            }
            break;
        }
            
        case ZIKViewRouteTypePresentModally:
        case ZIKViewRouteTypePresentAsPopover: {
            if (![[self class] _validateSourceNotPresentedAnyView:source]) {
                if (message) {
                    *message = [NSString stringWithFormat:@"Source (%@) presented another view controller (%@), can't present destination now.",source,[source presentedViewController]];
                }
                return NO;
            }
            break;
        }
        default:
            break;
    }
    return YES;
}

///override superclass
- (void)performRouteWithSuccessHandler:(void(^)(void))performerSuccessHandler
                          errorHandler:(void(^)(SEL routeAction, NSError *error))performerErrorHandler {
    ZIKRouterState state = self.state;
    if (state == ZIKRouterStateRouting) {
        [self _callbackError_errorCode:ZIKViewRouteErrorOverRoute
                            errorHandler:performerErrorHandler
                                  action:@selector(performRoute)
                        errorDescription:@"%@ is routing, can't perform route again",self];
        return;
    } else if (state == ZIKRouterStateRouted) {
        [self _callbackError_actionFailedWithAction:@selector(performRoute)
                                     errorDescription:@"%@ 's state is routed, can't perform route again",self];
        return;
    } else if (state == ZIKRouterStateRemoving) {
        [self _callbackError_errorCode:ZIKViewRouteErrorActionFailed
                            errorHandler:performerErrorHandler
                                  action:@selector(performRoute)
                        errorDescription:@"%@ 's state is removing, can't perform route again",self];
        return;
    }
    [super performRouteWithSuccessHandler:performerSuccessHandler errorHandler:performerErrorHandler];
}

///override superclass
- (void)performWithConfiguration:(__kindof ZIKViewRouteConfiguration *)configuration {
    NSParameterAssert(configuration);
    NSAssert([[[self class] defaultRouteConfiguration] isKindOfClass:[configuration class]], @"When using custom configuration class，you must override +defaultRouteConfiguration to return your custom configuration instance.");
    [[self class] increaseRecursiveDepth];
    if ([[self class] _validateInfiniteRecursion] == NO) {
        [self _callbackError_infiniteRecursionWithAction:@selector(performRoute) errorDescription:@"Infinite recursion for performing route detected, see -prepareDestination:configuration: for more detail. Recursive call stack:\n%@",[NSThread callStackSymbols]];
        [[self class] decreaseRecursiveDepth];
        return;
    }
    if (configuration.routeType == ZIKViewRouteTypePerformSegue) {
        [self performRouteOnDestination:nil configuration:configuration];
        [[self class] decreaseRecursiveDepth];
        return;
    }
    
    if ([NSThread isMainThread]) {
        [super performWithConfiguration:configuration];
        [[self class] decreaseRecursiveDepth];
    } else {
        NSAssert(NO, @"%@ performRoute should only be called in main thread!",self);
        dispatch_sync(dispatch_get_main_queue(), ^{
            [super performWithConfiguration:configuration];
            [[self class] decreaseRecursiveDepth];
        });
    }
}

- (void)performRouteOnDestination:(nullable id)destination configuration:(__kindof ZIKViewRouteConfiguration *)configuration {
    [self notifyRouteState:ZIKRouterStateRouting];
    
    if (!destination &&
        [[self class] _validateDestinationShouldExistInConfiguration:configuration]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_actionFailedWithAction:@selector(performRoute) errorDescription:@"-destinationWithConfiguration: of router: %@ return nil when performRoute, configuration may be invalid or router has bad impletmentation in -destinationWithConfiguration. Configuration: %@",[self class],configuration];
        return;
    } else if (![[self class] _validateDestinationClass:destination inConfiguration:configuration]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_actionFailedWithAction:@selector(performRoute) errorDescription:@"Bad impletment in destinationWithConfiguration: of router: %@, invalid destination: %@ !",[self class],destination];
        NSAssert(NO, @"Bad impletment in destinationWithConfiguration: of router: %@, invalid destination: %@ !",[self class],destination);
        return;
    }
    
    if (![[self class] _validateRouteSourceNotMissedInConfiguration:configuration]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_invalidSourceWithAction:@selector(performRoute)
                                      errorDescription:@"Source was dealloced when performRoute on (%@)",self];
        return;
    }
    
    id source = configuration.source;
    ZIKViewRouteType routeType = configuration.routeType;
    switch (routeType) {
        case ZIKViewRouteTypePush:
            [self _performPushOnDestination:destination fromSource:source];
            break;
            
        case ZIKViewRouteTypePresentModally:
            [self _performPresentModallyOnDestination:destination fromSource:source];
            break;
            
        case ZIKViewRouteTypePresentAsPopover:
            [self _performPresentAsPopoverOnDestination:destination fromSource:source popoverConfiguration:configuration.popoverConfiguration];
            break;
            
        case ZIKViewRouteTypeAddAsChildViewController:
            [self _performAddChildViewControllerOnDestination:destination fromSource:source];
            break;
            
        case ZIKViewRouteTypePerformSegue:
            [self _performSegueWithIdentifier:configuration.segueConfiguration.identifier fromSource:source sender:configuration.segueConfiguration.sender];
            break;
            
        case ZIKViewRouteTypeShow:
            [self _performShowOnDestination:destination fromSource:source];
            break;
            
        case ZIKViewRouteTypeShowDetail:
            [self _performShowDetailOnDestination:destination fromSource:source];
            break;
            
        case ZIKViewRouteTypeAddAsSubview:
            [self _performAddSubviewOnDestination:destination fromSource:source];
            break;
            
        case ZIKViewRouteTypeCustom:
            [self _performCustomOnDestination:destination fromSource:source];
            break;
            
        case ZIKViewRouteTypeGetDestination:
            [self _performGetDestination:destination fromSource:source];
            break;
    }
}

- (void)_performPushOnDestination:(UIViewController *)destination fromSource:(UIViewController *)source {
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    
    if (![[self class] _validateSourceInNavigationStack:source]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_invalidSourceWithAction:@selector(performRoute)
                                      errorDescription:@"Source: (%@) is not in any navigation stack when perform push.",source];
        return;
    }
    if (![[self class] _validateDestination:destination notInNavigationStackOfSource:source]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_overRouteWithAction:@selector(performRoute)
                                  errorDescription:@"Pushing the same view controller instance more than once is not supported. Source: (%@), destination: (%@), viewControllers in navigation stack: (%@)",source,destination,source.navigationController.viewControllers];
        return;
    }
    UIViewController *wrappedDestination = [self _wrappedDestination:destination];
    [self beginPerformRoute];
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePush)];
    self.realRouteType = ZIKViewRouteRealTypePush;
    [source.navigationController pushViewController:wrappedDestination animated:self.original_configuration.animated];
    [ZIKViewRouter _completeWithtransitionCoordinator:source.navigationController.transitionCoordinator
                                   transitionCompletion:^{
        [self endPerformRouteWithSuccess];
    }];
}

- (void)_performPresentModallyOnDestination:(UIViewController *)destination fromSource:(UIViewController *)source {
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    
    if (![[self class] _validateSourceNotPresentedAnyView:source]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_invalidSourceWithAction:@selector(performRoute)
                                      errorDescription:@"Warning: Attempt to present %@ on %@ whose view is not in the window hierarchy! %@ already presented %@.",destination,source,source,source.presentedViewController];
        return;
    }
    if (![[self class] _validateSourceInWindowHierarchy:source]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_invalidSourceWithAction:@selector(performRoute)
                                      errorDescription:@"Warning: Attempt to present %@ on %@ whose view is not in the window hierarchy! %@ 's view not in any superview.",destination,source,source];
        return;
    }
    UIViewController *wrappedDestination = [self _wrappedDestination:destination];
    [self beginPerformRoute];
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePresentModally)];
    self.realRouteType = ZIKViewRouteRealTypePresentModally;
    [source presentViewController:wrappedDestination animated:self.original_configuration.animated completion:^{
        [self endPerformRouteWithSuccess];
    }];
}

- (void)_performPresentAsPopoverOnDestination:(UIViewController *)destination fromSource:(UIViewController *)source popoverConfiguration:(ZIKViewRoutePopoverConfiguration *)popoverConfiguration {
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    
    if (!popoverConfiguration) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_invalidConfigurationWithAction:@selector(performRoute)
                                             errorDescription:@"Miss popoverConfiguration when perform presentAsPopover on source: (%@), router: (%@).",source,self];
        return;
    }
    if (![[self class] _validateSourceNotPresentedAnyView:source]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_invalidSourceWithAction:@selector(performRoute)
                                      errorDescription:@"Warning: Attempt to present %@ on %@ whose view is not in the window hierarchy! %@ already presented %@.",destination,source,source,source.presentedViewController];
        return;
    }
    if (![[self class] _validateSourceInWindowHierarchy:source]) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_invalidSourceWithAction:@selector(performRoute)
                                      errorDescription:@"Warning: Attempt to present %@ on %@ whose view is not in the window hierarchy! %@ 's view not in any superview.",destination,source,source];
        return;
    }
    
    ZIKViewRouteRealType realRouteType = ZIKViewRouteRealTypePresentAsPopover;
    ZIKViewRouteConfiguration *configuration = self.original_configuration;
    
    if (NSClassFromString(@"UIPopoverPresentationController")) {
        destination.modalPresentationStyle = UIModalPresentationPopover;
        UIPopoverPresentationController *popoverPresentationController = destination.popoverPresentationController;
        
        if (popoverConfiguration.barButtonItem) {
            popoverPresentationController.barButtonItem = popoverConfiguration.barButtonItem;
        } else if (popoverConfiguration.sourceView) {
            popoverPresentationController.sourceView = popoverConfiguration.sourceView;
            if (popoverConfiguration.sourceRectConfiged) {
                popoverPresentationController.sourceRect = popoverConfiguration.sourceRect;
            }
        } else {
            [self notifyRouteState:ZIKRouterStateRouteFailed];
            [self _callbackError_invalidConfigurationWithAction:@selector(performRoute)
                                                 errorDescription:@"Invalid popoverConfiguration: (%@) when perform presentAsPopover on source: (%@), router: (%@).",popoverConfiguration,source,self];
            
            return;
        }
        if (popoverConfiguration.delegate) {
            NSAssert([popoverConfiguration.delegate conformsToProtocol:@protocol(UIPopoverPresentationControllerDelegate)], @"delegate should conforms to UIPopoverPresentationControllerDelegate");
            popoverPresentationController.delegate = popoverConfiguration.delegate;
        }
        if (popoverConfiguration.passthroughViews) {
            popoverPresentationController.passthroughViews = popoverConfiguration.passthroughViews;
        }
        if (popoverConfiguration.backgroundColor) {
            popoverPresentationController.backgroundColor = popoverConfiguration.backgroundColor;
        }
        if (popoverConfiguration.popoverLayoutMarginsConfiged) {
            popoverPresentationController.popoverLayoutMargins = popoverConfiguration.popoverLayoutMargins;
        }
        if (popoverConfiguration.popoverBackgroundViewClass) {
            popoverPresentationController.popoverBackgroundViewClass = popoverConfiguration.popoverBackgroundViewClass;
        }
        
        UIViewController *wrappedDestination = [self _wrappedDestination:destination];
        [self beginPerformRoute];
        self.realRouteType = realRouteType;
        [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePresentAsPopover)];
        [source presentViewController:wrappedDestination animated:configuration.animated completion:^{
            [self endPerformRouteWithSuccess];
        }];
        return;
    }
    
    //iOS7 iPad
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UIViewController *wrappedDestination = [self _wrappedDestination:destination];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
        UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:wrappedDestination];
#pragma clang diagnostic pop
        objc_setAssociatedObject(destination, "zikrouter_popover", popover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        if (popoverConfiguration.delegate) {
            NSAssert([popoverConfiguration.delegate conformsToProtocol:@protocol(UIPopoverControllerDelegate)], @"delegate should conforms to UIPopoverControllerDelegate");
            popover.delegate = (id)popoverConfiguration.delegate;
        }
        
        if (popoverConfiguration.passthroughViews) {
            popover.passthroughViews = popoverConfiguration.passthroughViews;
        }
        if (popoverConfiguration.backgroundColor) {
            popover.backgroundColor = popoverConfiguration.backgroundColor;
        }
        if (popoverConfiguration.popoverLayoutMarginsConfiged) {
            popover.popoverLayoutMargins = popoverConfiguration.popoverLayoutMargins;
        }
        if (popoverConfiguration.popoverBackgroundViewClass) {
            popover.popoverBackgroundViewClass = popoverConfiguration.popoverBackgroundViewClass;
        }
        self.routingFromInternal = YES;
        [self prepareForPerformRouteOnDestination:destination];
        [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePresentAsPopover)];
        if (popoverConfiguration.barButtonItem) {
            self.realRouteType = realRouteType;
            [ZIKViewRouter AOP_notifyAll_router:self willPerformRouteOnDestination:destination fromSource:source];
            [popover presentPopoverFromBarButtonItem:popoverConfiguration.barButtonItem permittedArrowDirections:popoverConfiguration.permittedArrowDirections animated:configuration.animated];
        } else if (popoverConfiguration.sourceView) {
            self.realRouteType = realRouteType;
            [ZIKViewRouter AOP_notifyAll_router:self willPerformRouteOnDestination:destination fromSource:source];
            [popover presentPopoverFromRect:popoverConfiguration.sourceRect inView:popoverConfiguration.sourceView permittedArrowDirections:popoverConfiguration.permittedArrowDirections animated:configuration.animated];
        } else {
            [self notifyRouteState:ZIKRouterStateRouteFailed];
            [self _callbackError_invalidConfigurationWithAction:@selector(performRoute)
                                                 errorDescription:@"Invalid popoverConfiguration: (%@) when perform presentAsPopover on source: (%@), router: (%@).",popoverConfiguration,source,self];
            self.routingFromInternal = NO;
            return;
        }
        
        [ZIKViewRouter _completeWithtransitionCoordinator:popover.contentViewController.transitionCoordinator
                                       transitionCompletion:^{
            [self endPerformRouteWithSuccess];
        }];
        return;
    }
    
    //iOS7 iPhone
    UIViewController *wrappedDestination = [self _wrappedDestination:destination];
    [self beginPerformRoute];
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePresentAsPopover)];
    self.realRouteType = ZIKViewRouteRealTypePresentModally;
    [source presentViewController:wrappedDestination animated:configuration.animated completion:^{
        [self endPerformRouteWithSuccess];
    }];
}

- (void)_performSegueWithIdentifier:(NSString *)identifier fromSource:(UIViewController *)source sender:(nullable id)sender {
    
    ZIKViewRouteConfiguration *configuration = self.original_configuration;
    ZIKViewRouteSegueConfiguration *segueConfig = configuration.segueConfiguration;
    segueConfig.segueSource = nil;
    segueConfig.segueDestination = nil;
    segueConfig.destinationStateBeforeRoute = nil;
    
    self.routingFromInternal = YES;
    //Set nil in -ZIKViewRouter_hook_prepareForSegue:sender:
    [source setZix_sourceViewRouter:self];
    
    /*
     Hook UIViewController's -prepareForSegue:sender: and UIStoryboardSegue's -perform to prepare and complete
     Call -prepareForPerformRouteOnDestination in -ZIKViewRouter_hook_prepareForSegue:sender:
     Call +AOP_notifyAll_router:willPerformRouteOnDestination: in -ZIKViewRouter_hook_prepareForSegue:sender:
     Call -notifyRouteState:ZIKRouterStateRouted
          -notifyPerformRouteSuccessWithDestination:
          +AOP_notifyAll_router:didPerformRouteOnDestination:
     in -ZIKViewRouter_hook_seguePerform
     */
    [source performSegueWithIdentifier:identifier sender:sender];
    
    UIViewController *destination = segueConfig.segueDestination;//segueSource and segueDestination was set in -ZIKViewRouter_hook_prepareForSegue:sender:
    
    /*When perform a unwind segue, if destination's -canPerformUnwindSegueAction:fromViewController:withSender: return NO, here will be nil
     This inspection relies on synchronized call -prepareForSegue:sender: and -canPerformUnwindSegueAction:fromViewController:withSender: in -performSegueWithIdentifier:sender:
     */
    if (!destination) {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_segueNotPerformedWithAction:@selector(performRoute) errorDescription:@"destination can't perform segue identitier:%@ now",identifier];
        self.routingFromInternal = NO;
        return;
    }
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    NSAssert(![source zix_sourceViewRouter], @"Didn't set sourceViewRouter to nil in -ZIKViewRouter_hook_prepareForSegue:sender:, router will not be dealloced before source was dealloced");
}

- (void)_performShowOnDestination:(UIViewController *)destination fromSource:(UIViewController *)source {
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeShow)];
    UIViewController *wrappedDestination = [self _wrappedDestination:destination];
    ZIKPresentationState *destinationStateBeforeRoute = [destination zix_presentationState];
    [self beginPerformRoute];
    
    [source showViewController:wrappedDestination sender:self.original_configuration.sender];
    
    id<UIViewControllerTransitionCoordinator> transitionCoordinator = [source zix_currentTransitionCoordinator];
    if (!transitionCoordinator) {
        transitionCoordinator = [destination zix_currentTransitionCoordinator];
    }
    [ZIKViewRouter _completeRouter:self
      analyzeRouteTypeForDestination:destination
                              source:source
         destinationStateBeforeRoute:destinationStateBeforeRoute
               transitionCoordinator:transitionCoordinator
                          completion:^{
                              [self endPerformRouteWithSuccess];
                          }];
}

- (void)_performShowDetailOnDestination:(UIViewController *)destination fromSource:(UIViewController *)source {
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeShowDetail)];
    UIViewController *wrappedDestination = [self _wrappedDestination:destination];
    ZIKPresentationState *destinationStateBeforeRoute = [destination zix_presentationState];
    [self beginPerformRoute];
    
    [source showDetailViewController:wrappedDestination sender:self.original_configuration.sender];
    
    id<UIViewControllerTransitionCoordinator> transitionCoordinator = [source zix_currentTransitionCoordinator];
    if (!transitionCoordinator) {
        transitionCoordinator = [destination zix_currentTransitionCoordinator];
    }
    [ZIKViewRouter _completeRouter:self
      analyzeRouteTypeForDestination:destination
                              source:source
         destinationStateBeforeRoute:destinationStateBeforeRoute
               transitionCoordinator:transitionCoordinator
                          completion:^{
                              [self endPerformRouteWithSuccess];
                          }];
}

- (void)_performAddChildViewControllerOnDestination:(UIViewController *)destination fromSource:(UIViewController *)source {
    NSParameterAssert([destination isKindOfClass:[UIViewController class]]);
    NSParameterAssert([source isKindOfClass:[UIViewController class]]);
    UIViewController *wrappedDestination = [self _wrappedDestination:destination];
//    [self beginPerformRoute];
    self.routingFromInternal = YES;
    [self prepareForPerformRouteOnDestination:destination];
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeAddAsChildViewController)];
    [source addChildViewController:wrappedDestination];
    
//    self.realRouteType = ZIKViewRouteRealTypeAddAsChildViewController;
    self.realRouteType = ZIKViewRouteRealTypeUnknown;
//    [self endPerformRouteWithSuccess];
    [self notifyRouteState:ZIKRouterStateRouted];
    self.routingFromInternal = NO;
    [self notifyPerformRouteSuccessWithDestination:destination];
}

- (void)_performAddSubviewOnDestination:(UIView *)destination fromSource:(UIView *)source {
    NSParameterAssert([destination isKindOfClass:[UIView class]]);
    NSParameterAssert([source isKindOfClass:[UIView class]]);
    [self beginPerformRoute];
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeAddAsSubview)];
    
    [source addSubview:destination];
    
    self.realRouteType = ZIKViewRouteRealTypeAddAsSubview;
    [self endPerformRouteWithSuccess];
}

- (void)_performCustomOnDestination:(id)destination fromSource:(nullable id)source {
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeCustom)];
    self.realRouteType = ZIKViewRouteRealTypeCustom;
    if ([self respondsToSelector:@selector(performCustomRouteOnDestination:fromSource:configuration:)]) {
        [self performCustomRouteOnDestination:destination fromSource:source configuration:self.original_configuration];
    } else {
        [self notifyRouteState:ZIKRouterStateRouteFailed];
        [self _callbackError_actionFailedWithAction:@selector(performRoute) errorDescription:@"Perform custom route but router(%@) didn't implement -performCustomRouteOnDestination:fromSource:configuration:",[self class]];
        NSAssert(NO, @"Perform custom route but router(%@) didn't implement -performCustomRouteOnDestination:fromSource:configuration:",[self class]);
    }
}

- (void)_performGetDestination:(id)destination fromSource:(nullable id)source {
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeGetDestination)];
    self.routingFromInternal = YES;
    [self prepareForPerformRouteOnDestination:destination];
    self.stateBeforeRoute = [destination zix_presentationState];
    self.realRouteType = ZIKViewRouteRealTypeUnknown;
    [self notifyRouteState:ZIKRouterStateRouted];
    self.routingFromInternal = NO;
    [self notifyPerformRouteSuccessWithDestination:destination];
}

- (UIViewController *)_wrappedDestination:(UIViewController *)destination {
    self.container = nil;
    ZIKViewRouteConfiguration *configuration = self.original_configuration;
    if (!configuration.containerWrapper) {
        return destination;
    }
    UIViewController<ZIKViewRouteContainer> *container = configuration.containerWrapper(destination);
    
    NSString *errorDescription;
    if (!container) {
        errorDescription = @"container is nil";
    } else if ([container isKindOfClass:[UINavigationController class]]) {
        if (configuration.routeType == ZIKViewRouteTypePush) {
            errorDescription = [NSString stringWithFormat:@"navigationController:(%@) can't be pushed into another navigationController",container];
        } else if (configuration.routeType == ZIKViewRouteTypeShow
                   && [configuration.source isKindOfClass:[UIViewController class]]
                   && [(UIViewController *)configuration.source navigationController]) {
            errorDescription = [NSString stringWithFormat:@"navigationController:(%@) can't be pushed into another navigationController",container];
        } else if (configuration.routeType == ZIKViewRouteTypeShowDetail
                   && [configuration.source isKindOfClass:[UIViewController class]]
                   && [(UIViewController *)configuration.source splitViewController].isCollapsed &&
                   [[[(UIViewController *)configuration.source splitViewController].viewControllers firstObject] isKindOfClass:[UINavigationController class]]) {
            errorDescription = [NSString stringWithFormat:@"navigationController:(%@) can't be pushed into another navigationController",container];
        } else if ([[(UINavigationController *)container viewControllers] firstObject] != destination) {
            errorDescription = [NSString stringWithFormat:@"container:(%@) must set destination as root view controller, destination:(%@), container's viewcontrollers:(%@)",container,destination,[(UINavigationController *)container viewControllers]];
        }
    } else if ([container isKindOfClass:[UITabBarController class]]) {
        if (![[(UITabBarController *)container viewControllers] containsObject:destination]) {
            errorDescription = [NSString stringWithFormat:@"container:(%@) must contains destination in it's viewControllers, destination:(%@), container's viewcontrollers:(%@)",container,destination,[(UITabBarController *)container viewControllers]];
        }
    } else if ([container isKindOfClass:[UISplitViewController class]]) {
        if (configuration.routeType == ZIKViewRouteTypePush) {
            errorDescription = [NSString stringWithFormat:@"Split View Controllers cannot be pushed to a Navigation Controller %@",destination];
        } else if (configuration.routeType == ZIKViewRouteTypeShow
                   && [configuration.source isKindOfClass:[UIViewController class]]
                   && [(UIViewController *)configuration.source navigationController]) {
            errorDescription = [NSString stringWithFormat:@"Split View Controllers cannot be pushed to a Navigation Controller %@",destination];
        } else if (configuration.routeType == ZIKViewRouteTypeShowDetail
                   && [configuration.source isKindOfClass:[UIViewController class]]
                   && [(UIViewController *)configuration.source splitViewController].isCollapsed &&
                   [[[(UIViewController *)configuration.source splitViewController].viewControllers firstObject] isKindOfClass:[UINavigationController class]]) {
            errorDescription = [NSString stringWithFormat:@"Split View Controllers cannot be pushed to a Navigation Controller %@",destination];
        } else if (![[(UISplitViewController *)container viewControllers] containsObject:destination]) {
            errorDescription = [NSString stringWithFormat:@"container:(%@) must contains destination in it's viewControllers, destination:(%@), container's viewcontrollers:(%@)",container,destination,[(UITabBarController *)container viewControllers]];
        }
    }
    if (errorDescription) {
        [self _callbackError_invalidContainerWithAction:@selector(performRoute) errorDescription:@"containerWrapper returns invalid container: %@",errorDescription];
        NSAssert(NO, @"containerWrapper returns invalid container");
        return destination;
    }
    self.container = container;
    return container;
}

+ (void)_prepareDestinationFromExternal:(id)destination router:(ZIKViewRouter *)router performer:(nullable id)performer {
    NSParameterAssert(destination);
    NSParameterAssert(router);
    
    if (![[router class] destinationPrepared:destination]) {
        if (!performer) {
            NSString *description = [NSString stringWithFormat:@"Can't find which custom UIView or UIViewController added destination:(%@) as subview, so we can't notify the performer to config the destination. You may add destination to a superview in code directly, and the superview is not a custom class. Please change your code and add subview by a custom view router with ZIKViewRouteTypeAddAsSubview. CallStack: %@",destination, [NSThread callStackSymbols]];
            [self _callbackError_invalidPerformerWithAction:@selector(performRoute) errorDescription:description];
            NSAssert(NO, description);
        }
        
        if ([performer respondsToSelector:@selector(prepareDestinationFromExternal:configuration:)]) {
            ZIKViewRouteConfiguration *config = router.original_configuration;
            id source = config.source;
            ZIKViewRouteType routeType = config.routeType;
            ZIKViewRouteSegueConfiguration *segueConfig = config.segueConfiguration;
            BOOL handleExternalRoute = config.handleExternalRoute;
            [performer prepareDestinationFromExternal:destination configuration:config];
            if (config.source != source) {
                config.source = source;
            }
            if (config.routeType != routeType) {
                config.routeType = routeType;
            }
            if (segueConfig.identifier && ![config.segueConfiguration.identifier isEqualToString:segueConfig.identifier]) {
                config.segueConfiguration = segueConfig;
            }
            if (config.handleExternalRoute != handleExternalRoute) {
                config.handleExternalRoute = handleExternalRoute;
            }
        } else {
            [router _callbackError_invalidSourceWithAction:@selector(performRoute) errorDescription:@"Destination %@ 's performer :%@ missed -prepareDestinationFromExternal:configuration: to config destination.",destination, performer];
            NSAssert(NO, @"Destination %@ 's performer :%@ missed -prepareDestinationFromExternal:configuration: to config destination.",destination, performer);
        }
    }
    
    [router prepareForPerformRouteOnDestination:destination];
}

- (void)prepareForPerformRouteOnDestination:(id)destination {
    ZIKViewRouteConfiguration *configuration = self.original_configuration;
    if (configuration.prepareForRoute) {
        configuration.prepareForRoute(destination);
    }
    if ([self respondsToSelector:@selector(prepareDestination:configuration:)]) {
        [self prepareDestination:destination configuration:configuration];
    }
    if ([self respondsToSelector:@selector(didFinishPrepareDestination:configuration:)]) {
        [self didFinishPrepareDestination:destination configuration:configuration];
    }
}

+ (void)_completeRouter:(ZIKViewRouter *)router
analyzeRouteTypeForDestination:(UIViewController *)destination
                   source:(UIViewController *)source
destinationStateBeforeRoute:(ZIKPresentationState *)destinationStateBeforeRoute
    transitionCoordinator:(nullable id <UIViewControllerTransitionCoordinator>)transitionCoordinator
               completion:(void(^)(void))completion {
    [ZIKViewRouter _completeWithtransitionCoordinator:transitionCoordinator transitionCompletion:^{
        ZIKPresentationState *destinationStateAfterRoute = [destination zix_presentationState];
        if ([destinationStateBeforeRoute isEqual:destinationStateAfterRoute]) {
            router.realRouteType = ZIKViewRouteRealTypeCustom;//maybe ZIKViewRouteRealTypeUnwind, but we just need to know this route can't be remove
            NSLog(@"⚠️Warning: segue(%@) 's destination(%@)'s state was not changed after perform route from source: %@. current state: %@. You may override %@'s -showViewController:sender:/-showDetailViewController:sender:/-presentViewController:animated:completion:/-pushViewController:animated: or use a custom segue, but didn't perform real presentation, or your presentation was async.",self,destination,source,destinationStateAfterRoute,source);
        } else {
            ZIKViewRouteDetailType routeType = [ZIKPresentationState detailRouteTypeFromStateBeforeRoute:destinationStateBeforeRoute stateAfterRoute:destinationStateAfterRoute];
            router.realRouteType = [[router class] _realRouteTypeFromDetailType:routeType];
        }
        if (completion) {
            completion();
        }
    }];
}

+ (void)_completeWithtransitionCoordinator:(nullable id <UIViewControllerTransitionCoordinator>)transitionCoordinator transitionCompletion:(void(^)(void))completion {
    NSParameterAssert(completion);
    //If user use a custom transition from source to destination, such as methods in UIView(UIViewAnimationWithBlocks) or UIView (UIViewKeyframeAnimations), the transitionCoordinator will be nil, route will complete before animation complete
    if (!transitionCoordinator) {
        completion();
        return;
    }
    [transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        completion();
    }];
}

- (void)notifyPerformRouteSuccessWithDestination:(id)destination {
    ZIKViewRouteConfiguration *configuration = self.original_configuration;
    if (configuration.routeCompletion) {
        configuration.routeCompletion(destination);
    }
    [super notifySuccessWithAction:@selector(performRoute)];
}

- (void)beginPerformRoute {
    NSAssert(self.state == ZIKRouterStateRouting, @"state should be routing when begin to route.");
    self.retainedSelf = self;
    self.routingFromInternal = YES;
    id destination = self.destination;
    id source = self.original_configuration.source;
    [self prepareForPerformRouteOnDestination:destination];
    [ZIKViewRouter AOP_notifyAll_router:self willPerformRouteOnDestination:destination fromSource:source];
}

- (void)endPerformRouteWithSuccess {
    NSAssert(self.state == ZIKRouterStateRouting, @"state should be routing when end route.");
    id destination = self.destination;
    id source = self.original_configuration.source;
    [self notifyRouteState:ZIKRouterStateRouted];
    [self notifyPerformRouteSuccessWithDestination:destination];
    [ZIKViewRouter AOP_notifyAll_router:self didPerformRouteOnDestination:destination fromSource:source];
    self.routingFromInternal = NO;
    self.retainedSelf = nil;
}

- (void)endPerformRouteWithError:(NSError *)error {
    NSParameterAssert(error);
    NSAssert(self.state == ZIKRouterStateRouting, @"state should be routing when end route.");
    [self notifyRouteState:ZIKRouterStateRouteFailed];
    [self _callbackErrorWithAction:@selector(performRoute) error:error];
    self.routingFromInternal = NO;
    self.retainedSelf = nil;
}

//+ (ZIKViewRouteRealType)_realRouteTypeForViewController:(UIViewController *)destination {
//    ZIKViewRouteType routeType = [destination zix_routeType];
//    return [self _realRouteTypeForRouteTypeFromViewController:routeType];
//}

///routeType must from -[viewController zix_routeType]
+ (ZIKViewRouteRealType)_realRouteTypeForRouteTypeFromViewController:(ZIKViewRouteType)routeType {
    ZIKViewRouteRealType realRouteType;
    switch (routeType) {
        case ZIKViewRouteTypePush:
            realRouteType = ZIKViewRouteRealTypePush;
            break;
            
        case ZIKViewRouteTypePresentModally:
            realRouteType = ZIKViewRouteRealTypePresentModally;
            break;
            
        case ZIKViewRouteTypePresentAsPopover:
            realRouteType = ZIKViewRouteRealTypePresentAsPopover;
            break;
            
        case ZIKViewRouteTypeAddAsChildViewController:
            realRouteType = ZIKViewRouteRealTypeAddAsChildViewController;
            break;
            
        case ZIKViewRouteTypeShow:
            realRouteType = ZIKViewRouteRealTypeCustom;
            break;
            
        case ZIKViewRouteTypeShowDetail:
            realRouteType = ZIKViewRouteRealTypeCustom;
            break;
            
        default:
            realRouteType = ZIKViewRouteRealTypeCustom;
            break;
    }
    return realRouteType;
}

+ (ZIKViewRouteRealType)_realRouteTypeFromDetailType:(ZIKViewRouteDetailType)detailType {
    ZIKViewRouteRealType realType;
    switch (detailType) {
        case ZIKViewRouteDetailTypePush:
        case ZIKViewRouteDetailTypeParentPushed:
            realType = ZIKViewRouteRealTypePush;
            break;
            
        case ZIKViewRouteDetailTypePresentModally:
            realType = ZIKViewRouteRealTypePresentModally;
            break;
            
        case ZIKViewRouteDetailTypePresentAsPopover:
            realType = ZIKViewRouteRealTypePresentAsPopover;
            break;
            
        case ZIKViewRouteDetailTypeAddAsChildViewController:
            realType = ZIKViewRouteRealTypeAddAsChildViewController;
            break;
            
        case ZIKViewRouteDetailTypeRemoveFromParentViewController:
        case ZIKViewRouteDetailTypeRemoveFromNavigationStack:
        case ZIKViewRouteDetailTypeDismissed:
        case ZIKViewRouteDetailTypeRemoveAsSplitMaster:
        case ZIKViewRouteDetailTypeRemoveAsSplitDetail:
            realType = ZIKViewRouteRealTypeUnwind;
            break;
            
        default:
            realType = ZIKViewRouteRealTypeCustom;
            break;
    }
    return realType;
}

#pragma mark Remove Route

- (BOOL)canRemove {
    NSAssert([NSThread isMainThread], @"Always check state in main thread, bacause state may change in main thread after you check the state in child thread.");
    return [self _canRemoveWithErrorMessage:NULL];
}

- (BOOL)canRemoveCustomRoute {
    return NO;
}

- (BOOL)_canRemoveWithErrorMessage:(NSString **)message {
    ZIKViewRouteConfiguration *configuration = self.original_configuration;
    if (!configuration) {
        if (message) {
            *message = @"Configuration missed.";
        }
        return NO;
    }
    ZIKViewRouteType routeType = configuration.routeType;
    ZIKViewRouteRealType realRouteType = self.realRouteType;
    id destination = self.destination;
    
    if (self.state != ZIKRouterStateRouted) {
        if (message) {
            *message = [NSString stringWithFormat:@"Router can't remove, it's not performed, current state:%ld router:%@",(long)self.state,self];
        }
        return NO;
    }
    
    if (routeType == ZIKViewRouteTypeCustom) {
        return [self canRemoveCustomRoute];
    }
    
    if (!destination) {
        if (self.state != ZIKRouterStateRemoved) {
            [self notifyRouteState:ZIKRouterStateRemoved];
        }
        if (message) {
            *message = [NSString stringWithFormat:@"Router can't remove, destination is dealloced. router:%@",self];
        }
        return NO;
    }
    
    switch (realRouteType) {
        case ZIKViewRouteRealTypeUnknown:
        case ZIKViewRouteRealTypeUnwind:
        case ZIKViewRouteRealTypeCustom: {
            if (message) {
                *message = [NSString stringWithFormat:@"Router can't remove, realRouteType is %ld, doesn't support remove, router:%@",(long)realRouteType,self];
            }
            return NO;
            break;
        }
            
        case ZIKViewRouteRealTypePush: {
            if (![self _canPop]) {
                [self notifyRouteState:ZIKRouterStateRemoved];
                if (message) {
                    *message = [NSString stringWithFormat:@"Router can't remove, destination doesn't have navigationController when pop, router:%@",self];
                }
                return NO;
            }
            break;
        }
            
        case ZIKViewRouteRealTypePresentModally:
        case ZIKViewRouteRealTypePresentAsPopover: {
            if (![self _canDismiss]) {
                [self notifyRouteState:ZIKRouterStateRemoved];
                if (message) {
                    *message = [NSString stringWithFormat:@"Router can't remove, destination is not presented when dismiss. router:%@",self];
                }
                return NO;
            }
            break;
        }
          
        case ZIKViewRouteRealTypeAddAsChildViewController: {
            if (![self _canRemoveFromParentViewController]) {
                [self notifyRouteState:ZIKRouterStateRemoved];
                if (message) {
                    *message = [NSString stringWithFormat:@"Router can't remove, doesn't have parent view controller when remove from parent. router:%@",self];
                }
                return NO;
            }
            break;
        }
            
        case ZIKViewRouteRealTypeAddAsSubview: {
            if (![self _canRemoveFromSuperview]) {
                [self notifyRouteState:ZIKRouterStateRemoved];
                if (message) {
                    *message = [NSString stringWithFormat:@"Router can't remove, destination doesn't have superview when remove from superview. router:%@",self];
                }
                return NO;
            }
            break;
        }
    }
    return YES;
}

- (BOOL)_canPop {
    UIViewController *destination = self.destination;
    if (!destination.navigationController) {
        return NO;
    }
    return YES;
}

- (BOOL)_canDismiss {
    UIViewController *destination = self.destination;
    if (!destination.presentingViewController && /*can dismiss destination itself*/
        !destination.presentedViewController /*can dismiss destination's presentedViewController*/
        ) {
        return NO;
    }
    return YES;
}

- (BOOL)_canRemoveFromParentViewController {
    UIViewController *destination = self.destination;
    if (!destination.parentViewController) {
        return NO;
    }
    return YES;
}

- (BOOL)_canRemoveFromSuperview {
    UIView *destination = self.destination;
    if (!destination.superview) {
        return NO;
    }
    return YES;
}

- (void)removeRouteWithSuccessHandler:(void(^)(void))performerSuccessHandler
                         errorHandler:(void(^)(SEL routeAction, NSError *error))performerErrorHandler {
    void(^doRemoveRoute)(void) = ^ {
        if (self.state != ZIKRouterStateRouted || !self.original_configuration) {
            [self _callbackError_errorCode:ZIKViewRouteErrorActionFailed
                                errorHandler:performerErrorHandler
                                      action:@selector(removeRoute)
                            errorDescription:@"State should be ZIKRouterStateRouted when removeRoute, current state:%ld, configuration:%@",self.state,self.original_configuration];
            return;
        }
        NSString *errorMessage;
        if (![self _canRemoveWithErrorMessage:&errorMessage]) {
            NSString *description = [NSString stringWithFormat:@"%@, configuration:%@",errorMessage,self.original_configuration];
            [self _callbackError_actionFailedWithAction:@selector(removeRoute)
                                         errorDescription:description];
            if (performerErrorHandler) {
                performerErrorHandler(@selector(removeRoute),[[self class] errorWithCode:ZIKViewRouteErrorActionFailed localizedDescription:description]);
            }
            return;
        }
        
        [super removeRouteWithSuccessHandler:performerSuccessHandler errorHandler:performerErrorHandler];
    };
    
    if ([NSThread isMainThread]) {
        doRemoveRoute();
    } else {
        NSAssert(NO, @"%@ removeRoute should only be called in main thread!",self);
        dispatch_sync(dispatch_get_main_queue(), ^{
            doRemoveRoute();
        });
    }
}

- (void)removeDestination:(id)destination removeConfiguration:(__kindof ZIKRouteConfiguration *)removeConfiguration {
    [self notifyRouteState:ZIKRouterStateRemoving];
    if (!destination) {
        [self notifyRouteState:ZIKRouterStateRemoveFailed];
        [self _callbackError_actionFailedWithAction:@selector(removeRoute)
                                     errorDescription:@"Destination was deallced when removeRoute, router:%@",self];
        return;
    }
    
    ZIKViewRouteConfiguration *configuration = self.original_configuration;
    if (configuration.routeType == ZIKViewRouteTypeCustom) {
        if ([self respondsToSelector:@selector(removeCustomRouteOnDestination:fromSource:removeConfiguration:configuration:)]) {
            [self removeCustomRouteOnDestination:destination
                                      fromSource:self.original_configuration.source
                             removeConfiguration:self.original_removeConfiguration
                                   configuration:configuration];
        } else {
            [self notifyRouteState:ZIKRouterStateRemoveFailed];
            [self _callbackError_actionFailedWithAction:@selector(performRoute) errorDescription:@"Remove custom route but router(%@) didn't implement -removeCustomRouteOnDestination:fromSource:removeConfiguration:configuration:",[self class]];
            NSAssert(NO, @"Remove custom route but router(%@) didn't implement -removeCustomRouteOnDestination:fromSource:removeConfiguration:configuration:",[self class]);
        }
        return;
    }
    ZIKViewRouteRealType realRouteType = self.realRouteType;
    NSString *errorDescription;
    
    switch (realRouteType) {
        case ZIKViewRouteRealTypePush:
            [self _popOnDestination:destination];
            break;
            
        case ZIKViewRouteRealTypePresentModally:
            [self _dismissOnDestination:destination];
            break;
            
        case ZIKViewRouteRealTypePresentAsPopover:
            [self _dismissPopoverOnDestination:destination];
            break;
            
        case ZIKViewRouteRealTypeAddAsChildViewController:
            [self _removeFromParentViewControllerOnDestination:destination];
            break;
            
        case ZIKViewRouteRealTypeAddAsSubview:
            [self _removeFromSuperviewOnDestination:destination];
            break;
            
        case ZIKViewRouteRealTypeUnknown:
            errorDescription = @"RouteType(Unknown) can't removeRoute";
            break;
            
        case ZIKViewRouteRealTypeUnwind:
            errorDescription = @"RouteType(Unwind) can't removeRoute";
            break;
            
        case ZIKViewRouteRealTypeCustom:
            errorDescription = @"RouteType(Custom) can't removeRoute";
            break;
    }
    if (errorDescription) {
        [self notifyRouteState:ZIKRouterStateRemoveFailed];
        [self _callbackError_actionFailedWithAction:@selector(removeRoute)
                                     errorDescription:errorDescription];
    }
}

- (void)_popOnDestination:(UIViewController *)destination {
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePush)];
    UIViewController *source = destination.navigationController.visibleViewController;
    [self beginRemoveRouteFromSource:source];
    
    UINavigationController *navigationController;
    if (self.container.navigationController) {
        navigationController = self.container.navigationController;
    } else {
        navigationController = destination.navigationController;
    }
    UIViewController *popTo = (UIViewController *)self.original_configuration.source;
    
    if ([navigationController.viewControllers containsObject:popTo]) {
        [navigationController popToViewController:popTo animated:self.original_removeConfiguration.animated];
    } else {
        NSAssert(NO, @"navigationController doesn't contains original source when pop destination.");
        [destination.navigationController popViewControllerAnimated:self.original_removeConfiguration.animated];
    }
    [ZIKViewRouter _completeWithtransitionCoordinator:destination.navigationController.transitionCoordinator
                                   transitionCompletion:^{
        [self endRemoveRouteWithSuccessOnDestination:destination fromSource:source];
    }];
}

- (void)_dismissOnDestination:(UIViewController *)destination {
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePresentModally)];
    UIViewController *source = destination.presentingViewController;
    [self beginRemoveRouteFromSource:source];
    
    [destination dismissViewControllerAnimated:self.original_removeConfiguration.animated completion:^{
        [self endRemoveRouteWithSuccessOnDestination:destination fromSource:source];
    }];
}

- (void)_dismissPopoverOnDestination:(UIViewController *)destination {
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypePresentAsPopover)];
    UIViewController *source = destination.presentingViewController;
    [self beginRemoveRouteFromSource:source];
    
    if (NSClassFromString(@"UIPopoverPresentationController") ||
        [UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        [destination dismissViewControllerAnimated:self.original_removeConfiguration.animated completion:^{
            [self endRemoveRouteWithSuccessOnDestination:destination fromSource:source];
        }];
        return;
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
    UIPopoverController *popover = objc_getAssociatedObject(destination, "zikrouter_popover");
#pragma clang diagnostic pop
    if (!popover) {
        NSAssert(NO, @"Didn't set UIPopoverController to destination in -_performPresentAsPopoverOnDestination:fromSource:popoverConfiguration:");
        [destination dismissViewControllerAnimated:self.original_removeConfiguration.animated completion:^{
            [self endRemoveRouteWithSuccessOnDestination:destination fromSource:source];
        }];
        return;
    }
    [popover dismissPopoverAnimated:self.original_removeConfiguration.animated];
    [ZIKViewRouter _completeWithtransitionCoordinator:destination.transitionCoordinator
                                   transitionCompletion:^{
        [self endRemoveRouteWithSuccessOnDestination:destination fromSource:source];
    }];
}

- (void)_removeFromParentViewControllerOnDestination:(UIViewController *)destination {
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeAddAsChildViewController)];
    
    UIViewController *wrappedDestination = self.container;
    if (!wrappedDestination) {
        wrappedDestination = destination;
    }
    UIViewController *source = wrappedDestination.parentViewController;
    [self beginRemoveRouteFromSource:source];
    
    [wrappedDestination willMoveToParentViewController:nil];
    BOOL isViewLoaded = wrappedDestination.isViewLoaded;
    if (isViewLoaded) {
        [wrappedDestination.view removeFromSuperview];//If do removeFromSuperview before removeFromParentViewController, -didMoveToParentViewController:nil in destination may be called twice
    }
    [wrappedDestination removeFromParentViewController];
    
    [self endRemoveRouteWithSuccessOnDestination:destination fromSource:source];
    if (!isViewLoaded) {
        [destination setZix_routeTypeFromRouter:nil];
    }
}

- (void)_removeFromSuperviewOnDestination:(UIView *)destination {
    NSAssert(destination.superview, @"Destination doesn't have superview when remove from superview.");
    [destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeAddAsSubview)];
    UIView *source = destination.superview;
    [self beginRemoveRouteFromSource:source];
    
    [destination removeFromSuperview];
    
    [self endRemoveRouteWithSuccessOnDestination:destination fromSource:source];
}

- (void)notifyRemoveRouteSuccess {
    ZIKViewRemoveConfiguration *configuration = self.original_removeConfiguration;
    if (configuration.removeCompletion) {
        configuration.removeCompletion();
    }
    [super notifySuccessWithAction:@selector(removeRoute)];
}

- (void)beginRemoveRouteFromSource:(id)source {
    NSAssert(self.destination, @"Destination is not exist when remove route.");
    NSAssert(self.state == ZIKRouterStateRemoving, @"state should be removing when begin to remove.");
    self.retainedSelf = self;
    self.routingFromInternal = YES;
    id destination = self.destination;
    if ([destination conformsToProtocol:@protocol(ZIKRoutableView)]) {
        [ZIKViewRouter AOP_notifyAll_router:self willRemoveRouteOnDestination:destination fromSource:source];
    } else {
        NSAssert([self isMemberOfClass:[ZIKViewRouter class]] && self.original_configuration.routeType == ZIKViewRouteTypePerformSegue, @"Only ZIKViewRouteTypePerformSegue's destination can not conform to ZIKRoutableView");
    }
}

- (void)endRemoveRouteWithSuccessOnDestination:(id)destination fromSource:(id)source {
    NSParameterAssert(destination);
    NSAssert(self.state == ZIKRouterStateRemoving, @"state should be removing when end remove.");
    [self notifyRouteState:ZIKRouterStateRemoved];
    [self notifyRemoveRouteSuccess];
    if ([destination conformsToProtocol:@protocol(ZIKRoutableView)]) {
        [ZIKViewRouter AOP_notifyAll_router:self didRemoveRouteOnDestination:destination fromSource:source];
    } else {
        NSAssert([self isMemberOfClass:[ZIKViewRouter class]] && self.original_configuration.routeType == ZIKViewRouteTypePerformSegue, @"Only ZIKViewRouteTypePerformSegue's destination can not conform to ZIKRoutableView");
    }
    self.routingFromInternal = NO;
    self.container = nil;
    self.retainedSelf = nil;
}

- (void)endRemoveRouteWithError:(NSError *)error {
    NSParameterAssert(error);
    NSAssert(self.state == ZIKRouterStateRemoving, @"state should be removing when end remove.");
    [self notifyRouteState:ZIKRouterStateRemoveFailed];
    [self _callbackErrorWithAction:@selector(removeRoute) error:error];
    self.routingFromInternal = NO;
    self.retainedSelf = nil;
}

#pragma mark AOP

+ (void)AOP_notifyAll_router:(nullable ZIKViewRouter *)router willPerformRouteOnDestination:(id)destination fromSource:(id)source {
    NSParameterAssert([destination conformsToProtocol:@protocol(ZIKRoutableView)]);
    EnumerateRoutersForViewClass([destination class], ^(__unsafe_unretained Class routerClass) {
        if ([routerClass respondsToSelector:@selector(router:willPerformRouteOnDestination:fromSource:)]) {
            [routerClass router:router willPerformRouteOnDestination:destination fromSource:source];
        }
    });
}

+ (void)AOP_notifyAll_router:(nullable ZIKViewRouter *)router didPerformRouteOnDestination:(id)destination fromSource:(id)source {
    NSParameterAssert([destination conformsToProtocol:@protocol(ZIKRoutableView)]);
    EnumerateRoutersForViewClass([destination class], ^(__unsafe_unretained Class routerClass) {
        if ([routerClass respondsToSelector:@selector(router:didPerformRouteOnDestination:fromSource:)]) {
            [routerClass router:router didPerformRouteOnDestination:destination fromSource:source];
        }
    });
}

+ (void)AOP_notifyAll_router:(nullable ZIKViewRouter *)router willRemoveRouteOnDestination:(id)destination fromSource:(id)source {
    NSParameterAssert([destination conformsToProtocol:@protocol(ZIKRoutableView)]);
    EnumerateRoutersForViewClass([destination class], ^(__unsafe_unretained Class routerClass) {
        if ([routerClass respondsToSelector:@selector(router:willRemoveRouteOnDestination:fromSource:)]) {
            [routerClass router:router willRemoveRouteOnDestination:destination fromSource:(id)source];
        }
    });
}

+ (void)AOP_notifyAll_router:(nullable ZIKViewRouter *)router didRemoveRouteOnDestination:(id)destination fromSource:(id)source {
    NSParameterAssert([destination conformsToProtocol:@protocol(ZIKRoutableView)]);
    EnumerateRoutersForViewClass([destination class], ^(__unsafe_unretained Class routerClass) {
        if ([routerClass respondsToSelector:@selector(router:didRemoveRouteOnDestination:fromSource:)]) {
            [routerClass router:router didRemoveRouteOnDestination:destination fromSource:(id)source];
        }
    });
}

#pragma mark Hook System Navigation

///Update state when route action is not performed from router
- (void)_handleWillPerformRouteNotification:(NSNotification *)note {
    id destination = note.object;
    if (!self.destination || self.destination != destination) {
        return;
    }
    ZIKRouterState state = self.state;
    if (!self.routingFromInternal && state != ZIKRouterStateRouting) {
        ZIKViewRouteConfiguration *configuration = self.original_configuration;
        BOOL isFromAddAsChild = (configuration.routeType == ZIKViewRouteTypeAddAsChildViewController);
        if (state != ZIKRouterStateRouted ||
            (self.stateBeforeRoute &&
             configuration.routeType == ZIKViewRouteTypeGetDestination) ||
            (isFromAddAsChild &&
             self.realRouteType == ZIKViewRouteRealTypeUnknown)) {
                if (isFromAddAsChild) {
                    self.realRouteType = ZIKViewRouteRealTypeAddAsChildViewController;
                }
            [self notifyRouteState:ZIKRouterStateRouting];//not performed from router (dealed by system, or your code)
            if (configuration.handleExternalRoute) {
                [self prepareForPerformRouteOnDestination:destination];
            } else {
                [self prepareDestination:destination configuration:configuration];
                [self didFinishPrepareDestination:destination configuration:configuration];
            }
        }
    }
}

- (void)_handleDidPerformRouteNotification:(NSNotification *)note {
    id destination = note.object;
    if (!self.destination || self.destination != destination) {
        return;
    }
    if (self.stateBeforeRoute &&
        self.original_configuration.routeType == ZIKViewRouteTypeGetDestination) {
        NSAssert(self.realRouteType == ZIKViewRouteRealTypeUnknown, @"real route type is unknown before destination is real routed");
        ZIKPresentationState *stateBeforeRoute = self.stateBeforeRoute;
        ZIKViewRouteDetailType detailRouteType = [ZIKPresentationState detailRouteTypeFromStateBeforeRoute:stateBeforeRoute stateAfterRoute:[destination zix_presentationState]];
        self.realRouteType = [ZIKViewRouter _realRouteTypeFromDetailType:detailRouteType];
        self.stateBeforeRoute = nil;
    }
    if (!self.routingFromInternal &&
        self.state != ZIKRouterStateRouted) {
        [self notifyRouteState:ZIKRouterStateRouted];//not performed from router (dealed by system, or your code)
        if (self.original_configuration.handleExternalRoute) {
            [self notifyPerformRouteSuccessWithDestination:destination];
        }
    }
}

- (void)_handleWillRemoveRouteNotification:(NSNotification *)note {
    id destination = note.object;
    if (!self.destination || self.destination != destination) {
        return;
    }
    ZIKRouterState state = self.state;
    if (!self.routingFromInternal && state != ZIKRouterStateRemoving) {
        if (state != ZIKRouterStateRemoved ||
            (self.stateBeforeRoute &&
             self.original_configuration.routeType == ZIKViewRouteTypeGetDestination)) {
                [self notifyRouteState:ZIKRouterStateRemoving];//not performed from router (dealed by system, or your code)
            }
    }
    if (state == ZIKRouterStateRouting) {
        [self _callbackError_unbalancedTransitionWithAction:@selector(removeRoute) errorDescription:@"Unbalanced calls to begin/end appearance transitions for destination. This error occurs when you try and display a view controller before the current view controller is finished displaying. This may cause the UIViewController skips or messes up the order calling -viewWillAppear:, -viewDidAppear:, -viewWillDisAppear: and -viewDidDisappear:, and messes up the route state. Current error reason is trying to remove route on destination when destination is routing, router:(%@), callStack:%@",self,[NSThread callStackSymbols]];
    }
}

- (void)_handleDidRemoveRouteNotification:(NSNotification *)note {
    id destination = note.object;
    if (!self.destination || self.destination != destination) {
        return;
    }
    if (self.stateBeforeRoute &&
        self.original_configuration.routeType == ZIKViewRouteTypeGetDestination) {
        NSAssert(self.realRouteType == ZIKViewRouteRealTypeUnknown, @"real route type is unknown before destination is real routed");
        ZIKPresentationState *stateBeforeRoute = self.stateBeforeRoute;
        ZIKViewRouteDetailType detailRouteType = [ZIKPresentationState detailRouteTypeFromStateBeforeRoute:stateBeforeRoute stateAfterRoute:[destination zix_presentationState]];
        self.realRouteType = [ZIKViewRouter _realRouteTypeFromDetailType:detailRouteType];
        self.stateBeforeRoute = nil;
    }
    if (!self.routingFromInternal &&
        self.state != ZIKRouterStateRemoved) {
        [self notifyRouteState:ZIKRouterStateRemoved];//not performed from router (dealed by system, or your code)
        if (self.original_removeConfiguration.handleExternalRoute) {
            [self notifyRemoveRouteSuccess];
        }
    }
}

- (void)_handleRemoveRouteCanceledNotification:(NSNotification *)note {
    id destination = note.object;
    if (!self.destination || self.destination != destination) {
        return;
    }
    if (!self.routingFromInternal &&
        self.state == ZIKRouterStateRemoving) {
        ZIKRouterState preState = self.preState;
        [self notifyRouteState:preState];//not performed from router (dealed by system, or your code)
    }
}

- (void)ZIKViewRouter_hook_willMoveToParentViewController:(UIViewController *)parent {
    [self ZIKViewRouter_hook_willMoveToParentViewController:parent];
    if (parent) {
        [(UIViewController *)self setZix_parentMovingTo:parent];
    } else {
        UIViewController *currentParent = [(UIViewController *)self parentViewController];
        NSAssert(currentParent, @"currentParent shouldn't be nil when removing from parent");
        [(UIViewController *)self setZix_parentRemovingFrom:currentParent];
    }
}

- (void)ZIKViewRouter_hook_didMoveToParentViewController:(UIViewController *)parent {
    [self ZIKViewRouter_hook_didMoveToParentViewController:parent];
    if (parent) {
        NSAssert([(UIViewController *)self parentViewController], @"currentParent shouldn't be nil when didMoved to parent");
//        NSAssert([(UIViewController *)self zix_parentMovingTo] ||
//                 [(UIViewController *)self zix_isRootViewControllerInContainer], @"parentMovingTo should be set in -ZIKViewRouter_hook_willMoveToParentViewController:. But if a container is from storyboard, it's not created with initWithRootViewController:, so rootViewController may won't call willMoveToParentViewController: before didMoveToParentViewController:.");
        
        [(UIViewController *)self setZix_parentMovingTo:nil];
    } else {
        NSAssert([(UIViewController *)self parentViewController] == nil, @"currentParent should be nil when removed from parent");
        //If you do removeFromSuperview before removeFromParentViewController, -didMoveToParentViewController:nil in child view controller may be called twice.
        //        NSAssert([(UIViewController *)self zix_parentRemovingFrom], @"RemovingFrom should be set in -ZIKViewRouter_hook_willMoveToParentViewController.");
        
        [(UIViewController *)self setZix_parentRemovingFrom:nil];
    }
}

- (void)ZIKViewRouter_hook_viewWillAppear:(BOOL)animated {
    UIViewController *destination = (UIViewController *)self;
    BOOL removing = destination.zix_removing;
    BOOL isRoutableView = ([self conformsToProtocol:@protocol(ZIKRoutableView)] == YES);
    if (removing) {
        [destination setZix_removing:NO];
        if (isRoutableView) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteRemoveRouteCanceledNotification object:destination];
        }
    }
    if (isRoutableView) {
        BOOL routed = [(UIViewController *)self zix_routed];
        if (!routed) {
            NSAssert(removing == NO, @"removing a not routed view is unexpected");
            UIViewController *parentMovingTo = [(UIViewController *)self zix_parentMovingTo];
            [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteWillPerformRouteNotification object:destination];
            NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
            if (!routeTypeFromRouter ||
                [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination ||
                [routeTypeFromRouter integerValue] == ZIKViewRouteTypeAddAsChildViewController) {
                UIViewController *source = parentMovingTo;
                if (!source) {
                    UIViewController *node = destination;
                    while (node) {
                        if (node.isBeingPresented) {
                            source = node.presentingViewController;
                            break;
                        } else {
                            node = node.parentViewController;
                        }
                    }
                }
                [ZIKViewRouter AOP_notifyAll_router:nil willPerformRouteOnDestination:destination fromSource:source];
            }
        }
    }
    
    [self ZIKViewRouter_hook_viewWillAppear:animated];
}

- (void)ZIKViewRouter_hook_viewDidAppear:(BOOL)animated {
    BOOL routed = [(UIViewController *)self zix_routed];
    UIViewController *parentMovingTo = [(UIViewController *)self zix_parentMovingTo];
    if (!routed &&
        [self conformsToProtocol:@protocol(ZIKRoutableView)]) {
        UIViewController *destination = (UIViewController *)self;
        [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteDidPerformRouteNotification object:destination];
        NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];//This destination is routing from router
        if (!routeTypeFromRouter ||
            [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination ||
            [routeTypeFromRouter integerValue] == ZIKViewRouteTypeAddAsChildViewController) {
            UIViewController *source = parentMovingTo;
            if (!source) {
                UIViewController *node = destination;
                while (node) {
                    if (node.isBeingPresented) {
                        source = node.presentingViewController;
                        break;
                    } else if (node.isMovingToParentViewController) {
                        source = node.parentViewController;
                        break;
                    } else {
                        node = node.parentViewController;
                    }
                }
            }
            [ZIKViewRouter AOP_notifyAll_router:nil didPerformRouteOnDestination:destination fromSource:source];
        }
        if (routeTypeFromRouter) {
            [destination setZix_routeTypeFromRouter:nil];
        }
    }
    
    [self ZIKViewRouter_hook_viewDidAppear:animated];
    if (!routed) {
        [(UIViewController *)self setZix_routed:YES];
    }
}

- (void)ZIKViewRouter_hook_viewWillDisappear:(BOOL)animated {
    UIViewController *destination = (UIViewController *)self;
    if (destination.zix_removing == NO) {
        UIViewController *node = destination;
        while (node) {
            UIViewController *parentRemovingFrom = node.zix_parentRemovingFrom;
            UIViewController *source;
            if (parentRemovingFrom || //removing from navigation / willMoveToParentViewController:nil, removeFromParentViewController
                node.isMovingFromParentViewController || //removed from splite
                (!node.parentViewController && !node.presentingViewController && ![node zix_isAppRootViewController])) {
                source = parentRemovingFrom;
            } else if (node.isBeingDismissed) {
                source = node.presentingViewController;
            } else {
                node = node.parentViewController;
                continue;
            }
            if ([self conformsToProtocol:@protocol(ZIKRoutableView)]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteWillRemoveRouteNotification object:destination];
                NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
                if (!routeTypeFromRouter ||
                    [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                    [ZIKViewRouter AOP_notifyAll_router:nil willRemoveRouteOnDestination:destination fromSource:source];
                }
            }
            [destination setZix_parentRemovingFrom:source];
            [destination setZix_removing:YES];
            break;
        }
    }
    
    [self ZIKViewRouter_hook_viewWillDisappear:animated];
}

- (void)ZIKViewRouter_hook_viewDidDisappear:(BOOL)animated {
    UIViewController *destination = (UIViewController *)self;
    BOOL removing = destination.zix_removing;
    if ([self conformsToProtocol:@protocol(ZIKRoutableView)]) {
        if (removing) {
            UIViewController *source = destination.zix_parentRemovingFrom;
            [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteDidRemoveRouteNotification object:destination];
            NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
            if (!routeTypeFromRouter ||
                [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                [ZIKViewRouter AOP_notifyAll_router:nil didRemoveRouteOnDestination:destination fromSource:source];
            }
            if (routeTypeFromRouter) {
                [destination setZix_routeTypeFromRouter:nil];
            }
        }
    }
    if (removing) {
        [destination setZix_removing:NO];
        [destination setZix_routed:NO];
    } else if (ZIKRouter_classIsCustomClass([destination class])) {
        //Check unbalanced calls to begin/end appearance transitions
        UIViewController *node = destination;
        while (node) {
            UIViewController *parentRemovingFrom = node.zix_parentRemovingFrom;
            UIViewController *source;
            if (parentRemovingFrom ||
                node.isMovingFromParentViewController ||
                (!node.parentViewController && !node.presentingViewController && ![node zix_isAppRootViewController])) {
                source = parentRemovingFrom;
            } else if (node.isBeingDismissed) {
                source = node.presentingViewController;
            } else {
                node = node.parentViewController;
                continue;
            }
            
            [destination setZix_parentRemovingFrom:source];
            [ZIKViewRouter _callbackGlobalErrorHandlerWithRouter:nil action:@selector(removeRoute) error:[ZIKViewRouter errorWithCode:ZIKViewRouteErrorUnbalancedTransition localizedDescriptionFormat:@"Unbalanced calls to begin/end appearance transitions for destination. This error occurs when you try and display a view controller before the current view controller is finished displaying. This may cause the UIViewController skips or messes up the order calling -viewWillAppear:, -viewDidAppear:, -viewWillDisAppear: and -viewDidDisappear:, and messes up the route state. Current error reason is already removed destination but destination appears again before -viewDidDisappear:, router:(%@), callStack:%@",self,[NSThread callStackSymbols]]];
            NSAssert(NO, @"Unbalanced calls to begin/end appearance transitions for destination. This error may from your custom transition.");
            break;
        }
    }
    
    [self ZIKViewRouter_hook_viewDidDisappear:animated];
}

/**
 Note: in -viewWillAppear:, if the view controller contains sub routable UIView added from external (addSubview:, storyboard or xib), the subview may not be ready yet. The UIView has to search the performer with -nextResponder to prepare itself, nextResponder can only be gained after -viewDidLoad or -willMoveToWindow:. But -willMoveToWindow: may not be called yet in -viewWillAppear:. If the subview is not ready, config the subview in -handleViewReady may fail.
 So we have to make sure routable UIView is prepared before -viewDidLoad if it's added to the superview when superview is not on screen yet.
 */
- (void)ZIKViewRouter_hook_viewDidLoad {
    NSAssert([NSThread isMainThread], @"UI thread must be main thread.");
    [self ZIKViewRouter_hook_viewDidLoad];
    
    //Find performer and prepare for destination added to a superview not on screen in -ZIKViewRouter_hook_willMoveToSuperview
    NSMutableArray *preparingRouters = g_preparingUIViewRouters;
    
    NSMutableArray *preparedRouters;
    if (preparingRouters.count > 0) {
        for (ZIKViewRouter *router in preparingRouters) {
            UIView *destination = router.destination;
            NSAssert([destination isKindOfClass:[UIView class]], @"Only UIView destination need fix.");
            id performer = [destination zix_routePerformer];
            if (performer) {
                [ZIKViewRouter _prepareDestinationFromExternal:destination router:router performer:performer];
                router.prepared = YES;
                if (!preparedRouters) {
                    preparedRouters = [NSMutableArray array];
                }
                [preparedRouters addObject:router];
            }
        }
        if (preparedRouters.count > 0) {
            [preparingRouters removeObjectsInArray:preparedRouters];
        }
    }
}

///Add subview by code or storyboard will auto create a corresponding router. We assume it's superview's view controller as the performer. If your custom class view use a routable view as it's part, the custom view should use a router to add and prepare the routable view, then the routable view don't need to search performer.

/**
 When a routable view is added from storyboard or xib
 Invoking order in subview when subview needs prepare:
 1.willMoveToSuperview: (can't find performer until -viewDidLoad, add to preparing list)
 2.didMoveToSuperview
 3.ZIKViewRouter_hook_viewDidLoad
    4.didFinishPrepareDestination:configuration:
    5.viewDidLoad
 6.willMoveToWindow:
    7.router:willPerformRouteOnDestination:fromSource:
 8.didMoveToWindow
    9.router:didPerformRouteOnDestination:fromSource:
 
 Invoking order in subview when subview doesn't need prepare:
 1.willMoveToSuperview: (don't need to find performer, so finish directly)
    2.didFinishPrepareDestination:configuration:
 3.didMoveToSuperview
 4.willMoveToWindow:
    5.router:willPerformRouteOnDestination:fromSource:
 6.didMoveToWindow
    7.router:didPerformRouteOnDestination:fromSource:
 */

/**
 Directly add a routable subview to a visible UIView in view controller.
 Invoking order in subview:
 1.willMoveToWindow:
 2.willMoveToSuperview: (superview is already in a view controller, so can find performer now)
    3.didFinishPrepareDestination:configuration:
    4.router:willPerformRouteOnDestination:fromSource:
 5.didMoveToWindow
    6.router:didPerformRouteOnDestination:fromSource:
 7.didMoveToSuperview
 */

/**
 Directly add a routable subview to an invisible UIView in view controller.
 Invoking order in subview:
 1.willMoveToSuperview: (superview is already in a view controller, so can find performer now)
    2.didFinishPrepareDestination:configuration:
 3.didMoveToSuperview
 4.willMoveToWindow: (when superview is visible)
    5.router:willPerformRouteOnDestination:fromSource:
 6.didMoveToWindow
    7.router:didPerformRouteOnDestination:fromSource:
 */

/**
 Add a routable subview to a superview, then add the superview to a UIView in view controller.
 Invoking order in subview when subview needs prepare:
 1.willMoveToSuperview: (add to prepare list if it's superview chain is not in window)
 2.didMoveToSuperview
 3.willMoveToWindow: (still in preparing list, if destination is already on screen, search performer fail, else search in didMoveToWindow)
 4.didMoveToWindow
    5.didFinishPrepareDestination:configuration:
    6.router:willPerformRouteOnDestination:fromSource:
 
 Invoking order in subview when subview doesn't need prepare:
 1.willMoveToSuperview: (don't need to find performer, so finish directly)
    2.didFinishPrepareDestination:configuration:
 3.didMoveToSuperview
 4.willMoveToWindow:
    5.router:willPerformRouteOnDestination:fromSource:
 6.didMoveToWindow
    7.router:didPerformRouteOnDestination:fromSource:
 */

/**
 Add a routable subview to a superviw, but the superview was never added to any view controller. This should get an assert failure when subview needs prepare.
 Invoking order in subview when subview needs prepare:
 1.willMoveToSuperview:newSuperview (add to preparing list, prepare until )
 2.didMoveToSuperview
 3.willMoveToSuperview:nil
    4.when detected that router is still in prepareing list, means last preparation is not finished, assert fail, route fail with a invalid performer error.
    5.router:willRemoveRouteOnDestination:fromSource:
 6.didMoveToSuperview
    7.router:didRemoveRouteOnDestination:fromSource:
 
 Invoking order in subview when subview don't need prepare:
 1.willMoveToSuperview:newSuperview
    2.didFinishPrepareDestination:configuration:
 3.didMoveToSuperview
 4.willMoveToSuperview:nil
    5.router:willPerformRouteOnDestination:fromSource:
    6.router:didPerformRouteOnDestination:fromSource: (the view was never displayed after added, so willMoveToWindow: is never be invoked, so router needs to end the perform route action here.)
    7.router:willRemoveRouteOnDestination:fromSource:
 8.didMoveToSuperview
    9.router:didRemoveRouteOnDestination:fromSource:
 */

/**
 Add a routable subview to a UIWindow. This should get an assert failure when subview needs prepare.
 Invoking order in subview when subview needs prepare:
 1.willMoveToWindow:newWindow
 2.willMoveToSuperview:newSuperview
    3.when detected that newSuperview is already on screen, but can't find the performer, assert fail, get a global invalid performer error
    4.router:willPerformRouteOnDestination:fromSource: (if no assert fail, route will continue)
 5.didMoveToWindow
    6.router:didPerformRouteOnDestination:fromSource:
 7.didMoveToSuperview
 
 Invoking order in subview when subview doesn't need prepare:
 1.willMoveToWindow:newWindow
 2.willMoveToSuperview:newSuperview
    3.didFinishPrepareDestination:configuration:
    4.router:willPerformRouteOnDestination:fromSource:
 5.didMoveToWindow
    6.router:didPerformRouteOnDestination:fromSource:
 7.didMoveToSuperview
 */

- (void)ZIKViewRouter_hook_willMoveToSuperview:(nullable UIView *)newSuperview {
    UIView *destination = (UIView *)self;
    if ([self conformsToProtocol:@protocol(ZIKRoutableView)]) {
        if (!newSuperview) {
            //Removing from superview
            ZIKViewRouter *destinationRouter = [destination zix_destinationViewRouter];
            if (destinationRouter) {
                //This is routing from router
                if ([g_preparingUIViewRouters containsObject:destinationRouter]) {
                    //Didn't fine the performer of UIView until it's removing from superview, maybe it's superview was never added to any view controller
                    [g_preparingUIViewRouters removeObject:destinationRouter];
                    NSString *description = [NSString stringWithFormat:@"Didn't fine the performer of UIView until it's removing from superview, maybe it's superview was never added to any view controller. Can't find which custom UIView or UIViewController added destination:(%@) as subview, so we can't notify the performer to config the destination. You may add destination to a UIWindow in code directly, and the UIWindow is not a custom class. Please change your code and add subview by a custom view router with ZIKViewRouteTypeAddAsSubview. Destination superview: (%@).",destination, newSuperview];
                    [destinationRouter endPerformRouteWithError:[ZIKViewRouter errorWithCode:ZIKViewRouteErrorInvalidPerformer localizedDescription:description]];
                    NSAssert(NO, description);
                }
                //Destination don't need prepare, but it's superview never be added to a view controller, so destination is never on a window
                if (destinationRouter.state == ZIKRouterStateRouting &&
                    ![destination zix_firstAvailableUIViewController]) {
                    //end perform
                    [ZIKViewRouter AOP_notifyAll_router:destinationRouter willPerformRouteOnDestination:destination fromSource:destination.superview];
                    [destinationRouter endPerformRouteWithSuccess];
                }
                [destination setZix_destinationViewRouter:nil];
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteWillRemoveRouteNotification object:destination];
            NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
            if (!routeTypeFromRouter ||
                [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                [ZIKViewRouter AOP_notifyAll_router:nil willRemoveRouteOnDestination:destination fromSource:destination.superview];
            }
        } else if (!destination.zix_routed) {
            //Adding to a superview
            ZIKViewRouter *router;
            NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
            if (!routeTypeFromRouter) {
                //Not routing from router
                Class routerClass = ZIKViewRouterToRegisteredView([destination class]);
                NSAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]], @"Router should be subclass of ZIKViewRouter.");
                NSAssert([routerClass _validateSupportedRouteTypesForUIView], @"Router for UIView only suppourts ZIKViewRouteTypeAddAsSubview, ZIKViewRouteTypeGetDestination and ZIKViewRouteTypeCustom, override +supportedRouteTypes in your router.");
                
                id performer = nil;
                BOOL needPrepare = NO;
                if (![routerClass destinationPrepared:destination]) {
                    needPrepare = YES;
                    if (destination.nextResponder) {
                        performer = [destination zix_routePerformer];
                    } else if (newSuperview.nextResponder) {
                        performer = [newSuperview zix_routePerformer];
                    }
                    //Adding to a superview on screen.
                    if (!performer && (newSuperview.window || [newSuperview isKindOfClass:[UIWindow class]])) {
                        NSString *description = [NSString stringWithFormat:@"Adding to a superview on screen. Can't find which custom UIView or UIViewController added destination:(%@) as subview, so we can't notify the performer to config the destination. You may add destination to a UIWindow in code directly. Please fix your code and add subview by a custom view router with ZIKViewRouteTypeAddAsSubview. Destination superview: (%@).",destination, newSuperview];
                        [ZIKViewRouter _callbackError_invalidPerformerWithAction:@selector(performRoute) errorDescription:description];
                        NSAssert(NO, description);
                    }
                }
                
                ZIKViewRouter *destinationRouter = [routerClass routerFromView:destination source:newSuperview];
                destinationRouter.routingFromInternal = YES;
                [destinationRouter notifyRouteState:ZIKRouterStateRouting];
                [destination setZix_destinationViewRouter:destinationRouter];
                if (needPrepare) {
                    if (performer) {
                        [ZIKViewRouter _prepareDestinationFromExternal:destination router:destinationRouter performer:performer];
                        destinationRouter.prepared = YES;
                    } else {
                        if (!newSuperview.window && ![newSuperview isKindOfClass:[UIWindow class]]) {
                            //Adding to a superview not on screen, can't search performer before -viewDidLoad. willMoveToSuperview: is called before willMoveToWindow:. Find performer and prepare in -ZIKViewRouter_hook_viewDidLoad, do willPerformRoute AOP in -ZIKViewRouter_hook_willMoveToWindow:
                            [g_preparingUIViewRouters addObject:destinationRouter];
                        }
                        NSAssert1(!newSuperview.window && ![newSuperview isKindOfClass:[UIWindow class]], @"When new superview is already on screen, performer should not be nil.You may add destination to a system UIViewController in code directly. Please fix your code and add subview by a custom view router with ZIKViewRouteTypeAddAsSubview. Destination superview: (%@).",newSuperview);
                    }
                } else {
                    [destinationRouter prepareDestination:destination configuration:destinationRouter.original_configuration];
                    [destinationRouter didFinishPrepareDestination:destination configuration:destinationRouter.original_configuration];
                    destinationRouter.prepared = YES;
                }
                router = destinationRouter;
                
                //Adding to a superview on screen.
                if (newSuperview.window || [newSuperview isKindOfClass:[UIWindow class]]) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteWillPerformRouteNotification object:destination];
                    NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
                    if (!routeTypeFromRouter ||
                        [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                        [ZIKViewRouter AOP_notifyAll_router:router willPerformRouteOnDestination:destination fromSource:newSuperview];
                    }
                }
            }
        }
    }
    if (!newSuperview) {
//        NSAssert(destination.zix_routed == YES, @"zix_routed should be YES before remove");
        [destination setZix_routed:NO];
    }
    [self ZIKViewRouter_hook_willMoveToSuperview:newSuperview];
}

- (void)ZIKViewRouter_hook_didMoveToSuperview {
    UIView *destination = (UIView *)self;
    UIView *superview = destination.superview;
    if ([self conformsToProtocol:@protocol(ZIKRoutableView)]) {
        if (!superview) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteDidRemoveRouteNotification object:destination];
            NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
            if (!routeTypeFromRouter ||
                [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                [ZIKViewRouter AOP_notifyAll_router:nil didRemoveRouteOnDestination:destination fromSource:nil];//Can't get source, source may already be dealloced here or is in dealloc
            }
            if (routeTypeFromRouter) {
                [destination setZix_routeTypeFromRouter:nil];
            }
        }
    }
    
    [self ZIKViewRouter_hook_didMoveToSuperview];
}

- (void)ZIKViewRouter_hook_willMoveToWindow:(nullable UIWindow *)newWindow {
    UIView *destination = (UIView *)self;
    BOOL routed = destination.zix_routed;
    if ([self conformsToProtocol:@protocol(ZIKRoutableView)]) {
        if (!routed) {
            ZIKViewRouter *router;
            UIView *source;
            NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
            BOOL searchPerformerInDidMoveToWindow = NO;
            if (!routeTypeFromRouter) {
                ZIKViewRouter *destinationRouter = [destination zix_destinationViewRouter];
                NSString *failedToPrepareDescription;
                if (destinationRouter) {
                    if ([g_preparingUIViewRouters containsObject:destinationRouter]) {
                        //Didn't fine the performer of UIView route  before it's displayed on screen. But maybe can find in -didMoveToWindow.
                        [g_preparingUIViewRouters removeObject:destinationRouter];
                        failedToPrepareDescription = [NSString stringWithFormat:@"Didn't fine the performer of UIView route before it's displayed on screen. Can't find which custom UIView or UIViewController added destination:(%@) as subview, so we can't notify the performer to config the destination. You may add destination to a UIWindow in code directly, and the UIWindow is not a custom class. Please change your code and add subview by a custom view router with ZIKViewRouteTypeAddAsSubview. Destination superview: %@.",destination, destination.superview];
                    }
                }
                
                //Was added to a superview when superview was not on screen, and it's displayed now.
                if (destination.superview) {
                    Class routerClass = ZIKViewRouterToRegisteredView([destination class]);
                    NSAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]], @"Router should be subclass of ZIKViewRouter.");
                    NSAssert([routerClass _validateSupportedRouteTypesForUIView], @"Router for UIView only suppourts ZIKViewRouteTypeAddAsSubview, ZIKViewRouteTypeGetDestination and ZIKViewRouteTypeCustom, override +supportedRouteTypes in your router.");
                    
                    source = destination.superview;
                    
                    if (!destinationRouter) {
                        destinationRouter = [routerClass routerFromView:destination source:source];
                        destinationRouter.routingFromInternal = YES;
                        [destinationRouter notifyRouteState:ZIKRouterStateRouting];
                        [destination setZix_destinationViewRouter:destinationRouter];
                    }
                    
                    if (!destinationRouter.prepared) {
                        id performer = nil;
                        BOOL needPrepare = NO;
                        BOOL onScreen = NO;
                        if (![routerClass destinationPrepared:destination]) {
                            needPrepare = YES;
                            onScreen = ([destination zix_firstAvailableUIViewController] != nil);
                            
                            if (onScreen) {
                                performer = [destination zix_routePerformer];
                            }
                            
                            if (onScreen) {
                                if (!performer) {
                                    NSString *description;
                                    if (failedToPrepareDescription) {
                                        description = failedToPrepareDescription;
                                    } else {
                                        description = [NSString stringWithFormat:@"Can't find which custom UIView or UIViewController added destination:(%@) as subview, so we can't notify the performer to config the destination. You may add destination to a UIWindow in code directly, and the UIWindow is not a custom class. Please change your code and add subview by a custom view router with ZIKViewRouteTypeAddAsSubview. Destination superview: %@.",destination, destination.superview];
                                    }
                                    [ZIKViewRouter _callbackError_invalidPerformerWithAction:@selector(performRoute) errorDescription:description];
                                    NSAssert(NO, description);
                                }
                                NSAssert(ZIKRouter_classIsCustomClass(performer), @"performer should be a subclass of UIViewController in your project.");
                            }
                        }
                        if (onScreen) {
                            if (needPrepare) {
                                [ZIKViewRouter _prepareDestinationFromExternal:destination router:destinationRouter performer:performer];
                            } else {
                                [destinationRouter prepareDestination:destination configuration:destinationRouter.original_configuration];
                                [destinationRouter didFinishPrepareDestination:destination configuration:destinationRouter.original_configuration];
                            }
                        } else {
                            searchPerformerInDidMoveToWindow = YES;
                            [g_preparingUIViewRouters addObject:destinationRouter];
                        }
                    }
                    
                    router = destinationRouter;
                }
            }
            
            //Was added to a superview when superview was not on screen, and it's displayed now.
            if (!routed && destination.superview && !searchPerformerInDidMoveToWindow) {
                [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteWillPerformRouteNotification object:destination];
                if (!routeTypeFromRouter ||
                    [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                    [ZIKViewRouter AOP_notifyAll_router:router willPerformRouteOnDestination:destination fromSource:source];
                }
            }
        }
    }
    
    [self ZIKViewRouter_hook_willMoveToWindow:newWindow];
}

- (void)ZIKViewRouter_hook_didMoveToWindow {
    UIView *destination = (UIView *)self;
    UIWindow *window = destination.window;
    UIView *superview = destination.superview;
    BOOL routed = destination.zix_routed;
    if ([self conformsToProtocol:@protocol(ZIKRoutableView)]) {
        if (!routed) {
            ZIKViewRouter *router;
            NSNumber *routeTypeFromRouter = [destination zix_routeTypeFromRouter];
            if (!routeTypeFromRouter) {
                ZIKViewRouter *destinationRouter = destination.zix_destinationViewRouter;
                NSAssert(destinationRouter, @"destinationRouter should be set in -ZIKViewRouter_hook_willMoveToSuperview:");
                router = destinationRouter;
                
                //Find performer and prepare for destination added to a superview not on screen in -ZIKViewRouter_hook_willMoveToSuperview
                if (g_preparingUIViewRouters.count > 0) {
                    if ([g_preparingUIViewRouters containsObject:destinationRouter]) {
                        [g_preparingUIViewRouters removeObject:destinationRouter];
                        id performer = [destination zix_routePerformer];
                        if (performer) {
                            [ZIKViewRouter _prepareDestinationFromExternal:destination router:destinationRouter performer:performer];
                            router.prepared = YES;
                            
                        } else {
                            NSString *description = [NSString stringWithFormat:@"Didn't find performer when UIView is already on screen. Can't find which custom UIView or UIViewController added destination:(%@) as subview, so we can't notify the performer to config the destination. You may add destination to a UIWindow in code directly, and the UIWindow is not a custom class. Please change your code and add subview by a custom view router with ZIKViewRouteTypeAddAsSubview. Destination superview: %@.",destination, destination.superview];
                            [ZIKViewRouter _callbackError_invalidPerformerWithAction:@selector(performRoute) errorDescription:description];
                            NSAssert(NO, description);
                        }
                        [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteWillPerformRouteNotification object:destination];
                        if (!routeTypeFromRouter ||
                            [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                            [ZIKViewRouter AOP_notifyAll_router:router willPerformRouteOnDestination:destination fromSource:superview];
                        }
                    }
                }
                //end perform
                [destinationRouter notifyRouteState:ZIKRouterStateRouted];
                [destinationRouter notifyPerformRouteSuccessWithDestination:destination];
                [destination setZix_destinationViewRouter:nil];
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:kZIKViewRouteDidPerformRouteNotification object:destination];
            if (!routeTypeFromRouter ||
                [routeTypeFromRouter integerValue] == ZIKViewRouteTypeGetDestination) {
                [ZIKViewRouter AOP_notifyAll_router:router didPerformRouteOnDestination:destination fromSource:superview];
            }
            router.routingFromInternal = NO;
            if (routeTypeFromRouter) {
                [destination setZix_routeTypeFromRouter:nil];
            }
        }
    }
    
    [self ZIKViewRouter_hook_didMoveToWindow];
    if (!routed && window) {
        [destination setZix_routed:YES];
    }
}

///Auto prepare storyboard's routable initial view controller or it's routable child view controllers
- (nullable __kindof UIViewController *)ZIKViewRouter_hook_instantiateInitialViewController {
    UIViewController *initialViewController = [self ZIKViewRouter_hook_instantiateInitialViewController];
    
    NSMutableArray<UIViewController *> *routableViews;
    if ([initialViewController conformsToProtocol:@protocol(ZIKRoutableView)]) {
        routableViews = [NSMutableArray arrayWithObject:initialViewController];
    }
    NSArray<UIViewController *> *childViews = [ZIKViewRouter routableViewsInContainerViewController:initialViewController];
    if (childViews.count > 0) {
        if (routableViews == nil) {
            routableViews = [NSMutableArray array];
        }
        [routableViews addObjectsFromArray:childViews];
    }
    for (UIViewController *destination in routableViews) {
        Class routerClass = ZIKViewRouterToRegisteredView([destination class]);
        NSAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]], @"Destination's view router should be subclass of ZIKViewRouter");
        [routerClass prepareDestination:destination configuring:^(ZIKViewRouteConfiguration * _Nonnull config) {
            
        }];
    }
    return initialViewController;
}

- (void)ZIKViewRouter_hook_prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    /**
     We hooked every UIViewController and subclasses in +load, because a vc may override -prepareForSegue:sender: and not call [super prepareForSegue:sender:].
     If subclass vc call [super prepareForSegue:sender:] in it's -prepareForSegue:sender:, because it's superclass's -prepareForSegue:sender: was alse hooked, we will enter -ZIKViewRouter_hook_prepareForSegue:sender: for superclass. But we can't invoke superclass's original implementation by [self ZIKViewRouter_hook_prepareForSegue:sender:], it will call current class's original implementation, then there is an endless loop.
     To sovle this, we use a 'currentClassCalling' variable to mark the next class which calling -prepareForSegue:sender:, if -prepareForSegue:sender: was called again in a same call stack, fetch the original implementation in 'currentClassCalling', and just call original implementation, don't enter -ZIKViewRouter_hook_prepareForSegue:sender: again.
     
     Something else: this solution relies on correct use of [super prepareForSegue:sender:]. Every time -prepareForSegue:sender: was invoked, the 'currentClassCalling' will be updated as 'currentClassCalling = [currentClassCalling superclass]'.So these codes will lead to bug:
     1. - (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
     [super prepareForSegue:segue sender:sender];
     [super prepareForSegue:segue sender:sender];
     }
     1. - (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
     dispatch_async(dispatch_get_main_queue(), ^{
     [super prepareForSegue:segue sender:sender];
     });
     }
     These bad implementations should never exist in your code, so we ignore these situations.
     */
    Class currentClassCalling = [(UIViewController *)self zix_currentClassCallingPrepareForSegue];
    if (!currentClassCalling) {
        currentClassCalling = [self class];
    }
    [(UIViewController *)self setZix_currentClassCallingPrepareForSegue:[currentClassCalling superclass]];
    
    if (currentClassCalling != [self class]) {
        //Call [super prepareForSegue:segue sender:sender]
        Method superMethod = class_getInstanceMethod(currentClassCalling, @selector(ZIKViewRouter_hook_prepareForSegue:sender:));
        IMP superImp = method_getImplementation(superMethod);
        NSAssert(superMethod && superImp, @"ZIKViewRouter_hook_prepareForSegue:sender: should exist in super");
        if (superImp) {
            ((void(*)(id, SEL, UIStoryboardSegue *, id))superImp)(self, @selector(prepareForSegue:sender:), segue, sender);
        }
        return;
    }
    
    UIViewController *source = segue.sourceViewController;
    UIViewController *destination = segue.destinationViewController;
    
    BOOL isUnwindSegue = YES;
    if (![destination isViewLoaded] ||
        (!destination.parentViewController &&
         !destination.presentingViewController)) {
            isUnwindSegue = NO;
        }
    
    //The router performing route for this view controller
    ZIKViewRouter *sourceRouter = [(UIViewController *)self zix_sourceViewRouter];
    if (sourceRouter) {
        //This segue is performed from router, see -_performSegueWithIdentifier:fromSource:sender:
        ZIKViewRouteSegueConfiguration *configuration = sourceRouter.original_configuration.segueConfiguration;
        if (!configuration.segueSource) {
            NSAssert([segue.identifier isEqualToString:configuration.identifier], @"should be same identifier");
            [sourceRouter attachDestination:destination];
            configuration.segueSource = source;
            configuration.segueDestination = destination;
            configuration.destinationStateBeforeRoute = [destination zix_presentationState];
            if (isUnwindSegue) {
                sourceRouter.realRouteType = ZIKViewRouteRealTypeUnwind;
            }
        }
        
        [(UIViewController *)self setZix_sourceViewRouter:nil];
        [source setZix_sourceViewRouter:sourceRouter];//Set nil in -ZIKViewRouter_hook_seguePerform
    }
    
    //The sourceRouter and routers for child view controllers conform to ZIKRoutableView in destination
    NSMutableArray<ZIKViewRouter *> *destinationRouters;
    NSMutableArray<UIViewController *> *routableViews;
    
    if (!isUnwindSegue) {
        destinationRouters = [NSMutableArray array];
        if ([destination conformsToProtocol:@protocol(ZIKRoutableView)]) {//if destination is ZIKRoutableView, create router for it
            if (sourceRouter && sourceRouter.original_configuration.segueConfiguration.segueDestination == destination) {
                [destinationRouters addObject:sourceRouter];//If this segue is performed from router, don't auto create router again
            } else {
                routableViews = [NSMutableArray array];
                [routableViews addObject:destination];
            }
        }
        
        NSArray<UIViewController *> *subRoutableViews = [ZIKViewRouter routableViewsInContainerViewController:destination];//Search child view controllers conform to ZIKRoutableView in destination
        if (subRoutableViews.count > 0) {
            if (!routableViews) {
                routableViews = [NSMutableArray array];
            }
            [routableViews addObjectsFromArray:subRoutableViews];
        }
        
        //Generate router for each routable view
        if (routableViews.count > 0) {
            for (UIViewController *routableView in routableViews) {
                Class routerClass = ZIKViewRouterToRegisteredView([routableView class]);
                NSAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]], @"Destination's view router should be subclass of ZIKViewRouter");
                ZIKViewRouter *destinationRouter = [routerClass routerFromSegueIdentifier:segue.identifier sender:sender destination:routableView source:(UIViewController *)self];
                destinationRouter.routingFromInternal = YES;
                ZIKViewRouteSegueConfiguration *segueConfig = destinationRouter.original_configuration.segueConfiguration;
                NSAssert(destinationRouter && segueConfig, @"Failed to create router.");
                segueConfig.destinationStateBeforeRoute = [routableView zix_presentationState];
                if (destinationRouter) {
                    [destinationRouters addObject:destinationRouter];
                }
            }
        }
        if (destinationRouters.count > 0) {
            [destination setZix_destinationViewRouters:destinationRouters];//Get and set nil in -ZIKViewRouter_hook_seguePerform
        }
    }
    
    //Call original implementation of current class
    [self ZIKViewRouter_hook_prepareForSegue:segue sender:sender];
    [(UIViewController *)self setZix_currentClassCallingPrepareForSegue:nil];
    
    //Prepare for unwind destination or unroutable views
    if (sourceRouter && sourceRouter.original_configuration.segueConfiguration.segueDestination == destination) {
        void(^prepareForRouteInSourceRouter)(id destination);
        if (sourceRouter) {
            prepareForRouteInSourceRouter = sourceRouter.original_configuration.prepareForRoute;
        }
        if (isUnwindSegue) {
            if (prepareForRouteInSourceRouter) {
                prepareForRouteInSourceRouter(destination);
            }
            return;
        }
        if (![destination conformsToProtocol:@protocol(ZIKRoutableView)]) {
            if (prepareForRouteInSourceRouter) {
                prepareForRouteInSourceRouter(destination);
            }
        }
    }
    //Prepare routable views
    for (NSInteger idx = 0; idx < destinationRouters.count; idx++) {
        ZIKViewRouter *router = [destinationRouters objectAtIndex:idx];
        UIViewController * routableView = router.destination;
        NSAssert(routableView, @"Destination wasn't set when create destinationRouters");
        [routableView setZix_routeTypeFromRouter:@(ZIKViewRouteTypePerformSegue)];
        [router notifyRouteState:ZIKRouterStateRouting];
        if (sourceRouter) {
            //Segue is performed from a router
            [router prepareForPerformRouteOnDestination:routableView];
        } else {
            //View controller is from storyboard, need to notify the performer of segue to config the destination
            [ZIKViewRouter _prepareDestinationFromExternal:routableView router:router performer:(UIViewController *)self];
        }
        [ZIKViewRouter AOP_notifyAll_router:router willPerformRouteOnDestination:routableView fromSource:source];
    }
}

- (void)ZIKViewRouter_hook_seguePerform {
    Class currentClassCalling = [(UIStoryboardSegue *)self zix_currentClassCallingPerform];
    if (!currentClassCalling) {
        currentClassCalling = [self class];
    }
    [(UIStoryboardSegue *)self setZix_currentClassCallingPerform:[currentClassCalling superclass]];
    
    if (currentClassCalling != [self class]) {
        //[super perform]
        Method superMethod = class_getInstanceMethod(currentClassCalling, @selector(ZIKViewRouter_hook_seguePerform));
        IMP superImp = method_getImplementation(superMethod);
        NSAssert(superMethod && superImp, @"ZIKViewRouter_hook_seguePerform should exist in super");
        if (superImp) {
            ((void(*)(id, SEL))superImp)(self, @selector(perform));
        }
        return;
    }
    
    UIViewController *destination = [(UIStoryboardSegue *)self destinationViewController];
    UIViewController *source = [(UIStoryboardSegue *)self sourceViewController];
    ZIKViewRouter *sourceRouter = [source zix_sourceViewRouter];//Was set in -ZIKViewRouter_hook_prepareForSegue:sender:
    NSArray<ZIKViewRouter *> *destinationRouters = [destination zix_destinationViewRouters];
    
    //Call original implementation of current class
    [self ZIKViewRouter_hook_seguePerform];
    [(UIStoryboardSegue *)self setZix_currentClassCallingPerform:nil];
    
    if (destinationRouters.count > 0) {
        [destination setZix_destinationViewRouters:nil];
    }
    if (sourceRouter) {
        [source setZix_sourceViewRouter:nil];
    }
    
    id <UIViewControllerTransitionCoordinator> transitionCoordinator = [source zix_currentTransitionCoordinator];
    if (!transitionCoordinator) {
        transitionCoordinator = [destination zix_currentTransitionCoordinator];
    }
    if (sourceRouter) {
        //Complete unwind route. Unwind route doesn't need to config destination
        if (sourceRouter.realRouteType == ZIKViewRouteRealTypeUnwind &&
            sourceRouter.original_configuration.segueConfiguration.segueDestination == destination) {
            [ZIKViewRouter _completeWithtransitionCoordinator:transitionCoordinator transitionCompletion:^{
                [sourceRouter notifyRouteState:ZIKRouterStateRouted];
                [sourceRouter notifyPerformRouteSuccessWithDestination:destination];
                sourceRouter.routingFromInternal = NO;
            }];
            return;
        }
    }
    
    //Complete routable views
    for (NSInteger idx = 0; idx < destinationRouters.count; idx++) {
        ZIKViewRouter *router = [destinationRouters objectAtIndex:idx];
        UIViewController *routableView = router.destination;
        ZIKPresentationState *destinationStateBeforeRoute = router.original_configuration.segueConfiguration.destinationStateBeforeRoute;
        NSAssert(destinationStateBeforeRoute, @"Didn't set state in -ZIKViewRouter_hook_prepareForSegue:sender:");
        [ZIKViewRouter _completeRouter:router
          analyzeRouteTypeForDestination:routableView
                                  source:source
             destinationStateBeforeRoute:destinationStateBeforeRoute
                   transitionCoordinator:transitionCoordinator
                              completion:^{
                                  NSAssert(router.state == ZIKRouterStateRouting, @"state should be routing when end route");
                                  [router notifyRouteState:ZIKRouterStateRouted];
                                  [router notifyPerformRouteSuccessWithDestination:routableView];
                                  if (sourceRouter) {
                                      if (routableView == sourceRouter.destination) {
                                          NSAssert(idx == 0, @"If destination is in destinationRouters, it should be at index 0.");
                                          NSAssert(router == sourceRouter, nil);
                                      }
                                  }
                                  [ZIKViewRouter AOP_notifyAll_router:router didPerformRouteOnDestination:routableView fromSource:source];
                                  router.routingFromInternal = NO;
                              }];
    }
    //Complete unroutable view
    if (sourceRouter && sourceRouter.original_configuration.segueConfiguration.segueDestination == destination && ![destination conformsToProtocol:@protocol(ZIKRoutableView)]) {
        ZIKPresentationState *destinationStateBeforeRoute = sourceRouter.original_configuration.segueConfiguration.destinationStateBeforeRoute;
        NSAssert(destinationStateBeforeRoute, @"Didn't set state in -ZIKViewRouter_hook_prepareForSegue:sender:");
        [ZIKViewRouter _completeRouter:sourceRouter
          analyzeRouteTypeForDestination:destination
                                  source:source
             destinationStateBeforeRoute:destinationStateBeforeRoute
                   transitionCoordinator:transitionCoordinator
                              completion:^{
                                  [sourceRouter notifyRouteState:ZIKRouterStateRouted];
                                  [sourceRouter notifyPerformRouteSuccessWithDestination:destination];
                                  sourceRouter.routingFromInternal = NO;
                              }];
    }
}

///Search child view controllers conforming to ZIKRoutableView in vc, if the vc is a container or is system class
+ (nullable NSArray<UIViewController *> *)routableViewsInContainerViewController:(UIViewController *)vc {
    NSMutableArray *routableViews;
    NSArray<__kindof UIViewController *> *childViewControllers = vc.childViewControllers;
    if (childViewControllers.count == 0) {
        return routableViews;
    }
    
    BOOL isContainerVC = NO;
    BOOL isSystemViewController = NO;
    NSArray<UIViewController *> *rootVCs;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        isContainerVC = YES;
        if ([(UINavigationController *)vc viewControllers].count > 0) {
            UIViewController *rootViewController = [[(UINavigationController *)vc viewControllers] firstObject];
            if (rootViewController) {
                rootVCs = @[rootViewController];
            } else {
                rootVCs = @[];
            }
        }
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        isContainerVC = YES;
        rootVCs = [(UITabBarController *)vc viewControllers];
    } else if ([vc isKindOfClass:[UISplitViewController class]]) {
        isContainerVC = YES;
        rootVCs = [(UISplitViewController *)vc viewControllers];
    }
    
    if (ZIKRouter_classIsCustomClass([vc class]) == NO) {
        isSystemViewController = YES;
    }
    if (isContainerVC) {
        if (!routableViews) {
            routableViews = [NSMutableArray array];
        }
        for (UIViewController *child in rootVCs) {
            if ([child conformsToProtocol:@protocol(ZIKRoutableView)]) {
                [routableViews addObject:child];
            } else {
                NSArray<UIViewController *> *routableViewsInChild = [self routableViewsInContainerViewController:child];
                if (routableViewsInChild.count > 0) {
                    [routableViews addObjectsFromArray:routableViewsInChild];
                }
            }
        }
    }
    if (isSystemViewController) {
        if (!routableViews) {
            routableViews = [NSMutableArray array];
        }
        for (UIViewController *child in vc.childViewControllers) {
            if (rootVCs && [rootVCs containsObject:child]) {
                continue;
            }
            if ([child conformsToProtocol:@protocol(ZIKRoutableView)]) {
                [routableViews addObject:child];
            } else {
                NSArray<UIViewController *> *routableViewsInChild = [self routableViewsInContainerViewController:child];
                if (routableViewsInChild.count > 0) {
                    [routableViews addObjectsFromArray:routableViewsInChild];
                }
            }
        }
    }
    return routableViews;
}

#pragma mark Validate

+ (BOOL)_validateRouteTypeInConfiguration:(ZIKViewRouteConfiguration *)configuration {
    if (![self supportRouteType:configuration.routeType]) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateRouteSourceNotMissedInConfiguration:(ZIKViewRouteConfiguration *)configuration {
    if (!configuration.source) {
        if (configuration.routeType != ZIKViewRouteTypeCustom && configuration.routeType != ZIKViewRouteTypeGetDestination) {
            NSLog(@"");
        }
    }
    if (!configuration.source &&
        (configuration.routeType != ZIKViewRouteTypeCustom &&
        configuration.routeType != ZIKViewRouteTypeGetDestination)) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateRouteSourceClassInConfiguration:(ZIKViewRouteConfiguration *)configuration {
    if (!configuration.source &&
        (configuration.routeType != ZIKViewRouteTypeCustom &&
         configuration.routeType != ZIKViewRouteTypeGetDestination)) {
        return NO;
    }
    id source = configuration.source;
    switch (configuration.routeType) {
        case ZIKViewRouteTypeAddAsSubview:
            if (![source isKindOfClass:[UIView class]]) {
                return NO;
            }
            break;
            
        case ZIKViewRouteTypePerformSegue:
            break;
            
        case ZIKViewRouteTypeCustom:
        case ZIKViewRouteTypeGetDestination:
            break;
        default:
            if (![source isKindOfClass:[UIViewController class]]) {
                return NO;
            }
            break;
    }
    return YES;
}

+ (BOOL)_validateSegueInConfiguration:(ZIKViewRouteConfiguration *)configuration {
    if (!configuration.segueConfiguration.identifier && !configuration.autoCreated) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validatePopoverInConfiguration:(ZIKViewRouteConfiguration *)configuration {
    ZIKViewRoutePopoverConfiguration *popoverConfig = configuration.popoverConfiguration;
    if (!popoverConfig ||
        (!popoverConfig.barButtonItem && !popoverConfig.sourceView)) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateDestinationShouldExistInConfiguration:(ZIKViewRouteConfiguration *)configuration {
    if (configuration.routeType == ZIKViewRouteTypePerformSegue) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateDestinationClass:(nullable id)destination inConfiguration:(ZIKViewRouteConfiguration *)configuration {
    NSAssert(!destination || [destination conformsToProtocol:@protocol(ZIKRoutableView)], @"Destination must conforms to ZIKRoutableView. It's used to config view not created from router.");
    
    switch (configuration.routeType) {
        case ZIKViewRouteTypeAddAsSubview:
            if ([destination isKindOfClass:[UIView class]]) {
                NSAssert([[self class] _validateSupportedRouteTypesForUIView], @"%@ 's +supportedRouteTypes returns error types, if destination is a UIView, %@ only support ZIKViewRouteTypeAddAsSubview and ZIKViewRouteTypeCustom",[self class], [self class]);
                return YES;
            }
            break;
        case ZIKViewRouteTypeCustom:
            if ([destination isKindOfClass:[UIView class]]) {
                NSAssert([[self class] _validateSupportedRouteTypesForUIView], @"%@ 's +supportedRouteTypes returns error types, if destination is a UIView, %@ only support ZIKViewRouteTypeAddAsSubview and ZIKViewRouteTypeCustom, if use ZIKViewRouteTypeCustom, router must implement -performCustomRouteOnDestination:fromSource:configuration:.",[self class], [self class]);
                return YES;
            } else if ([destination isKindOfClass:[UIViewController class]]) {
                NSAssert([[self class] _validateSupportedRouteTypesForUIViewController], @"%@ 's +supportedRouteTypes returns error types, if destination is a UIViewController, %@ can't support ZIKViewRouteTypeAddAsSubview, if use ZIKViewRouteTypeCustom, router must implement -performCustomRouteOnDestination:fromSource:configuration:.",[self class], [self class]);
                return YES;
            }
            break;
            
        case ZIKViewRouteTypePerformSegue:
            NSAssert(!destination, @"ZIKViewRouteTypePerformSegue's destination should be created by UIKit automatically");
            return YES;
            break;
        
        case ZIKViewRouteTypeGetDestination:
            if ([destination isKindOfClass:[UIViewController class]] || [destination isKindOfClass:[UIView class]]) {
                return YES;
            }
            break;
            
        default:
            if ([destination isKindOfClass:[UIViewController class]]) {
                NSAssert([[self class] _validateSupportedRouteTypesForUIViewController], @"%@ 's +supportedRouteTypes returns error types, if destination is a UIViewController, %@ can't support ZIKViewRouteTypeAddAsSubview",[self class], [self class]);
                return YES;
            }
            break;
    }
    return NO;
}

+ (BOOL)_validateSourceInNavigationStack:(UIViewController *)source {
    BOOL canPerformPush = [source respondsToSelector:@selector(navigationController)];
    if (!canPerformPush ||
        (canPerformPush && !source.navigationController)) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateDestination:(UIViewController *)destination notInNavigationStackOfSource:(UIViewController *)source {
    NSArray<UIViewController *> *viewControllersInStack = source.navigationController.viewControllers;
    if ([viewControllersInStack containsObject:destination]) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateSourceNotPresentedAnyView:(UIViewController *)source {
    if (source.presentedViewController) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateSourceInWindowHierarchy:(UIViewController *)source {
    if (!source.isViewLoaded) {
        return NO;
    }
    if (!source.view.superview) {
        return NO;
    }
    if (!source.view.window) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateSupportedRouteTypesForUIView {
    ZIKViewRouteTypeMask supportedRouteTypes = [self supportedRouteTypes];
    if ((supportedRouteTypes & ZIKViewRouteTypeMaskCustom) == ZIKViewRouteTypeMaskCustom) {
        if (![self instancesRespondToSelector:@selector(performCustomRouteOnDestination:fromSource:configuration:)]) {
            return NO;
        }
    }
    if ((supportedRouteTypes & ZIKViewRouteTypeMaskAddAsSubview & ZIKViewRouteTypeMaskGetDestination & ZIKViewRouteTypeMaskCustom) != 0) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateSupportedRouteTypesForUIViewController {
    ZIKViewRouteTypeMask supportedRouteTypes = [self supportedRouteTypes];
    if ((supportedRouteTypes & ZIKViewRouteTypeMaskCustom) == ZIKViewRouteTypeMaskCustom) {
        if (![self instancesRespondToSelector:@selector(performCustomRouteOnDestination:fromSource:configuration:)]) {
            return NO;
        }
    }
    if ((supportedRouteTypes & ZIKViewRouteTypeMaskAddAsSubview) == ZIKViewRouteTypeMaskAddAsSubview) {
        return NO;
    }
    return YES;
}

+ (BOOL)_validateInfiniteRecursion {
    NSUInteger maxRecursiveDepth = 200;
    if ([self recursiveDepth] > maxRecursiveDepth) {
        return NO;
    }
    return YES;
}

#pragma mark Error Handle

+ (NSString *)errorDomain {
    return kZIKViewRouteErrorDomain;
}

+ (void)setGlobalErrorHandler:(ZIKViewRouteGlobalErrorHandler)globalErrorHandler {
    dispatch_semaphore_wait(g_globalErrorSema, DISPATCH_TIME_FOREVER);
    
    g_globalErrorHandler = globalErrorHandler;
    
    dispatch_semaphore_signal(g_globalErrorSema);
}

- (void)_callbackErrorWithAction:(SEL)routeAction error:(NSError *)error {
    [[self class] _callbackGlobalErrorHandlerWithRouter:self action:routeAction error:error];
    [super notifyError:error routeAction:routeAction];
}

//Call your errorHandler and globalErrorHandler, use this if you don't want to affect the routing
- (void)_callbackError_errorCode:(ZIKViewRouteError)code
                      errorHandler:(void(^)(SEL routeAction, NSError *error))errorHandler
                            action:(SEL)action
                  errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    
    NSError *error = [[self class] errorWithCode:code localizedDescription:description];
    [[self class] _callbackGlobalErrorHandlerWithRouter:self action:action error:error];
    if (errorHandler) {
        errorHandler(action,error);
    }
}

+ (void)_callbackError_invalidPerformerWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackGlobalErrorHandlerWithRouter:nil action:action error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidPerformer localizedDescription:description]];
}

+ (void)_callbackError_invalidProtocolWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [[self class] _callbackGlobalErrorHandlerWithRouter:nil action:action error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidProtocol localizedDescription:description]];
    NSAssert(NO, @"Error when get router for viewProtocol: %@",description);
}

- (void)_callbackError_invalidConfigurationWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidConfiguration localizedDescription:description]];
}

- (void)_callbackError_unsupportTypeWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorUnsupportType localizedDescription:description]];
}

- (void)_callbackError_unbalancedTransitionWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [[self class] _callbackGlobalErrorHandlerWithRouter:self action:action error:[[self class] errorWithCode:ZIKViewRouteErrorUnbalancedTransition localizedDescription:description]];
    NSAssert(NO, @"Unbalanced calls to begin/end appearance transitions for destination. This error occurs when you try and display a view controller before the current view controller is finished displaying. This may cause the UIViewController skips or messes up the order calling -viewWillAppear:, -viewDidAppear:, -viewWillDisAppear: and -viewDidDisappear:, and messes up the route state.");
}

- (void)_callbackError_invalidSourceWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidSource localizedDescription:description]];
}

- (void)_callbackError_invalidContainerWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidContainer localizedDescription:description]];
}

- (void)_callbackError_actionFailedWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorActionFailed localizedDescription:description]];
}

- (void)_callbackError_segueNotPerformedWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorSegueNotPerformed localizedDescription:description]];
}

- (void)_callbackError_overRouteWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorOverRoute localizedDescription:description]];
}

- (void)_callbackError_infiniteRecursionWithAction:(SEL)action errorDescription:(NSString *)format ,... {
    va_list argList;
    va_start(argList, format);
    NSString *description = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    [self _callbackErrorWithAction:action error:[[self class] errorWithCode:ZIKViewRouteErrorInfiniteRecursion localizedDescription:description]];
}

#pragma mark Getter/Setter

- (BOOL)autoCreated {
    return self.original_configuration.autoCreated;
}

+ (NSUInteger)recursiveDepth {
    NSNumber *depth = objc_getAssociatedObject(self, @"ZIKViewRouter_recursiveDepth");
    if ([depth isKindOfClass:[NSNumber class]]) {
        return [depth unsignedIntegerValue];
    }
    return 0;
}

+ (void)setRecursiveDepth:(NSUInteger)depth {
    objc_setAssociatedObject(self, @"ZIKViewRouter_recursiveDepth", @(depth), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)increaseRecursiveDepth {
    NSUInteger depth = [self recursiveDepth];
    [self setRecursiveDepth:++depth];
}

+ (void)decreaseRecursiveDepth {
    NSUInteger depth = [self recursiveDepth];
    [self setRecursiveDepth:--depth];
}

#pragma mark Debug

+ (NSString *)descriptionOfRouteType:(ZIKViewRouteType)routeType {
    NSString *description;
    switch (routeType) {
        case ZIKViewRouteTypePush:
            description = @"Push";
            break;
        case ZIKViewRouteTypePresentModally:
            description = @"PresentModally";
            break;
        case ZIKViewRouteTypePresentAsPopover:
            description = @"PresentAsPopover";
            break;
        case ZIKViewRouteTypePerformSegue:
            description = @"PerformSegue";
            break;
        case ZIKViewRouteTypeShow:
            description = @"Show";
            break;
        case ZIKViewRouteTypeShowDetail:
            description = @"ShowDetail";
            break;
        case ZIKViewRouteTypeAddAsChildViewController:
            description = @"AddAsChildViewController";
            break;
        case ZIKViewRouteTypeAddAsSubview:
            description = @"AddAsSubview";
            break;
        case ZIKViewRouteTypeCustom:
            description = @"Custom";
            break;
        case ZIKViewRouteTypeGetDestination:
            description = @"GetDestination";
            break;
    }
    return description;
}

+ (NSString *)descriptionOfRealRouteType:(ZIKViewRouteRealType)routeType {
    NSString *description;
    switch (routeType) {
        case ZIKViewRouteRealTypeUnknown:
            description = @"Unknown";
            break;
        case ZIKViewRouteRealTypePush:
            description = @"Push";
            break;
        case ZIKViewRouteRealTypePresentModally:
            description = @"PresentModally";
            break;
        case ZIKViewRouteRealTypePresentAsPopover:
            description = @"PresentAsPopover";
            break;
        case ZIKViewRouteRealTypeAddAsChildViewController:
            description = @"AddAsChildViewController";
            break;
        case ZIKViewRouteRealTypeAddAsSubview:
            description = @"AddAsSubview";
            break;
        case ZIKViewRouteRealTypeUnwind:
            description = @"Unwind";
            break;
        case ZIKViewRouteRealTypeCustom:
            description = @"Custom";
            break;
    }
    return description;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@, realRouteType:%@, autoCreated:%d",[super description],[[self class] descriptionOfRealRouteType:self.realRouteType],self.autoCreated];
}

@end

@implementation ZIKViewRouter (Perform)

- (BOOL)canPerform {
    return [self _canPerformWithErrorMessage:NULL];
}

+ (BOOL)supportRouteType:(ZIKViewRouteType)type {
    ZIKViewRouteTypeMask supportedRouteTypes = [self supportedRouteTypes];
    ZIKViewRouteTypeMask mask = 1 << type;
    if ((supportedRouteTypes & mask) == mask) {
        return YES;
    }
    return NO;
}

+ (nullable __kindof ZIKViewRouter *)performFromSource:(nullable id<ZIKViewRouteSource>)source configuring:(void(NS_NOESCAPE ^)(ZIKViewRouteConfiguration *config))configBuilder {
    return [super performWithConfiguring:^(ZIKViewRouteConfiguration * _Nonnull config) {
        if (configBuilder) {
            configBuilder(config);
        }
        if (source) {
            config.source = source;
        }
    }];
}

+ (nullable __kindof ZIKViewRouter *)performFromSource:(nullable id<ZIKViewRouteSource>)source
                                           configuring:(void(NS_NOESCAPE ^)(ZIKViewRouteConfiguration *config))configBuilder
                                              removing:(void(NS_NOESCAPE ^ _Nullable)(ZIKViewRemoveConfiguration *config))removeConfigBuilder {
    return [super performWithConfiguring:^(ZIKViewRouteConfiguration * _Nonnull config) {
        if (configBuilder) {
            configBuilder(config);
        }
        if (source) {
            config.source = source;
        }
    } removing:removeConfigBuilder];
}

+ (__kindof ZIKViewRouter *)performFromSource:(nullable id)source routeType:(ZIKViewRouteType)routeType {
    return [super performWithConfiguring:^(ZIKRouteConfiguration *configuration) {
        ZIKViewRouteConfiguration *config = (ZIKViewRouteConfiguration *)configuration;
        if (source) {
            config.source = source;
        }
        config.routeType = routeType;
    }];
}

@end

@implementation ZIKViewRouter (Factory)

+ (nullable id)makeDestinationWithPreparation:(void(^ _Nullable)(id destination))prepare {
    NSAssert(self != [ZIKViewRouter class], @"Only get destination from router subclass");
    NSAssert1([self completeSynchronously] == YES, @"The router (%@) should return the destination Synchronously when use +destinationForConfigure",self);
    ZIKViewRouter *router = [[self alloc] initWithConfiguring:(void(^)(ZIKRouteConfiguration*))^(ZIKViewRouteConfiguration * _Nonnull config) {
        config.routeType = ZIKViewRouteTypeGetDestination;
        if (prepare) {
            config.prepareForRoute = ^(id  _Nonnull destination) {
                prepare(destination);
            };
        }
    } removing:nil];
    [router performRoute];
    return router.destination;
}

+ (nullable id)makeDestination {
    return [self makeDestinationWithPreparation:nil];
}

@end

@implementation ZIKViewRouter (PerformOnDestination)

+ (nullable __kindof ZIKViewRouter *)performOnDestination:(id)destination
                                               fromSource:(nullable id<ZIKViewRouteSource>)source
                                              configuring:(void(NS_NOESCAPE ^)(ZIKViewRouteConfiguration *config))configBuilder
                                                 removing:(void(NS_NOESCAPE ^ _Nullable)(ZIKViewRemoveConfiguration *config))removeConfigBuilder {
    if (![destination conformsToProtocol:@protocol(ZIKRoutableView)]) {
        [[self class] _callbackGlobalErrorHandlerWithRouter:nil action:@selector(init) error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidConfiguration localizedDescription:[NSString stringWithFormat:@"Perform route on invalid destination: (%@)",destination]]];
        NSAssert1(NO, @"Perform route on invalid destination: (%@)",destination);
        return nil;
    }
    CFMutableSetRef routers = (CFMutableSetRef)CFDictionaryGetValue(g_viewToRoutersMap, (__bridge const void *)([destination class]));
    BOOL valid = YES;
    if (!routers) {
        valid = NO;
    } else {
        NSSet *registeredRouters = (__bridge NSSet *)(routers);
        if (![registeredRouters containsObject:[self class]]) {
            valid = NO;
        }
    }
    if (!valid) {
        [[self class] _callbackGlobalErrorHandlerWithRouter:nil action:@selector(performOnDestination:fromSource:configuring:removing:) error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidConfiguration localizedDescription:[NSString stringWithFormat:@"Perform route on invalid destination (%@), this view is not registered with this router (%@)",destination,self]]];
        NSAssert2(NO, @"Perform route on invalid destination (%@), this view is not registered with this router (%@)",destination,self);
        return nil;
    }
    ZIKViewRouter *router = [[self alloc] initWithConfiguring:(void(^)(ZIKRouteConfiguration *))configBuilder removing:(void(^)(ZIKRouteConfiguration *))removeConfigBuilder];
    NSAssert(router.original_configuration.routeType != ZIKViewRouteTypeGetDestination, @"It's meaningless to get destination when you already offer a prepared destination.");
    if (source) {
        router.original_configuration.source = source;
    }
    [router attachDestination:destination];
    [router performRouteOnDestination:destination configuration:router.original_configuration];
    return router;
}

+ (nullable __kindof ZIKViewRouter *)performOnDestination:(id)destination
                                               fromSource:(nullable id<ZIKViewRouteSource>)source
                                              configuring:(void(NS_NOESCAPE ^)(ZIKViewRouteConfiguration *config))configBuilder {
    return [self performOnDestination:destination fromSource:source configuring:configBuilder removing:nil];
}

+ (__kindof ZIKViewRouter *)performOnDestination:(id)destination
                                      fromSource:(nullable id<ZIKViewRouteSource>)source
                                       routeType:(ZIKViewRouteType)routeType {
    return [self performOnDestination:destination fromSource:source configuring:^(__kindof ZIKViewRouteConfiguration * _Nonnull config) {
        config.routeType = routeType;
    } removing:nil];
}

@end

@implementation ZIKViewRouter (Prepare)

+ (nullable __kindof ZIKViewRouter *)prepareDestination:(id)destination
                                            configuring:(void(NS_NOESCAPE ^)(ZIKViewRouteConfiguration *config))configBuilder
                                               removing:(void(NS_NOESCAPE ^ _Nullable)(ZIKViewRemoveConfiguration *config))removeConfigBuilder {
    if (![destination conformsToProtocol:@protocol(ZIKRoutableView)]) {
        [[self class] _callbackGlobalErrorHandlerWithRouter:nil action:@selector(prepareDestination:configuring:removing:) error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidConfiguration localizedDescription:[NSString stringWithFormat:@"Prepare for invalid destination: (%@)",destination]]];
        NSAssert1(NO, @"Prepare for invalid destination: (%@)",destination);
        return nil;
    }
    CFMutableSetRef routers = (CFMutableSetRef)CFDictionaryGetValue(g_viewToRoutersMap, (__bridge const void *)([destination class]));
    BOOL valid = YES;
    if (!routers) {
        valid = NO;
    } else {
        NSSet *registeredRouters = (__bridge NSSet *)(routers);
        if (![registeredRouters containsObject:[self class]]) {
            valid = NO;
        }
    }
    if (!valid) {
        [[self class] _callbackGlobalErrorHandlerWithRouter:nil action:@selector(prepareDestination:configuring:removing:) error:[[self class] errorWithCode:ZIKViewRouteErrorInvalidConfiguration localizedDescription:[NSString stringWithFormat:@"Prepare for invalid destination (%@), this view is not registered with this router (%@)",destination,self]]];
        NSAssert2(NO, @"Prepare for invalid destination (%@), this view is not registered with this router (%@)",destination,self);
        return nil;
    }
    ZIKViewRouteConfiguration *configuration = [[self class] defaultRouteConfiguration];
    configuration.routeType = ZIKViewRouteTypeGetDestination;
    if (configBuilder) {
        configBuilder(configuration);
    }
    ZIKViewRemoveConfiguration *removeConfiguration;
    if (removeConfigBuilder) {
        removeConfiguration = [self defaultRemoveConfiguration];
        removeConfigBuilder(removeConfiguration);
    }
    ZIKViewRouter *router =  [[self alloc] initWithConfiguration:configuration removeConfiguration:removeConfiguration];
    [router attachDestination:destination];
    [router prepareForPerformRouteOnDestination:destination];
    
    NSNumber *routeType = [destination zix_routeTypeFromRouter];
    if (routeType == nil) {
        [(id)destination setZix_routeTypeFromRouter:@(ZIKViewRouteTypeGetDestination)];
    }
    return router;
}

+ (nullable __kindof ZIKViewRouter *)prepareDestination:(id)destination
                                            configuring:(void(NS_NOESCAPE ^)(ZIKViewRouteConfiguration *config))configBuilder {
    return [self prepareDestination:destination configuring:configBuilder removing:nil];
}

@end

@implementation ZIKViewRouter (Register)

+ (void)registerView:(Class)viewClass {
    Class routerClass = self;
    NSParameterAssert([viewClass isSubclassOfClass:[UIView class]] ||
                      [viewClass isSubclassOfClass:[UIViewController class]]);
    NSParameterAssert([viewClass conformsToProtocol:@protocol(ZIKRoutableView)]);
    NSParameterAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]]);
    NSAssert(!_isLoadFinished, @"Only register in +registerRoutableDestination.");
    NSAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_viewToDefaultRouterMap) {
            g_viewToDefaultRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
        if (!g_viewToRoutersMap) {
            g_viewToRoutersMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#if ZIKVIEWROUTER_CHECK
        if (!_check_routerToViewsMap) {
            _check_routerToViewsMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#endif
    });
    NSCAssert(!g_viewToExclusiveRouterMap ||
              (g_viewToExclusiveRouterMap && !CFDictionaryGetValue(g_viewToExclusiveRouterMap, (__bridge const void *)(viewClass))), @"There is a registered exclusive router, can't use another router for this viewClass.");
    
    if (!CFDictionaryContainsKey(g_viewToDefaultRouterMap, (__bridge const void *)(viewClass))) {
        CFDictionarySetValue(g_viewToDefaultRouterMap, (__bridge const void *)(viewClass), (__bridge const void *)(routerClass));
    }
    CFMutableSetRef routers = (CFMutableSetRef)CFDictionaryGetValue(g_viewToRoutersMap, (__bridge const void *)(viewClass));
    if (routers == NULL) {
        routers = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(g_viewToRoutersMap, (__bridge const void *)(viewClass), routers);
    }
    CFSetAddValue(routers, (__bridge const void *)(routerClass));
    
#if ZIKVIEWROUTER_CHECK
    CFMutableSetRef views = (CFMutableSetRef)CFDictionaryGetValue(_check_routerToViewsMap, (__bridge const void *)(routerClass));
    if (views == NULL) {
        views = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(_check_routerToViewsMap, (__bridge const void *)(routerClass), views);
    }
    CFSetAddValue(views, (__bridge const void *)(viewClass));
#endif
}

+ (void)registerExclusiveView:(Class)viewClass {
    Class routerClass = self;
    NSCParameterAssert([viewClass isSubclassOfClass:[UIView class]] ||
                       [viewClass isSubclassOfClass:[UIViewController class]]);
    NSCParameterAssert([viewClass conformsToProtocol:@protocol(ZIKRoutableView)]);
    NSCParameterAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]]);
    NSCAssert(!_isLoadFinished, @"Only register in +registerRoutableDestination.");
    NSCAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_viewToExclusiveRouterMap) {
            g_viewToExclusiveRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
        if (!g_viewToDefaultRouterMap) {
            g_viewToDefaultRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
        if (!g_viewToRoutersMap) {
            g_viewToRoutersMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#if ZIKVIEWROUTER_CHECK
        if (!_check_routerToViewsMap) {
            _check_routerToViewsMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#endif
    });
    NSCAssert(!CFDictionaryGetValue(g_viewToExclusiveRouterMap, (__bridge const void *)(viewClass)), @"There is already a registered exclusive router for this viewClass, you can only specific one exclusive router for each viewClass. Choose the one used inside view.");
    NSCAssert(!CFDictionaryGetValue(g_viewToDefaultRouterMap, (__bridge const void *)(viewClass)), @"ViewClass already registered with another router, check and remove them. You shall only use the exclusive router for this viewClass.");
    NSCAssert(!CFDictionaryContainsKey(g_viewToRoutersMap, (__bridge const void *)(viewClass)) ||
              (CFDictionaryContainsKey(g_viewToRoutersMap, (__bridge const void *)(viewClass)) &&
               !CFSetContainsValue(
                                   (CFMutableSetRef)CFDictionaryGetValue(g_viewToRoutersMap, (__bridge const void *)(viewClass)),
                                   (__bridge const void *)(routerClass)
                                   ))
              , @"ViewClass already registered with another router, check and remove them. You shall only use the exclusive router for this viewClass.");
    
    CFDictionarySetValue(g_viewToExclusiveRouterMap, (__bridge const void *)(viewClass), (__bridge const void *)(routerClass));
    CFDictionarySetValue(g_viewToDefaultRouterMap, (__bridge const void *)(viewClass), (__bridge const void *)(routerClass));
    CFMutableSetRef routers = (CFMutableSetRef)CFDictionaryGetValue(g_viewToRoutersMap, (__bridge const void *)(viewClass));
    if (routers == NULL) {
        routers = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(g_viewToRoutersMap, (__bridge const void *)(viewClass), routers);
    }
    CFSetAddValue(routers, (__bridge const void *)(routerClass));
    
#if ZIKVIEWROUTER_CHECK
    CFMutableSetRef views = (CFMutableSetRef)CFDictionaryGetValue(_check_routerToViewsMap, (__bridge const void *)(routerClass));
    if (views == NULL) {
        views = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(_check_routerToViewsMap, (__bridge const void *)(routerClass), views);
    }
    CFSetAddValue(views, (__bridge const void *)(viewClass));
#endif
}

+ (void)registerViewProtocol:(Protocol *)viewProtocol {
    Class routerClass = self;
    NSParameterAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]]);
    NSAssert(!_isLoadFinished, @"Only register in +registerRoutableDestination.");
    NSAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
#if ZIKVIEWROUTER_CHECK
    NSAssert1(protocol_conformsToProtocol(viewProtocol, @protocol(ZIKViewRoutable)), @"%@ should conforms to ZIKViewRoutable in DEBUG mode for safety checking", NSStringFromProtocol(viewProtocol));
#endif
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_viewProtocolToRouterMap) {
            g_viewProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    NSAssert(!CFDictionaryGetValue(g_viewProtocolToRouterMap, (__bridge const void *)(viewProtocol)) ||
             (Class)CFDictionaryGetValue(g_viewProtocolToRouterMap, (__bridge const void *)(viewProtocol)) == routerClass
             , @"Protocol already registered by another router, viewProtocol should only be used by this routerClass.");
    
    CFDictionarySetValue(g_viewProtocolToRouterMap, (__bridge const void *)(viewProtocol), (__bridge const void *)(routerClass));
}

+ (void)registerModuleProtocol:(Protocol *)configProtocol {
    Class routerClass = self;
    NSParameterAssert([routerClass isSubclassOfClass:[ZIKViewRouter class]]);
    NSAssert2([[routerClass defaultRouteConfiguration] conformsToProtocol:configProtocol], @"configProtocol(%@) should be conformed by this router(%@)'s defaultRouteConfiguration.",NSStringFromProtocol(configProtocol),self);
    NSAssert(!_isLoadFinished, @"Only register in +registerRoutableDestination.");
    NSAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
#if ZIKVIEWROUTER_CHECK
    NSAssert1(protocol_conformsToProtocol(configProtocol, @protocol(ZIKViewModuleRoutable)), @"%@ should conforms to ZIKViewModuleRoutable in DEBUG mode for safety checking", NSStringFromProtocol(configProtocol));
#endif
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_configProtocolToRouterMap) {
            g_configProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    NSAssert(!CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol)) ||
             (Class)CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol)) == routerClass
             , @"Protocol already registered by another router, configProtocol should only be used by this routerClass.");
    
    CFDictionarySetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol), (__bridge const void *)(routerClass));
}

@end

@implementation ZIKViewRouter (Discover)

+ (Class(^)(Protocol *))toView {
    return ^(Protocol *viewProtocol) {
        return _ZIKViewRouterToView(viewProtocol);
    };
}

+ (Class(^)(Protocol *))toModule {
    return ^(Protocol *configProtocol) {
        return _ZIKViewRouterToModule(configProtocol);
    };
}

@end

@implementation ZIKViewRouter (Private)

+ (void)_callbackGlobalErrorHandlerWithRouter:(nullable __kindof ZIKViewRouter *)router action:(SEL)action error:(NSError *)error {
    dispatch_semaphore_wait(g_globalErrorSema, DISPATCH_TIME_FOREVER);
    
    ZIKViewRouteGlobalErrorHandler errorHandler = g_globalErrorHandler;
    if (errorHandler) {
        errorHandler(router, action, error);
    } else {
#ifdef DEBUG
        NSLog(@"❌ZIKViewRouter Error: router's action (%@) catch error: (%@),\nrouter:(%@)", NSStringFromSelector(action), error,router);
#endif
    }
    
    dispatch_semaphore_signal(g_globalErrorSema);
}

+ (BOOL)_isLoadFinished {
    return _isLoadFinished;
}

+ (void)_swift_registerViewProtocol:(id)viewProtocol {
    NSCParameterAssert(ZIKRouter_isObjcProtocol(viewProtocol));
    [self registerViewProtocol:viewProtocol];
}

+ (void)_swift_registerConfigProtocol:(id)configProtocol {
    NSCParameterAssert(ZIKRouter_isObjcProtocol(configProtocol));
    [self registerModuleProtocol:configProtocol];
}

+ (_Nullable Class)validateRegisteredViewClasses:(ZIKViewClassValidater)handler {
#if ZIKVIEWROUTER_CHECK
    Class routerClass = self;
    CFMutableSetRef views = (CFMutableSetRef)CFDictionaryGetValue(_check_routerToViewsMap, (__bridge const void *)(routerClass));
    __block Class badClass = nil;
    [(__bridge NSSet *)(views) enumerateObjectsUsingBlock:^(Class  _Nonnull viewClass, BOOL * _Nonnull stop) {
        if (handler) {
            if (!handler(viewClass)) {
                badClass = viewClass;
                *stop = YES;
            }
            ;
        }
    }];
    return badClass;
#else
    return nil;
#endif
}

_Nullable Class _swift_ZIKViewRouterToView(id viewProtocol) {
    return _ZIKViewRouterToView(viewProtocol);
}

_Nullable Class _swift_ZIKViewRouterToModule(id configProtocol) {
    return _ZIKViewRouterToModule(configProtocol);
}

@end