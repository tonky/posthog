package pkgs

import (
	"strings"
	"github.com/tonky/enve/schema/v1:schema"
)

// Playwright's own browser builds for one Playwright version, as one store object laid out
// the way `playwright install` lays out its cache, exported as PLAYWRIGHT_BROWSERS_PATH:
//
//	tools: [pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["chromium-headless-shell", "ffmpeg"]}]
//
// `version` is the project's Playwright version (its lockfile's playwright-core): Playwright
// looks a browser up by the revision its own browsers.json names, so the two must match.
// `features` names the browsers (Playwright's names). Each archive is a fixed-output fetch
// checked against the sha256 recorded in pkgs/playwright.cue. On Linux the builds expect a
// distribution's shared libraries: auto-patchelf points their interpreter and RPATH at the
// snapshot's libraries instead, so nothing comes from the host. Which libraries is read from the
// archives themselves (`linuxNeeds`, recorded with the hashes). Playwright's host-library check
// is skipped: the build already proved every library resolves. Pages render with the fonts the
// object carries: FONTCONFIG_FILE names its own fontconfig file (_playwrightFonts).
#PlaywrightBrowsers: schema.#PackageSpec & {
	// A version pkgs/playwright.cue records; indexing the table with any other fails.
	version: string
	features: [...string]
	pname: "playwright-browsers"

	let builds = _playwrightBuilds[version]
	fetch: {
		for browser in features {
			(_playwrightVar[browser]): {
				url: {for system, archive in builds[browser].archives {(system): archive.url}}
				sha256: {for system, archive in builds[browser].archives {(system): archive.sha256}}
			}
		}
	}
	// The packages providing what the browsers' Linux builds link (their recorded `linuxNeeds`),
	// as a set so browsers sharing a library list it once. A soname _playwrightLibraries doesn't
	// map fails evaluation here, before any download.
	let linux = {
		for name in _playwrightLinuxTools {(name): true}
		for browser in features for soname in builds[browser].linuxNeeds {(_playwrightLibraries[soname]): true}

		// WebKit draws through EGL, which libglvnd dispatches to a vendor it loads at run time:
		// Mesa's, software-rendered where the machine has no GPU (_playwrightWebkitRuntime).
		// Its media backend (GStreamer) also dlopens `autoaudiosink` from gst-plugins-good on
		// `<video>`/`<audio>` elements; without it WPEWebProcess crashes on a NULL sink pointer.
		for browser in features if browser == "webkit" {
			"mesa":             true
			"gst-plugins-good": true
		}
	}
	buildInputs: [
		{pname: "unzip"},
		for name, _ in linux {
			pname: name
			if _playwrightAttrs[name] != _|_ {attr: _playwrightAttrs[name]}
			platforms: [schema.#Platform.Linux]
		},
	]
	let unpack = strings.Join([
		for browser in features {"unzip -q \"$\(_playwrightVar[browser])\" -d \"$out/\(builds[browser].dir)\"\ntouch \"$out/\(builds[browser].dir)/INSTALLATION_COMPLETE\""},
	], "\n")
	let patch = [for browser in features if browser == "firefox" {_playwrightPatchFirefox}, _playwrightPatch][0]
	let runtime = [for browser in features if browser == "webkit" {_playwrightWebkitRuntime}, ""][0]
	installPhase: """
		set -eu
		\(unpack)
		\(patch)
		\(runtime)
		\(_playwrightFonts)
		"""
	exports: {
		PLAYWRIGHT_BROWSERS_PATH:                   "$out"
		PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS: "1"
		FONTCONFIG_FILE:                            "$out/fonts.conf"
	}
}

_playwrightVar: {
	"chromium":                "playwright_chromium"
	"chromium-headless-shell": "playwright_chromium_headless_shell"
	"firefox":                 "playwright_firefox"
	"webkit":                  "playwright_webkit"
	"ffmpeg":                  "playwright_ffmpeg"
}

// Build tools, and the fonts the Linux browsers render with (_playwrightFonts).
_playwrightLinuxTools: ["auto-patchelf", "patchelf", "dejavu_fonts", "liberation_ttf", "noto-fonts-color-emoji"]

