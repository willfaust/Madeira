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
  `0x80040265`) and the game showed a white screen with no sound;
- the WMVideo Decoder DMO and MFT (`CLSID_CWMVDecMediaObject`, Wine's
  `wmv_decoder_create()` in `dlls/winegstreamer/video_decoder.c`), which a
  DirectShow graph or a Media Foundation pipeline uses to decode compressed
  Windows Media video. Sabbat of the Witch's `krmovie.dll` reads compressed
  WMV3 samples from `IWMSyncReader` and decodes them with it; without it the
  DMO could not even be created and the cutscenes were a white screen.

This port supplies that unix side in `libntdll_unix.a`, bound by name in
`load_builtin_unixlib()` (`build/ntdll-unix/virtual_ios.c`).

**32-bit (WoW64) and 64-bit (ARM64EC) processes both get it.** The ARM64EC
farm ships `winegstreamer.dll` and `wmadmod.dll`, so an x64 program's xWMA
voices (XAudio2/FAudio's WMA decoder DMO) decode instead of playing silence.
A 64-bit process gets the transforms only (the WMA and WMV decoders and the
resampler): its `wg_parser` (quartz / Media Foundation source) is refused as
before unless `MADEIRA_WG_64BIT=1`.
`MADEIRA_WG_64BIT=0` gives 64-bit processes the generic stub table again.

## Pieces

| File | What it is |
|---|---|
| `build/ntdll-unix/winegstreamer_unixlib_ios.c` | Both unix call tables (entry for entry with `dlls/winegstreamer/unixlib.h`), the wow64 thunks, and two kinds of `wg_transform` on libavcodec: the WMA decoder `wma_decoder.c` uses (WMA v1/v2/Pro/Lossless, XMA1/2) and the WMV decoder `video_decoder.c`'s WMVideo Decoder DMO/MFT uses (WMV1, WMV2, WMV3, WMVA, WVC1; see below). `transform_create` gives a create to the first kind that claims its input type; every other entry finds the kind by the magic its object starts with. Raw audio in is a third kind, the resampler `resampler.c` uses, on libswresample (see below). Other transforms (AAC, H.264, the colour converter) are refused at create, and `wg_muxer` returns `STATUS_NOT_IMPLEMENTED`. |
| `build/ntdll-unix/wg_parser_av_ios.c` | The `wg_parser` core, `#include`d by the file above: the PE read thread's pull protocol as an AVIOContext, libavformat demux (mp3, wav, mov, asf), MPEG audio / PCM / WMA decode through libavcodec + libswresample, Windows Media video (WMV7/8/9, VC-1, MS-MPEG4 v1-v3) decoded in software by libavcodec (`mav_lavc_video`), a packet queue with back-pressure, B-frame reordering, keyframe seek with exact trim, and conversion (`mav_convert_picture`, which the WMV transform uses too) to the formats `quartz_parser.c`, `media_source.c` and `wm_reader.c` ask for: NV12, I420, YV12, YUY2, UYVY, YVYU, BGRx, BGRA, RGBA, 24-bit BGR (the WM reader's default, bottom-up), RGB565 and RGB555. |
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

