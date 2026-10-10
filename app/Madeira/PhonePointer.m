// PhonePointer.m — opt-in iPhone pointer experiments (docs/KEYBOARD_MOUSE.md).
//
// On iPhone a mouse reaches apps only through AssistiveTouch, and UIKit keeps
// its pointer machinery (hover, pointer lock) for iPad. Two switches, both off
// by default and read from madeira.cfg when the app starts (MadeiraApp.init,
// before any scene exists, as PojavLauncher does it from main), so a restart is
// needed after changing them:
//
//   env.MADEIRA_PHONE_HOVER = 1
//     UIPointerInteraction leaves its drivers detached on iPhone, so hover
//     never reaches the app and HardwareInput only learns the AssistiveTouch
//     cursor's position from clicks. After UIKit's own update, an enabled
//     interaction's drivers are attached to its view, as on iPad.
//
//   env.MADEIRA_PHONE_IPAD_IDIOM = 1
//     The app runs with the iPad interface idiom (UIDevice and UIScreen), so
//     its pointer-lock request is made at all. Whether the system grants it on
//     iPhone is what this tests: HardwareInput's "[hwinput] system pointer lock"
//     line reports the scene's actual state. Madeira's own screens then use
//     iPad layouts.
//
// Neither changes where iOS sends the mouse; with AssistiveTouch off an iPhone
// still delivers nothing (HardwareInput raises its AssistiveTouch hint).
// madeira_phone_pointer_status() describes what was applied, for the log.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include "../../build/madeira_cfg.h"

@interface UIDevice (MadeiraPhonePointer)
- (void)_setActiveUserInterfaceIdiom:(UIUserInterfaceIdiom)idiom;
@end
@interface UIScreen (MadeiraPhonePointer)
- (void)_setUserInterfaceIdiom:(UIUserInterfaceIdiom)idiom;
@end

static char g_phone_pointer_status[192] = "not run";
static IMP g_update_interaction_orig;

static void madeira_attach_driver(id driver, UIView *view)
{
    if (driver && [driver respondsToSelector:@selector(setView:)])
        ((void (*)(id, SEL, id))objc_msgSend)(driver, @selector(setView:), view);
}

static void madeira_update_interaction_is_enabled(id self, SEL _cmd)
{
    UIPointerInteraction *interaction = self;
    UIView *view;

    ((void (*)(id, SEL))g_update_interaction_orig)(self, _cmd);
    if (!interaction.enabled || !(view = interaction.view)) return;
    if ([interaction respondsToSelector:NSSelectorFromString(@"drivers")])
    {
        for (id driver in [interaction valueForKey:@"drivers"]) madeira_attach_driver(driver, view);
    }
    else if ([interaction respondsToSelector:NSSelectorFromString(@"driver")])
        madeira_attach_driver([interaction valueForKey:@"driver"], view);
}

void madeira_phone_pointer_setup(void)
{
    const char *idiom = "off", *hover = "off";

    @autoreleasepool
    {
        if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone)
        {
            snprintf(g_phone_pointer_status, sizeof(g_phone_pointer_status), "phone=0 (nothing to do)");
            return;
        }
        /* 1: the app runs with the iPad interface idiom on iPhone, so pointer lock is requested (Madeira's screens use iPad layouts) */
        if (madeira_cfg_bool("env.MADEIRA_PHONE_IPAD_IDIOM", 0))
        {
            if ([UIDevice.currentDevice respondsToSelector:@selector(_setActiveUserInterfaceIdiom:)] &&
                [UIScreen.mainScreen respondsToSelector:@selector(_setUserInterfaceIdiom:)])
            {
                [UIDevice.currentDevice _setActiveUserInterfaceIdiom:UIUserInterfaceIdiomPad];
                [UIScreen.mainScreen _setUserInterfaceIdiom:UIUserInterfaceIdiomPad];
                idiom = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? "applied" : "not taken";
            }
            else idiom = "unavailable";
        }
        /* 1: on iPhone, pointer interactions attach their drivers as on iPad, so hover from the AssistiveTouch cursor reaches the game view */
        if (madeira_cfg_bool("env.MADEIRA_PHONE_HOVER", 0))
        {
            Method m = class_getInstanceMethod(UIPointerInteraction.class,
                                               NSSelectorFromString(@"_updateInteractionIsEnabled"));
            if (m)
            {
                g_update_interaction_orig = method_setImplementation(m, (IMP)madeira_update_interaction_is_enabled);
                hover = "installed";
            }
            else hover = "unavailable";
        }
    }
    snprintf(g_phone_pointer_status, sizeof(g_phone_pointer_status), "phone=1 ipad-idiom=%s hover=%s", idiom, hover);
}

const char *madeira_phone_pointer_status(void)
{
    return g_phone_pointer_status;
}
