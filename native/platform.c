/* OS transport and file primitives only. All state/adapter logic lives in Zig. */
#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "hidapi.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <sddl.h>
#include <bcrypt.h>
#include <direct.h>
#include <psapi.h>
typedef SOCKET sock_t;
#define BAD_SOCKET INVALID_SOCKET
#define close_socket closesocket
static HANDLE pipe_handle = INVALID_HANDLE_VALUE, lock_handle = INVALID_HANDLE_VALUE;
static PSECURITY_DESCRIPTOR security_descriptor;
static SECURITY_ATTRIBUTES security_attributes;
static wchar_t pipe_name[256];
static wchar_t *wide(const char *s) {
    static _Thread_local wchar_t buffers[4][4096];
    static _Thread_local int index;
    wchar_t *b = buffers[(index++) & 3];
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, b, 4096))
        return NULL;
    return b;
}
static int secure_user(void) {
    HANDLE token;
    DWORD n = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
        return -1;
    GetTokenInformation(token, TokenUser, NULL, 0, &n);
    TOKEN_USER *user = malloc(n);
    if (!user) {
        CloseHandle(token);
        return -1;
    }
    if (!GetTokenInformation(token, TokenUser, user, n, &n)) {
        free(user);
        CloseHandle(token);
        return -1;
    }
    LPSTR sid = NULL;
    ConvertSidToStringSidA(user->User.Sid, &sid);
    char sddl[256];
    snprintf(sddl, sizeof(sddl), "D:P(A;;GA;;;%s)", sid ? sid : "");
    int ok = ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl, SDDL_REVISION_1,
                                                                  &security_descriptor, NULL);
    if (sid)
        LocalFree(sid);
    free(user);
    CloseHandle(token);
    security_attributes =
        (SECURITY_ATTRIBUTES){sizeof(SECURITY_ATTRIBUTES), security_descriptor, FALSE};
    return ok ? 0 : -1;
}
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>
#include <sys/resource.h>
#include <mach/mach.h>
typedef int sock_t;
#define BAD_SOCKET (-1)
#define close_socket close
static int lock_handle = -1;
static char socket_path[108];
#endif
static sock_t ipc_listener = BAD_SOCKET, http_listener = BAD_SOCKET, current = BAD_SOCKET;
static int current_pipe, http_ready, pipe_replied;
static volatile int stopping;
static char state_directory[4096];

uint64_t kf_now_ns(void) {
#ifdef _WIN32
    FILETIME t;
    GetSystemTimePreciseAsFileTime(&t);
    ULARGE_INTEGER n;
    n.LowPart = t.dwLowDateTime;
    n.HighPart = t.dwHighDateTime;
    return (n.QuadPart - 116444736000000000ULL) * 100;
#else
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
#endif
}
uint64_t kf_monotonic_ns(void) {
#ifdef _WIN32
    LARGE_INTEGER t, f;
    QueryPerformanceCounter(&t);
    QueryPerformanceFrequency(&f);
    return (uint64_t)((double)t.QuadPart * 1e9 / (double)f.QuadPart);
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
#endif
}
int kf_process_stats(uint64_t out[3]) {
#ifdef _WIN32
    FILETIME created, exited, kernel, user;
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user))
        return -1;
    ULARGE_INTEGER k, u;
    k.LowPart = kernel.dwLowDateTime;
    k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime;
    u.HighPart = user.dwHighDateTime;
    PROCESS_MEMORY_COUNTERS memory;
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &memory, sizeof(memory)))
        return -1;
    out[0] = (k.QuadPart + u.QuadPart) * 100;
    out[1] = (uint64_t)memory.WorkingSetSize;
#else
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage))
        return -1;
    out[0] = ((uint64_t)usage.ru_utime.tv_sec + (uint64_t)usage.ru_stime.tv_sec) * 1000000000ULL +
             ((uint64_t)usage.ru_utime.tv_usec + (uint64_t)usage.ru_stime.tv_usec) * 1000;
    mach_task_basic_info_data_t memory;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&memory, &count) !=
        KERN_SUCCESS)
        return -1;
    out[1] = (uint64_t)memory.resident_size;