**Compressed samples from the WM reader.** An application can ask the WM
reader (`IWMSyncReader::SetReadStreamSamples`) for a stream's compressed
samples and decode them itself. KiriKiri's movie plugin (`krmovie.dll`) does
this for both streams of a WMV and feeds them to the WMV and WMA decoder DMOs
(Sabbat of the Witch's video CGs). The reader then opens a compressed-output
parser. This port's parser refused every compressed-output parser for an ASF,
and Wine's reader freed its streams when that reinit failed but kept their
count, so the next call wrote through a NULL array. Now:
- a compressed-output parser exposes an ASF's streams as the decoding one does
  (Wine's reader asserts the counts match);
- its WMA, WMV1/2/3, WMVA and WVC1 streams report their codec format as the
  current format and, enabled with it, hand out the demuxer's packets as they
  are: the file's bytes, keyframe flags (`delta`) and timestamps;
- after a seek the video starts at a keyframe;
- a stream enabled with a raw format in the same parser is decoded as usual
  (MS-MPEG4, which has no `wg_format`, always is);
- Wine's reader (in the wine submodule) chooses compressed or decoded per
  stream, keeps its streams when a reinit fails, goes back to the previous
  parser, and fails instead of asserting when the stream counts differ.

Each compressed stream logs `first compressed packet delivered` once.
`MADEIRA_WG_COMPRESSED=0` refuses compressed output for an ASF again.

**The WMV decoder (`wg_transform`).** `video_decoder.c` probes a WMV3
1920x1080 to I420 transform without codec private data when the DMO is
created (`check_video_transform_support`), and libavcodec cannot open `wmv3`
or `vc1` without it. So a create whose input type has no codec private data
succeeds with the decoder closed and logs `[decoder not open: ...]`; frames
pushed into such a transform are dropped and logged. A sequence header that
libavcodec refuses refuses the create. As in upstream's GStreamer
`wg_transform.c`, `push_data` only queues the compressed frame (at most
`input_queue_length` + 1, then `MF_E_NOTACCEPTING`) and `read_data` decodes
until a picture comes out. Nothing ready is `MF_E_TRANSFORM_NEED_MORE_INPUT`,
which the DMO turns into `S_FALSE`. A picture is never split, so
`WG_SAMPLE_FLAG_INCOMPLETE` (the DMO's `DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE`,
on which Wine's DMO wrapper calls `ProcessOutput` again) is never set. Output
formats: NV12, YV12, I420/IYUV, YUY2, UYVY, YVYU, RGB32, ARGB32, ABGR32,
RGB24, RGB565 and RGB555, top-down or bottom-up
(`MFVideoFlag_BottomUpLinearRep`). NV11 and RGB8 are refused, as GStreamer
refuses them. The frame is laid out as upstream's does it (4-byte aligned
rows, NV12 at 2), or at the stride of the caller's 2D buffer. An aperture
smaller than the frame is where the picture goes. A picture is not scaled: a
different size is cropped or padded with black, unless the caller allowed a
format change (`MF_E_TRANSFORM_STREAM_CHANGE`, then `get_output_type`; WMV
callers never allow it). Each picture is a sync point and keeps the time and
duration of the sample it was coded in, flagged
`WG_SAMPLE_FLAG_PRESERVE_TIMESTAMPS`, as `video_decoder.c` expects. A sample
without a time gets the previous picture's end (the first gets 0) and one
frame at the input type's frame rate. `set_output_type` keeps the decoder and
the pictures it holds, and writes them in the new format. Limits: WMV3 and
VC-1 are checked by codec-id plumbing only, because FFmpeg cannot encode
them. The DMO never drains, so a picture the decoder holds back (WMV3 with
B-frames) is lost at the end of a stream, as with GStreamer. When the DMO
wrapper meets a new output media type, `video_decoder.c` makes a new
transform, whose new decoder waits for a keyframe.

**The resampler.** Media Foundation's topology loader puts winegstreamer's
resampler (`CLSID_CResamplerMediaObject`, `wg_resampler`) between a source's
PCM and the audio renderer, which takes only the device mix format. Its
`wg_transform` was refused here ("input format tag 0x1 is not a WMA family
stream"), so `resampler_create` failed. For Senren Banka's WMV movie (48 kHz
S16 from the WMA stream) the topology then had no audio branch and no
presentation clock, and the video renderer never presented. The resampler is
now libswresample:
- integer PCM of 8, 16, 24 or 32 bits and float of 32 or 64, in and out;
- `WAVEFORMATEX` or `WAVEFORMATEXTENSIBLE`, any rate, 1 to 8 channels;
- timestamps run from the input's, less what the resampler holds back, and do
  not drift.

It logs one `[resampler] created ...` line per transform.
`MADEIRA_WG_RESAMPLER=0` refuses it again.

**One demuxer, several readers: back-pressure.** Quartz reads each stream on
its own thread (Media Foundation's source does not; see decode-ahead below); a
packet read for another stream is queued for it. A stream whose reader falls behind (a video decoded slower
than real time) used to lose packets once its queue passed 16,384 packets or
64 MB, which breaks every picture up to the next keyframe. Now, once a queue
passes 1,024 packets or 16 MB while another thread reads that stream, the
reader that demuxes for it waits (without the parser lock, which the other
reader needs) until the queue has drained to three quarters of that. A stream
that is not read for 5 s is marked unread and queued without waiting (dropped
past the old hard limits, as before) until it is read again; one thread
reading both streams (the WM reader's earliest-buffer mode) never waits for
itself; a seek, a disable or disconnect wakes a waiting reader.

**Decode-ahead.** Wine's media source asks for every stream's samples on one
work-queue thread (a standard work queue has one thread), and so does the WM
reader reading the earliest buffer. Decoded on demand, each picture held that
thread. Senren Banka's 1080p WMV needs about 20 ms a picture in software, so
the audio request behind it was late, and the audio renderer ran short for 6
to 17% of each 10 s (`[ios_audio] ... client wrote 8.33 s of audio in 10.01 s`).
GStreamer decodes in streaming threads of its own. Here each decoded video
stream gets a worker at its first request:
- it keeps up to three pictures ready, and a request pops one;
- it demuxes under the parser lock like any reader;
- it decodes and converts without that lock, so the audio request is
  answered meanwhile;
- a seek, a new format or a disconnect waits for the picture the worker is
  on, and it starts no new one until they are done.

Each such stream logs `decoding ahead on a thread of its own` once.
`MADEIRA_WG_VIDEO_AHEAD=0` decodes on the requesting thread again.

**The video renderer on DXMT.** A Media Foundation movie reaches the EVR
through Wine's sample copier and the EVR mixer, both on Direct3D 9 surfaces
that Wine's DXVA2 creates. Two of Wine's choices only worked on wined3d, which
is lenient where native d3d9 and DXMT are not. Both are fixed in the wine
submodule:
- **A black picture.** `CreateSurface` made every surface an offscreen plain
  surface. The mixer's targets are the size of the video window (Senren:
  1920x1080 into 2360x1328), and `StretchRect` does not stretch into a
  surface that is not a render target, so the mixer left only its black
  background. `DXVA2_VideoProcessorRenderTarget` surfaces are now lockable
  render targets, and a scaled blit is filtered (`D3DTEXF_LINEAR`).
- **A GPU wait per frame.** The copier's `ContiguousCopyFrom` locked its
  target without flags, so DXMT read the surface back first and waited for
  the GPU: 9 to 12 ms per frame (`[d9-drain] ... avg-us=9300`), on the
  session thread that also feeds the audio. It now locks with
  `D3DLOCK_DISCARD`, since it overwrites every byte.

The PE half of winegstreamer is upstream's but for `wm_reader.c` (above). Wine's configure
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
| `MADEIRA_WG_64BIT` | transforms only | `0`: 64-bit processes get the stub table again; `1`: their `wg_parser` too (see above). |
| `MADEIRA_WG_PARSER` | on | `0`: `wg_parser_create` returns `STATUS_NOT_IMPLEMENTED` again, as before this series; quartz and the MF source then fail the way they did. The WMA decoder is unaffected. |
| `MADEIRA_WG_VIDEO` | on | `0`: MP3/WAV only; an MP4/MOV or ASF is refused at connect. |
| `MADEIRA_WG_WMV_TRANSFORM` | on | `0`: every video `wg_transform` is refused at create again, so the WMVideo Decoder DMO/MFT cannot be created, as before. Read once per process. WMA is unaffected. |
| `MADEIRA_WG_RESAMPLER` | on | `0`: the resampler transform is refused at create, as before. |
| `MADEIRA_WG_COMPRESSED` | on | `0`: a compressed-output parser refuses an ASF, as before: the WM reader's compressed samples are not available (see above). |
| `MADEIRA_WG_VIDEO_AHEAD` | on | `0`: video is decoded on the thread that asks for it, as before; a Media Foundation movie's audio then waits behind each picture (see above). |
| `MADEIRA_WG_VIDEO_FORMAT` | `rgb32` | Native format a video stream reports: `nv12`, `i420`, `yv12`, `yuy2`, `rgb32`, `argb32` or `abgr32` (see above for why the default is `rgb32`). |
| `MADEIRA_WMA_SEARCH` | on | `0`: keep the WMA v1/v2 decoder at the bit rate and flags it opened with; no search over other candidates when a bit-reservoir stream fails. A packet that fails is concealed with silence of its length and the next one is decoded as usual. (An xWMA stream still opens at the rate libavformat's xWMA table normalises to.) |
| `MADEIRA_WMA_DUMP` | off | Set: write each WMA decoder's input to `wma-dump-<n>.bin` in the Documents folder, for reproducing a decode failure on a host. |

Log tags: `[wma]` for the WMA decoder, `[wmv]` for the WMV decoder (one line
per create and per destroy, refusals with their reason), `[resampler]` for the
resampler (one line per create), `[wg-parser]` for the parser. All are
rate-limited per process (`MADEIRA_DIAG=1` lifts the `[wma]`, `[wmv]` and
`[resampler]` caps).

## Tests

- `tests/host/check-wg-parser.py` (Linux): source checks on the call
  tables, wow64 thunks, kill switches, FFmpeg configuration and app link; then
  builds a host FFmpeg from the same tarball and runs the parser core under
  ASan/UBSan against MP3, MPEG layer II, WAV and synthetic MP4 (stub video and
  AAC backends), every picture format pixel by pixel; then, built with small
  queue limits, the back-pressure cases (a slow video reader loses nothing,
  while the same build without back-pressure drops pictures; an unread stream
  holds the other reader once; one thread reading both never waits; disconnect
  wakes a waiting reader). Decode-ahead: with a stub decoder that takes 20 ms
  a picture and one thread asking for both streams at 30 fps (the media
  source's way), a video request takes 0.0 ms instead of 21. Every picture
  still comes in order, the audio has no gaps, a seek lands exactly, and a
  disconnect mid-decode is clean. The threaded cases run again under
  ThreadSanitizer.
- `tests/host/check-wg-parser-asf.py` (Linux): builds a host FFmpeg from the
  same tarball with the port's demuxers and decoders and test-only WMV/WMA
  encoders and the asf muxer, synthesises WMV7, WMV8 and MS-MPEG4 v3 files
  with WMA2 audio, and checks under ASan/UBSan, against an independent
  libavcodec decode of the same file: every picture bit-exact, in order; the
  WM reader's way (bottom-up BGR, S16, earliest-buffer reads) to the end; every
  format it offers after a keyframe seek; a WMV3 stream of garbage; and, with
  small queue limits, the back-pressure cases (a slow video reader loses
  nothing, while the same build without back-pressure drops pictures; an
  unread stream; one thread reading both, and the worker decoding ahead for
  it; disconnect while a reader waits).
  Compressed output: every packet of WMV7, WMV8, the WMV3 garbage stream and
  WMA2 against an independent demux of the same file (bytes, keyframe flags,
  timestamps); compressed video with decoded audio; a seek starting at a
  keyframe; back to decoded pictures, bit-exact; MS-MPEG4 refused compressed;
  `MADEIRA_WG_COMPRESSED=0`. Also source checks on Wine's reader (per-stream
  compressed reading, no `free_streams` in a failed reinit). With video
  decoded ahead (the default), every case above runs again under
  ThreadSanitizer, the back-pressure ones included.
  WMV9/VC-1 streams themselves are not covered: FFmpeg cannot encode them.
- `tests/host/check-mf-video-render.py`: source checks on the path a Media
  Foundation movie takes to the screen:
  - DXMT's StretchRect rule the DXVA2 fix answers, and its discard lock;
  - Wine's DXVA2 render targets and filtered scaling;
  - mfplat's discard copy;
  - the allocators that ask for `DXVA2_VideoProcessorRenderTarget`;
  - the one-thread work queue that makes decode-ahead necessary.
- `tests/host/check-wma-decoder.py` (Linux or macOS, needs a configured
  Wine tree for the generated headers): compiles the production
  `winegstreamer_unixlib_ios.c` under ASan/UBSan against a host FFmpeg built
  from the tracked tarball, encodes WMA v1 and v2 streams (a 440 Hz tone) with
  FFmpeg's own encoders at several rates and channel counts, drives them
  through the `wg_transform` entries the way `wma_decoder.c` does, to s16 and
  to float, with the parameter search on and off, and requires audio with the
  right level and fundamental back. Also checks that 64-bit callers get the
  transforms by default and their parser only with `MADEIRA_WG_64BIT=1`. Bit-reservoir (superframe) streams are not covered:
  FFmpeg cannot encode them.
- `tests/host/check-wmv-transform.py` (Linux or macOS, needs a configured
  Wine tree): source checks on both call tables, the kind table, the switch,
  and the facts of the Wine pin the transform relies on. Then it compiles the
  production file under ASan/UBSan against the host FFmpeg build that
  `check-wg-parser-asf.py` uses, encodes WMV7 and WMV8 streams with FFmpeg's
  encoders, and drives them through both call tables. It checks: every
  picture bit-exact against libavcodec; every output format in both
  orientations at the default layout and at a 2D buffer's stride, pixel by
  pixel with the bytes around them untouched; apertures, cropping and
  padding; timestamps; the queue limit, drain, flush, mid-stream
  `set_output_type`, a format change, a buffer too small; Wine's DMO-wrapper
  loop; two threads; refusals; the wow64 thunks with 32-bit argument blocks
  below 4 GB; WMA through the same dispatcher; and
  `MADEIRA_WG_WMV_TRANSFORM=0`. WMV3/WVC1/WMVA are covered by codec-id
  plumbing only (the DMO's probe, hand-built sequence headers, garbage
  frames): FFmpeg cannot encode them.
- `tests/host/check-wg-resampler.py` (needs a configured Wine tree, like
  the WMA test): drives the resampler through the `wg_transform` entries under
  ASan/UBSan. It covers:
  - 48 kHz S16 stereo to 48 and 44.1 kHz float (Senren's case): the tone's
    frequency and level, the frame count, timestamps without gaps or drift;
  - all 36 pairs of u8/s16/s24/s32/f32/f64, with identity bit-exact;
  - 5.1 to stereo, mono to stereo, stereo to mono;
  - `check_audio_transform_support()`'s probe, back-pressure, flush, a new
    output type mid-stream, drain;
  - refusals and `MADEIRA_WG_RESAMPLER=0`.
- `tests/x86/wma-x86.c` (`build-wma-test.sh`): a 32-bit program that
  reaches the WMA decoder exactly as FAudio does and checks that the decoded
  PCM has the 440 Hz fundamental it was encoded from. Exit 62 pass, 63 decode
  failed, 64 class not registered, 65 watchdog.
