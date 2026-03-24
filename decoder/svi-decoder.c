/*
 * svi-decoder.c — SVI-Decoder (Saccade Video Interface)
 *
 * EGL zero-copy H.264 VAAPI receiver + display.
 *
 * Pipeline: Paced UDP (custom framing) → frame reassembly → H.264 Annex B
 *           → libavcodec VAAPI decode → DMA-BUF export
 *           → EGLImage (NV12) → GL_TEXTURE_EXTERNAL_OES → GBM BO FBO
 *           → drmModePageFlip (async, vsync-locked)
 *
 * Zero CPU involvement in the video path after reassembly.
 *
 * Build:
 *   gcc -O3 -march=silvermont -msse4.1 -flto -ffast-math -I/usr/include/libdrm \
 *     -o svi-decoder svi-decoder.c \
 *     -lEGL -lGLESv2 -lgbm -ldrm -lavcodec -lavutil -lva -lva-drm -lpthread
 *
 * Run:
 *   LIBVA_DRIVER_NAME=i965 chrt -f 50 taskset -c 1-3 ./svi-decoder <udp_port>
 *   LIBVA_DRIVER_NAME=i965 chrt -f 50 taskset -c 1-3 ./svi-decoder 5004
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <endian.h>

#include <drm/drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <gbm.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>

/* ─── Packet Protocol (shared with encoder) ─── */

#define MAX_PAYLOAD    1400
#define MAX_FRAME_SIZE (2 * 1024 * 1024)
#define MAX_PKTS       1500  /* 2MB / 1400 ≈ 1490 */
#define BITMAP_WORDS   ((MAX_PKTS + 63) / 64)
#define FRAME_SLOTS    8
#define SLOT_MASK      (FRAME_SLOTS - 1)

#pragma pack(push, 1)
struct pkt_hdr {
    uint32_t frame_id;
    uint16_t pkt_idx;
    uint16_t pkt_total;
    uint32_t payload_len;
    uint8_t  flags;        /* bit 0: keyframe, bit 1: end-of-frame */
    uint8_t  reserved[3];
    uint64_t encode_ts_ns;
};
#pragma pack(pop)

struct frame_slot {
    uint32_t frame_id;
    uint16_t total_pkts;
    uint16_t recv_count;
    uint64_t recv_bitmap[BITMAP_WORDS];
    uint8_t  data[MAX_FRAME_SIZE]; /* scatter: pkt_idx * MAX_PAYLOAD */
    uint16_t pkt_sizes[MAX_PKTS];
    size_t   total_size;
    uint8_t  flags;
    uint64_t encode_ts_ns;
    int      complete;
};

struct receiver {
    int sock;
    struct frame_slot slots[FRAME_SLOTS];
    uint32_t newest_frame_id;
    uint32_t last_decoded_id;
    int      has_decoded;         /* set after first frame decoded */

    /* clock sync */
    int sync_sock;                /* sends pings on port+1 */
    struct sockaddr_in encoder_addr;
    int64_t  clock_offset_ns;     /* encoder_time - decoder_time */
    int      clock_valid;
    uint64_t last_sync_time;

    /* stats */
    uint64_t frames_received;
    uint64_t frames_dropped;
    uint64_t packets_received;
    uint64_t packets_lost;
};

/* ─── Globals ─── */

static volatile int g_running = 1;
static volatile int g_flip_pending = 0;

static void signal_handler(int sig) {
    (void)sig;
    g_running = 0;
}

static void page_flip_handler(int fd, unsigned int sequence,
                               unsigned int tv_sec, unsigned int tv_usec,
                               void *user_data) {
    (void)fd; (void)sequence; (void)tv_sec; (void)tv_usec; (void)user_data;
    g_flip_pending = 0;
}

/* EGL function pointers */
static PFNEGLCREATEIMAGEKHRPROC pCreateImage;
static PFNEGLDESTROYIMAGEKHRPROC pDestroyImage;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC pTexImage;