#endif
    out[2] = kf_monotonic_ns();
    return 0;
}
int kf_random(unsigned char *out, size_t n) {
#ifdef _WIN32
    return BCryptGenRandom(NULL, out, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0 ? 0 : -1;
#else
    arc4random_buf(out, n);
    return 0;
#endif
}
void kf_print(const char *s, size_t n, int error) {
    fwrite(s, 1, n, error ? stderr : stdout);
    fflush(error ? stderr : stdout);
}
int kf_stdin(char *out, size_t cap) {
    size_t n = fread(out, 1, cap, stdin);
    if (n == cap && fgetc(stdin) != EOF)
        return -1;
    return ferror(stdin) ? -1 : (int)n;
}
void kf_exit(int code) { exit(code); }
static int filename(char *out, size_t cap, const char *name) {
    int n = snprintf(out, cap, "%s/%s", state_directory, name);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}
int kf_init(const char *directory) {
#ifdef _WIN32
    WSADATA w;
    if (WSAStartup(MAKEWORD(2, 2), &w) || secure_user())
        return -1;
#endif
    if (directory)
        snprintf(state_directory, sizeof(state_directory), "%s", directory);
    else {
#ifdef _WIN32
        wchar_t env[3500];
        if (!GetEnvironmentVariableW(L"LOCALAPPDATA", env, 3500))
            return -1;
        char utf8[3800];
        if (!WideCharToMultiByte(CP_UTF8, 0, env, -1, utf8, sizeof(utf8), NULL, NULL))
            return -1;
        snprintf(state_directory, sizeof(state_directory), "%s/Keyflux", utf8);
#else
        const char *home = getenv("HOME");
        if (!home)
            return -1;
        snprintf(state_directory, sizeof(state_directory), "%s/Library/Application Support/Keyflux",
                 home);
#endif
    }
    if (strlen(state_directory) > 3500)
        return -1;
    char path[4096];
    snprintf(path, sizeof(path), "%s", state_directory);
    for (char *p = path + 1;; p++) {
        if (*p != '/' && *p != '\\' && *p)
            continue;
        char saved = *p;
        *p = 0;
#ifdef _WIN32
        if (strlen(path) > 2) {
            if (!CreateDirectoryW(wide(path), &security_attributes) &&
                GetLastError() != ERROR_ALREADY_EXISTS)
                return -1;
        }
#else
        struct stat st;
        if (lstat(path, &st) == 0) {
            if (!S_ISDIR(st.st_mode))
                return -1;
        } else if (errno != ENOENT || mkdir(path, 0700))
            return -1;
#endif
        *p = saved;
        if (!saved)
            break;
    }
#ifndef _WIN32
    struct stat st;
    if (lstat(state_directory, &st) || st.st_uid != getuid() || chmod(state_directory, 0700))
        return -1;
    int n = snprintf(socket_path, sizeof(socket_path), "%s/control.sock", state_directory);
    if (n < 0 || (size_t)n >= sizeof(socket_path))
        return -1;
#else
    /* Different state dirs have separate endpoints; ACL limits them to this user. */
    if (!SetFileSecurityW(wide(state_directory),
                          DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                          security_descriptor))
        return -1;
    uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char *p = (const unsigned char *)state_directory; *p; p++) {
        hash ^= *p;
        hash *= 1099511628211ULL;
    }
    swprintf(pipe_name, 256, L"\\\\.\\pipe\\keyflux-%016llx", (unsigned long long)hash);
#endif
    return 0;
}
const char *kf_state_dir(void) { return state_directory; }
int kf_read_file(const char *name, char *out, size_t cap) {
    char path[4096];
    if (filename(path, sizeof(path), name))
        return -1;
#ifdef _WIN32
    HANDLE f = CreateFileW(wide(path), GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return GetLastError() == ERROR_FILE_NOT_FOUND ? -2 : -1;
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(f, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        CloseHandle(f);
        return -1;
    }
    DWORD n = 0;
    int ok = ReadFile(f, out, (DWORD)cap, &n, NULL);
    CloseHandle(f);
    return ok && n < cap ? (int)n : -1;
#else
    int f = open(path, O_RDONLY | O_NOFOLLOW);
    if (f < 0)
        return errno == ENOENT ? -2 : -1;
    struct stat st;
    if (fstat(f, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_size < 0 ||
        (uint64_t)st.st_size >= cap) {
        close(f);
        return -1;
    }
    size_t n = 0;
    while (n < (size_t)st.st_size) {
        ssize_t r = read(f, out + n, (size_t)st.st_size - n);
        if (r <= 0) {
            close(f);
            return -1;
        }
        n += (size_t)r;
    }
    close(f);
    return (int)n;
#endif
}
int kf_write_file(const char *name, const char *bytes, size_t n) {
    char path[4096], tmp[4096];
    if (filename(path, sizeof(path), name))
        return -1;
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp))
        return -1;
#ifdef _WIN32
    HANDLE f = CreateFileW(wide(tmp), GENERIC_WRITE, 0, &security_attributes, CREATE_NEW,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return -1;
    DWORD wrote = 0;
    int ok = WriteFile(f, bytes, (DWORD)n, &wrote, NULL) && wrote == n && FlushFileBuffers(f);
    CloseHandle(f);
    if (ok)
        ok = MoveFileExW(wide(tmp), wide(path), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    if (!ok)
        DeleteFileW(wide(tmp));
    return ok ? 0 : -1;
#else
    int f = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (f < 0)
        return -1;
    size_t sent = 0;
    int ok = 1;
    while (sent < n) {
        ssize_t r = write(f, bytes + sent, n - sent);
        if (r <= 0) {
            ok = 0;
            break;
        }
        sent += (size_t)r;
    }
    if (fsync(f))
        ok = 0;
    if (close(f))
        ok = 0;
    if (ok && rename(tmp, path))
        ok = 0;
    if (!ok)
        unlink(tmp);
    if (ok) {
        int dir = open(state_directory, O_RDONLY);
        if (dir >= 0) {
            if (fsync(dir))
                ok = 0;
            close(dir);
        }
    }
    return ok ? 0 : -1;
#endif
}
int kf_remove_file(const char *name) {
    char path[4096];
    if (filename(path, sizeof(path), name))
        return -1;
#ifdef _WIN32
    return DeleteFileW(wide(path)) || GetLastError() == ERROR_FILE_NOT_FOUND ? 0 : -1;
#else
    return unlink(path) == 0 || errno == ENOENT ? 0 : -1;
#endif
}
#ifndef _WIN32
static void signal_stop(int s) {
    (void)s;
    stopping = 1;
}
#else
static BOOL WINAPI signal_stop(DWORD s) {
    (void)s;
    stopping = 1;
    return TRUE;
}
#endif
int kf_listen(unsigned short port) {
    char path[4096];
    if (filename(path, sizeof(path), "daemon.lock"))
        return -1;
#ifdef _WIN32
    lock_handle = CreateFileW(wide(path), GENERIC_READ | GENERIC_WRITE, 0, &security_attributes,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (lock_handle == INVALID_HANDLE_VALUE)
        return -1;
    pipe_handle = CreateNamedPipeW(pipe_name, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                   PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT |
                                       PIPE_REJECT_REMOTE_CLIENTS,
                                   1, 65536, 65536, 200, &security_attributes);
    if (pipe_handle == INVALID_HANDLE_VALUE)
        return -1;
    SetConsoleCtrlHandler(signal_stop, TRUE);
#else
    lock_handle = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (lock_handle < 0 || flock(lock_handle, LOCK_EX | LOCK_NB))
        return -1;
    signal(SIGINT, signal_stop);
    signal(SIGTERM, signal_stop);
    signal(SIGHUP, signal_stop);
    signal(SIGPIPE, SIG_IGN);
    ipc_listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (ipc_listener < 0)
        return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, socket_path);
    unlink(socket_path);
    mode_t mask = umask(0077);
    int bound = bind(ipc_listener, (struct sockaddr *)&addr, sizeof(addr));
    umask(mask);
    if (bound || listen(ipc_listener, 8))
        return -1;
#endif
    if (port) {
        http_listener = socket(AF_INET, SOCK_STREAM, 0);
        if (http_listener == BAD_SOCKET)
            return -1;
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(port);
        if (bind(http_listener, (struct sockaddr *)&addr, sizeof(addr)) || listen(http_listener, 8))
            return -1;
        http_ready = 1;
    }
    return 0;
}
static void socket_timeout(sock_t fd) {
#ifdef _WIN32
    DWORD ms = 200;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (char *)&ms, sizeof(ms));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, (char *)&ms, sizeof(ms));
#else
    struct timeval t = {0, 200000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof(t));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof(t));