// The nixpkgs package providing each library a recorded Linux build links (its `linuxNeeds`:
// the DT_NEEDED sonames no file of its own archive provides).
_playwrightLibraries: {
	for soname in ["libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "libresolv.so.2", "ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2"] {(soname): "glibc"}
	"libgcc_s.so.1":          "gcc-unwrapped"
	"libstdc++.so.6":         "gcc-unwrapped"
	"libasound.so.2":         "alsa-lib"
	"libatk-1.0.so.0":        "at-spi2-core"
	"libatk-bridge-2.0.so.0": "at-spi2-core"
	"libatspi.so.0":          "at-spi2-core"
	"libcairo.so.2":          "cairo"
	"libcairo-gobject.so.2":  "cairo"
	"libcups.so.2":           "cups"
	"libdbus-1.so.3":         "dbus"
	"libexpat.so.1":          "expat"
	"libfontconfig.so.1":     "fontconfig"
	"libfreetype.so.6":       "freetype"
	"libgbm.so.1":            "libgbm"
	"libgdk-3.so.0":          "gtk3"
	"libgtk-3.so.0":          "gtk3"
	"libgdk_pixbuf-2.0.so.0": "gdk-pixbuf"
	"libgio-2.0.so.0":        "glib"
	"libglib-2.0.so.0":       "glib"
	"libgobject-2.0.so.0":    "glib"
	"libnspr4.so":            "nspr"
	"libnss3.so":             "nss"
	"libnssutil3.so":         "nss"
	"libsmime3.so":           "nss"
	"libpango-1.0.so.0":      "pango"
	"libpangocairo-1.0.so.0": "pango"
	"libudev.so.1":           "udev"
	"libX11.so.6":            "libx11"
	"libX11-xcb.so.1":        "libx11"
	"libxcb.so.1":            "libxcb"
	"libxcb-shm.so.0":        "libxcb"
	"libXcomposite.so.1":     "libxcomposite"
	"libXcursor.so.1":        "libxcursor"
	"libXdamage.so.1":        "libxdamage"
	"libXext.so.6":           "libxext"
	"libXfixes.so.3":         "libxfixes"
	"libXi.so.6":             "libxi"
	"libxkbcommon.so.0":      "libxkbcommon"
	"libXrandr.so.2":         "libxrandr"
	"libXrender.so.1":        "libxrender"
	// WebKit's builds (Ubuntu 24.04's libraries).
	"libatomic.so.1":         "gcc-unwrapped"
	"libavif.so.16":          "libavif"
	"libdrm.so.2":            "libdrm"
	"libenchant-2.so.2":      "enchant"
	"libepoxy.so.0":          "libepoxy"
	"libevent-2.1.so.7":      "libevent"
	"libgcrypt.so.20":        "libgcrypt"
	"libgmodule-2.0.so.0":    "glib"
	"libgpg-error.so.0":      "libgpg-error"
	"libgraphene-1.0.so.0":   "graphene"
	"libgtk-4.so.1":          "gtk4"
	"libharfbuzz.so.0":       "harfbuzzFull"
	"libharfbuzz-icu.so.0":   "harfbuzzFull"
	"libhyphen.so.0":         "hyphen"
	"liblcms2.so.2":          "lcms2"
	"libmanette-0.2.so.0":    "libmanette"
	"libnghttp2.so.14":       "nghttp2"
	"libopus.so.0":           "libopus"
	"libpng16.so.16":         "libpng"
	"libpsl.so.5":            "libpsl"
	"libsecret-1.so.0":       "libsecret"
	"libsqlite3.so.0":        "sqlite"
	"libsystemd.so.0":        "udev"
	"libtasn1.so.6":          "libtasn1"
	"libvulkan.so.1":         "vulkan-loader"
	"libwayland-client.so.0": "wayland"
	"libwayland-egl.so.1":    "wayland"
	"libwayland-server.so.0": "wayland"
	"libwebp.so.7":           "libwebp"
	"libwebpdemux.so.2":      "libwebp"
	"libwebpmux.so.3":        "libwebp"
	"libwoff2dec.so.1.0.2":   "woff2"
	"libxslt.so.1":           "libxslt"
	"libz.so.1":              "zlib"
	for soname in ["libflite.so.1", "libflite_cmu_grapheme_lang.so.1", "libflite_cmu_grapheme_lex.so.1", "libflite_cmu_indic_lang.so.1", "libflite_cmu_indic_lex.so.1", "libflite_cmu_time_awb.so.1", "libflite_cmu_us_awb.so.1", "libflite_cmu_us_kal.so.1", "libflite_cmu_us_kal16.so.1", "libflite_cmu_us_rms.so.1", "libflite_cmu_us_slt.so.1", "libflite_cmulex.so.1", "libflite_usenglish.so.1"] {(soname): "flite"}
	for soname in ["libgstreamer-1.0.so.0", "libgstbase-1.0.so.0"] {(soname): "gstreamer"}
	for soname in ["libgstallocators-1.0.so.0", "libgstapp-1.0.so.0", "libgstaudio-1.0.so.0", "libgstfft-1.0.so.0", "libgstgl-1.0.so.0", "libgstpbutils-1.0.so.0", "libgsttag-1.0.so.0", "libgstvideo-1.0.so.0"] {(soname): "gst-plugins-base"}
	"libgstcodecparsers-1.0.so.0": "gst-plugins-bad"
	// Version-pinned sonames the snapshot's current package moved past: its older attribute
	// that still ships Ubuntu 24.04's soname (icu 78 ships .so.78, libxml2 2.15 .so.16,
	// libjpeg-turbo's default build libjpeg.so.62). ICU and libjpeg-turbo version their
	// symbols, so the snapshot's own copies loaded beside them (harfbuzzFull's ICU, GTK's
	// libjpeg.so.62) bind apart.
	for soname in ["libicudata.so.74", "libicui18n.so.74", "libicuuc.so.74"] {(soname): "icu74"}
	"libjpeg.so.8": "libjpeg8"
	"libxml2.so.2": "libxml2_13"
}

// The nixpkgs attribute of a _playwrightLibraries package that is not a top-level attribute.
_playwrightAttrs: {
	"gstreamer":        "gst_all_1.gstreamer"
	"gst-plugins-base": "gst_all_1.gst-plugins-base"
	"gst-plugins-good": "gst_all_1.gst-plugins-good"
	"gst-plugins-bad":  "gst_all_1.gst-plugins-bad"
}

// Linux: every ELF in the output gets the snapshot's interpreter and an RPATH over the build
// inputs' library directories; a library no input provides fails the build here. Each browser
// is patched on its own, so one never resolves a library to another's bundled copy (Firefox
// ships its own NSS; Chromium links nixpkgs'). auto-patchelf writes the absolute directory it
// found each library in, so two spellings are put right after it: a directory of the output
// itself (the build's staging dir, gone once the object is published) becomes $ORIGIN-relative,
// and where /nix/store is a link to enve's store, that machine's store root goes back to
// /nix/store, so the object is the same on every machine.
//
// Firefox's x86_64-linux libraries pack relative relocations with Mozilla's relrhack
// (DT_MOZ_RELR = 0x08000024): their DT_INIT stub reads the original .dynamic address via a
// PC-relative offset before DT_INIT_ARRAY runs. When patchelf grows RUNPATH, it moves .dynamic
// to a new segment and overwrites the original .dynamic bytes in place with 'X', so DT_INIT
// sees no DT_MOZ_RELR and leaves DT_INIT_ARRAY unrelocated (SIGSEGV). Save each DT_MOZ_RELR
// .dynamic slice before auto-patchelf and write it back to its original offset if patchelf
// wiped it.
_playwrightPatch: """
	if [ "$(uname -s)" = Linux ]; then
		for browser in "$out"/*/; do
			auto-patchelf --paths "$browser" --libs $(printf '%s' "$LIBRARY_PATH" | tr ':' ' ')
		done
		root=$(cd /nix/store && pwd -P)
		outreal=$(cd "$out" && pwd -P)
		# The path from directory $1 to directory $2, both inside $out.
		relative() {
			local from=$1 up=
			while [ "${2#"$from"/}" = "$2" ] && [ "$2" != "$from" ]; do from=${from%/*}; up="$up../"; done
			local rest=${2#"$from"}
			rest="$up${rest#/}"
			printf '%s' "${rest%/}"
		}
		shopt -s globstar
		for elf in "$out"/**; do
			[ -f "$elf" ] && [ ! -L "$elf" ] || continue
			interp=$(patchelf --print-interpreter "$elf" 2>/dev/null) || interp=
			case "$interp" in "$root"/*) patchelf --set-interpreter "/nix/store/${interp#"$root"/}" "$elf" ;; esac
			rpath=$(patchelf --print-rpath "$elf" 2>/dev/null) || continue
			fixed=
			for entry in ${rpath//:/ }; do
				case "$entry" in "$outreal" | "$outreal"/*) entry="$out${entry#"$outreal"}" ;; esac
				case "$entry" in
				"$out" | "$out"/*)
					rel=$(relative "${elf%/*}" "$entry")
					entry='$ORIGIN'${rel:+/$rel}
					;;
				"$root"/*) entry="/nix/store/${entry#"$root"/}" ;;
				esac
				fixed=${fixed:+$fixed:}$entry
			done
			[ "$fixed" = "$rpath" ] || patchelf --set-rpath "$fixed" "$elf"
		done
	fi
	"""

_playwrightPatchFirefox: """
	if [ "$(uname -s)" = Linux ]; then
		IFS= read -r python < "$(command -v auto-patchelf)"
		python=${python#*!}
		moz_relr=$("$python" - "$out" <<-'EOF'
			import pathlib, struct, sys
			for p in pathlib.Path(sys.argv[1]).rglob("*"):
			    if not p.is_file() or p.is_symlink(): continue
			    b = p.read_bytes()
			    if b[:6] != b"\\x7fELF\\x02\\x01": continue
			    phoff, _, _, phent, phnum = struct.unpack_from("<QQIHH", b, 32)
			    for i in range(phnum):
			        ptype, _, off, _, _, filesz = struct.unpack_from("<IIQQQQ", b, phoff + i * phent)
			        if ptype == 2 and b"\\x24\\x00\\x00\\x08\\x00\\x00\\x00\\x00" in b[off:off + filesz]:
			            print(f"{off}\\t{b[off:off + filesz].hex()}\\t{p}")
			EOF
		)
		for browser in "$out"/*/; do
			auto-patchelf --paths "$browser" --libs $(printf '%s' "$LIBRARY_PATH" | tr ':' ' ')
		done
		root=$(cd /nix/store && pwd -P)
		outreal=$(cd "$out" && pwd -P)
		# The path from directory $1 to directory $2, both inside $out.
		relative() {
			local from=$1 up=
			while [ "${2#"$from"/}" = "$2" ] && [ "$2" != "$from" ]; do from=${from%/*}; up="$up../"; done
			local rest=${2#"$from"}
			rest="$up${rest#/}"
			printf '%s' "${rest%/}"
		}
		for elf in "$out"/*/* "$out"/*/*/* "$out"/*/*/*/* "$out"/*/*/*/*/*; do
			[ -f "$elf" ] && [ ! -L "$elf" ] || continue
			interp=$(patchelf --print-interpreter "$elf" 2>/dev/null) || interp=
			case "$interp" in "$root"/*) patchelf --set-interpreter "/nix/store/${interp#"$root"/}" "$elf" ;; esac
			rpath=$(patchelf --print-rpath "$elf" 2>/dev/null) || continue
			fixed=
			for entry in ${rpath//:/ }; do
				case "$entry" in "$outreal" | "$outreal"/*) entry="$out${entry#"$outreal"}" ;; esac
				case "$entry" in
				"$out" | "$out"/*)
					rel=$(relative "${elf%/*}" "$entry")
					entry='$ORIGIN'${rel:+/$rel}
					;;
				"$root"/*) entry="/nix/store/${entry#"$root"/}" ;;
				esac
				fixed=${fixed:+$fixed:}$entry
			done
			[ "$fixed" = "$rpath" ] || patchelf --set-rpath "$fixed" "$elf"
		done
		[ -z "$moz_relr" ] || "$python" - "$moz_relr" <<-'EOF'
			import sys
			for line in sys.argv[1].splitlines():
			    off, raw, path = line.split("\\t", 2)
			    with open(path, "r+b") as f:
			        f.seek(int(off))
			        if f.read(8) == b"XXXXXXXX":
			            f.seek(int(off))
			            f.write(bytes.fromhex(raw))
			EOF
	fi
	"""

// WebKit's Linux MiniBrowser wrappers (minibrowser-wpe, Playwright's headless one, and
// minibrowser-gtk) set its library and helper paths and run the browser. What it loads at run
// time the snapshot's packages find in their own default places, but two lookups default to the
// host: libglvnd's EGL vendors (/run/opengl-driver, /usr/share/glvnd; with none WPE aborts
// "Could not create WPE EGL display") and GStreamer's plugins (only gstreamer's own dir). Each
// wrapper names the inputs' instead: Mesa's EGL vendor, and every input's GStreamer plugin dir.
_playwrightWebkitRuntime: """
	if [ "$(uname -s)" = Linux ]; then
		root=$(cd /nix/store && pwd -P)
		# Directory $1 as a /nix/store path.
		store() {
			local dir
			dir=$(cd "$1" && pwd -P)
			case "$dir" in "$root"/*) dir="/nix/store/${dir#"$root"/}" ;; esac
			printf '%s' "$dir"
		}
		egl= gst=
		for lib in $(printf '%s' "$LIBRARY_PATH" | tr ':' ' '); do
			if [ -z "$egl" ] && [ -f "$lib/../share/glvnd/egl_vendor.d/50_mesa.json" ]; then
				egl="$(store "$lib/../share/glvnd/egl_vendor.d")/50_mesa.json"
			fi
			[ -d "$lib/gstreamer-1.0" ] || continue
			dir=$(store "$lib/gstreamer-1.0")
			case ":$gst:" in *":$dir:"*) ;; *) gst=${gst:+$gst:}$dir ;; esac
		done
		[ -n "$egl" ] || { echo "webkit: no input carries Mesa's EGL vendor (50_mesa.json)" >&2; exit 1; }
		for wrapper in "$out"/webkit-*/minibrowser-*/MiniBrowser; do
			[ -f "$wrapper" ] || continue
			{
				IFS= read -r shebang
				printf '%s
	' "$shebang" "export __EGL_VENDOR_LIBRARY_FILENAMES='$egl'" "export GST_PLUGIN_SYSTEM_PATH_1_0='$gst'"
				cat
			} < "$wrapper" > "$wrapper.enve"
			cat "$wrapper.enve" > "$wrapper"
			rm "$wrapper.enve"
		done
	fi
	"""

// The fontconfig file FONTCONFIG_FILE names. On Linux it lists only the fonts this object's
// inputs carry (DejaVu, Liberation, and Noto Color Emoji), so a page renders the same on every
// machine whatever fonts the host has. Liberation is metric-compatible with Arial, Times
// New Roman and Courier New; Noto supplies intrinsic-color glyphs for emoji support checks. The
// generic families resolve to them. darwin's browsers don't read fontconfig: there the file
// lists the system's font dirs, what fontconfig reads by default, for other tools in the
// profile. The cache goes to $XDG_CACHE_HOME/fontconfig.
_playwrightFonts: """
	fontdirs() {
		root=$(cd /nix/store 2>/dev/null && pwd -P) || root=/nix/store
		for dir in $(printf '%s' "${XDG_DATA_DIRS:-}" | tr ':' ' '); do
			[ -d "$dir/fonts" ] || continue
			case "$dir" in "$root"/*) dir="/nix/store/${dir#"$root"/}" ;; esac
			printf '  <dir>%s/fonts</dir>
	' "$dir"
		done
		if [ "$(uname -s)" = Darwin ]; then
			printf '  <dir>%s</dir>
	' /System/Library/Fonts /Library/Fonts
			printf '  <dir>~/Library/Fonts</dir>
	'
		fi
	}
	prefer() {
		printf '  <alias binding="same"><family>%s</family><prefer><family>%s</family><family>%s</family></prefer></alias>
	' "$@"
	}
	{
		printf '<?xml version="1.0"?>
	<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
	<fontconfig>
	'
		fontdirs
		printf '  <cachedir prefix="xdg">fontconfig</cachedir>
	'
		prefer sans-serif "Liberation Sans" "DejaVu Sans"
		prefer serif "Liberation Serif" "DejaVu Serif"
		prefer monospace "Liberation Mono" "DejaVu Sans Mono"
		prefer Arial "Liberation Sans" "DejaVu Sans"
		prefer Helvetica "Liberation Sans" "DejaVu Sans"
		prefer "Times New Roman" "Liberation Serif" "DejaVu Serif"
		prefer "Courier New" "Liberation Mono" "DejaVu Sans Mono"
		printf '</fontconfig>
	'
	} > "$out/fonts.conf"
	"""