static inline int wait_render_gpu_complete(void) {
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (!fence) {
        glFinish();
        return 1;
    }

    glFlush();
    GLenum st = GL_TIMEOUT_EXPIRED;
    for (int i = 0; i < 4; i++) {
        st = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000ULL); /* 1ms */
        if (st == GL_ALREADY_SIGNALED || st == GL_CONDITION_SATISFIED)
            break;
        if (st == GL_WAIT_FAILED)
            break;
    }

    if (st == GL_TIMEOUT_EXPIRED || st == GL_WAIT_FAILED) {
        glFinish();
        glDeleteSync(fence);
        return 1;
    }

    glDeleteSync(fence);
    return 0;
}

/* ─── Shaders ─── */

static const char *vs_src =
    "#version 300 es\n"
    "in vec2 aPos;\n"
    "in vec2 aTC;\n"
    "out vec2 vTC;\n"
    "void main() {\n"
    "  gl_Position = vec4(aPos, 0.0, 1.0);\n"
    "  vTC = aTC;\n"
    "}\n";

static const char *fs_src =
    "#version 300 es\n"
    "#extension GL_OES_EGL_image_external_essl3 : require\n"
    "precision mediump float;\n"
    "in vec2 vTC;\n"
    "out vec4 fc;\n"
    "uniform samplerExternalOES tex;\n"
    "void main() {\n"
    "  fc = texture(tex, vTC);\n"
    "}\n";

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "Shader compile error: %s\n", log);
        return 0;
    }
    return s;
}

/* ─── Timing ─── */

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

/* ─── VAAPI ─── */

static AVBufferRef *hw_device_ctx = NULL;

static enum AVPixelFormat get_vaapi_format(AVCodecContext *ctx,
                                            const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VAAPI)
            return AV_PIX_FMT_VAAPI;
    fprintf(stderr, "VAAPI format not offered by decoder\n");
    return AV_PIX_FMT_NONE;
}

/* ─── DRM flip wait helper ─── */

static void wait_flip(int drm_fd) {
    drmEventContext ev = {
        .version = 2,
        .page_flip_handler = page_flip_handler,
    };
    while (g_flip_pending && g_running) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(drm_fd, &fds);
        struct timeval tv = { .tv_sec = 0, .tv_usec = 16000 };
        int r = select(drm_fd + 1, &fds, NULL, NULL, &tv);
        if (r > 0)
            drmHandleEvent(drm_fd, &ev);
        else if (r == 0)
            break;
    }
}

/* ─── UDP Receiver ─── */

static int udp_init(int port) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); return -1; }

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sock);
        return -1;
    }

    int rcvbuf = 8 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    struct timeval tv = { .tv_sec = 0, .tv_usec = 500 }; /* 0.5ms timeout */
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    return sock;
}