#endif
}
static int ready(sock_t fd, int ms) {
    if (fd == BAD_SOCKET)
        return 0;
#ifdef _WIN32
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    struct timeval t = {ms / 1000, (ms % 1000) * 1000};
    return select(0, &set, NULL, NULL, &t) > 0;
#else
    struct pollfd p = {fd, POLLIN, 0};
    return poll(&p, 1, ms) > 0 && (p.revents & POLLIN);
#endif
}
static int read_message(char *out, size_t cap, int http) {
    size_t n = 0;
    uint64_t start = kf_monotonic_ns();
    while (n + 1 < cap && kf_monotonic_ns() - start < 2000000000ULL) {
        int r;
#ifdef _WIN32
        if (current_pipe) {
            DWORD got = 0;
            if (!ReadFile(pipe_handle, out + n, (DWORD)(cap - n - 1), &got, NULL)) {
                if (GetLastError() == ERROR_NO_DATA) {
                    Sleep(5);
                    continue;
                }
                return -1;
            }
            r = (int)got;
        } else
#endif
            r = (int)recv(current, out + n, (int)(cap - n - 1), 0);
        if (r <= 0)
            return -1;
        n += (size_t)r;
        out[n] = 0;
        if (!http) {
            char *lf = memchr(out, '\n', n);
            if (lf)
                return (int)(lf - out);
        } else {
            char *end = strstr(out, "\r\n\r\n");
            if (!end && n > 8192)
                return -1;
            if (end) {
                size_t header = (size_t)(end - out) + 4, body = 0;
                /* Zig validates headers. Here only determine the bounded frame. */
                for (char *p = out; p < end; p++) {
                    if ((p == out || p[-1] == '\n') && (end - p) >= 15) {
                        const char *key = "content-length:";
                        int same = 1;
                        for (int i = 0; i < 15; i++) {
                            char c = p[i];
                            if (c >= 'A' && c <= 'Z')
                                c += 32;
                            if (c != key[i])
                                same = 0;
                        }
                        if (same) {
                            char *q = p + 15;
                            while (*q == ' ')
                                q++;
                            if (*q < '0' || *q > '9')
                                return -1;
                            char *tail;
                            unsigned long long value = strtoull(q, &tail, 10);
                            if (value > cap - header - 1)
                                return -1;
                            body = (size_t)value;
                        }
                    }
                }
                if (n >= header + body)
                    return (int)(header + body);
            }
        }
    }
    return -1;
}
void kf_close_client(void) {
#ifdef _WIN32
    if (current_pipe) {
        /* DisconnectNamedPipe discards unread data. Wait for the client's
           read-confirmation byte, bounded so a dead client cannot stall us. */
        if (pipe_replied) {
            uint64_t until = kf_monotonic_ns() + 200000000ULL;
            while (kf_monotonic_ns() < until) {
                DWORD available = 0;
                if (!PeekNamedPipe(pipe_handle, NULL, 0, NULL, &available, NULL))
                    break;
                if (available) {
                    char ack;
                    DWORD got;
                    ReadFile(pipe_handle, &ack, 1, &got, NULL);
                    break;
                }
                Sleep(1);
            }
        }
        DisconnectNamedPipe(pipe_handle);
        current_pipe = 0;
        pipe_replied = 0;
    }
#endif
    if (current != BAD_SOCKET) {
        close_socket(current);
        current = BAD_SOCKET;
    }
}
int kf_next(char *out, size_t cap, int *http) {
    if (stopping)
        return -2;
    current_pipe = 0;
    *http = 0;
#ifdef _WIN32
    BOOL connected = ConnectNamedPipe(pipe_handle, NULL);
    if (connected || GetLastError() == ERROR_PIPE_CONNECTED) {
        current_pipe = 1;
        return read_message(out, cap, 0);
    }
    if (http_ready && ready(http_listener, 100)) {
        *http = 1;
        current = accept(http_listener, NULL, NULL);
    } else {
        Sleep(25);
        return 0;
    }
#else
    struct pollfd fds[2] = {{ipc_listener, POLLIN, 0}, {http_listener, POLLIN, 0}};
    int r = poll(fds, http_ready ? 2 : 1, 100);
    if (r <= 0)
        return 0;
    if (fds[0].revents & POLLIN)
        current = accept(ipc_listener, NULL, NULL);
    else if (http_ready && (fds[1].revents & POLLIN)) {
        *http = 1;
        current = accept(http_listener, NULL, NULL);
    } else
        return 0;
#endif
    if (current == BAD_SOCKET)
        return -1;
    socket_timeout(current);
    return read_message(out, cap, *http);
}
int kf_reply(const char *bytes, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        int r;
#ifdef _WIN32
        if (current_pipe) {
            DWORD wrote = 0;
            if (!WriteFile(pipe_handle, bytes + sent, (DWORD)(n - sent), &wrote, NULL))
                return -1;
            r = (int)wrote;
            pipe_replied = 1;
        } else
#endif
            r = (int)send(current, bytes + sent, (int)(n - sent), 0);
        if (r <= 0)
            return -1;
        sent += (size_t)r;
    }
    return 0;
}
int kf_request(const char *bytes, size_t n, char *out, size_t cap) {
#ifdef _WIN32
    /* The preceding client may have returned before the server consumed its
       ACK/disconnected. A busy single-instance pipe is not an absent daemon.
       Wait only before sending anything; never replay a mutation after write. */
    HANDLE f;
    uint64_t connect_until = kf_monotonic_ns() + 1000000000ULL;
    for (;;) {
        f = CreateFileW(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (f != INVALID_HANDLE_VALUE)
            break;
        if (GetLastError() != ERROR_PIPE_BUSY || kf_monotonic_ns() >= connect_until)
            return -1;
        if (!WaitNamedPipeW(pipe_name, 50) && GetLastError() != ERROR_SEM_TIMEOUT)
            return -1;
    }
    DWORD sent = 0;
    DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
    if (!SetNamedPipeHandleState(f, &mode, NULL, NULL)) {
        CloseHandle(f);
        return -1;
    }
    int ok = WriteFile(f, bytes, (DWORD)n, &sent, NULL) && sent == n;
    char lf = '\n';
    DWORD x;
    if (ok)
        ok = WriteFile(f, &lf, 1, &x, NULL) && x == 1;
    size_t got = 0;
    uint64_t until = kf_monotonic_ns() + 2000000000ULL;
    while (ok && got + 1 < cap && kf_monotonic_ns() < until) {
        DWORD r = 0;
        if (!ReadFile(f, out + got, (DWORD)(cap - got - 1), &r, NULL)) {
            if (GetLastError() == ERROR_NO_DATA) {
                Sleep(1);
                continue;
            }
            break;
        }
        if (!r) {
            Sleep(1);
            continue;
        }
        got += r;
        char *end = memchr(out, '\n', got);
        if (end) {
            got = (size_t)(end - out) + 1;
            break;
        }
    }
    if (ok && got && out[got - 1] == '\n') {
        char ack = 6;
        DWORD wrote;
        WriteFile(f, &ack, 1, &wrote, NULL);
    }
    CloseHandle(f);
    return ok && got && out[got - 1] == '\n' ? (int)got : -1;
#else
    sock_t f = socket(AF_UNIX, SOCK_STREAM, 0);
    if (f < 0)
        return -1;
    socket_timeout(f);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, socket_path);
    if (connect(f, (struct sockaddr *)&addr, sizeof(addr))) {
        close(f);
        return -1;
    }
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = send(f, bytes + sent, n - sent, 0);
        if (r <= 0) {
            close(f);
            return -1;
        }
        sent += (size_t)r;
    }
    if (send(f, "\n", 1, 0) != 1) {
        close(f);
        return -1;
    }
    size_t got = 0;
    while (got + 1 < cap) {
        ssize_t r = recv(f, out + got, cap - got - 1, 0);
        if (r <= 0)
            break;
        got += (size_t)r;
        if (memchr(out, '\n', got))
            break;
    }
    close(f);
    return got ? (int)got : -1;
