/*
 * svi-encoder.m — SVI-Encoder (Saccade Video Interface)
 *
 * Captures frames from a Syphon server (e.g., Resolume Arena),
 * encodes to H.264 via VideoToolbox with ultra-low-latency settings,
 * and sends raw Annex B NALUs over paced UDP with custom packet framing.
 *
 * Build:
 *   clang -O2 -fobjc-arc -o svi-encoder svi-encoder.m \
 *     -F"/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
 *     -rpath "/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
 *     -framework Syphon -framework Cocoa -framework OpenGL \
 *     -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
 *     -framework CoreFoundation -framework IOSurface -lpthread
 *
 * Usage:
 *   ./svi-encoder <syphon_name> <dest_ip> <dest_port> [bitrate_mbps]
 *   ./svi-encoder Composition 192.168.0.14 5004 40
 */

#define GL_SILENCE_DEPRECATION
#define GLES_SILENCE_DEPRECATION

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Syphon/Syphon.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <libkern/OSByteOrder.h>

#ifndef GL_TEXTURE_RECTANGLE
#define GL_TEXTURE_RECTANGLE 0x84F5
#endif
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* ---------- packet header (shared with decoder) ---------- */

#define MAX_PAYLOAD 1400
#define MAX_ANNEX_B (2 * 1024 * 1024)

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

/* ---------- globals ---------- */

static volatile sig_atomic_t g_running = 1;
static void sig_handler(int s) { (void)s; g_running = 0; }

/* mach_absolute_time → nanoseconds */
static mach_timebase_info_data_t g_timebase;
static inline uint64_t mach_to_ns(uint64_t t) {
    return t * g_timebase.numer / g_timebase.denom;
}
static inline uint64_t now_ns(void) {
    return mach_to_ns(mach_absolute_time());
}

/* ---------- send queue (VT callback → sender thread) ---------- */

#include <pthread.h>

#define SEND_QUEUE_SLOTS 8
#define SEND_FRAME_MAX   (2 * 1024 * 1024)

struct send_frame {
    uint8_t  data[SEND_FRAME_MAX];
    size_t   len;
    int      keyframe;
    uint64_t encode_ts;
    uint32_t frame_id;
};

struct send_queue {
    struct send_frame frames[SEND_QUEUE_SLOTS];
    volatile int write_idx;  /* written by VT callback */
    volatile int read_idx;   /* read by sender thread */
    pthread_mutex_t mutex;
    pthread_cond_t  cond;
};

static struct send_queue g_sq;

/* ---------- encoder context ---------- */

typedef struct {
    /* UDP */
    int sock;
    struct sockaddr_in dest;

    /* pacing */
    uint64_t frame_interval_ns;
    uint32_t pace_mbps;

    /* frame counter */
    uint32_t frame_counter;

    /* stats (updated atomically from sender thread) */
    volatile uint64_t n_encoded;
    volatile uint64_t n_dropped;
    volatile uint64_t n_bytes_sent;
    uint64_t stats_time;
    volatile uint64_t n_queue_full;
    volatile uint64_t n_gl_fallback;

    /* clock sync */
    int listen_sock;

    /* codec selection */
    int use_hevc;
} enc_ctx;

static enc_ctx g_enc;

static inline void wait_blit_gpu_complete(enc_ctx *enc) {
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (!fence) {
        glFinish();
        __sync_fetch_and_add(&enc->n_gl_fallback, 1);
        return;
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
        __sync_fetch_and_add(&enc->n_gl_fallback, 1);
    }
    glDeleteSync(fence);
}

/* ---------- sender thread ---------- */

