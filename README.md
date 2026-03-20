# Saccade Video Interface (SVI)

Ultra-low-latency 1080p60 video pipeline from Resolume Arena to HDMI display over GigE. Captures via Syphon (zero-copy GPU), encodes HEVC (H.265) with VideoToolbox, streams over paced UDP, and decodes with VAAPI hardware acceleration on a Linux display node. H.264 is also supported but HEVC is preferred.

**Typical end-to-end latency: ~21–23ms** (async flip, GigE)

---

## Architecture

```
Resolume Arena  ──Syphon──▶  svi-encoder (Mac)  ──UDP/GigE──▶  svi-decoder (Linux)  ──DRM──▶  HDMI
                              IOSurface capture                   VAAPI HEVC decode
                              VideoToolbox HEVC                   DMA-BUF → EGL → GBM
                              paced UDP send                      async page flip
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for a full pipeline breakdown, packet protocol spec, and tuning guide.

---

## Components

| Component | Platform | Purpose |
|-----------|----------|---------|
| `svi-encoder` | macOS | Syphon capture → HEVC/H.264 encode → paced UDP send |
| `svi-decoder` | Linux | UDP receive → HEVC/H.264 decode → DRM display |
| `svi-list` | macOS | List available Syphon servers |

---

## Requirements

**Encoder (Mac)**
- macOS with Syphon-compatible source (tested: Resolume Arena)
- Resolume Arena installed (provides `Syphon.framework`)
- GigE NIC

**Decoder (Linux)**
- Intel integrated GPU with VAAPI support (`i965` or `iHD` driver)
- Packages: `libdrm`, `libgbm`, `libEGL`, `libGLESv2`, `libavcodec`, `libavutil`, `libva`, `libva-drm`
- GigE NIC; direct or switched link to encoder

---

## Quick Start

### 1. Build the encoder (Mac)

```bash
cd encoder && bash build.sh
```

Requires Resolume Arena at the default install path. See [ARCHITECTURE.md](ARCHITECTURE.md) if Arena is installed elsewhere.

### 2. Deploy and start the decoder (Linux target)

```bash
# Copy source, build on device, and start — uses SSH key auth by default
cd scripts && bash deploy.sh <target-ip>

# Password auth (if SSH keys aren't set up)
SSH_PASSWORD=<password> bash deploy.sh <target-ip>
```

`deploy.sh` compiles the decoder on the target device and starts it with RT scheduling.

### 3. Run the encoder

```bash
# List available Syphon sources
./svi-list

# Stream to decoder (HEVC, recommended)
./svi-encoder <syphon-name> <dest-ip> <dest-port> [bitrate-mbps] [pace-mbps] --hevc

# Example: 40 Mbps encode, 200 Mbps pacing, HEVC
./svi-encoder Composition 192.168.1.10 5004 40 200 --hevc

# H.264 fallback (omit --hevc flag)
./svi-encoder Composition 192.168.1.10 5004 40 200
```

---

## Performance

Measured on 2026-03-19, Intel Cherry Trail decoder over point-to-point GigE:

| Configuration | End-to-end latency |
|---------------|-------------------|
| pace=200, async flip | ~21–23ms avg |
| pace=150, async flip | ~20–22ms avg |
| pace=150, sync flip | ~40ms avg |

- **FPS**: ~59–60 (matches Arena output)
- **Bandwidth**: ~38–40 Mbps per 1080p60 stream
- **Packet loss**: 0 dropped frames across all test runs

---

## Decoder Flags

```
svi-decoder <port> [--async-flip] [--hevc]
```

| Flag | Description |
|------|-------------|
| `--async-flip` | Use `DRM_MODE_PAGE_FLIP_ASYNC` (recommended; auto-falls back to sync if unsupported) |
| `--hevc` | Decode HEVC (H.265) stream; must match encoder (recommended) |

---

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/deploy.sh <host> [port] [async\|sync]` | Build and start decoder on remote device |
| `scripts/start_decoder.sh [port] [async\|sync]` | Start decoder locally with RT scheduling |
| `scripts/stress-test-6x.sh <dest-ip> [duration]` | Multi-stream panoramic stress test |

**Authentication for deploy scripts** (choose one):
- SSH key: ensure your public key is authorised on the target device
- Password: `export SSH_PASSWORD=<password>` before running

---

## License

MIT — see [LICENSE](LICENSE).
