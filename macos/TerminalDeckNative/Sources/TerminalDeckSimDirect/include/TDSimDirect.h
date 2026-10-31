// The iOS Simulator's screen and input, straight from CoreSimulator (finding 3, 22 Oct 2026).
//
// Runs ONLY inside the helper process (`TerminalDeckNativeHelper --sim-direct`), never in the
// app: CoreSimulator and SimulatorKit are Apple's private frameworks, and anything that goes
// wrong in them ends this helper, not Terminal Deck. The app sees the helper stop and shows the
// screen through its own still pictures instead (BackendAppDeviceOwnIOS).
//
// Protocol, one line per message:
//   stdin  (app -> helper)  T <fingers 1|2> x y [x2 y2]   finger(s) down or moved, 0...1 from top left
//                           U <fingers 1|2> x y [x2 y2]   finger(s) lifted
//                           K <hid usage> <d|u>           a key (HID keyboard usage page)
//                           B <home|lock> <d|u>           a hardware button; also volume-up, volume-down
//                                                         and action (side=1 on Indigo, always on CoreDevice's)
//                           P <1|0>                       pause / resume frame notices
//                           Q                             quit (end of input quits too)
//   stdout (helper -> app)  ready <width> <height> touch=<0|1> keys=<0|1> buttons=<0|1> side=<0|1> core=<0|1> hid=<indigo|coredevice>
//                                                         touch/keys/buttons: what the simulator's own (Indigo)
//                                                         input takes; core=1: CoreDevice's touchscreen (fingers,
//                                                         keys, every button) can be reached. The app sends input
//                                                         here only when the touchscreen in use takes it.
//                           hid <indigo|coredevice>       whose touchscreen the simulator uses changed
//                           note <words>                  for engine.log (a handful at most); input that had no
//                                                         way in is noted, never dropped silently
//                           error <words>                 then it exits
//                           gone                          the simulator shut down; then it exits
// The screen surface and the per-frame notices travel over Mach (TDDirectMach.h). A service of "-" is
// input only (AI sessions' device tools while no panel shows the simulator): no screen, no frame notices,
// the same input lines and answers.
#ifndef TD_SIM_DIRECT_H
#define TD_SIM_DIRECT_H

#ifdef __cplusplus
extern "C" {
#endif

/// Serves one booted simulator until its input ends. Returns the process exit code.
int td_sim_direct_run(const char *udid, const char *service);

/// `--sim-ax <udid> tree [max nodes] | point <x> <y> | front`: what is on the simulator's screen, from Apple's
/// accessibility translation, as one line of JSON on stdout (TDSimTools.m). `point` takes 0...1 in the front app's
/// frame. An answer with "error" says why nothing could be read. Returns the process exit code.
int td_sim_ax_run(const char *udid, const char *verb, const char *first, const char *second);

/// `--sim-rotate <udid> <portrait|portrait-upside-down|landscape-left|landscape-right>`: turns the simulated device
/// (TDSimTools.m). Prints `ok <orientation>` or `error <words>`. Returns the process exit code.
int td_sim_rotate_run(const char *udid, const char *orientation);

#ifdef __cplusplus
}
#endif

#endif
