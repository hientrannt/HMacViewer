// C interface of RemoteCore (src/ffi.rs): VNC and RDP viewer sessions.
#ifndef REMOTECORE_H
#define REMOTECORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct RcSession RcSession;

enum { RC_PROTOCOL_VNC = 1, RC_PROTOCOL_RDP = 2 };
enum { RC_EVENT_NONE = 0, RC_EVENT_STATUS = 1, RC_EVENT_CONNECTED = 2, RC_EVENT_CLOSED = 3 };
enum {
    RC_KEY_BACKSPACE, RC_KEY_TAB, RC_KEY_ENTER, RC_KEY_ESCAPE, RC_KEY_DELETE, RC_KEY_HOME, RC_KEY_END,
    RC_KEY_PAGE_UP, RC_KEY_PAGE_DOWN, RC_KEY_LEFT, RC_KEY_UP, RC_KEY_RIGHT, RC_KEY_DOWN, RC_KEY_WINDOWS,
    RC_KEY_SHIFT, RC_KEY_CONTROL, RC_KEY_ALT,
};
enum { RC_BUTTON_LEFT = 1, RC_BUTTON_MIDDLE = 2, RC_BUTTON_RIGHT = 4 };

RcSession *rc_connect(int32_t protocol, const char *host, uint16_t port, const char *username,
                      const char *password, uint32_t width, uint32_t height);
int32_t rc_poll_event(const RcSession *session, char *buffer, size_t capacity, uint32_t *width, uint32_t *height);
int32_t rc_copy_frame(const RcSession *session, uint32_t *pixels, size_t capacity, uint32_t *width, uint32_t *height);
void rc_pointer(const RcSession *session, uint32_t x, uint32_t y, uint8_t buttons);
void rc_scroll(const RcSession *session, float steps);
void rc_key(const RcSession *session, int32_t key, bool down);
void rc_text(const RcSession *session, const char *utf8);
void rc_close(RcSession *session);

#endif