static void receive_packet(struct receiver *rs, uint8_t *buf, ssize_t len,
                            struct sockaddr_in *from) {
    if (len < (ssize_t)sizeof(struct pkt_hdr)) return;

    struct pkt_hdr hdr;
    memcpy(&hdr, buf, sizeof(hdr));

    uint32_t frame_id    = ntohl(hdr.frame_id);
    uint16_t pkt_idx     = ntohs(hdr.pkt_idx);
    uint16_t total       = ntohs(hdr.pkt_total);
    uint32_t payload_len = ntohl(hdr.payload_len);
    uint64_t encode_ts   = be64toh(hdr.encode_ts_ns);

    /* clock sync ping/pong */
    if (frame_id == 0xFFFFFFFF) {
        /* pong from encoder (pkt_idx == 1) */
        if (pkt_idx == 1 && len >= (ssize_t)(sizeof(struct pkt_hdr) + 8)) {
            uint64_t encoder_ts = encode_ts;
            uint64_t decoder_orig;
            memcpy(&decoder_orig, buf + sizeof(struct pkt_hdr), 8);
            decoder_orig = be64toh(decoder_orig);
            uint64_t now = now_ns();
            uint64_t rtt = now - decoder_orig;
            rs->clock_offset_ns = (int64_t)encoder_ts - (int64_t)decoder_orig - (int64_t)(rtt / 2);
            rs->clock_valid = 1;
            printf("[sync] RTT=%.2fms offset=%.2fms\n",
                   rtt / 1e6, rs->clock_offset_ns / 1e6);
        }
        return;
    }

    /* sanity checks */
    if (pkt_idx >= total || total > MAX_PKTS || payload_len > MAX_PAYLOAD) return;
    if (len < (ssize_t)(sizeof(struct pkt_hdr) + payload_len)) return;

    /* drop old frames — but detect encoder restart (frame_id resets to 0) */
    if (rs->has_decoded && frame_id <= rs->last_decoded_id) {
        if (rs->last_decoded_id - frame_id < 1000) return; /* truly old */
        /* encoder restart detected — reset state */
        fprintf(stderr, "Encoder restart detected (fid=%u last_dec=%u), resetting\n",
               frame_id, rs->last_decoded_id);
        rs->has_decoded = 0;
        rs->last_decoded_id = 0;
        rs->newest_frame_id = 0;
        for (int i = 0; i < FRAME_SLOTS; i++) {
            rs->slots[i].frame_id = 0;
            rs->slots[i].complete = 0;
            rs->slots[i].recv_count = 0;
        }
    }

    if (frame_id > rs->newest_frame_id)
        rs->newest_frame_id = frame_id;

    /* remember encoder address for clock sync */
    if (from && rs->encoder_addr.sin_addr.s_addr == 0)
        rs->encoder_addr = *from;

    /* get/evict slot */
    int idx = frame_id & SLOT_MASK;
    struct frame_slot *slot = &rs->slots[idx];

    if (slot->frame_id != frame_id) {
        if (slot->frame_id != 0 && !slot->complete && slot->recv_count > 0) {
            rs->frames_dropped++;
            rs->packets_lost += (slot->total_pkts - slot->recv_count);
        }
        memset(slot, 0, sizeof(*slot));
        slot->frame_id = frame_id;
    }

    slot->total_pkts = total;
    slot->encode_ts_ns = encode_ts;
    slot->flags |= hdr.flags;

    /* duplicate check */
    if (pkt_idx >= MAX_PKTS) return;
    if (slot->recv_bitmap[pkt_idx / 64] & (1ULL << (pkt_idx % 64))) return;

    /* store at scatter offset */
    size_t store_off = (size_t)pkt_idx * MAX_PAYLOAD;
    if (store_off + payload_len > MAX_FRAME_SIZE) return;
    memcpy(slot->data + store_off, buf + sizeof(struct pkt_hdr), payload_len);
    slot->pkt_sizes[pkt_idx] = (uint16_t)payload_len;
    slot->recv_bitmap[pkt_idx / 64] |= (1ULL << (pkt_idx % 64));
    slot->recv_count++;
    rs->packets_received++;

    /* check complete */
    if (slot->recv_count == total) {
        slot->complete = 1;

        /* compact scattered packets into contiguous buffer */
        static uint8_t compact[MAX_FRAME_SIZE];
        size_t pos = 0;
        for (uint16_t i = 0; i < total; i++) {
            memcpy(compact + pos, slot->data + (size_t)i * MAX_PAYLOAD, slot->pkt_sizes[i]);
            pos += slot->pkt_sizes[i];
        }
        memcpy(slot->data, compact, pos);
        slot->total_size = pos;
    }
}

static int g_listen_port = 5004; /* set from argv, used for clock sync */

static void send_clock_ping(struct receiver *rs) {
    rs->last_sync_time = now_ns(); /* always update to prevent spam */
    if (rs->sock < 0 || rs->encoder_addr.sin_addr.s_addr == 0) return;

    uint64_t now = now_ns();
    struct pkt_hdr ping = {
        .frame_id = htonl(0xFFFFFFFF),
        .pkt_idx = htons(0), /* ping */
        .pkt_total = 0,
        .payload_len = htonl(8),
        .flags = 0x80,
        .encode_ts_ns = 0,
    };
    uint8_t buf[sizeof(struct pkt_hdr) + 8];
    memcpy(buf, &ping, sizeof(ping));
    uint64_t now_be = htobe64(now);
    memcpy(buf + sizeof(ping), &now_be, 8);

    /* Send ping to encoder's sync port (listen_port + 1) */
    struct sockaddr_in dest;
    dest.sin_family = AF_INET;
    dest.sin_addr = rs->encoder_addr.sin_addr;
    dest.sin_port = htons(g_listen_port + 1);

    sendto(rs->sock, buf, sizeof(buf), 0,
           (struct sockaddr *)&dest, sizeof(dest));
    rs->last_sync_time = now;
}

