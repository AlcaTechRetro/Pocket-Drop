LÖVE engine (bundled in the release)
====================================

On the handheld, Pocket Drop runs on LÖVE 11.4 for aarch64 (build by Cebion,
github.com/Cebion/love2d_aarch64). The engine files - love, libs/liblove-11.4.so,
libs/libluajit-5.1.so.2 and libs/libogg.so.0 - are included in the release zip:

    https://github.com/AlcaTechRetro/Pocket-Drop/releases/latest

They are not stored in this repository because of their size.
mux_launch.sh checks them against checksums.md5 every time the app starts.
LÖVE is released under the zlib licence: see LOVE-LICENSE.txt.
