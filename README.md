# Saccade Video Interface (SVI)

Ultra-low-latency 1080p60 video pipeline from Resolume Arena to HDMI projectors over Ethernet.

## Architecture

```
Resolume Arena (Syphon output, 1080p60 BGRA)
  → SVI-Encoder (Mac, Objective-C)
    → SyphonClient → IOSurface FBO blit (GPU)
      → VTCompressionSession (H.264, low-latency)
        → AVCC→Annex B + custom UDP packets (24B header + 1400B payload)
          → Paced send (configurable rate cap, default 200 Mbps) → GigE
            → SVI-Decoder (Mac or Linux, C)
              → UDP recv → frame reassembly (8-slot ring buffer)
                → avcodec_send_packet (VAAPI H.264 decode)
                  → DMA-BUF → EGLImage (NV12) → DRM page flip (sync/async) → HDMI
```

## Components

| Component | Platform | Description |
|-----------|----------|-------------|
| **SVI-Encoder** | Mac only | Syphon capture → H.264 encode → paced UDP send |
| **SVI-Decoder** | Mac or Linux | UDP receive → H.264 decode → display output |
| **SVI-Toolkit** | TBD | Utilities and diagnostics (coming later) |

## Performance

| Metric | Value |
|--------|-------|
| FPS | ~59-60 (matches Arena output) |
| Bandwidth | ~38-40 Mbps per stream |
| End-to-end latency (default: pace=200, async flip) | ~21-23ms avg |
| End-to-end latency (uplink-constrained: pace=150, async flip) | ~20-22ms avg |
| End-to-end latency (pace=150, sync flip) | ~40ms avg |
| Packet loss (test runs) | 0 dropped frames, 0 packets lost |

Measured on March 19, 2026 using local Arena encoder + remote Intel Cherry Trail decoder (`192.168.0.14`) over point-to-point GigE.

## SVI-Encoder (`encoder/`)

Runs on Mac. Captures from Syphon, encodes H.264 via VideoToolbox, sends paced UDP.

**Build** (requires Resolume Arena installed for Syphon.framework):
```bash
cd encoder && bash build.sh
```

**Run:**
```bash
./svi-encoder Composition 192.168.0.14 5004 40 150
# args: syphon_name dest_ip dest_port [bitrate_mbps] [pace_mbps]
# defaults: bitrate_mbps=40, pace_mbps=200
```

**Utilities:**
- `svi-list` — discover available Syphon servers

## SVI-Decoder (`decoder/`)

Receives UDP, decodes H.264, renders to display. Currently targeting Intel Atom (Cherry Trail) with VAAPI on Linux.

**Build** (on the target device):
```bash
cd decoder && bash build.sh
```

**Run:**
```bash
LIBVA_DRIVER_NAME=i965 chrt -f 50 taskset -c 1-3 ./svi-decoder 5004 --async-flip
# args: udp_port [--async-flip]
```

`--async-flip` is now actively applied (`DRM_MODE_PAGE_FLIP_ASYNC`) with automatic fallback to sync flip when unsupported by the display driver.

## Scripts (`scripts/`)

- `start_decoder.sh` — start SVI-Decoder with RT scheduling
- `deploy.sh` — copy, build, and start SVI-Decoder on remote device

**Deploy:**
```bash
cd scripts && bash deploy.sh 192.168.0.14 5004 async
# args: [host] [port] [async|sync], default flip mode is async
```

## Packet Protocol

24-byte header per UDP datagram, max 1400-byte payload (fits under 1472-byte MTU-safe limit):

```c
struct pkt_hdr {
    uint32_t frame_id;       // Monotonic frame counter (network byte order)
    uint16_t pkt_idx;        // 0-based packet index within frame
    uint16_t pkt_total;      // Total packets in this frame
    uint32_t payload_len;    // Bytes of H.264 data in this packet (≤1400)
    uint8_t  flags;          // bit 0: keyframe, bit 1: end-of-frame
    uint8_t  reserved[3];
    uint64_t encode_ts_ns;   // Encoder timestamp for latency measurement
};
```

Clock sync uses ping-pong on `data_port + 1` every 10 seconds.

## Key Design Decisions

- **Syphon** over NDI: zero-copy IOSurface GPU capture, eliminates ~12ms NDI encode
- **Direct VTCompressionSession** over ffmpeg wrapper: eliminates ~42ms pipeline buffering
- **Paced UDP** over TCP/MPEG-TS: no head-of-line blocking, no mux overhead, configurable rate cap (`pace_mbps`) to fit shared-uplink budgets
- **Sender thread**: VT callback queues to ring buffer, dedicated thread does paced send — keeps VT unblocked
- **Frame handler callback** over polling: Syphon notifies on new frame via block callback
- **Bitmap-based dedup**: `uint64_t[24]` bitmap supports up to 1500 packets per frame
- **Multi-frame processing**: decoder processes up to 4 frames per recv iteration to prevent falling behind
- **Encoder restart detection**: if incoming frame_id is >1000 behind last_decoded_id, reset decoder state
- **Fence-based GPU sync**: encoder/decoder use `glFenceSync`/`glClientWaitSync` with bounded fallback to `glFinish()` instead of unconditional full-pipeline stalls
- **Display flip mode control**: decoder supports sync and async page flip; async mode materially reduces flip wait latency at the same bandwidth cap
