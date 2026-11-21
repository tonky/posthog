package pkgs

// Playwright's browser builds by Playwright version, recorded by
// scripts/playwright_browsers.py: per browser, the directory Playwright looks it up in under
// PLAYWRIGHT_BROWSERS_PATH and each platform's archive with its sha256. #PlaywrightBrowsers
// (pkgs/playwright_browsers.cue) builds a version's browsers into one store object.
_playwrightBuilds: {
	// BEGIN playwright 1.56.1
	"1.56.1": {
		"chromium-headless-shell": {
			dir: "chromium_headless_shell-1194"
			linuxNeeds: ["ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2", "libX11.so.6", "libXcomposite.so.1", "libXdamage.so.1", "libXext.so.6", "libXfixes.so.3", "libXrandr.so.2", "libasound.so.2", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0", "libatspi.so.0", "libc.so.6", "libdbus-1.so.3", "libdl.so.2", "libexpat.so.1", "libgbm.so.1", "libgcc_s.so.1", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libm.so.6", "libnspr4.so", "libnss3.so", "libnssutil3.so", "libpthread.so.0", "libudev.so.1", "libxcb.so.1", "libxkbcommon.so.0"]
			archives: {
				"aarch64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1194/chromium-headless-shell-mac-arm64.zip", sha256: "c4c97caab34c16f9a2bb411da0e68505deacb35c86d70db63dc117381a5e6d60"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1194/chromium-headless-shell-linux-arm64.zip", sha256: "6b963b7651119c81fa51312c1176429d3235bbefb56d5c687730cf44a5b1fdd7"}
				"x86_64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1194/chromium-headless-shell-mac.zip", sha256: "a84cf791a7c7d195c3fdfced9e28c591383522d396a15242602304587b825755"}
				"x86_64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1194/chromium-headless-shell-linux.zip", sha256: "d745c7210cc88b73c7991a22c9624819960d84bc3de77ac7336d2de841a8c91f"}
			}
		}
		"ffmpeg": {
			dir: "ffmpeg-1011"
			linuxNeeds: []
			archives: {
				"aarch64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-mac-arm64.zip", sha256: "7d77eb0d44b59acc4065faa2476c0df1a242cc904c346f820626818c953c5277"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-linux-arm64.zip", sha256: "2628c03f05318ff812c8c9baaf207dea2ddf53e818c0dc936714b0fbe3afb009"}
				"x86_64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-mac.zip", sha256: "17ed15a2fa60d3c74181befcb2bdf7c9bb288d19b2a3b9893b94b63f2ce260e4"}
				"x86_64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-linux.zip", sha256: "ebc74fc5b94830176a3c2914ae96bd8bc7f6a91f4f33890230f84a172ee61ccc"}
			}
		}
	}
	// END playwright 1.56.1
	// BEGIN playwright 1.60.0
	"1.60.0": {
		"chromium": {
			dir: "chromium-1223"
			linuxNeeds: ["ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2", "libX11.so.6", "libXcomposite.so.1", "libXdamage.so.1", "libXext.so.6", "libXfixes.so.3", "libXrandr.so.2", "libasound.so.2", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0", "libatspi.so.0", "libc.so.6", "libcairo.so.2", "libcups.so.2", "libdbus-1.so.3", "libdl.so.2", "libexpat.so.1", "libgbm.so.1", "libgcc_s.so.1", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libm.so.6", "libnspr4.so", "libnss3.so", "libnssutil3.so", "libpango-1.0.so.0", "libpthread.so.0", "libsmime3.so", "libudev.so.1", "libxcb.so.1", "libxkbcommon.so.0"]
			archives: {
				"aarch64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/148.0.7778.96/mac-arm64/chrome-mac-arm64.zip", sha256: "fbab7ac5c63f72771a7cd79ab15ed6f198b0f9567ec927c9cf5ece3b1f08ffb1"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1223/chromium-linux-arm64.zip", sha256: "3f7fd102f646dad864a987de04782e238e98a3d38543a1c8be0129b96706a283"}
				"x86_64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/148.0.7778.96/mac-x64/chrome-mac-x64.zip", sha256: "9d896b8c242652fe274b5ff7029853ac4b1471086ecfe48a675552783323108a"}
				"x86_64-linux": {url: "https://storage.googleapis.com/chrome-for-testing-public/148.0.7778.96/linux64/chrome-linux64.zip", sha256: "e58a0612f6156ad287ff392c681f6e1154d0c938feccf631d0c5d7abf3bbf81a"}
			}
		}
		"chromium-headless-shell": {
			dir: "chromium_headless_shell-1223"
			linuxNeeds: ["ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2", "libX11.so.6", "libXcomposite.so.1", "libXdamage.so.1", "libXext.so.6", "libXfixes.so.3", "libXrandr.so.2", "libasound.so.2", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0", "libatspi.so.0", "libc.so.6", "libdbus-1.so.3", "libdl.so.2", "libexpat.so.1", "libgbm.so.1", "libgcc_s.so.1", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libm.so.6", "libnspr4.so", "libnss3.so", "libnssutil3.so", "libpthread.so.0", "libudev.so.1", "libxcb.so.1", "libxkbcommon.so.0"]
			archives: {
				"aarch64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/148.0.7778.96/mac-arm64/chrome-headless-shell-mac-arm64.zip", sha256: "d9014195871a583b0978001a23000aa2cff22e3bb951a92919b7c7775cd14e01"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1223/chromium-headless-shell-linux-arm64.zip", sha256: "4578d731ef7f2f344ae1d79c0ae2664453fc0848ccaa726856a5e9d34aaa1a0e"}
				"x86_64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/148.0.7778.96/mac-x64/chrome-headless-shell-mac-x64.zip", sha256: "1dabfd7b4ecc5759d3fe90dd3e782ae41659f5dc7c756cf403db104e93c918f0"}
				"x86_64-linux": {url: "https://storage.googleapis.com/chrome-for-testing-public/148.0.7778.96/linux64/chrome-headless-shell-linux64.zip", sha256: "88817c574c1838a39f88fda0bbd043b4481fd385fb10e92c323e230844d636ce"}
			}
		}
		"ffmpeg": {
			dir: "ffmpeg-1011"
			linuxNeeds: []
			archives: {
				"aarch64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-mac-arm64.zip", sha256: "7d77eb0d44b59acc4065faa2476c0df1a242cc904c346f820626818c953c5277"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-linux-arm64.zip", sha256: "2628c03f05318ff812c8c9baaf207dea2ddf53e818c0dc936714b0fbe3afb009"}
				"x86_64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-mac.zip", sha256: "17ed15a2fa60d3c74181befcb2bdf7c9bb288d19b2a3b9893b94b63f2ce260e4"}
				"x86_64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-linux.zip", sha256: "ebc74fc5b94830176a3c2914ae96bd8bc7f6a91f4f33890230f84a172ee61ccc"}
			}
		}
		"webkit": {
			dir: "webkit-2287"
			linuxNeeds: ["ld-linux-x86-64.so.2", "libX11.so.6", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0", "libatomic.so.1", "libavif.so.16", "libc.so.6", "libcairo-gobject.so.2", "libcairo.so.2", "libdrm.so.2", "libenchant-2.so.2", "libepoxy.so.0", "libevent-2.1.so.7", "libexpat.so.1", "libflite.so.1", "libflite_cmu_grapheme_lang.so.1", "libflite_cmu_grapheme_lex.so.1", "libflite_cmu_indic_lang.so.1", "libflite_cmu_indic_lex.so.1", "libflite_cmu_time_awb.so.1", "libflite_cmu_us_awb.so.1", "libflite_cmu_us_kal.so.1", "libflite_cmu_us_kal16.so.1", "libflite_cmu_us_rms.so.1", "libflite_cmu_us_slt.so.1", "libflite_cmulex.so.1", "libflite_usenglish.so.1", "libfontconfig.so.1", "libfreetype.so.6", "libgbm.so.1", "libgcc_s.so.1", "libgcrypt.so.20", "libgdk_pixbuf-2.0.so.0", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgmodule-2.0.so.0", "libgobject-2.0.so.0", "libgpg-error.so.0", "libgraphene-1.0.so.0", "libgstallocators-1.0.so.0", "libgstapp-1.0.so.0", "libgstaudio-1.0.so.0", "libgstbase-1.0.so.0", "libgstcodecparsers-1.0.so.0", "libgstfft-1.0.so.0", "libgstgl-1.0.so.0", "libgstpbutils-1.0.so.0", "libgstreamer-1.0.so.0", "libgsttag-1.0.so.0", "libgstvideo-1.0.so.0", "libgtk-4.so.1", "libharfbuzz-icu.so.0", "libharfbuzz.so.0", "libhyphen.so.0", "libicudata.so.74", "libicui18n.so.74", "libicuuc.so.74", "libjpeg.so.8", "liblcms2.so.2", "libm.so.6", "libmanette-0.2.so.0", "libnghttp2.so.14", "libopus.so.0", "libpango-1.0.so.0", "libpangocairo-1.0.so.0", "libpng16.so.16", "libpsl.so.5", "libsecret-1.so.0", "libsqlite3.so.0", "libstdc++.so.6", "libsystemd.so.0", "libtasn1.so.6", "libvulkan.so.1", "libwayland-client.so.0", "libwayland-egl.so.1", "libwayland-server.so.0", "libwebp.so.7", "libwebpdemux.so.2", "libwebpmux.so.3", "libwoff2dec.so.1.0.2", "libxkbcommon.so.0", "libxml2.so.2", "libxslt.so.1", "libz.so.1"]
			archives: {
				"aarch64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/webkit/2287/webkit-mac-15-arm64.zip", sha256: "b6350511228b377a5be1fd8d0730eeb2897d56adabee58c325332ca41eb450c6"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/webkit/2287/webkit-ubuntu-24.04-arm64.zip", sha256: "29f12c5e6af7f8859390391294ad6c7fc718f48c6610988bbe7672ee1b8b40dd"}
				"x86_64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/webkit/2287/webkit-mac-15.zip", sha256: "259099ed7ad20d4e9fd532451489d1e879b0c82c693bc986512e998c5474db84"}
				"x86_64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/webkit/2287/webkit-ubuntu-24.04.zip", sha256: "2c407e6568314076512139d77f7805dc0f65e724ce18a920702e9cf228f0f6a1"}
			}
		}
	}
	// END playwright 1.60.0
	// BEGIN playwright 1.62.1
	"1.62.1": {
		"chromium": {
			dir: "chromium-1234"
			linuxNeeds: ["ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2", "libX11.so.6", "libXcomposite.so.1", "libXdamage.so.1", "libXext.so.6", "libXfixes.so.3", "libXrandr.so.2", "libasound.so.2", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0", "libatspi.so.0", "libc.so.6", "libcairo.so.2", "libcups.so.2", "libdbus-1.so.3", "libdl.so.2", "libexpat.so.1", "libgbm.so.1", "libgcc_s.so.1", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libm.so.6", "libnspr4.so", "libnss3.so", "libnssutil3.so", "libpango-1.0.so.0", "libpthread.so.0", "libsmime3.so", "libudev.so.1", "libxcb.so.1", "libxkbcommon.so.0"]
			archives: {
				"aarch64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.34/mac-arm64/chrome-mac-arm64.zip", sha256: "01a23ef9501b2745e0c2944c2e583207e6f6132d8d91c3a87ff65b5079e438ef"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1234/chromium-linux-arm64.zip", sha256: "b5ad7d8fe70f230b34198ddb5626d717c016db2f627cb44b922babbcaf3479b9"}
				"x86_64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.34/mac-x64/chrome-mac-x64.zip", sha256: "69bcc853db975a2380767e9ff36da17f1d7b782fbbe191a210f676d2d5967d3e"}
				"x86_64-linux": {url: "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.34/linux64/chrome-linux64.zip", sha256: "ae8736ac28bc69278551500f219fc749575648263c43ec5990749eff43b9fcf8"}
			}
		}
		"chromium-headless-shell": {
			dir: "chromium_headless_shell-1234"
			linuxNeeds: ["ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2", "libX11.so.6", "libXcomposite.so.1", "libXdamage.so.1", "libXext.so.6", "libXfixes.so.3", "libXrandr.so.2", "libasound.so.2", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0", "libatspi.so.0", "libc.so.6", "libdbus-1.so.3", "libdl.so.2", "libexpat.so.1", "libgbm.so.1", "libgcc_s.so.1", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libm.so.6", "libnspr4.so", "libnss3.so", "libnssutil3.so", "libpthread.so.0", "libudev.so.1", "libxcb.so.1", "libxkbcommon.so.0"]
			archives: {
				"aarch64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.34/mac-arm64/chrome-headless-shell-mac-arm64.zip", sha256: "cb46a336dbe3d6f1339c5039c3083e4e5dd8e4379710790e34f8f4a865e2452d"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1234/chromium-headless-shell-linux-arm64.zip", sha256: "b03443e1e1a60d06e07b6cdfe650b8c2bfcbb3db497d2b652f73dc6912f4ae15"}
				"x86_64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.34/mac-x64/chrome-headless-shell-mac-x64.zip", sha256: "608e2b5b1815b45e8bf59c9a381412b62df3ce36f2c182bc04e22fcf04ad53ea"}
				"x86_64-linux": {url: "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.34/linux64/chrome-headless-shell-linux64.zip", sha256: "3cfc2bd00d1bafcf8a68dc74c9c92bb7150ddc8d26ade948a776316e1cec4f14"}
			}
		}
		"ffmpeg": {
			dir: "ffmpeg-1011"
			linuxNeeds: []
			archives: {
				"aarch64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-mac-arm64.zip", sha256: "7d77eb0d44b59acc4065faa2476c0df1a242cc904c346f820626818c953c5277"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-linux-arm64.zip", sha256: "2628c03f05318ff812c8c9baaf207dea2ddf53e818c0dc936714b0fbe3afb009"}
				"x86_64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-mac.zip", sha256: "17ed15a2fa60d3c74181befcb2bdf7c9bb288d19b2a3b9893b94b63f2ce260e4"}
				"x86_64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1011/ffmpeg-linux.zip", sha256: "ebc74fc5b94830176a3c2914ae96bd8bc7f6a91f4f33890230f84a172ee61ccc"}
			}
		}
		"firefox": {
			dir: "firefox-1538"
			linuxNeeds: ["ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2", "libX11-xcb.so.1", "libX11.so.6", "libXcomposite.so.1", "libXcursor.so.1", "libXdamage.so.1", "libXext.so.6", "libXfixes.so.3", "libXi.so.6", "libXrandr.so.2", "libXrender.so.1", "libasound.so.2", "libatk-1.0.so.0", "libc.so.6", "libcairo-gobject.so.2", "libcairo.so.2", "libdbus-1.so.3", "libdl.so.2", "libfontconfig.so.1", "libfreetype.so.6", "libgcc_s.so.1", "libgdk-3.so.0", "libgdk_pixbuf-2.0.so.0", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libgtk-3.so.0", "libm.so.6", "libpango-1.0.so.0", "libpangocairo-1.0.so.0", "libpthread.so.0", "libresolv.so.2", "librt.so.1", "libstdc++.so.6", "libxcb-shm.so.0", "libxcb.so.1"]
			archives: {
				"aarch64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/firefox/1538/firefox-mac-arm64.zip", sha256: "b7b8e068fb1776dee8abfeb649ad6313f9ec8f6bbaa333d8dc00d013cc389256"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/firefox/1538/firefox-ubuntu-24.04-arm64.zip", sha256: "ec0600a40bd8f8ba221bd8e952aeaefb23aa06b5a239891c0e71c602109da30e"}
				"x86_64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/firefox/1538/firefox-mac.zip", sha256: "984f0350062d2fcc7ac9e7736ad3ef2d8c15db33ee8fe3d19c57f26e24f9a766"}
				"x86_64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/firefox/1538/firefox-ubuntu-24.04.zip", sha256: "49208d3ed74e525575eca41d053082902b88933e31943a091d25080bdfcfcb25"}
			}
		}
	}
	// END playwright 1.62.1
	// BEGIN playwright 1.64.1
	"1.64.1": {
		"chromium-headless-shell": {
			dir: "chromium_headless_shell-1248"
			linuxNeeds: ["ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2", "libX11.so.6", "libXcomposite.so.1", "libXdamage.so.1", "libXext.so.6", "libXfixes.so.3", "libXrandr.so.2", "libasound.so.2", "libatk-1.0.so.0", "libatk-bridge-2.0.so.0", "libatspi.so.0", "libc.so.6", "libdbus-1.so.3", "libdl.so.2", "libexpat.so.1", "libgbm.so.1", "libgcc_s.so.1", "libgio-2.0.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libm.so.6", "libnspr4.so", "libnss3.so", "libnssutil3.so", "libpthread.so.0", "libudev.so.1", "libxcb.so.1", "libxkbcommon.so.0"]
			archives: {
				"aarch64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.4/mac-arm64/chrome-headless-shell-mac-arm64.zip", sha256: "94e4337b70cbc5638f0935fbc46b9f242bc7416f657e3fbe924baf348404b53d"}
				"aarch64-linux": {url: "https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.4/linux-arm64/chrome-headless-shell-linux-arm64.zip", sha256: "81ab9d4d3c301dc5fdfb6c541b9e6632b16fc819a6a854460f40a76fe2b2c476"}
				"x86_64-darwin": {url: "https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.4/mac-x64/chrome-headless-shell-mac-x64.zip", sha256: "8a9e4a32ba5b1a796f8b16d01896e355cf6662544d9743296394fd999d782331"}
				"x86_64-linux": {url: "https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.4/linux64/chrome-headless-shell-linux64.zip", sha256: "c3e50596aef52c58f8fda3c6b3411c33d34c88b177b3ed1c2243359fd3b8ba20"}
			}
		}
		"ffmpeg": {
			dir: "ffmpeg-1013"
			linuxNeeds: []
			archives: {
				"aarch64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1013/ffmpeg-mac-arm64.zip", sha256: "63e48ce8d4a6d9d496383e5ac557b26466e719fa29126bbbd5f5f7016ac9229c"}
				"aarch64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1013/ffmpeg-linux-arm64.zip", sha256: "457360e803a7d8d5f8f7f5ecf562b2d338f6b4f7f86339d0c31938a451e8878b"}
				"x86_64-darwin": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1013/ffmpeg-mac.zip", sha256: "ffdf08ab13def2b63e81ed9782e39debc5bd498220e8e134f9a36e984db6d9db"}
				"x86_64-linux": {url: "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/1013/ffmpeg-linux.zip", sha256: "ee986434d158f74fb5d9c5ff1092026ceedb63f324fe90b5be89460926b7b679"}
			}
		}
	}
	// END playwright 1.64.1
}
