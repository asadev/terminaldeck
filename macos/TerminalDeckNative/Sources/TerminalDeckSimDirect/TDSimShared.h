// What the helper's simulator entry points share (TDSimDirect.m, TDSimTools.m). Private to this module.
#ifndef TD_SIM_SHARED_H
#define TD_SIM_SHARED_H

#import <Foundation/Foundation.h>

/// `target.selector` for a no-argument selector that returns an object, or nil when it does not answer.
id td_sim_send0(id target, NSString *selector);
/// The Xcode developer folder (DEVELOPER_DIR, else `xcode-select -p`).
NSString *td_sim_developer_directory(void);
/// CoreSimulator's device with this UDID, or nil with the reason in plain words.
id td_sim_find_device(NSString *udid, NSString *developer, NSString **why);
/// CoreSimulator's state number (3 = booted), -1 when it cannot be read.
long td_sim_device_state(id device);

#endif
