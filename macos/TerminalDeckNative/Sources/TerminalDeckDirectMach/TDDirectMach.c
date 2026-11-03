#include "TDDirectMach.h"

#include <servers/bootstrap.h>
#include <string.h>

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    uint32_t width;
    uint32_t height;
} td_surface_message;

typedef struct {
    mach_msg_header_t header;
} td_frame_message;

typedef union {
    mach_msg_header_t header;
    td_surface_message surface;
    td_frame_message frame;
    // Room for the largest message plus the audit trailer the kernel appends.
    uint8_t bytes[sizeof(td_surface_message) + sizeof(mach_msg_audit_trailer_t) + 64];
} td_receive_buffer;

kern_return_t td_direct_listen(const char *name, mach_port_t *port) {
    if (!name || !port) return KERN_INVALID_ARGUMENT;
    *port = MACH_PORT_NULL;
    return bootstrap_check_in(bootstrap_port, name, port);
}

void td_direct_close(mach_port_t port) {
    if (port == MACH_PORT_NULL) return;
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
}

TDDirectMessage td_direct_receive(mach_port_t port, uint32_t timeout_ms, pid_t expected_sender) {
    TDDirectMessage out = {TDDirectNothing, MACH_PORT_NULL, 0, 0, 0};
    td_receive_buffer buffer;
    memset(&buffer, 0, sizeof(buffer));
    mach_msg_option_t options = MACH_RCV_MSG | MACH_RCV_TIMEOUT
        | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    kern_return_t result = mach_msg(&buffer.header, options, 0, sizeof(buffer), port, timeout_ms, MACH_PORT_NULL);
    if (result == MACH_RCV_TIMED_OUT || result == MACH_RCV_TOO_LARGE || result == MACH_RCV_INTERRUPTED) return out;
    if (result != MACH_MSG_SUCCESS) { out.kind = TDDirectFailed; return out; }

    mach_msg_size_t size = buffer.header.msgh_size;
    if (size > sizeof(td_surface_message)) { mach_msg_destroy(&buffer.header); return out; }
    const mach_msg_audit_trailer_t *trailer = (const mach_msg_audit_trailer_t *)((const uint8_t *)&buffer + round_msg(size));
    pid_t sender = (pid_t)trailer->msgh_audit.val[5];
    out.sender = sender;
    if (expected_sender != 0 && sender != expected_sender) { mach_msg_destroy(&buffer.header); return out; }

    int complex = (buffer.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
    if (buffer.header.msgh_id == TD_DIRECT_MSG_SURFACE && complex && size == sizeof(td_surface_message)
        && buffer.surface.body.msgh_descriptor_count == 1
        && buffer.surface.surface.type == MACH_MSG_PORT_DESCRIPTOR
        && buffer.surface.surface.disposition == MACH_MSG_TYPE_PORT_SEND
        && buffer.surface.width > 0 && buffer.surface.width <= 16384
        && buffer.surface.height > 0 && buffer.surface.height <= 16384) {
        out.kind = TDDirectSurface;
        out.surface = buffer.surface.surface.name;
        out.width = buffer.surface.width;
        out.height = buffer.surface.height;
        return out;
    }
    if (buffer.header.msgh_id == TD_DIRECT_MSG_FRAME && !complex && size == sizeof(td_frame_message)) {
        out.kind = TDDirectFrame;
        return out;
    }
    mach_msg_destroy(&buffer.header);
    return out;
}

kern_return_t td_direct_connect(const char *name, mach_port_t *port) {
    if (!name || !port) return KERN_INVALID_ARGUMENT;
    *port = MACH_PORT_NULL;
    return bootstrap_look_up(bootstrap_port, name, port);
}

kern_return_t td_direct_send_surface(mach_port_t app, mach_port_t surface, uint32_t width, uint32_t height) {
    td_surface_message message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = app;
    message.header.msgh_id = TD_DIRECT_MSG_SURFACE;
    message.body.msgh_descriptor_count = 1;
    message.surface.name = surface;
    message.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    message.width = width;
    message.height = height;
    kern_return_t result = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0,
                                    MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    if (result != MACH_MSG_SUCCESS) mach_port_deallocate(mach_task_self(), surface);
    return result;
}

kern_return_t td_direct_send_frame(mach_port_t app) {
    td_frame_message message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = app;
    message.header.msgh_id = TD_DIRECT_MSG_FRAME;
    return mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
}
