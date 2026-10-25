/**
 * @file src/platform/macos/microphone.mm
 * @brief Definitions for microphone capture on macOS.
 */
// standard includes
#include <algorithm>
#include <chrono>
#include <thread>

// local includes
#include "src/capture_source.h"
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_audio.h"
#include "src/platform/macos/misc.h"

namespace platf {
  using namespace std::literals;

  /**
   * @brief Reads application audio produced by ScreenCaptureKit.
   */
  struct sck_mic_t: public mic_t {
    std::uint32_t sample_rate {48000};  ///< Sample rate requested by the stream.
    std::uint32_t channels {2};  ///< Channel count requested by the stream.

    /**
     * @brief Deliver application audio, or time out while the target is still starting.
     *
     * @param sample_in Sample in.
     * @return Capture status reported to the streaming pipeline.
     */
    capture_e sample(std::vector<float> &sample_in) override {
      if (capture_source::read_audio(sample_in.data(), sample_in.size(), sample_rate, channels, 5s)) {
        return capture_e::ok;
      }

      std::fill(sample_in.begin(), sample_in.end(), 0.0F);
      return capture_e::timeout;
    }
  };

  struct av_mic_t: public mic_t {
    AVAudio *av_audio_capture {};  ///< AV audio capture.

    ~av_mic_t() override {
      [av_audio_capture release];
    }

    /**
     * @brief Deliver a captured audio sample to Sunshine's audio pipeline.
     *
     * @param sample_in Sample in.
     * @return Capture status reported to the streaming pipeline.
     */
    capture_e sample(std::vector<float> &sample_in) override {
      const uint32_t neededBytes = static_cast<uint32_t>(sample_in.size() * sizeof(float));
      uint8_t *dst = reinterpret_cast<uint8_t *>(sample_in.data());

      uint32_t remaining = neededBytes;

      while (remaining > 0) {
        uint32_t avail = 0;
        void *tail = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &avail);

        if (avail == 0) {
          // Using 5 second timeout to prevent indefinite hanging
          dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC);
          if (dispatch_semaphore_wait(av_audio_capture->audioSemaphore, timeout) != 0) {
            BOOST_LOG(warning) << "Audio sample timeout - no audio data received within 5 seconds"sv;

            // Fill with silence and return to prevent hanging
            std::fill(sample_in.begin(), sample_in.end(), 0.0f);
            return capture_e::timeout;
          }
          continue;
        }

        const uint32_t toCopy = (avail < remaining) ? avail : remaining;
        std::memcpy(dst, tail, toCopy);

        TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, toCopy);

