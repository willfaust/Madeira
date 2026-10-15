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
  resolver).

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
| `build/ntdll-unix/wg_parser_av_ios.c` | The `wg_parser` core, `#include`d by the file above: the PE read thread's pull protocol as an AVIOContext, libavformat demux (mp3, wav, mov), MPEG audio / PCM decode through libavcodec + libswresample, a packet queue, B-frame reordering, keyframe seek with exact trim, and conversion to the formats `quartz_parser.c` / `media_source.c` ask for. |
| `build/ntdll-unix/wg_parser_apple_ios.c` | H.264/HEVC on VideoToolbox (NV12 out) and AAC on an AudioToolbox AudioConverter (float PCM out). Its own translation unit with no Wine or FFmpeg header. |
| `build/ntdll-unix/wg_parser_backend_ios.h` | The contract between the core and a decoder backend; plain C types only, so the host test can supply stub backends. |
| `build/ffmpeg/build.sh` | FFmpeg 7.1.1, pinned by SHA-256, LGPL-only configuration. |

FFmpeg is built with no H.264, HEVC or AAC decoder or parser: those streams go
to the platform decoders. See `THIRD-PARTY-NOTICES.md` for the exact component
list and its licence.

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
| `MADEIRA_WG_VIDEO` | on | `0`: MP3/WAV only; an MP4/MOV is refused at connect. |
| `MADEIRA_WG_VIDEO_FORMAT` | `nv12` | Native format a video stream reports: `nv12`, `i420`, `yv12`, `yuy2`, `rgb32`, `argb32` or `abgr32`. |
| `MADEIRA_WMA_SEARCH` | on | `0`: keep the WMA v1/v2 decoder at the bit rate and flags it opened with; no search over other candidates when a bit-reservoir stream fails. A packet that fails is concealed with silence of its length and the next one is decoded as usual. (An xWMA stream still opens at the rate libavformat's xWMA table normalises to.) |
| `MADEIRA_WMA_DUMP` | off | Set: write each WMA decoder's input to `wma-dump-<n>.bin` in the Documents folder, for reproducing a decode failure on a host. |

Log tags: `[wma]` for the decoder, `[wg-parser]` for the parser; both are
rate-limited per process (`MADEIRA_DIAG=1` lifts the `[wma]` cap).

## Tests

- `tests/host/check-wg-parser.py` (Linux): source checks on the call
  tables, wow64 thunks, kill switches, FFmpeg configuration and app link; then
  builds a host FFmpeg from the same tarball and runs the parser core under
  ASan/UBSan against MP3, MPEG layer II, WAV and synthetic MP4 (stub video and
  AAC backends).
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
