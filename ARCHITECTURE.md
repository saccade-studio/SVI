# SVI Architecture

Deep-dive reference for the Saccade Video Interface pipeline. Covers encoder and decoder internals, the packet protocol, clock synchronisation, display pipeline, and tuning.

---

## Table of Contents

1. [Pipeline Overview](#pipeline-overview)
2. [Encoder](#encoder)
3. [Decoder](#decoder)
4. [Packet Protocol](#packet-protocol)
5. [Clock Synchronisation](#clock-synchronisation)
6. [Crop and Visible Rect](#crop-and-visible-rect)
7. [Scripts Reference](#scripts-reference)
8. [Building](#building)
9. [Performance Tuning](#performance-tuning)
10. [Platform Notes](#platform-notes)
11. [Known Limitations](#known-limitations)

---

## Pipeline Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Mac (Encoder)                                                          │
│                                                                         │
│  Resolume Arena                                                         │
│       │ Syphon GL texture                                               │
│       ▼                                                                 │
│  SyphonClient (frame callback)                                          │
│       │ GL_TEXTURE_RECTANGLE → IOSurface FBO blit                       │
│       │ glFenceSync / glClientWaitSync (4 × 1ms, fallback glFinish)    │
│       ▼                                                                 │
│  VTCompressionSession (HEVC preferred / H.264, VideoToolbox)            │
│       │ AVCC → Annex B, VPS/SPS/PPS (HEVC) or SPS/PPS (H.264) on IDR  │
│       ▼                                                                 │
│  Send queue (8-slot ring, 2MB/slot)                                     │
│       │                                                                 │
│  Sender thread ── paced UDP send (pace_mbps cap)                        │
│       │ 24-byte header + ≤1400-byte payload per datagram                │
└───────┼─────────────────────────────────────────────────────────────────┘
        │  GigE UDP
┌───────┼─────────────────────────────────────────────────────────────────┐
│  Linux (Decoder)                                                        │
│       ▼                                                                 │
│  UDP recv (8MB SO_RCVBUF, drain ≤200 pkts/iteration)                   │
│       │ Scatter into frame slot (pkt_idx × 1400 offset)                 │
│       │ Bitmap completion tracking                                      │
│       ▼                                                                 │
│  Compaction → avcodec_send_packet (libavcodec, AV_CODEC_FLAG_LOW_DELAY)│
│       │ VAAPI hardware decode (/dev/dri/renderD128, i965 driver)        │
│       ▼                                                                 │
│  vaExportSurfaceHandle → DMA-BUF (NV12, two planes)                    │
│       │ eglCreateImageKHR (EGL_LINUX_DMA_BUF_EXT)                       │
│       ▼                                                                 │
│  GL_TEXTURE_EXTERNAL_OES → FBO render (fullscreen quad, UV flip)       │
│       │ GBM buffer (XRGB8888)                                           │
│       ▼                                                                 │
│  drmModePageFlip (async or sync) → HDMI                                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Encoder

### Invocation

```bash
./svi-encoder <syphon-name> <dest-ip> <dest-port> [bitrate-mbps] [pace-mbps] [--h264]
```

| Argument | Default | Description |
|----------|---------|-------------|
| `syphon-name` | — | Syphon server name (`svi-list` to discover) |
| `dest-ip` | — | Decoder IP address |
| `dest-port` | — | Decoder UDP port |
| `bitrate-mbps` | `40` | Average encode bitrate |
| `pace-mbps` | `200` | Network pacing cap (min 50) |
| `--h264` | off | Encode as H.264 (override default HEVC) |
| `--hevc` | on  | Encode as HEVC (H.265); default / legacy flag |

### Capture

Syphon delivers each frame via a block callback. On each callback:

1. A GL blit copies the Syphon texture (`GL_TEXTURE_RECTANGLE`) into a double-buffered IOSurface-backed FBO.
2. A fence sync (`glFenceSync` / `glClientWaitSync`) waits up to 4 × 1ms for GPU completion. If all attempts time out, falls back to `glFinish()` (counted in `glfb` stat).
3. The IOSurface is passed to VideoToolbox as a `CVPixelBuffer` for HEVC or H.264 encoding.

### Encode (VideoToolbox)

Key VTCompressionSession settings:

| Property | Value | Reason |
|----------|-------|--------|
| `AverageBitRate` | `bitrate_mbps × 1e6` | Target rate |
| `DataRateLimits` | 200 KB / 33ms | Prevent keyframe bursts |
| `RealTime` | true | Low-latency scheduling hint |
| `AllowFrameReordering` | false | No B-frames; reduces latency |
| `MaxKeyFrameInterval` | 30 frames | IDR every ~0.5s |
| `MaxKeyFrameIntervalDuration` | 0.5s | Time-based IDR cap |
| `ExpectedFrameRate` | 60 fps | Rate hint to encoder |

The VT callback converts AVCC NALUs to Annex B format, injecting parameter sets before every keyframe: VPS + SPS + PPS for HEVC, SPS + PPS for H.264. Output is queued into the send ring buffer.

### Send Queue and Pacing

A lock-free 8-slot ring buffer (2 MB per slot) decouples the VT callback thread from the sender thread:

- VT callback writes the completed Annex B frame to the next free slot.
- If all slots are full the frame is dropped (`qfull` stat increments).
- The dedicated sender thread reads from the queue, slices each frame into ≤1400-byte payloads, prepends the 24-byte header, and sends each datagram.
- Pacing is enforced per-packet: the sender spins until the inter-packet deadline (derived from `pace_mbps`) before sending the next datagram. This keeps the downstream switch buffer from spiking on large keyframes.

### Statistics (logged every 5 s)

```
[stats] Ns fps  Mbps  enc=N drop=N qfull=N glfb=N q=N cap=N
[fence-5s] fence stats
```

| Field | Meaning |
|-------|---------|
| `fps` | Encoded frames/s |
| `Mbps` | Wire bandwidth |
| `drop` | Frames dropped (queue full) |
| `qfull` | Queue-full events |
| `glfb` | GPU fence timeout → glFinish fallbacks |
| `q` | Current queue depth |
| `cap` | Total frames captured |

---

## Decoder

### Invocation

```bash
LIBVA_DRIVER_NAME=i965 ./svi-decoder <port> [--async-flip] [--h264]
```

In production, run with RT scheduling:

```bash
LIBVA_DRIVER_NAME=i965 chrt -f 50 taskset -c 1-3 ./svi-decoder 5004 --async-flip
```

| Argument | Default | Description |
|----------|---------|-------------|
| `port` | — | UDP listen port |
| `--async-flip` | off | Enable `DRM_MODE_PAGE_FLIP_ASYNC`; auto-falls back to sync |
| `--h264` | off | Decode H.264 stream (override default HEVC) |
| `--hevc` | on  | Decode HEVC (H.265); default / legacy flag |

### Packet Reception and Frame Reassembly

The decoder maintains 8 frame slots in a circular buffer. Each slot holds:

```c
struct frame_slot {
    uint32_t frame_id;
    uint16_t total_pkts;
    uint16_t recv_count;
    uint64_t recv_bitmap[24];     // 1 bit per packet, supports ≤1500 pkts/frame
    uint8_t  data[MAX_FRAME_SIZE];// Scatter-stored at pkt_idx × 1400
    uint16_t pkt_sizes[MAX_PKTS];
    size_t   total_size;
    uint8_t  flags;
    uint64_t encode_ts_ns;
    int      complete;
};
```

On each receive iteration the decoder drains up to 200 datagrams without blocking (`SO_RCVTIMEO` = 500µs). For each packet:

1. Validate header fields (bounds checks on `pkt_idx`, `pkt_total`, `payload_len`).
2. Map `frame_id` to a slot (`frame_id % 8`). Evict and discard if the slot holds a different, incomplete frame.
3. Scatter-store the payload at `pkt_idx × 1400` within the slot's data buffer.
4. Set the corresponding bitmap bit; increment `recv_count`.
5. When `recv_count == total_pkts`: compact scattered packets into a contiguous Annex B buffer and decode.

Incomplete frames are counted as `dropped` in statistics.

**Encoder restart detection**: if an incoming `frame_id` is more than 1000 behind the last decoded frame ID, the decoder resets its state and waits for the next keyframe. This handles encoder process restarts without requiring a decoder restart.

### VAAPI Decode Pipeline

```
avcodec_send_packet (AV_CODEC_FLAG_LOW_DELAY | AV_CODEC_FLAG2_FAST)
  → vaCreateSurfaces (NV12)
  → vaBeginPicture / vaRenderPicture / vaEndPicture
  → vaExportSurfaceHandle (VA_EXPORT_SURFACE_READ_ONLY)
  → DMA-BUF fd (two planes: Y, UV)
```

- Device: `/dev/dri/renderD128`
- Driver: set via `LIBVA_DRIVER_NAME` (`i965` for Atom/Silvermont; `iHD` for newer Intel)
- Thread count: 1 (avoids libavcodec's internal threading latency)
- Pixel format: `AV_PIX_FMT_VAAPI` → NV12 via DMA-BUF export

After packet loss the decoder waits for the next keyframe (flag bit 0 set) before resuming decode to avoid corrupted output.

### Display Pipeline (EGL / DRM)

```
DMA-BUF fd
  → eglCreateImageKHR (EGL_LINUX_DMA_BUF_EXT, EGL_DMA_BUF_PLANE0/1_FD_EXT)
  → GL_TEXTURE_EXTERNAL_OES (samplerExternalOES)
  → fullscreen quad render (UV-flipped; corrects VAAPI top-origin)
  → GBM buffer (XRGB8888) registered as DRM framebuffer
  → drmModePageFlip
```

**Page flip modes:**

| Mode | Flag | Behaviour |
|------|------|-----------|
| Async | `DRM_MODE_PAGE_FLIP_ASYNC` | Flip at next scanline; skips vsync wait. Lowest latency on supported drivers. |
| Sync | `DRM_MODE_PAGE_FLIP_EVENT` | Flip at next vblank. Adds up to one frame period of wait (~16.7ms at 60 Hz). |

If `DRM_MODE_PAGE_FLIP_ASYNC` returns `-EINVAL` the decoder falls back to sync flip automatically.

Double-buffered GBM buffers are used to prevent tearing. The decoder waits for the `g_flip_pending` flag (set by the DRM page flip event handler) before issuing the next flip.

### Statistics (logged every 5 s)

```
[stats] fps=N export=Xms import=Xms wait=Xms render=Xms flip=Xms active=Xms glfb=N latency=Xms dropped=N
```

| Field | Meaning |
|-------|---------|
| `export` | DMA-BUF export time per frame |
| `import` | EGLImage import time per frame |
| `wait` | Page flip wait time per frame |
| `render` | GL render time per frame |
| `flip` | DRM flip submission time per frame |
| `active` | Total GPU pipeline time per frame |
| `glfb` | GPU fence timeout → glFinish fallbacks |
| `latency` | Network + decode + render latency (requires clock sync) |
| `dropped` | Incomplete frames discarded |

---

## Packet Protocol

Each UDP datagram carries one packet of a single video frame (HEVC or H.264).

### Header (24 bytes, all fields network byte order)

```c
struct pkt_hdr {
    uint32_t frame_id;       // Monotonic frame counter; 0xFFFFFFFF = clock sync
    uint16_t pkt_idx;        // 0-based packet index within frame
    uint16_t pkt_total;      // Total packets in this frame
    uint32_t payload_len;    // Bytes of video data in this packet (≤1400)
    uint8_t  flags;          // bit 0: keyframe; bit 1: end-of-frame; 0x80: sync pong
    uint8_t  reserved[3];
    uint64_t encode_ts_ns;   // Encoder wall-clock timestamp (nanoseconds)
};
```

### Key Values

| Field | Value | Meaning |
|-------|-------|---------|
| `frame_id` | 0–0xFFFFFFFE | Normal video frame |
| `frame_id` | 0xFFFFFFFF | Clock sync datagram |
| `flags` bit 0 | 1 | This frame is a keyframe (IDR) |
| `flags` bit 1 | 1 | This is the last packet of the frame |
| `flags` | 0x80 | Clock sync pong reply from encoder |
| `pkt_idx` | 0 (sync) | Ping from decoder |
| `pkt_idx` | 1 (sync) | Pong from encoder |

### Sizing

| Parameter | Value |
|-----------|-------|
| Max payload per datagram | 1400 bytes |
| Max frame size | 2 MB |
| Max packets per frame | ~1500 |
| UDP datagram max | 1424 bytes (1400 payload + 24 header) |
| Stays under MTU-safe limit | 1472 bytes (1500 MTU − 28 IP+UDP overhead) |

---

## Clock Synchronisation

Accurate latency measurement requires a shared time reference across the encoder (Mac) and decoder (Linux).

**Mechanism (NTP-style ping-pong):**

1. Decoder sends a ping every 10 seconds on `listen_port + 1` (e.g., 5005).
   Payload: `frame_id=0xFFFFFFFF`, `pkt_idx=0`, 8-byte decoder timestamp (`T₁`).

2. Encoder receives the ping, records its local timestamp (`T₂`), and immediately sends a pong back.
   Payload: `frame_id=0xFFFFFFFF`, `flags=0x80`, `encode_ts_ns=T₂`.

3. Decoder receives the pong at time `T₃`. It computes:
   ```
   RTT    = T₃ − T₁
   offset = T₂ − T₁ − RTT/2
   ```

4. Every subsequent decoded frame's `encode_ts_ns` is corrected by `offset` to compute end-to-end latency:
   ```
   latency = T_decode − (encode_ts_ns + offset)
   ```

The offset is updated each ping cycle. It is only used for the `latency` display stat and does not affect the video pipeline.

---

## Crop and Visible Rect

`visible_rect.h` provides `svi_compute_visible_rect()` for computing UV texture coordinates and pixel dimensions after cropping. The utility and its tests (`decoder/tests/`) are implemented but not yet wired to decoder CLI flags.

```c
svi_visible_rect svi_compute_visible_rect(
    int surface_w, int surface_h,   // Full surface size
    int frame_w,   int frame_h,     // Frame size (0 = full surface)
    int crop_left, int crop_right,
    int crop_top,  int crop_bottom  // Pixel amounts to crop
);

typedef struct {
    float u0, v0, u1, v1;  // Normalised UV coords for GL sampling
    int visible_w, visible_h;
    int clipped;            // Non-zero if any crop was applied
} svi_visible_rect;
```

Invalid or excessive crop values are clamped. If the resulting visible area is zero, the function falls back to the full surface.

**Intended use case (panoramic stack):**
A 1920×3240 frame (3× 1080p panels stacked vertically) sent to a single decoder that displays only one 1080p slice — e.g. `--crop-top 2160` to show only the bottom panel. This will be exposed as decoder CLI flags once wired.

---

## Scripts Reference

### `scripts/deploy.sh`

Copies decoder source to a remote Linux device, compiles it there, and starts it.

```bash
bash deploy.sh <host> [port] [async|sync]

# SSH key auth (default):
bash deploy.sh 192.168.1.10

# Password auth:
SSH_PASSWORD=secret bash deploy.sh 192.168.1.10 5004 async
```

Steps performed:
1. Kill any running `svi-decoder` on the target.
2. Copy `svi-decoder.c`, `visible_rect.h`, and `decoder/build.sh` to `/root/` on the target.
3. Run `build.sh` on the target.
4. Copy `start_decoder.sh` and run it with the specified port and flip mode.

### `scripts/start_decoder.sh`

Starts the decoder with SCHED_FIFO RT scheduling and CPU affinity.

```bash
bash start_decoder.sh [port] [async|sync] [extra-decoder-args...]

bash start_decoder.sh 5004 async
```

Runs:
```bash
nohup chrt -f 50 taskset -c 1-3 /root/svi-decoder <args> > /tmp/decoder.log 2>&1 &
```

Outputs the first lines of the decoder log before returning.

### `scripts/stress-test-6x.sh`

Two-stream 6× 1080p panoramic stress test. Sends a 1920×3240 stream to the real decoder and a second stream to an RFC 5737 TEST-NET-2 sink IP (switch-discarded via static ARP).

```bash
bash stress-test-6x.sh <dest-ip> [duration-secs]

SSH_PASSWORD=secret bash stress-test-6x.sh 192.168.1.10 120
```

Validates:
- All encoder processes remain alive throughout the test.
- No `qfull` events (no dropped frames at the encoder).
- No new kernel UDP `RcvbufErrors` at the decoder.
- Reports per-stream FPS, Mbps, and aggregate bandwidth.

---

## Building

### Encoder (Mac)

```bash
cd encoder && bash build.sh
```

`build.sh` runs:
```bash
clang -O2 -fobjc-arc -o svi-encoder svi-encoder.m \
  -F"/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
  -rpath "/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
  -framework Syphon -framework Cocoa -framework OpenGL \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -framework CoreFoundation -framework IOSurface -lpthread
```

If Arena is installed to a non-default path, edit the `-F` and `-rpath` flags in `encoder/build.sh`.

### Decoder (Linux)

```bash
cd decoder && bash build.sh
```

`build.sh` runs:
```bash
gcc -O3 -march=silvermont -msse4.1 -flto -ffast-math \
  -I/usr/include/libdrm -o svi-decoder svi-decoder.c \
  -lEGL -lGLESv2 -lgbm -ldrm -lavcodec -lavutil -lva -lva-drm -lpthread
```

The `-march=silvermont` flag targets Intel Atom (Cherry Trail). Replace with `-march=native` if building for a different CPU.

**Install dependencies (Debian/Ubuntu):**
```bash
apt install \
  libdrm-dev libgbm-dev libegl-dev libgles2-mesa-dev \
  libavcodec-dev libavutil-dev \
  libva-dev libva-drm2 i965-va-driver
```

---

## Performance Tuning

### Latency vs Bandwidth Trade-off

`pace_mbps` controls the sender's packet pacing rate. A lower cap reduces peak burst at the switch but spreads packet delivery over more of the frame period:

| `pace_mbps` | Frame delivery time (1080p60, ~38 Mbps stream) | Effect |
|-------------|------------------------------------------------|--------|
| 200 | ~1.5ms | Packets arrive early; flip can happen sooner |
| 150 | ~2ms | Slightly extended; useful on congested links |
| 50 | ~6ms | Conservative; for shared 100 Mbps links |

`bitrate_mbps` is the target encode rate. Larger keyframes are rate-limited by `DataRateLimits` (200 KB / 33ms window); inter-frames are smaller.

### Async vs Sync Flip

`--async-flip` (decoder) issues the DRM page flip without waiting for the next vsync. This saves up to one full frame period (~16.7ms at 60 Hz) at the cost of potential micro-tearing on the display hardware. Most embedded display controllers tested support async flip cleanly.

If async flip is unsupported the decoder emits a warning and falls back to sync flip automatically.

### RT Scheduling

`chrt -f 50` (SCHED_FIFO priority 50) and `taskset -c 1-3` (cores 1–3) are strongly recommended for the decoder. On a 4-core Atom the OS and IRQs are left on core 0; the decoder monopolises the remaining cores.

### UDP Receive Buffer

The decoder sets `SO_RCVBUF` to 8 MB. If you see `RcvbufErrors` in `/proc/net/snmp`, increase the kernel maximum:

```bash
sysctl -w net.core.rmem_max=33554432
```

---

## Platform Notes

### Encoder

- **macOS**: VideoToolbox H.264 requires macOS 10.8+; HEVC requires macOS 10.13+. Tested on Apple Silicon and Intel Macs.
- **Syphon**: The encoder uses Syphon.framework bundled with Resolume Arena. Building against the standalone Syphon SDK is untested but should work with an updated `-F` path.

### Decoder

- **VAAPI driver**: `i965` (legacy Intel Atom/Cherry Trail). Newer Intel hardware may use `iHD` (Intel Media Driver). Set `LIBVA_DRIVER_NAME` accordingly.
- **DRM device**: Decoder opens `/dev/dri/card0` for display and `/dev/dri/renderD128` for VAAPI. These are hardcoded for single-display embedded targets.
- **Display mode**: The decoder uses the first active connected CRTC/connector it finds. It does not support multi-head or hotplug.
- **macOS decoder**: The decoder's UDP/reassembly/decode core is portable C; the DRM/VAAPI display backend is Linux-only.

---

## Known Limitations

| Area | Limitation |
|------|-----------|
| Encoder drop | If the sender thread can't drain the ring buffer fast enough, the oldest frame in the next slot is silently dropped. |
| Max frame size | Annex B data per frame is capped at 2 MB (~14,000 packets). Exceeding this would require a larger ring slot. |
| Single display | Decoder opens the first CRTC it finds; no multi-head support. |
| DRM device path | `/dev/dri/card0` and `/dev/dri/renderD128` are hardcoded. |
| NV12 only | VAAPI output is always NV12 (8-bit, 4:2:0). No 10-bit or 4:4:4 support. |
| No dynamic resolution | A resolution change mid-stream (encoder restart or source resize) requires a decoder restart. |
| Async flip fallback silent | Driver rejection of async flip is logged but not separately reported in stats. |
| Clock sync precision | The NTP-style offset calculation assumes symmetric RTT, which may not hold over a loaded switch. Latency readings are indicative, not precise. |