static void *sender_thread(void *arg) {
    enc_ctx *enc = (enc_ctx *)arg;
    uint32_t pace_mbps = enc->pace_mbps ? enc->pace_mbps : 200;
    uint64_t pace_ns = (uint64_t)MAX_PAYLOAD * 8 * 1000 / pace_mbps; /* per-packet pacing */
    uint8_t pkt_buf[sizeof(struct pkt_hdr) + MAX_PAYLOAD];

    while (g_running) {
        /* wait for data */
        pthread_mutex_lock(&g_sq.mutex);
        while (g_sq.read_idx == g_sq.write_idx && g_running) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 2000000; /* 2ms timeout */
            if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
            pthread_cond_timedwait(&g_sq.cond, &g_sq.mutex, &ts);
        }
        if (!g_running) { pthread_mutex_unlock(&g_sq.mutex); break; }
        int idx = g_sq.read_idx % SEND_QUEUE_SLOTS;
        pthread_mutex_unlock(&g_sq.mutex);

        struct send_frame *sf = &g_sq.frames[idx];
        uint16_t total = (uint16_t)((sf->len + MAX_PAYLOAD - 1) / MAX_PAYLOAD);
        if (total == 0) total = 1;

        uint64_t send_start = now_ns();

        for (uint16_t i = 0; i < total; i++) {
            size_t offset = (size_t)i * MAX_PAYLOAD;
            size_t chunk = sf->len - offset;
            if (chunk > MAX_PAYLOAD) chunk = MAX_PAYLOAD;

            struct pkt_hdr hdr = {
                .frame_id    = htonl(sf->frame_id),
                .pkt_idx     = htons(i),
                .pkt_total   = htons(total),
                .payload_len = htonl((uint32_t)chunk),
                .flags       = (uint8_t)((sf->keyframe ? 0x01 : 0) |
                               ((i == total - 1) ? 0x02 : 0)),
                .reserved    = {0},
                .encode_ts_ns = OSSwapHostToBigInt64(sf->encode_ts),
            };

            memcpy(pkt_buf, &hdr, sizeof(hdr));
            memcpy(pkt_buf + sizeof(hdr), sf->data + offset, chunk);

            /* pace: spin-wait for rate limit */
            uint64_t target = send_start + (uint64_t)i * pace_ns;
            while (now_ns() < target)
                ; /* spin */

            ssize_t sent = sendto(enc->sock, pkt_buf, sizeof(hdr) + chunk, 0,
                                  (struct sockaddr *)&enc->dest, sizeof(enc->dest));
            if (sent > 0)
                __sync_fetch_and_add(&enc->n_bytes_sent, (uint64_t)sent);
        }

        /* advance read index */
        __sync_fetch_and_add(&g_sq.read_idx, 1);
    }
    return NULL;
}

/* ---------- queue a frame for sending (called from VT callback) ---------- */

static void queue_frame(enc_ctx *enc, const uint8_t *data, size_t len,
                         int keyframe, uint64_t encode_ts)
{
    uint32_t frame_id = enc->frame_counter++;

    /* check if queue is full */
    int queued = g_sq.write_idx - g_sq.read_idx;
    if (queued >= SEND_QUEUE_SLOTS) {
        __sync_fetch_and_add(&enc->n_queue_full, 1);
        return; /* drop frame rather than block VT callback */
    }

    int idx = g_sq.write_idx % SEND_QUEUE_SLOTS;
    struct send_frame *sf = &g_sq.frames[idx];

    if (len > SEND_FRAME_MAX) len = SEND_FRAME_MAX;
    memcpy(sf->data, data, len);
    sf->len = len;
    sf->keyframe = keyframe;
    sf->encode_ts = encode_ts;
    sf->frame_id = frame_id;

    /* publish */
    __sync_fetch_and_add(&g_sq.write_idx, 1);

    /* wake sender */
    pthread_mutex_lock(&g_sq.mutex);
    pthread_cond_signal(&g_sq.cond);
    pthread_mutex_unlock(&g_sq.mutex);
}

/* ---------- VTCompressionSession output callback ---------- */

