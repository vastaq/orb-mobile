#include <stdint.h>
#include <string.h>
#include "fvad.h"

// A 40 ms, 4 kHz window is enough to check periodicity in the voiced range.
// Check the upper harmonics of a voice. A fan motor may be periodic too, but
// consecutive low motor harmonics contain little power after this high-pass.
static int voiced_period(const float *wave) {
  float filtered[160] = {0}, upper_power = 0, total_power = 0;
  for (int i = 2; i < 160; i++) {
    filtered[i] = wave[i] - 2.f * wave[i - 1] + wave[i - 2];
    upper_power += filtered[i] * filtered[i];
    total_power += wave[i] * wave[i];
  }
  if (upper_power < .045f * total_power) return 0;
  float power = 0;
  for (int i = 55; i < 160; i++) power += filtered[i] * filtered[i];
  if (power == 0) return 0;
  for (int lag = 10; lag <= 55; lag++) { // 73–400 Hz
    float cross = 0, other = 0;
    for (int i = 55; i < 160; i++) {
      float prior = filtered[i - lag];
      cross += filtered[i] * prior;
      other += prior * prior;
    }
    if (cross > 0 && cross * cross > .70f * .70f * power * other) return 1;
  }
  return 0;
}

// WebRTC's adaptive multiband VAD is the first gate. Some phone microphones
// amplify fluctuating fan noise into its speech bands. In a 200 ms span require
// at least three periodic voiced frames as corroboration, independently of gain.
__attribute__((visibility("default"))) int orb_has_speech(
    const uint8_t *pcm, intptr_t length, int rate) {
  if (rate != 8000 && rate != 16000 && rate != 32000 && rate != 48000) return 0;
  const int frame = rate / 50, stride = rate / 4000;
  const intptr_t frames = length / (frame * 2);
  if (frames < 4) return 0;
  Fvad *vad = fvad_new();
  if (!vad) return 0;
  fvad_set_sample_rate(vad, rate);
  fvad_set_mode(vad, 2);
  int16_t samples[960];
  float window[160] = {0};
  int votes[10] = {0}, voice_frames = 0;
  int result = 0;
  for (intptr_t i = 0; i < frames; i++) {
    for (int j = 0; j < frame; j++) {
      const intptr_t k = (i * frame + j) * 2;
      samples[j] = (int16_t)((unsigned)pcm[k] | ((unsigned)pcm[k + 1] << 8));
    }
    memmove(window, window + 80, 80 * sizeof(float));
    for (int j = 0; j < 80; j++) {
      int sum = 0;
      for (int n = 0; n < stride; n++) sum += samples[j * stride + n];
      window[j + 80] = (float)sum / stride;
    }
    int speech = fvad_process(vad, samples, frame);
    int slot = (int)(i % 10);
    voice_frames -= votes[slot];
    votes[slot] = speech == 1 && i > 0 && voiced_period(window);
    voice_frames += votes[slot];
    if (voice_frames >= 3) { result = 1; break; }
  }
  fvad_free(vad);
  return result;
}
