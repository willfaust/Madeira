# Media: winegstreamer on FFmpeg, VideoToolbox and AudioToolbox

Upstream Wine implements the unix side of `winegstreamer.dll` with GStreamer,
which does not exist on iOS. Without it `winegstreamer.dll` cannot load, and
three things that Windows programs use every day have no decoder:

- the Windows WMA decoder MFT/DMO (`CLSID_CWMADecMediaObject` in `wmadmod.dll`,
  which forwards to `CLSID_wg_wma_decoder` in winegstreamer). FAudio asks COM
  for it for every xWMA/XMA voice; without it the compressed bytes reached the
  mixer as PCM, which sounds like loud static;
- quartz's MPEG-I and "GStreamer" splitters (DirectShow MP3/WAV playback);
- Media Foundation's fallback media source (MP4/MOV video through the source
  resolver);
- the Windows Media Format reader (`wmvcore`: `WMCreateReader`,
  `WMCreateSyncReader`, and DirectShow's WM ASF Reader on top of it), which
  plays WMV/WMA (ASF) files. A visual novel's cutscenes went through it; the
  reader failed to connect (`no enabled demuxer recognised the stream`,
  `0x80040265`) and the game showed a white screen with no sound.

This port supplies that unix side in `libntdll_unix.a`, bound by name in
`load_builtin_unixlib()` (`build/ntdll-unix/virtual_ios.c`).

**32-bit (WoW64) and 64-bit (ARM64EC) processes both get it.** The ARM64EC
farm ships `winegstreamer.dll` and `wmadmod.dll`, so an x64 program's xWMA
voices (XAudio2/FAudio's WMA decoder DMO) decode instead of playing silence.
A 64-bit process gets the WMA transform only: its `wg_parser` (quartz / Media
Foundation source) is refused as before unless `MADEIRA_WG_64BIT=1`.
`MADEIRA_WG_64BIT=0` gives 64-bit processes the generic stub table again.

## Pieces

| File | What it is |
|---|---|
| `build/ntdll-unix/winegstreamer_unixlib_ios.c` | Both unix call tables (entry for entry with `dlls/winegstreamer/unixlib.h`), the wow64 thunks, and the `wg_transform` subset `wma_decoder.c` uses, on libavcodec: WMA v1/v2/Pro/Lossless and XMA1/2 only. Other transforms (AAC, H.264, WMV, resampler, colour converter) are refused at create, and `wg_muxer` returns `STATUS_NOT_IMPLEMENTED`. |
| `build/ntdll-unix/wg_parser_av_ios.c` | The `wg_parser` core, `#include`d by the file above: the PE read thread's pull protocol as an AVIOContext, libavformat demux (mp3, wav, mov, asf), MPEG audio / PCM / WMA decode through libavcodec + libswresample, Windows Media video (WMV7/8/9, VC-1, MS-MPEG4 v1-v3) decoded in software by libavcodec (`mav_lavc_video`), a packet queue with back-pressure, B-frame reordering, keyframe seek with exact trim, and conversion to the formats `quartz_parser.c`, `media_source.c` and `wm_reader.c` ask for: NV12, I420, YV12, YUY2, UYVY, YVYU, BGRx, BGRA, RGBA, 24-bit BGR (the WM reader's default, bottom-up), RGB565 and RGB555. |
| `build/ntdll-unix/wg_parser_apple_ios.c` | H.264/HEVC on VideoToolbox (NV12 out) and AAC on an AudioToolbox AudioConverter (float PCM out). Its own translation unit with no Wine or FFmpeg header. |
| `build/ntdll-unix/wg_parser_backend_ios.h` | The contract between the core and a decoder backend; plain C types only, so the host test can supply stub backends. |
| `build/ffmpeg/build.sh` | FFmpeg 7.1.5, pinned by SHA-256, LGPL-only configuration. |

FFmpeg is built with no H.264, HEVC or AAC decoder or parser: those streams go
to the platform decoders. Windows Media video has no platform decoder on iOS,
so FFmpeg's LGPL `wmv1`, `wmv2`, `wmv3`, `vc1` and `msmpeg4v1-3` decoders are
built and decode it on the CPU (one thread, FFmpeg's C code: `--disable-asm`).
See `THIRD-PARTY-NOTICES.md` for the exact component list and its licence.

**Containers and codecs.** MP3/WAV: MPEG audio and PCM. MP4/MOV: H.264 or
HEVC video (VideoToolbox) with AAC, MPEG audio or PCM. ASF (WMV/WMA): Windows
Media video (libavcodec) with WMA v1/v2/Pro/Lossless or MPEG audio. AVI,
MPEG program streams, Bink and the like are not handled here (Bink and most
engines' own formats are decoded by the game itself). The codec format of an
ASF stream (`wg_parser_stream_get_codec_format`) is the one Wine's GStreamer
backend reports: WMV1/WMV2/WMV3/WMVA/WVC1 video, WMA audio with its version,
block alignment and codec data, so a game that reads the file's profile
through `IWMProfile` sees the real stream types.

**The video format a stream reports: RGB32.** A video stream's native format
(the media type Media Foundation's source lists first) is RGB32 by default,
although VideoToolbox decodes to NV12 and the picture is converted on the CPU.
A media session connects a source straight to its renderer with that native
type only. The EVR accepts NV12, and the session then asks the EVR's sample
allocator for NV12 Direct3D 9 surfaces. DXMT, this port's d3d9, has no YUV
surface format, so the allocator fails. The session then drops the renderer's
output node and every node after it, and still reports that playback
started. No sample is ever requested, the audio renderer never starts, and the
title shows an empty video window. Senren Banka's CG movie did this (an MP4
through krkrz's MFPlayer; the workaround was `MADEIRA_WG_VIDEO=0`, which skips
the movie). RGB32 surfaces are ordinary DXMT surfaces. A source reader that
asks for NV12 still gets it from the YUV types listed after the native one.
`MADEIRA_WG_VIDEO_FORMAT=nv12` restores the old default. Each stream logs
`stream N: first picture delivered` (or `first audio buffer delivered`) once,
so a device log shows whether any sample was ever requested.

**One demuxer, several readers: back-pressure.** Each stream is read on its
own thread by quartz and Media Foundation; a packet read for another stream
is queued for it. A stream whose reader falls behind (a video decoded slower
than real time) used to lose packets once its queue passed 16,384 packets or
64 MB, which breaks every picture up to the next keyframe. Now, once a queue
passes 1,024 packets or 16 MB while another thread reads that stream, the
reader that demuxes for it waits (without the parser lock, which the other
reader needs) until the queue has drained to three quarters of that. A stream
that is not read for 5 s is marked unread and queued without waiting (dropped
past the old hard limits, as before) until it is read again; one thread
reading both streams (the WM reader's earliest-buffer mode) never waits for
itself; a seek, a disable or disconnect wakes a waiting reader.

The PE half of winegstreamer is upstream's and unchanged. Wine's configure
disables the module when GStreamer is missing, so a PE build tree has to be
configured with `--enable-winegstreamer` (`build/wine-pe/build-ntdll.sh` does
this for the arm64ec tree) and only the PE target is built. A 32-bit
(i386) build tree needs the same flag and must not skip `winegstreamer.dll`;
the 32-bit processes that use this unix side get their `winegstreamer.dll`
and `wmadmod.dll` from that tree.

## Switches

Environment variables (`env.NAME = value` in `madeira.cfg`):

| Variable | Default | Effect |
|---|---|---|
| `MADEIRA_WG_64BIT` | WMA only | `0`: 64-bit processes get the stub table again; `1`: their `wg_parser` too (see above). |
| `MADEIRA_WG_PARSER` | on | `0`: `wg_parser_create` returns `STATUS_NOT_IMPLEMENTED` again, as before this series; quartz and the MF source then fail the way they did. The WMA decoder is unaffected. |
| `MADEIRA_WG_VIDEO` | on | `0`: MP3/WAV only; an MP4/MOV or ASF is refused at connect. |
| `MADEIRA_WG_VIDEO_FORMAT` | `rgb32` | Native format a video stream reports: `nv12`, `i420`, `yv12`, `yuy2`, `rgb32`, `argb32` or `abgr32` (see above for why the default is `rgb32`). |
| `MADEIRA_WMA_SEARCH` | on | `0`: keep the WMA v1/v2 decoder at the bit rate and flags it opened with; no search over other candidates when a bit-reservoir stream fails. A packet that fails is concealed with silence of its length and the next one is decoded as usual. (An xWMA stream still opens at the rate libavformat's xWMA table normalises to.) |
| `MADEIRA_WMA_DUMP` | off | Set: write each WMA decoder's input to `wma-dump-<n>.bin` in the Documents folder, for reproducing a decode failure on a host. |

Log tags: `[wma]` for the decoder, `[wg-parser]` for the parser; both are
rate-limited per process (`MADEIRA_DIAG=1` lifts the `[wma]` cap).

## Tests

- `tests/host/check-wg-parser.py` (Linux): source checks on the call
  tables, wow64 thunks, kill switches, FFmpeg configuration and app link; then
  builds a host FFmpeg from the same tarball and runs the parser core under
  ASan/UBSan against MP3, MPEG layer II, WAV and synthetic MP4 (stub video and
  AAC backends); then, built with small queue limits, the back-pressure cases
  (a slow video reader loses nothing, while the same build without
  back-pressure drops pictures; an unread stream holds the other reader once;
  one thread reading both never waits; disconnect wakes a waiting reader).
- `tests/host/check-wg-parser-asf.py` (Linux): builds a host FFmpeg from the
  same tarball with the port's demuxers and decoders and test-only WMV/WMA
  encoders and the asf muxer, synthesises WMV7, WMV8 and MS-MPEG4 v3 files
  with WMA2 audio, and checks under ASan/UBSan, against an independent
  libavcodec decode of the same file: every picture bit-exact, in order; the
  WM reader's way (bottom-up BGR, S16, earliest-buffer reads) to the end; every
  format it offers after a keyframe seek; a WMV3 stream of garbage; and, with
  small queue limits, the back-pressure cases (a slow video reader loses
  nothing, while the same build without back-pressure drops pictures; an
  unread stream; one thread reading both; disconnect while a reader waits).
  WMV9/VC-1 streams themselves are not covered: FFmpeg cannot encode them.
- `tests/host/check-wma-decoder.py` (Linux or macOS, needs a configured
  Wine tree for the generated headers): compiles the production
  `winegstreamer_unixlib_ios.c` under ASan/UBSan against a host FFmpeg built
  from the tracked tarball, encodes WMA v1 and v2 streams (a 440 Hz tone) with
  FFmpeg's own encoders at several rates and channel counts, drives them
  through the `wg_transform` entries the way `wma_decoder.c` does, to s16 and
  to float, with the parameter search on and off, and requires audio with the
  right level and fundamental back. Also checks that 64-bit callers keep the
  stub table by default. Bit-reservoir (superframe) streams are not covered:
  FFmpeg cannot encode them.
- `tests/x86/wma-x86.c` (`build-wma-test.sh`): a 32-bit program that
  reaches the WMA decoder exactly as FAudio does and checks that the decoded
  PCM has the 440 Hz fundamental it was encoded from. Exit 62 pass, 63 decode
  failed, 64 class not registered, 65 watchdog.