static void encode_callback(void *outputCallbackRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTEncodeInfoFlags infoFlags,
                             CMSampleBufferRef sampleBuffer)
{
    (void)sourceFrameRefCon;
    (void)infoFlags;
    enc_ctx *enc = (enc_ctx *)outputCallbackRefCon;

    if (status != noErr || !sampleBuffer) {
        enc->n_dropped++;
        return;
    }

    uint64_t encode_ts = now_ns();

    /* check keyframe */
    int keyframe = 1;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = NULL;
        if (CFDictionaryGetValueIfPresent(dict, kCMSampleAttachmentKey_NotSync,
                                          (const void **)&notSync)) {
            keyframe = !CFBooleanGetValue(notSync);
        }
    }

    /* build Annex B buffer (static to avoid 2MB stack allocation) */
    static uint8_t annex_b[MAX_ANNEX_B];
    size_t ab_len = 0;

    /* prepend parameter sets on keyframes (SPS/PPS for H.264; VPS/SPS/PPS for HEVC) */
    if (keyframe) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        size_t param_count = 0;

        if (enc->use_hevc) {
            /* HEVC: VPS(0) → SPS(1) → PPS(2) — order is required by spec */
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, 0, NULL, NULL,
                                                               &param_count, NULL);
            for (size_t pi = 0; pi < param_count; pi++) {
                const uint8_t *ps = NULL;
                size_t ps_size = 0;
                OSStatus pst = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, pi, &ps, &ps_size, NULL, NULL);
                if (pst != noErr || !ps) continue;
                if (ab_len + 4 + ps_size > MAX_ANNEX_B) break;
                annex_b[ab_len] = 0; annex_b[ab_len+1] = 0;
                annex_b[ab_len+2] = 0; annex_b[ab_len+3] = 1;
                ab_len += 4;
                memcpy(annex_b + ab_len, ps, ps_size);
                ab_len += ps_size;
            }
        } else {
            /* H.264: SPS(0) → PPS(1) */
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL,
                                                               &param_count, NULL);
            for (size_t pi = 0; pi < param_count; pi++) {
                const uint8_t *ps = NULL;
                size_t ps_size = 0;
                OSStatus pst = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, pi, &ps, &ps_size, NULL, NULL);
                if (pst != noErr || !ps) continue;
                if (ab_len + 4 + ps_size > MAX_ANNEX_B) break;
                annex_b[ab_len] = 0; annex_b[ab_len+1] = 0;
                annex_b[ab_len+2] = 0; annex_b[ab_len+3] = 1;
                ab_len += 4;
                memcpy(annex_b + ab_len, ps, ps_size);
                ab_len += ps_size;
            }
        }
    }

    /* convert AVCC NALUs to Annex B */
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t total_len = 0;
    char *data_ptr = NULL;
    CMBlockBufferGetDataPointer(block, 0, NULL, &total_len, &data_ptr);

    size_t off = 0;
    while (off + 4 <= total_len) {
        uint32_t nalu_len = 0;
        memcpy(&nalu_len, data_ptr + off, 4);
        nalu_len = CFSwapInt32BigToHost(nalu_len);
        off += 4;
        if (nalu_len == 0) continue; /* skip zero-length NALUs */
        if (off + nalu_len > total_len) break;
        if (ab_len + 4 + nalu_len > MAX_ANNEX_B) break;

        annex_b[ab_len] = 0; annex_b[ab_len+1] = 0;
        annex_b[ab_len+2] = 0; annex_b[ab_len+3] = 1;
        ab_len += 4;
        memcpy(annex_b + ab_len, data_ptr + off, nalu_len);
        ab_len += nalu_len;
        off += nalu_len;
    }

    enc->n_encoded++;
    queue_frame(enc, annex_b, ab_len, keyframe, encode_ts);
}

/* ---------- GL shader helpers ---------- */

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "Shader compile error: %s\n", log);
    }
    return s;
}

static GLuint create_blit_program(void) {
    const char *vs =
        "#version 120\n"
        "attribute vec2 pos;\n"
        "varying vec2 tc;\n"
        "uniform vec2 texSize;\n"
        "void main() {\n"
        "    gl_Position = vec4(pos, 0.0, 1.0);\n"
        "    tc = (pos * 0.5 + 0.5) * texSize;\n"
        "}\n";
    const char *fs =
        "#version 120\n"
        "#extension GL_ARB_texture_rectangle : require\n"
        "uniform sampler2DRect tex;\n"
        "varying vec2 tc;\n"
        "void main() { gl_FragColor = texture2DRect(tex, tc); }\n";

    GLuint vs_id = compile_shader(GL_VERTEX_SHADER, vs);
    GLuint fs_id = compile_shader(GL_FRAGMENT_SHADER, fs);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs_id);
    glAttachShader(prog, fs_id);
    glBindAttribLocation(prog, 0, "pos");
    glLinkProgram(prog);

    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(prog, sizeof(log), NULL, log);
        fprintf(stderr, "Program link error: %s\n", log);
    }

    glDeleteShader(vs_id);
    glDeleteShader(fs_id);
    return prog;
}

/* ---------- main ---------- */

