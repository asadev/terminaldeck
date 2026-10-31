// The device screen handed straight from a helper to the app (finding 3, 22 Oct 2026).
//
// The helper that reads a simulator's screen hands its IOSurface to the app as a Mach port,
// and then says "a new picture is in it" with a tiny message per frame. Public Mach and
// IOSurface calls only: the app registers a receive port under a name only it and its own
// helper know, the helper looks the name up and sends. Every message is checked for its id,
// size, kind and sender before anything in it is used.
#ifndef TD_DIRECT_MACH_H
#define TD_DIRECT_MACH_H

#include <mach/mach.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A new screen surface: one port (the IOSurface), its width and height.
#define TD_DIRECT_MSG_SURFACE 0x74640001
/// A new picture was drawn into the surface already handed over.
#define TD_DIRECT_MSG_FRAME 0x74640002

typedef enum {
    TDDirectNothing = 0,   ///< timed out, or a message that was not ours (thrown away)
    TDDirectSurface = 1,   ///< `surface` holds a send right: look it up, then deallocate it
    TDDirectFrame = 2,
    TDDirectFailed = 3,    ///< the port is gone
} TDDirectKind;

typedef struct {
    TDDirectKind kind;
    mach_port_t surface;
    uint32_t width;
    uint32_t height;
    pid_t sender;
} TDDirectMessage;

/// Registers a receive port under `name` in this user's bootstrap namespace.
kern_return_t td_direct_listen(const char *name, mach_port_t *port);
/// Gives up the receive right (the name goes with it).
void td_direct_close(mach_port_t port);
/// Waits up to `timeout_ms` for one message. Only messages from `expected_sender` are accepted
/// (0 accepts any sender; tests only). A rejected message's ports are released.
TDDirectMessage td_direct_receive(mach_port_t port, uint32_t timeout_ms, pid_t expected_sender);

/// Helper side: looks up the app's port by name.
kern_return_t td_direct_connect(const char *name, mach_port_t *port);
/// Helper side: hands over a surface port (moved; do not use it afterwards).
kern_return_t td_direct_send_surface(mach_port_t app, mach_port_t surface, uint32_t width, uint32_t height);
/// Helper side: one frame notice. Never waits: when the app is behind, the notice is dropped
/// (the app paints the newest picture with the next one anyway).
kern_return_t td_direct_send_frame(mach_port_t app);

#ifdef __cplusplus
}
#endif

#endif