        dst += toCopy;
        remaining -= toCopy;
      }

      return capture_e::ok;
    }
  };

  /**
   * @brief Report whether a PCM buffer contains audible energy.
   *
   * @param samples Interleaved float samples.
   * @return `true` when at least one sample exceeds a small threshold.
   */
  bool pcm_has_signal(const std::vector<float> &samples) {
    constexpr float threshold = 1.0e-4F;
    for (float sample : samples) {
      if (sample > threshold || sample < -threshold) {
        return true;
      }
    }
    return false;
  }

  /**
   * @brief Streams the captured application's audio through a Core Audio process tap.
   *
   * Other host applications keep playing on the local speakers. ScreenCaptureKit application
   * audio is kept as a fallback when the process tap only delivers silence.
   */
  struct process_tap_mic_t: public mic_t {
    AVAudio *av_audio_capture {};  ///< Process audio tap.
    std::uint32_t sample_rate {48000};  ///< Sample rate requested by the stream.
    std::uint32_t channels {2};  ///< Channel count requested by the stream.
    UInt32 frame_size {0};  ///< Frames requested per capture buffer.
    std::int32_t tapped_pid {0};  ///< Process currently attached to the tap.
    bool started {false};  ///< Whether the tap is producing samples.
    bool logged_sck_fallback {false};  ///< Whether the ScreenCaptureKit fallback was logged.

    ~process_tap_mic_t() override {
      [av_audio_capture release];
    }

    /**
     * @brief Attach or refresh the process tap for the active capture target.
     *
     * @return `true` when samples can be read from the tap.
     */
    bool ensure_tap() {
      const auto pid = capture_source::audio_pid();
      if (pid <= 0) {
        return false;
      }

      if (started && tapped_pid == pid) {
        return true;
      }

      if (av_audio_capture != nil) {
        [av_audio_capture release];
        av_audio_capture = nil;
      }

      av_audio_capture = [[AVAudio alloc] init];
      // Process taps stay unmuted so the aggregate device receives real samples. Other host
      // applications are still excluded because only this pid is listed in the tap.
      av_audio_capture.hostAudioEnabled = YES;
      if ([av_audio_capture setupProcessTap:pid sampleRate:sample_rate frameSize:frame_size channels:static_cast<UInt8>(channels)] != 0) {
        [av_audio_capture release];
        av_audio_capture = nil;
        started = false;
        tapped_pid = 0;
        return false;
      }

      started = true;
      tapped_pid = pid;
      BOOST_LOG(info) << "Streaming audio from application pid "sv << pid << " while other host audio stays local."sv;
      return true;
    }

    /**
     * @brief Read one frame from the process tap circular buffer.
     *
     * @param sample_in Destination PCM buffer.
     * @return `true` when a full frame was copied.
     */
    bool read_process_tap(std::vector<float> &sample_in) {
      if (av_audio_capture == nil) {
        return false;
      }

      const uint32_t neededBytes = static_cast<uint32_t>(sample_in.size() * sizeof(float));
      uint8_t *dst = reinterpret_cast<uint8_t *>(sample_in.data());
      uint32_t remaining = neededBytes;

      while (remaining > 0) {
        uint32_t avail = 0;
        void *tail = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &avail);

        if (avail == 0) {
          dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 50LL * NSEC_PER_MSEC);
          if (dispatch_semaphore_wait(av_audio_capture->audioSemaphore, timeout) != 0) {
            return false;
          }
          continue;
        }

        const uint32_t toCopy = (avail < remaining) ? avail : remaining;
        std::memcpy(dst, tail, toCopy);
        TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, toCopy);
        dst += toCopy;
        remaining -= toCopy;
      }

      return true;
    }

    /**
     * @brief Deliver application audio from the process tap, or ScreenCaptureKit as fallback.
     *
     * @param sample_in Sample in.
     * @return Capture status reported to the streaming pipeline.
     */
    capture_e sample(std::vector<float> &sample_in) override {
      ensure_tap();

      if (read_process_tap(sample_in) && pcm_has_signal(sample_in)) {
        return capture_e::ok;
      }

      if (capture_source::read_audio(sample_in.data(), sample_in.size(), sample_rate, channels, 50ms)) {
        if (!logged_sck_fallback) {
          BOOST_LOG(info) << "Using ScreenCaptureKit application audio because the process tap was silent."sv;
          logged_sck_fallback = true;
        }
        return capture_e::ok;
      }

      std::fill(sample_in.begin(), sample_in.end(), 0.0F);
      return capture_e::timeout;
    }
  };

  /**
   * @brief macOS audio control state used to create microphone streams.
   */
  struct macos_audio_control_t: public audio_control_t {
    AVCaptureDevice *audio_capture_device {};  ///< Audio capture device.

  public:
    /**
     * @brief Update the sink value on the backend.
     *
     * @param sink Audio sink name to route or capture.
     * @return Status from updating sink.
     */
    int set_sink(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::set_sink() unimplemented: "sv << sink;
      return 0;
    }

    /**
     * @brief Create a microphone capture stream for the requested layout.
     *
     * @param mapping Opus channel mapping table for the requested layout.
     * @param channels Number of audio channels in the stream.
     * @param sample_rate Audio sample rate in hertz.
     * @param frame_size Number of samples captured per audio frame.
     * @param continuous_audio Continuous audio.
     * @param host_audio_enabled Whether host playback should remain enabled during capture.
     * @return Microphone capture object for the requested audio layout.
     */
    std::unique_ptr<mic_t> microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size, bool continuous_audio, bool host_audio_enabled) override {
      if (capture_source::active().mode != capture_source::mode_e::display) {
        const auto audio_channels = static_cast<std::uint32_t>(std::max(channels, 1));
        // Keep ScreenCaptureKit application audio available as a fallback for the process tap.
        capture_source::set_audio_request({sample_rate, audio_channels});

        if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {14, 2, 0})]) {
          if (!request_system_audio_permission()) {
            BOOST_LOG(warning) << "System audio recording permission is unavailable for application capture."sv;
          }
          auto process_mic = std::make_unique<process_tap_mic_t>();
          process_mic->sample_rate = sample_rate;
          process_mic->channels = audio_channels;
          process_mic->frame_size = frame_size;
          BOOST_LOG(info) << "Capturing audio from the target application."sv;
          return process_mic;
        }

        auto application_mic = std::make_unique<sck_mic_t>();
        application_mic->sample_rate = sample_rate;
        application_mic->channels = audio_channels;
        BOOST_LOG(info) << "Capturing audio from the target application via ScreenCaptureKit."sv;
        return application_mic;
      }

      auto mic = std::make_unique<av_mic_t>();
      mic->av_audio_capture = [[AVAudio alloc] init];

      // Set the host audio enabled flag from the stream configuration
      mic->av_audio_capture.hostAudioEnabled = host_audio_enabled ? YES : NO;
      BOOST_LOG(debug) << "Set hostAudioEnabled to: "sv << (host_audio_enabled ? "YES" : "NO");

      if (config::audio.sink.empty()) {
        // Use macOS system-wide audio tap
        BOOST_LOG(info) << "Using macOS system audio tap for capture."sv;
        BOOST_LOG(info) << "Sample rate: "sv << sample_rate << ", Frame size: "sv << frame_size << ", Channels: "sv << channels;

        if ([mic->av_audio_capture setupSystemTap:sample_rate frameSize:frame_size channels:channels]) {
          BOOST_LOG(error) << "Failed to setup system audio tap."sv;
          return nullptr;
        }
      } else {
        // Use specified macOS audio sink
        const char *audio_sink = config::audio.sink.c_str();
        BOOST_LOG(info) << "Using configured audio sink "sv << audio_sink << " for capture."sv;

        if (!request_microphone_permission()) {
          return nullptr;
        }

        if ((audio_capture_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:audio_sink]]) == nullptr) {
          BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed. Please set a valid input source in the Sunshine config."sv;
          BOOST_LOG(error) << "Available inputs:"sv;

          for (NSString *name in [AVAudio microphoneNames]) {
            BOOST_LOG(error) << "\t"sv << [name UTF8String];
          }

          return nullptr;
        }

        if ([mic->av_audio_capture setupMicrophone:audio_capture_device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
          BOOST_LOG(error) << "Failed to setup microphone."sv;
          return nullptr;
        }
      }

      return mic;
    }

    bool is_sink_available(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::is_sink_available() unimplemented: "sv << sink;
      return true;
    }

    /**
     * @brief Query host and virtual sink names available to Sunshine.
     *
     * @return Host and virtual sink names when the backend can report them.
     */
    std::optional<sink_t> sink_info() override {
      sink_t sink;

      return sink;
    }
  };

  std::unique_ptr<audio_control_t> audio_control() {
    return std::make_unique<macos_audio_control_t>();
  }
}  // namespace platf
