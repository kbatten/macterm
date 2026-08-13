pushd ../ghostty && git clean -dfx && zig build -Doptimize=ReleaseFast && popd && git clean -dfx && ln -s ../ghostty/macos/GhosttyKit.xcframework && mise run build && open build/Macterm-0.0.0.dmg