/* ─── Main ─── */

int main(int argc, char **argv) {
    int port = (argc > 1) ? atoi(argv[1]) : 5004;
    int async_flip = 0;
    int use_hevc = 1; /* default to HEVC */
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--async-flip") == 0) async_flip = 1;
        if (strcmp(argv[i], "--h264") == 0)       use_hevc = 0;
        if (strcmp(argv[i], "--hevc") == 0)       use_hevc = 1; /* legacy no-op */
    }
    int async_flip_enabled = async_flip;
    g_listen_port = port;

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    printf("svi-decoder: EGL zero-copy %s VAAPI receiver (UDP)\n", use_hevc ? "HEVC" : "H.264");
    printf("Listening on UDP port %d\n\n", port);
    printf("Flip mode: %s\n", async_flip ? "async-requested" : "sync");

    /* ── 1. DRM + GBM ── */
    int drm_fd = open("/dev/dri/card0", O_RDWR);
    if (drm_fd < 0) { perror("open /dev/dri/card0"); return 1; }

    struct gbm_device *gbm = gbm_create_device(drm_fd);
    if (!gbm) { fprintf(stderr, "gbm_create_device failed\n"); return 1; }

    drmModeRes *res = drmModeGetResources(drm_fd);
    uint32_t crtc_id = 0, conn_id = 0;
    drmModeModeInfo mode = {0};
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(drm_fd, res->connectors[i]);
        if (!c) continue;
        if (c->connection == DRM_MODE_CONNECTED && c->count_modes > 0 && c->encoder_id) {
            drmModeEncoder *e = drmModeGetEncoder(drm_fd, c->encoder_id);
            if (e && e->crtc_id) {
                crtc_id = e->crtc_id;
                conn_id = c->connector_id;
                mode = c->modes[0];
                drmModeFreeEncoder(e);
            }
        }
        drmModeFreeConnector(c);
        if (crtc_id) break;
    }
    drmModeFreeResources(res);
    if (!crtc_id) { fprintf(stderr, "No active CRTC found\n"); return 1; }

    drmModeCrtc *orig_crtc = drmModeGetCrtc(drm_fd, crtc_id);

    printf("Display: CRTC %d, %dx%d@%dHz, connector %d\n",
           crtc_id, mode.hdisplay, mode.vdisplay, mode.vrefresh, conn_id);

    /* ── 2. EGL surfaceless ── */
    EGLDisplay edpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    if (edpy == EGL_NO_DISPLAY) { fprintf(stderr, "eglGetPlatformDisplay failed\n"); return 1; }
    eglInitialize(edpy, NULL, NULL);
    eglBindAPI(EGL_OPENGL_ES_API);

    EGLint cfg_attrs[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
    EGLConfig cfg;
    EGLint ncfg;
    eglChooseConfig(edpy, cfg_attrs, &cfg, 1, &ncfg);

    EGLint ctx_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext ectx = eglCreateContext(edpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    eglMakeCurrent(edpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ectx);

    printf("GL: %s\n", glGetString(GL_RENDERER));

    pCreateImage = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    pDestroyImage = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    pTexImage = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    void (*pRBImage)(GLenum, void*) = (void(*)(GLenum, void*))
        eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES");

    if (!pCreateImage || !pDestroyImage || !pTexImage || !pRBImage) {
        fprintf(stderr, "Missing required EGL/GL extensions\n"); return 1;
    }

    /* ── 3. Double-buffered GBM BOs → FBOs ── */
    struct gbm_bo *bo[2];
    uint32_t fb_id[2];
    GLuint fbo[2], rbo[2];
    EGLImage fbo_img[2];

    for (int i = 0; i < 2; i++) {
        bo[i] = gbm_bo_create(gbm, mode.hdisplay, mode.vdisplay,
                              GBM_FORMAT_XRGB8888,
                              GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
        if (!bo[i]) { fprintf(stderr, "gbm_bo_create %d failed\n", i); return 1; }

        uint32_t handle = gbm_bo_get_handle(bo[i]).u32;
        uint32_t stride = gbm_bo_get_stride(bo[i]);
        int ret = drmModeAddFB(drm_fd, mode.hdisplay, mode.vdisplay,
                               24, 32, stride, handle, &fb_id[i]);
        if (ret) { fprintf(stderr, "drmModeAddFB %d failed\n", i); return 1; }

        int bo_fd = gbm_bo_get_fd(bo[i]);
        EGLint img_attrs[] = {
            EGL_WIDTH, (EGLint)mode.hdisplay,
            EGL_HEIGHT, (EGLint)mode.vdisplay,
            EGL_LINUX_DRM_FOURCC_EXT, GBM_FORMAT_XRGB8888,
            EGL_DMA_BUF_PLANE0_FD_EXT, bo_fd,
            EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
            EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)stride,
            EGL_NONE
        };
        fbo_img[i] = pCreateImage(edpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, img_attrs);
        close(bo_fd);
        if (!fbo_img[i]) { fprintf(stderr, "FBO EGLImage %d failed\n", i); return 1; }

        glGenRenderbuffers(1, &rbo[i]);
        glBindRenderbuffer(GL_RENDERBUFFER, rbo[i]);
        pRBImage(GL_RENDERBUFFER, fbo_img[i]);

        glGenFramebuffers(1, &fbo[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo[i]);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_RENDERBUFFER, rbo[i]);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            fprintf(stderr, "FBO %d incomplete: 0x%x\n", i, status); return 1;
        }
    }
    printf("FBOs: 2x %dx%d XRGB8888 ready\n", mode.hdisplay, mode.vdisplay);

    /* ── 4. Shader + fullscreen quad ── */
    GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_src);
    if (!vs || !fs) return 1;

    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint link_ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &link_ok);
    if (!link_ok) {
        char log[1024];
        glGetProgramInfoLog(prog, sizeof(log), NULL, log);
        fprintf(stderr, "Program link error: %s\n", log);
        return 1;
    }
    glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "tex"), 0);

    /* VAAPI DMA-BUF import is top-origin, so flip V to avoid upside-down output. */
    float verts[] = {
        -1, -1,   0, 1,
         1, -1,   1, 1,
        -1,  1,   0, 0,
         1,  1,   1, 0,
    };
    GLuint vao, vbo_gl;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &vbo_gl);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_gl);
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, (void *)8);

    GLuint tex;
    glGenTextures(1, &tex);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glViewport(0, 0, mode.hdisplay, mode.vdisplay);
    glClearColor(0, 0, 0, 1);

    printf("Render pipeline ready\n");

    /* ── 5. VAAPI decoder ── */
    int ret = av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_VAAPI,
                                      "/dev/dri/renderD128", NULL, 0);
    if (ret < 0) { fprintf(stderr, "VAAPI init failed: %s\n", av_err2str(ret)); return 1; }

    AVHWDeviceContext *hwdev = (AVHWDeviceContext *)hw_device_ctx->data;
    AVVAAPIDeviceContext *vadev = (AVVAAPIDeviceContext *)hwdev->hwctx;
    VADisplay va_dpy = vadev->display;

    const AVCodec *dec = avcodec_find_decoder(use_hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264);
    if (!dec) { fprintf(stderr, "%s decoder not found\n", use_hevc ? "HEVC" : "H.264"); return 1; }
    AVCodecContext *dc = avcodec_alloc_context3(dec);
    dc->hw_device_ctx = av_buffer_ref(hw_device_ctx);
    dc->get_format = get_vaapi_format;
    dc->flags |= AV_CODEC_FLAG_LOW_DELAY;
    dc->flags2 |= AV_CODEC_FLAG2_FAST;
    dc->thread_count = 1;
    ret = avcodec_open2(dc, dec, NULL);
    if (ret < 0) { fprintf(stderr, "avcodec_open2 failed: %s\n", av_err2str(ret)); return 1; }

    AVCodecParserContext *parser = av_parser_init(use_hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264);
    if (!parser) { fprintf(stderr, "%s parser init failed\n", use_hevc ? "HEVC" : "H.264"); return 1; }

    printf("VAAPI H.264 decoder ready\n");

    /* ── 6. UDP receiver ── */
    static struct receiver rs;
    memset(&rs, 0, sizeof(rs));
    rs.sock = udp_init(port);
    if (rs.sock < 0) return 1;

    /* sync socket (for sending clock pings) */
    rs.sync_sock = socket(AF_INET, SOCK_DGRAM, 0);
    struct timeval stv = { .tv_sec = 0, .tv_usec = 100 };
    setsockopt(rs.sync_sock, SOL_SOCKET, SO_RCVTIMEO, &stv, sizeof(stv));

    printf("UDP socket bound on port %d\n", port);

    /* ── 7. Main decode + render loop ── */
    AVPacket *pkt = av_packet_alloc();
    AVFrame *hw_frame = av_frame_alloc();
    int buf_idx = 0;
    int n_frames = 0, n_rendered = 0, n_export_fail = 0, n_import_fail = 0;
    int n_gl_fallback = 0;
    int awaiting_keyframe = 1;
    uint64_t t_start = now_ns();
    uint64_t t_last_stats = t_start;
    double sum_export = 0, sum_import = 0, sum_render = 0, sum_flip = 0, sum_wait = 0, sum_vasync = 0;
    double sum_latency = 0;
    int n_latency = 0;

    /* Initial mode set */
    drmModeSetCrtc(drm_fd, crtc_id, fb_id[0], 0, 0, &conn_id, 1, &mode);

    printf("Waiting for packets...\n");

    uint8_t recv_buf[sizeof(struct pkt_hdr) + MAX_PAYLOAD];

    while (g_running) {
        /* receive packets — drain up to 200 per iteration */
        for (int i = 0; i < 200; i++) {
            struct sockaddr_in from;
            socklen_t fromlen = sizeof(from);
            ssize_t n = recvfrom(rs.sock, recv_buf, sizeof(recv_buf), 0,
                                 (struct sockaddr *)&from, &fromlen);
            if (n <= 0) break;
            receive_packet(&rs, recv_buf, n, &from);
        }

        /* periodic clock sync */
        if (now_ns() - rs.last_sync_time > 10000000000ULL) { /* every 10s */
            send_clock_ping(&rs);
        }

        /* process all complete frames before receiving more packets */
        int frames_this_iter = 0;
        while (frames_this_iter < 4 && g_running) {

        /* find oldest complete frame > last_decoded_id (sequential decode) */
        uint32_t best_id = 0xFFFFFFFF;
        struct frame_slot *best_slot = NULL;

        for (int i = 0; i < FRAME_SLOTS; i++) {
            struct frame_slot *s = &rs.slots[i];
            if (s->complete && (!rs.has_decoded || s->frame_id > rs.last_decoded_id) && s->frame_id < best_id) {
                best_id = s->frame_id;
                best_slot = s;
            }
        }

        /* drop stale incomplete frames */
        for (int i = 0; i < FRAME_SLOTS; i++) {
            struct frame_slot *s = &rs.slots[i];
            if (!s->complete && s->recv_count > 0 &&
                (!rs.has_decoded || s->frame_id > rs.last_decoded_id) &&
                rs.newest_frame_id > s->frame_id + 1) {
                rs.frames_dropped++;
                rs.packets_lost += (s->total_pkts - s->recv_count);
                s->recv_count = 0;
                s->frame_id = 0;
                awaiting_keyframe = 1;
            }
        }

        if (!best_slot) {
            if (frames_this_iter == 0) usleep(500);
            break;
        }

        /* keyframe recovery: after packet loss, wait for next keyframe */
        if (awaiting_keyframe && !(best_slot->flags & 0x01)) {
            rs.last_decoded_id = best_id;
            best_slot->frame_id = 0;
            best_slot->complete = 0;
            best_slot->recv_count = 0;
            continue;
        }
        awaiting_keyframe = 0;

        /* feed to H.264 decoder */
        uint8_t *parse_data = best_slot->data;
        int parse_size = (int)best_slot->total_size;
        uint64_t encode_ts = best_slot->encode_ts_ns;

        rs.last_decoded_id = best_id;
        rs.has_decoded = 1;
        rs.frames_received++;

        /* clear slot */
        best_slot->frame_id = 0;
        best_slot->complete = 0;
        best_slot->recv_count = 0;

        /* feed complete Annex B access unit directly to decoder */
        pkt->data = parse_data;
        pkt->size = parse_size;
        ret = avcodec_send_packet(dc, pkt);
        if (ret != 0 && ret != AVERROR(EAGAIN)) {
            awaiting_keyframe = 1;
        }

        /* receive decoded frames and render */
        while (avcodec_receive_frame(dc, hw_frame) == 0) {
            n_frames++;
            VASurfaceID surf = (VASurfaceID)(uintptr_t)hw_frame->data[3];
            uint64_t t_vasync0 = now_ns();
            vaSyncSurface(va_dpy, surf);
            sum_vasync += (now_ns() - t_vasync0) / 1e6;

            /* Export as DMA-BUF */
            uint64_t t1 = now_ns();
            VADRMPRIMESurfaceDescriptor desc;
            VAStatus st = vaExportSurfaceHandle(va_dpy, surf,
                VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_COMPOSED_LAYERS,
                &desc);
            uint64_t t2 = now_ns();
            sum_export += (t2 - t1) / 1e6;

            if (st != VA_STATUS_SUCCESS) {
                n_export_fail++;
                av_frame_unref(hw_frame);
                continue;
            }

            /* Import as NV12 EGLImage */
            t1 = now_ns();
            EGLint egl_attrs[] = {
                EGL_WIDTH, (EGLint)desc.width,
                EGL_HEIGHT, (EGLint)desc.height,
                EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_NV12,
                EGL_DMA_BUF_PLANE0_FD_EXT,
                    desc.objects[desc.layers[0].object_index[0]].fd,
                EGL_DMA_BUF_PLANE0_OFFSET_EXT,
                    (EGLint)desc.layers[0].offset[0],
                EGL_DMA_BUF_PLANE0_PITCH_EXT,
                    (EGLint)desc.layers[0].pitch[0],
                EGL_DMA_BUF_PLANE1_FD_EXT,
                    desc.objects[desc.layers[0].object_index[1]].fd,
                EGL_DMA_BUF_PLANE1_OFFSET_EXT,
                    (EGLint)desc.layers[0].offset[1],
                EGL_DMA_BUF_PLANE1_PITCH_EXT,
                    (EGLint)desc.layers[0].pitch[1],
                EGL_NONE
            };
            EGLImage img = pCreateImage(edpy, EGL_NO_CONTEXT,
                                         EGL_LINUX_DMA_BUF_EXT, NULL, egl_attrs);
            t2 = now_ns();
            sum_import += (t2 - t1) / 1e6;

            if (!img) {
                n_import_fail++;
                for (uint32_t o = 0; o < desc.num_objects; o++)
                    close(desc.objects[o].fd);
                av_frame_unref(hw_frame);
                continue;
            }

            /* Bind as external texture */
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex);
            pTexImage(GL_TEXTURE_EXTERNAL_OES, img);

            /* Wait for previous page flip */
            t1 = now_ns();
            if (g_flip_pending)
                wait_flip(drm_fd);
            t2 = now_ns();
            sum_wait += (t2 - t1) / 1e6;

            /* Render to FBO */
            t1 = now_ns();
            glBindFramebuffer(GL_FRAMEBUFFER, fbo[buf_idx]);
            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            n_gl_fallback += wait_render_gpu_complete();
            t2 = now_ns();
            sum_render += (t2 - t1) / 1e6;

            /* Async page flip */
            t1 = now_ns();
            uint32_t flip_flags = DRM_MODE_PAGE_FLIP_EVENT;
            if (async_flip_enabled)
                flip_flags |= DRM_MODE_PAGE_FLIP_ASYNC;
            ret = drmModePageFlip(drm_fd, crtc_id, fb_id[buf_idx], flip_flags, NULL);
            if (ret == -EINVAL && async_flip_enabled) {
                async_flip_enabled = 0;
                ret = drmModePageFlip(drm_fd, crtc_id, fb_id[buf_idx],
                                      DRM_MODE_PAGE_FLIP_EVENT, NULL);
                if (ret == 0)
                    fprintf(stderr, "Async flip unsupported, falling back to sync\n");
            }
            t2 = now_ns();
            sum_flip += (t2 - t1) / 1e6;

            if (ret == 0) {
                g_flip_pending = 1;
            } else if (ret == -EBUSY) {
                /* skip */
            }

            buf_idx = 1 - buf_idx;
            n_rendered++;

            /* latency measurement */
            if (rs.clock_valid && encode_ts > 0) {
                uint64_t decode_done = now_ns();
                int64_t adjusted_encode = (int64_t)encode_ts - rs.clock_offset_ns;
                double latency_ms = (double)((int64_t)decode_done - adjusted_encode) / 1e6;
                if (latency_ms > 0 && latency_ms < 500) {
                    sum_latency += latency_ms;
                    n_latency++;
                }
            }

            /* Cleanup */
            pDestroyImage(edpy, img);
            for (uint32_t o = 0; o < desc.num_objects; o++)
                close(desc.objects[o].fd);
            av_frame_unref(hw_frame);

            /* Stats every 5 seconds */
            uint64_t t_now = now_ns();
            if (t_now - t_last_stats > 5000000000ULL) {
                double elapsed = (t_now - t_start) / 1e9;
                double fps = n_rendered / elapsed;
                printf("%.1ffps | %d rendered | vasync=%.2fms active=%.2fms/f",
                       fps, n_rendered,
                       sum_vasync / n_rendered,
                       (sum_export + sum_import + sum_render + sum_flip) / n_rendered);
                if (n_gl_fallback > 0)
                    printf(" | glfb=%d", n_gl_fallback);
                if (n_latency > 0)
                    printf(" | latency=%.1fms", sum_latency / n_latency);
                if (rs.frames_dropped > 0)
                    printf(" | dropped=%lu lost_pkts=%lu",
                           (unsigned long)rs.frames_dropped,
                           (unsigned long)rs.packets_lost);
                printf("\n");
                t_last_stats = t_now;
            }
        }

        frames_this_iter++;
        } /* end inner while (frames_this_iter < 4) */
    }

    /* Drain pending flip */
    if (g_flip_pending)
        wait_flip(drm_fd);

    /* ── 8. Cleanup ── */
    printf("\nShutting down...\n");

    if (orig_crtc) {
        drmModeSetCrtc(drm_fd, orig_crtc->crtc_id, orig_crtc->buffer_id,
                       orig_crtc->x, orig_crtc->y, &conn_id, 1, &orig_crtc->mode);
        drmModeFreeCrtc(orig_crtc);
    }

    double total_s = (now_ns() - t_start) / 1e9;
    printf("\n=== Final Stats ===\n");
    printf("Duration: %.1fs\n", total_s);
    printf("Frames: %d decoded, %d rendered\n", n_frames, n_rendered);
    if (n_rendered > 0) {
        printf("FPS: %.1f\n", n_rendered / total_s);
        printf("Per-frame: vasync=%.3f export=%.3f import=%.3f wait=%.3f render=%.3f flip=%.3f active=%.3fms\n",
               sum_vasync / n_rendered,
               sum_export / n_rendered, sum_import / n_rendered,
               sum_wait / n_rendered,
               sum_render / n_rendered, sum_flip / n_rendered,
               (sum_export + sum_import + sum_render + sum_flip) / n_rendered);
        printf("GL fallback syncs: %d\n", n_gl_fallback);
        if (n_latency > 0)
            printf("Avg latency: %.1fms (over %d samples)\n", sum_latency / n_latency, n_latency);
    }
    printf("Dropped: %lu frames, %lu packets lost\n",
           (unsigned long)rs.frames_dropped, (unsigned long)rs.packets_lost);

    av_parser_close(parser);
    av_frame_free(&hw_frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dc);
    av_buffer_unref(&hw_device_ctx);

    glDeleteTextures(1, &tex);
    glDeleteBuffers(1, &vbo_gl);
    glDeleteVertexArrays(1, &vao);
    glDeleteProgram(prog);
    for (int i = 0; i < 2; i++) {
        glDeleteFramebuffers(1, &fbo[i]);
        glDeleteRenderbuffers(1, &rbo[i]);
        pDestroyImage(edpy, fbo_img[i]);
        drmModeRmFB(drm_fd, fb_id[i]);
        gbm_bo_destroy(bo[i]);
    }
    eglDestroyContext(edpy, ectx);
    eglTerminate(edpy);
    gbm_device_destroy(gbm);
    close(drm_fd);
    close(rs.sock);
    if (rs.sync_sock >= 0) close(rs.sync_sock);

    printf("Done.\n");
    return 0;
}