int main(int argc, const char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <syphon_name> <dest_ip> <dest_port> [bitrate_mbps] [pace_mbps] [--h264]\n", argv[0]);
        return 1;
    }

    const char *syphon_name = argv[1];
    const char *dest_ip = argv[2];
    int dest_port = atoi(argv[3]);
    int bitrate_mbps = (argc > 4) ? atoi(argv[4]) : 40;
    int pace_mbps = (argc > 5) ? atoi(argv[5]) : 200;
    if (pace_mbps < 50) pace_mbps = 50;

    int use_hevc = 1; /* default to HEVC */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--h264") == 0) use_hevc = 0;
        if (strcmp(argv[i], "--hevc") == 0) use_hevc = 1; /* legacy no-op when already default */
    }

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    mach_timebase_info(&g_timebase);

    fprintf(stderr, "svi-encoder: name=%s dest=%s:%d bitrate=%dMbps pace=%dMbps codec=%s\n",
            syphon_name, dest_ip, dest_port, bitrate_mbps, pace_mbps,
            use_hevc ? "HEVC" : "H264");

    @autoreleasepool {

    /* --- NSApplication (required for Syphon notifications) --- */
    [NSApplication sharedApplication];

    /* --- CGL context --- */
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAAccelerated,
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)32,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pf = NULL;
    GLint npix = 0;
    CGLChoosePixelFormat(attrs, &pf, &npix);
    if (!pf) {
        fprintf(stderr, "ERROR: CGLChoosePixelFormat failed\n");
        return 1;
    }
    CGLContextObj cgl_ctx = NULL;
    CGLCreateContext(pf, NULL, &cgl_ctx);
    CGLDestroyPixelFormat(pf);
    if (!cgl_ctx) {
        fprintf(stderr, "ERROR: CGLCreateContext failed\n");
        return 1;
    }
    CGLSetCurrentContext(cgl_ctx);
    fprintf(stderr, "CGL context created\n");

    /* --- Syphon discovery --- */
    fprintf(stderr, "Searching for Syphon server '%s'...\n", syphon_name);
    NSString *name = [NSString stringWithUTF8String:syphon_name];
    NSDictionary *serverDesc = nil;

    while (g_running && !serverDesc) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        NSArray *servers = [[SyphonServerDirectory sharedDirectory]
                            serversMatchingName:name appName:nil];
        if (servers.count > 0) {
            serverDesc = servers[0];
            fprintf(stderr, "Found Syphon server: %s (%s)\n",
                    [[serverDesc objectForKey:SyphonServerDescriptionNameKey] UTF8String],
                    [[serverDesc objectForKey:SyphonServerDescriptionAppNameKey] UTF8String]);
        } else {
            fprintf(stderr, ".");
        }
    }
    if (!g_running) return 0;

    /* --- Syphon client --- */
    __block volatile int g_new_frame = 0;
    SyphonClient *client = [[SyphonClient alloc]
        initWithServerDescription:serverDesc
        context:cgl_ctx
        options:nil
        newFrameHandler:^(SyphonClient *c) {
            (void)c;
            g_new_frame = 1;
        }];

    if (!client || !client.isValid) {
        fprintf(stderr, "ERROR: Failed to create Syphon client\n");
        return 1;
    }

    /* wait for first frame to get dimensions */
    SyphonImage *firstImg = nil;
    while (g_running && !firstImg) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        firstImg = [client newFrameImage];
    }
    if (!g_running) return 0;

    NSSize texSize = firstImg.textureSize;
    int width = (int)texSize.width;
    int height = (int)texSize.height;
    fprintf(stderr, "Syphon frame size: %dx%d\n", width, height);
    firstImg = nil; /* release */

    /* --- UDP socket --- */
    memset(&g_enc, 0, sizeof(g_enc));
    g_enc.pace_mbps = (uint32_t)pace_mbps;
    g_enc.use_hevc = use_hevc;
    g_enc.sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_enc.sock < 0) { perror("socket"); return 1; }
    int sndbuf = 524288;
    setsockopt(g_enc.sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    g_enc.dest.sin_family = AF_INET;
    g_enc.dest.sin_port = htons(dest_port);
    inet_pton(AF_INET, dest_ip, &g_enc.dest.sin_addr);
    fprintf(stderr, "UDP socket ready → %s:%d\n", dest_ip, dest_port);

    /* also bind listen socket for clock sync pings from decoder */
    g_enc.listen_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_enc.listen_sock >= 0) {
        struct sockaddr_in bind_addr = {
            .sin_family = AF_INET,
            .sin_port = htons(dest_port + 1), /* sync on port+1 */
            .sin_addr.s_addr = INADDR_ANY,
        };
        bind(g_enc.listen_sock, (struct sockaddr *)&bind_addr, sizeof(bind_addr));
        struct timeval tv = { .tv_sec = 0, .tv_usec = 100 };
        setsockopt(g_enc.listen_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }

    /* --- Double-buffered IOSurface CVPixelBuffers + FBOs --- */
    CVPixelBufferRef cvpb[2] = {NULL, NULL};
    IOSurfaceRef iosurfs[2] = {NULL, NULL};
    GLuint fbo[2] = {0, 0};
    GLuint fbo_tex[2] = {0, 0};

    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferOpenGLCompatibilityKey: @YES,
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };

    for (int i = 0; i < 2; i++) {
        CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)pbAttrs, &cvpb[i]);
        if (cr != kCVReturnSuccess) {
            fprintf(stderr, "ERROR: CVPixelBufferCreate failed: %d\n", cr);
            return 1;
        }
        iosurfs[i] = CVPixelBufferGetIOSurface(cvpb[i]);
        if (!iosurfs[i]) {
            fprintf(stderr, "ERROR: CVPixelBufferGetIOSurface returned NULL\n");
            return 1;
        }

        /* create GL texture backed by IOSurface */
        glGenTextures(1, &fbo_tex[i]);
        glBindTexture(GL_TEXTURE_RECTANGLE, fbo_tex[i]);
        CGLTexImageIOSurface2D(cgl_ctx, GL_TEXTURE_RECTANGLE,
            GL_RGBA, width, height,
            GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, iosurfs[i], 0);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        /* create FBO with IOSurface texture as color attachment */
        glGenFramebuffers(1, &fbo[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_RECTANGLE, fbo_tex[i], 0);
        GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (fbs != GL_FRAMEBUFFER_COMPLETE) {
            fprintf(stderr, "ERROR: FBO[%d] incomplete: 0x%x\n", i, fbs);
            return 1;
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    fprintf(stderr, "Double-buffered IOSurface FBOs ready (%dx%d)\n", width, height);

    /* --- GL blit shader --- */
    GLuint prog = create_blit_program();
    GLint loc_texSize = glGetUniformLocation(prog, "texSize");
    GLint loc_tex = glGetUniformLocation(prog, "tex");

    /* fullscreen quad VAO */
    float quad[] = { -1, -1,  1, -1,  -1, 1,  1, 1 };
    GLuint vbo;
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);

    /* --- VTCompressionSession --- */
    VTCompressionSessionRef vtSession = NULL;
    NSDictionary *encoderSpec = @{
        (id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES,
    };
    NSDictionary *srcAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };

    CMVideoCodecType codec_type = use_hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
    OSStatus vts = VTCompressionSessionCreate(kCFAllocatorDefault,
        width, height, codec_type,
        (__bridge CFDictionaryRef)encoderSpec,
        (__bridge CFDictionaryRef)srcAttrs,
        kCFAllocatorDefault,
        encode_callback, &g_enc, &vtSession);
    if (vts != noErr) {
        fprintf(stderr, "ERROR: VTCompressionSessionCreate failed: %d\n", (int)vts);
        return 1;
    }

    /* low-latency properties */
    VTSessionSetProperty(vtSession, kVTCompressionPropertyKey_RealTime,
                         kCFBooleanTrue);
    VTSessionSetProperty(vtSession, kVTCompressionPropertyKey_AllowFrameReordering,
                         kCFBooleanFalse);
    VTSessionSetProperty(vtSession,
        kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
        kCFBooleanTrue);

    int32_t bitrate = bitrate_mbps * 1000000;
    CFNumberRef bitrateRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &bitrate);
    VTSessionSetProperty(vtSession, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    int32_t gop = 30;
    CFNumberRef gopRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &gop);
    VTSessionSetProperty(vtSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, gopRef);
    CFRelease(gopRef);

    float gop_dur = 0.5f;
    CFNumberRef gopDurRef = CFNumberCreate(NULL, kCFNumberFloat32Type, &gop_dur);
    VTSessionSetProperty(vtSession,
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, gopDurRef);
    CFRelease(gopDurRef);

    float fps_val = 60.0f;
    CFNumberRef fpsRef = CFNumberCreate(NULL, kCFNumberFloat32Type, &fps_val);
    VTSessionSetProperty(vtSession, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    CFStringRef profile_level = use_hevc
        ? kVTProfileLevel_HEVC_Main_AutoLevel
        : kVTProfileLevel_H264_High_AutoLevel;
    VTSessionSetProperty(vtSession, kVTCompressionPropertyKey_ProfileLevel, profile_level);

    /* data rate limits: 5KB per Mbps per window, scales with bitrate_mbps.
     * At 40Mbps → 200KB; at 80Mbps → 400KB. Allows keyframe headroom without
     * capping the average rate below what was requested. */
    int limit_bytes = bitrate_mbps * 5 * 1024;
    float limit_window = 1.0f / 30.0f;  /* ~33ms window */
    CFNumberRef limitBytes = CFNumberCreate(NULL, kCFNumberSInt32Type, &limit_bytes);
    CFNumberRef limitWindow = CFNumberCreate(NULL, kCFNumberFloat32Type, &limit_window);
    CFTypeRef limitVals[] = { limitBytes, limitWindow };
    CFArrayRef limits = CFArrayCreate(NULL, limitVals, 2, &kCFTypeArrayCallBacks);
    VTSessionSetProperty(vtSession, kVTCompressionPropertyKey_DataRateLimits, limits);
    CFRelease(limits);
    CFRelease(limitBytes);
    CFRelease(limitWindow);

    VTCompressionSessionPrepareToEncodeFrames(vtSession);
    fprintf(stderr, "VTCompressionSession ready: %s %dMbps, GOP=%d, pace=%dMbps, low-latency\n",
            use_hevc ? "HEVC" : "H264", bitrate_mbps, gop, pace_mbps);

    /* --- frame pacing --- */
    g_enc.frame_interval_ns = 16666667; /* 60fps */
    int buf_idx = 0;
    uint64_t frame_count = 0;
    g_enc.stats_time = now_ns();

    /* --- send queue + sender thread --- */
    memset(&g_sq, 0, sizeof(g_sq));
    pthread_mutex_init(&g_sq.mutex, NULL);
    pthread_cond_init(&g_sq.cond, NULL);

    pthread_t send_tid;
    pthread_create(&send_tid, NULL, sender_thread, &g_enc);

    fprintf(stderr, "Starting capture loop (sender thread active)...\n");

    /* --- main capture loop --- */
    while (g_running) {
        /* Service run loop — process pending events */
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.0005]];

        /* check for clock sync pings */
        if (g_enc.listen_sock >= 0) {
            uint8_t sync_buf[sizeof(struct pkt_hdr) + 16];
            struct sockaddr_in from;
            socklen_t fromlen = sizeof(from);
            ssize_t n = recvfrom(g_enc.listen_sock, sync_buf, sizeof(sync_buf), 0,
                                 (struct sockaddr *)&from, &fromlen);
            if (n >= (ssize_t)sizeof(struct pkt_hdr)) {
                struct pkt_hdr *h = (struct pkt_hdr *)sync_buf;
                if (ntohl(h->frame_id) == 0xFFFFFFFF && ntohs(h->pkt_idx) == 0) {
                    /* ping from decoder — send pong */
                    struct pkt_hdr pong = {
                        .frame_id = htonl(0xFFFFFFFF),
                        .pkt_idx = htons(1), /* pong */
                        .pkt_total = 0,
                        .payload_len = htonl(8),
                        .flags = 0x80,
                        .encode_ts_ns = OSSwapHostToBigInt64(now_ns()),
                    };
                    uint8_t pong_buf[sizeof(struct pkt_hdr) + 8];
                    memcpy(pong_buf, &pong, sizeof(pong));
                    /* copy decoder's original timestamp */
                    if (n >= (ssize_t)(sizeof(struct pkt_hdr) + 8))
                        memcpy(pong_buf + sizeof(pong), sync_buf + sizeof(struct pkt_hdr), 8);
                    else
                        memset(pong_buf + sizeof(pong), 0, 8);
                    sendto(g_enc.listen_sock, pong_buf, sizeof(pong_buf), 0,
                           (struct sockaddr *)&from, fromlen);
                }
            }
        }

        /* check for new Syphon frame */
        if (!client.isValid) {
            fprintf(stderr, "Syphon server disconnected, reconnecting...\n");
            client = nil;
            while (g_running) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                NSArray *servers = [[SyphonServerDirectory sharedDirectory]
                                    serversMatchingName:name appName:nil];
                if (servers.count > 0) {
                    client = [[SyphonClient alloc]
                        initWithServerDescription:servers[0]
                        context:cgl_ctx options:nil newFrameHandler:nil];
                    if (client.isValid) {
                        fprintf(stderr, "Reconnected to Syphon server\n");
                        break;
                    }
                }
            }
            continue;
        }

        if (!g_new_frame) {
            continue; /* runloop sleep above handles the wait */
        }
        g_new_frame = 0;

        SyphonImage *img = [client newFrameImage];
        if (!img) continue;

        NSSize imgSize = img.textureSize;

        /* blit Syphon texture → IOSurface FBO */
        glBindFramebuffer(GL_FRAMEBUFFER, fbo[buf_idx]);
        glViewport(0, 0, width, height);

        glUseProgram(prog);
        glUniform2f(loc_texSize, (float)imgSize.width, (float)imgSize.height);
        glUniform1i(loc_tex, 0);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_RECTANGLE, img.textureName);

        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glDisableVertexAttribArray(0);

        wait_blit_gpu_complete(&g_enc); /* ensure blit completes before VT reads IOSurface */

        img = nil; /* release */

        /* encode */
        CMTime pts = CMTimeMake((int64_t)frame_count, 60);
        CMTime dur = CMTimeMake(1, 60);

        vts = VTCompressionSessionEncodeFrame(vtSession, cvpb[buf_idx],
                                              pts, dur, NULL, NULL, NULL);
        if (vts != noErr) {
            fprintf(stderr, "VTCompressionSessionEncodeFrame failed: %d\n", (int)vts);
            g_enc.n_dropped++;
        }

        buf_idx ^= 1;
        frame_count++;

        /* periodic stats */
        uint64_t now = now_ns();
        uint64_t elapsed = now - g_enc.stats_time;
        if (elapsed >= 5000000000ULL) { /* 5 seconds */
            double secs = (double)elapsed / 1e9;
            double fps = (double)g_enc.n_encoded / secs;
            double mbps = (double)g_enc.n_bytes_sent * 8.0 / secs / 1e6;
            int sq_queued = g_sq.write_idx - g_sq.read_idx;
            fprintf(stderr, "[stats] %.1ffps  %.1fMbps  enc=%llu drop=%llu qfull=%llu glfb=%llu q=%d  cap=%llu\n",
                    fps, mbps, g_enc.n_encoded, g_enc.n_dropped,
                    g_enc.n_queue_full, g_enc.n_gl_fallback, sq_queued, frame_count);
            g_enc.n_encoded = 0;
            g_enc.n_dropped = 0;
            g_enc.n_bytes_sent = 0;
            g_enc.n_queue_full = 0;
            g_enc.n_gl_fallback = 0;
            g_enc.stats_time = now;
        }
    }

    /* --- cleanup --- */
    fprintf(stderr, "\nShutting down...\n");

    /* stop sender thread */
    pthread_mutex_lock(&g_sq.mutex);
    pthread_cond_signal(&g_sq.cond);
    pthread_mutex_unlock(&g_sq.mutex);
    pthread_join(send_tid, NULL);
    pthread_mutex_destroy(&g_sq.mutex);
    pthread_cond_destroy(&g_sq.cond);

    VTCompressionSessionCompleteFrames(vtSession, kCMTimeInvalid);
    VTCompressionSessionInvalidate(vtSession);
    CFRelease(vtSession);

    [client stop];
    client = nil;

    for (int i = 0; i < 2; i++) {
        if (cvpb[i]) CVPixelBufferRelease(cvpb[i]);
        if (fbo[i]) glDeleteFramebuffers(1, &fbo[i]);
        if (fbo_tex[i]) glDeleteTextures(1, &fbo_tex[i]);
    }
    glDeleteBuffers(1, &vbo);
    glDeleteProgram(prog);

    close(g_enc.sock);
    if (g_enc.listen_sock >= 0) close(g_enc.listen_sock);
    CGLDestroyContext(cgl_ctx);

    } /* @autoreleasepool */

    fprintf(stderr, "Done.\n");
    return 0;
}
