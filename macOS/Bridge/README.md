# whisper.cpp Bridge

## Setup Instructions

1. Clone whisper.cpp:
   ```bash
   cd corvin
   git clone https://github.com/ggerganov/whisper.cpp.git vendor/whisper.cpp
   ```

2. Build whisper.cpp as a static library:
   ```bash
   cd vendor/whisper.cpp
   mkdir build && cd build
   cmake .. -DBUILD_SHARED_LIBS=OFF -DWHISPER_METAL=ON
   cmake --build . --config Release
   ```

3. In Xcode:
   - Add `vendor/whisper.cpp/include` to Header Search Paths
   - Add `vendor/whisper.cpp/build` to Library Search Paths
   - Link `libwhisper.a` in Build Phases
   - Set `whisper-bridge.h` as the Objective-C Bridging Header
