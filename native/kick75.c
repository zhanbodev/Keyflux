/* HIDAPI transport only. Encoding and lighting ownership live in Zig. */
#define _DARWIN_C_SOURCE 1
#include "hidapi.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#ifdef __APPLE__
#include "hidapi_darwin.h"
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif
extern uint64_t kf_monotonic_ns(void);
static hid_device *keyboard;
#ifdef __APPLE__
static int device_lock = -1;
#endif
void kf_kick_close(void) {
    if (keyboard)
        hid_close(keyboard);
    keyboard = NULL;
    hid_exit();
#ifdef __APPLE__
    if (device_lock >= 0)
        close(device_lock);
    device_lock = -1;
#endif
}
int kf_kick_open(unsigned char *identity, size_t capacity) {
#ifndef __APPLE__
    (void)identity;
    (void)capacity;
    return -5;
#else
    if (keyboard)
        return -1;
    char lock_path[160];
    snprintf(lock_path, sizeof(lock_path), "/private/tmp/keyflux-kick75-%u.lock", getuid());
    device_lock = open(lock_path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (device_lock < 0 || flock(device_lock, LOCK_EX | LOCK_NB)) {
        kf_kick_close();
        return -2;
    }
    if (hid_init()) {
        kf_kick_close();
        return -1;
    }
    hid_darwin_set_open_exclusive(0);
    struct hid_device_info *head = hid_enumerate(0x19f5, 0x1026), *chosen = NULL;
    int count = 0;
    for (struct hid_device_info *p = head; p; p = p->next) {
        if (p->usage_page == 1 && p->usage == 0 && p->interface_number == 3 &&
            p->bus_type == HID_API_BUS_USB) {
            chosen = p;
            count++;
        }
    }
    if (count != 1) {
        hid_free_enumeration(head);
        kf_kick_close();
        return count ? -4 : -3;
    }
    keyboard = hid_open_path(chosen->path);
    if (!keyboard) {
        hid_free_enumeration(head);
        kf_kick_close();
        return -1;
    }
    uint32_t location = 0;
    if (hid_darwin_get_location_id(keyboard, &location) || location == 0 || capacity < 8) {
        hid_free_enumeration(head);
        kf_kick_close();
        return -6;
    }
    memcpy(identity, &location, sizeof(location));
    size_t n = 4;
    if (chosen->serial_number) {
        size_t size = wcslen(chosen->serial_number) * sizeof(wchar_t);
        if (size > capacity - n) {
            hid_free_enumeration(head);
            kf_kick_close();
            return -6;
        }
        memcpy(identity + n, chosen->serial_number, size);
        n += size;
    }
    hid_free_enumeration(head);
    return (int)n;
#endif
}
int kf_kick_descriptor(unsigned char *out, size_t capacity) {
    return keyboard ? hid_get_report_descriptor(keyboard, out, capacity) : -1;
}
int kf_kick_exchange(const unsigned char frame[64], unsigned char reply[64], unsigned char key) {
    if (!keyboard)
        return -1;
    if (frame[0] != 0x55 || frame[2] != 0)
        return -7;
    unsigned checksum = 0;
    for (int i = 4; i < 64; i++)
        checksum += frame[i];
    if ((unsigned char)checksum != frame[3])
        return -7;
    unsigned command = frame[1], length = frame[4] ^ key;
    unsigned address = (frame[5] ^ key) | ((frame[6] ^ key) << 8), profile = frame[7] ^ key;
    if (length > 56)
        return -7;
    /* No EE, reset, firmware, keymap, side-light or per-key writes. */
    switch (command) {
    case 0xa0:
    case 0xa1:
        if (length != 8 || address || profile)
            return -7;
        break;
    case 0xd1:
        if (length != 1 || address || profile)
            return -7;
        break;
    case 0xd5:
        if (length != 17 || address || profile > 1)
            return -7;
        break;
    case 0xd6:
        if (length != 9 || address || profile != 0)
            return -7;
        break;
    default:
        return -7;
    }
    unsigned char discarded[128];
    for (int i = 0; i < 16; i++)
        if (hid_read_timeout(keyboard, discarded, sizeof(discarded), 0) <= 0)
            break;
    unsigned char output[65];
    output[0] = 0;
    memcpy(output + 1, frame, 64);
    if (hid_write(keyboard, output, sizeof(output)) != (int)sizeof(output))
        return -8;
    uint64_t deadline = kf_monotonic_ns() + 700000000ULL;
    while (kf_monotonic_ns() < deadline) {
        int n = hid_read_timeout(keyboard, discarded, sizeof(discarded), 50);
        if (n < 0)
            return -9;
        if (n == 64 && discarded[0] == 0xaa && discarded[1] == command) {
            memcpy(reply, discarded, 64);
            return 0;
        }
    }
    return -10;
}
void kf_sleep_ms(unsigned milliseconds) {
#ifdef __APPLE__
    usleep(milliseconds * 1000);
#else
    (void)milliseconds;
#endif
}
