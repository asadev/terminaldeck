# Notices for the Windows link engine (tdlink.dll + libwebrtc.dll)

The Windows app's direct link (stream step 2) ships two native files:

- `tdlink.dll`: Terminal Deck's own C wrapper (`../tdlink.cpp`, MIT, as Terminal Deck).
- `libwebrtc.dll`: webrtc-sdk **libwebrtc.m150.7871.07** for Windows x64, downloaded at build time from
  <https://github.com/webrtc-sdk/libwebrtc/releases/tag/libwebrtc.m150.7871.07>
  (`libwebrtc-win-x64-release.zip`, SHA-256 `0cf141cd803af8f860080d94861d2d591ab9081a28f5cdead1b7c775ad5d3bf8`).
  It is Google's WebRTC M150 (webrtc-sdk/webrtc branch `m150_release`), the same engine as the Mac, iPhone and Android apps,
  with these components compiled in:

| Component | Licence | Text here |
|---|---|---|
| webrtc-sdk/libwebrtc C++ wrapper | MIT | `libwebrtc-wrapper.MIT.txt` |
| WebRTC (Google) | BSD-3-Clause + additional patent grant | `webrtc.LICENSE.txt`, `webrtc.PATENTS.txt` |
| BoringSSL | Apache-2.0 (older parts OpenSSL / ISC) | `boringssl.LICENSE.txt` |
| FFmpeg (Chromium build, LGPL configuration, no GPL parts) | LGPL-2.1-or-later | `ffmpeg.LICENSE.md`, `ffmpeg.COPYING.LGPLv2.1.txt` |
| OpenH264 | BSD-2-Clause | `openh264.LICENSE.txt` |
| libvpx | BSD-3-Clause + patent grant | `libvpx.LICENSE.txt`, `libvpx.PATENTS.txt` |
| libaom | BSD-2-Clause + AOMedia patent licence 1.0 | `libaom.LICENSE.txt`, `libaom.PATENTS.txt` |
| dav1d | BSD-2-Clause | `dav1d.COPYING.txt` |
| Opus | BSD-3-Clause | `opus.COPYING.txt` |
| Abseil | Apache-2.0 | `abseil.LICENSE.txt` |
| libjpeg-turbo | IJG, BSD-3-Clause, zlib | `libjpeg-turbo.LICENSE.md` |
| libyuv | BSD-3-Clause + patent grant | `libyuv.LICENSE.txt`, `libyuv.PATENTS.txt` |
| libsrtp | BSD-3-Clause | `libsrtp.LICENSE.txt` |
| crc32c | BSD-3-Clause | `crc32c.LICENSE.txt` |
| zlib (Chromium) | zlib | `zlib.LICENSE.txt` |

The texts were taken from the exact commits webrtc-sdk/webrtc `m150_release` pins in its `DEPS`.

FFmpeg (LGPL-2.1): it is linked into `libwebrtc.dll`, a separate library that can be replaced by any build of
webrtc-sdk/libwebrtc with the same interface. Its source is Chromium's FFmpeg at commit
`ad41607c61898cf7150e0fb20fe4bbabd44922a3` (<https://chromium.googlesource.com/chromium/third_party/ffmpeg>), and
the build recipe is webrtc-sdk/libwebrtc's own (<https://github.com/webrtc-sdk/libwebrtc>).

Terminal Deck uses only the library's data channels. The screen's H.264 is encoded by Windows' own Media Foundation
encoder, not by OpenH264 or FFmpeg.