#endif
}
void kf_shutdown(void) {
    kf_close_client();
    if (http_listener != BAD_SOCKET)
        close_socket(http_listener);
#ifdef _WIN32
    if (pipe_handle != INVALID_HANDLE_VALUE)
        CloseHandle(pipe_handle);
    if (lock_handle != INVALID_HANDLE_VALUE)
        CloseHandle(lock_handle);
    if (security_descriptor)
        LocalFree(security_descriptor);
    WSACleanup();
#else
    if (ipc_listener != BAD_SOCKET) {
        close(ipc_listener);
        unlink(socket_path);
    }
    if (lock_handle >= 0)
        close(lock_handle);
#endif
}
int kf_hid_diagnose(char *out, size_t cap) {
    if (hid_init())
        return -1;
    struct hid_device_info *head = hid_enumerate(0x19f5, 0), *p = head;
    size_t n = 0;
    int r = snprintf(out, cap, "{\"schema_version\":1,\"read_only\":true,\"devices\":[");
    if (r < 0) {
        hid_free_enumeration(head);
        hid_exit();
        return -1;
    }
    n = (size_t)r;
    int first = 1;
    for (; p; p = p->next) {
        if (cap - n < 256) {
            hid_free_enumeration(head);
            hid_exit();
            return -1;
        }
        r = snprintf(out + n, cap - n,
                     "%s{\"vendor_id\":%u,\"product_id\":%u,\"usage_page\":%u,\"usage\":%u,"
                     "\"interface_number\":%d,\"bus_type\":%d,\"main_write_enabled\":false}",
                     first ? "" : ",", p->vendor_id, p->product_id, p->usage_page, p->usage,
                     p->interface_number, p->bus_type);
        n += (size_t)r;
        first = 0;
    }
    hid_free_enumeration(head);
    hid_exit();
    if (cap - n < 4)
        return -1;
    memcpy(out + n, "]}\n", 3);
    return (int)(n + 3);
}
