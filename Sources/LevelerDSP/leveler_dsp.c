#include "leveler_dsp.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct leveler_state {
    leveler_params p;
    float rms_coef, attack_coef, release_coef, limiter_release_coef;
    float speech_up_coef, speech_down_coef, boost_up_coef, peak_release_coef;
    float ms;            // 50 ms mean square of the input
    float peak_env;      // instant-attack peak follower, to catch loud onsets
    float env;           // ms after attack/release smoothing (downward compressor)
    float speech_db;     // running estimate of the current talker's level
    float boost_db;      // upward gain being applied
    float limiter_gain;  // current limiter gain (linear, <= 1)
    atomic_int bypass;   // pass audio through untouched

    // Meters, written by the audio thread and read (and reset) by the UI.
    _Atomic float meter_in_peak;   // linear peak of the input
    _Atomic float meter_out_peak;  // linear peak of the output
    _Atomic float meter_level_db;  // detector level at the end of the last buffer
    _Atomic float meter_gain_db;   // applied gain at the end of the last buffer
    atomic_uint_fast64_t frames;   // frames processed since start
};

// Runs on Core Audio's realtime thread: no allocation, locks or syscalls.

static inline float db_to_lin(float db) { return powf(10.0f, db / 20.0f); }
static inline float max_f(float a, float b) { return a > b ? a : b; }
static inline float clamp_f(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

static inline float coef_for_ms(float ms, float sample_rate) {
    if (ms <= 0.0f) return 0.0f;
    return expf(-1.0f / (ms * 0.001f * sample_rate));
}

leveler_params leveler_default_params(void) {
    // Slack huddle audio already peaks near full scale, and squashing loud
    // voices is audible, so by default only quiet voices are raised: a voice
    // 12 dB under the target comes up 8 dB, and loud voices pass untouched.
    leveler_params p = {
        .boost_below_db = -24.0f,
        .boost_ratio = 3.0f,
        .max_boost_db = 12.0f,
        .threshold_db = -20.0f,
        .ratio = 1.0f,
        .knee_db = 10.0f,
        .attack_ms = 10.0f,
        .release_ms = 300.0f,
        .makeup_db = 0.0f,
        .gate_db = -55.0f,
        .ceiling_db = -0.5f,
    };
    return p;
}

leveler_state *leveler_create(void) {
    leveler_state *s = calloc(1, sizeof(leveler_state));
    if (s) leveler_init(s, leveler_default_params(), 48000.0f);
    return s;
}

void leveler_destroy(leveler_state *s) { free(s); }

void leveler_set_bypass(leveler_state *s, int bypass) { atomic_store(&s->bypass, bypass ? 1 : 0); }
int leveler_get_bypass(leveler_state *s) { return atomic_load(&s->bypass); }

leveler_meters leveler_take_meters(leveler_state *s) {
    leveler_meters m = {
        .in_peak = atomic_exchange(&s->meter_in_peak, 0.0f),
        .out_peak = atomic_exchange(&s->meter_out_peak, 0.0f),
        .level_db = atomic_load(&s->meter_level_db),
        .gain_db = atomic_load(&s->meter_gain_db),
        .frames = atomic_load(&s->frames),
    };
    return m;
}

void leveler_init(leveler_state *s, leveler_params p, float sample_rate) {
    int bypass = atomic_load(&s->bypass);
    memset(s, 0, sizeof(*s));
    atomic_store(&s->bypass, bypass);
    if (p.ratio < 1.0f) p.ratio = 1.0f;
    if (p.boost_ratio < 1.0f) p.boost_ratio = 1.0f;
    if (p.max_boost_db < 0.0f) p.max_boost_db = 0.0f;
    if (p.knee_db < 0.0f) p.knee_db = 0.0f;
    s->p = p;
    s->rms_coef = coef_for_ms(50.0f, sample_rate);
    s->speech_up_coef = coef_for_ms(100.0f, sample_rate);
    s->speech_down_coef = coef_for_ms(1500.0f, sample_rate);
    s->boost_up_coef = coef_for_ms(50.0f, sample_rate);
    s->peak_release_coef = coef_for_ms(100.0f, sample_rate);
    s->speech_db = p.boost_below_db;  // no boost until someone has spoken
    s->attack_coef = coef_for_ms(p.attack_ms, sample_rate);
    s->release_coef = coef_for_ms(p.release_ms, sample_rate);
    s->limiter_release_coef = coef_for_ms(50.0f, sample_rate);
    s->limiter_gain = 1.0f;
    atomic_store(&s->meter_level_db, -120.0f);
}

// Downward compression plus makeup for a signal at level_db.
static float downward_gain_db(const leveler_params *p, float level_db) {
    float over = level_db - p->threshold_db;
    float slope = 1.0f / p->ratio - 1.0f;  // negative: dB removed per dB over
    float gain;
    if (p->knee_db > 0.0f && fabsf(over) <= p->knee_db / 2.0f) {
        float x = over + p->knee_db / 2.0f;
        gain = slope * x * x / (2.0f * p->knee_db);
    } else if (over > 0.0f) {
        gain = slope * over;
    } else {
        gain = 0.0f;
    }
    // Fade the makeup in over 12 dB around the gate so silence and room noise
    // aren't lifted.
    float weight = clamp_f((level_db - (p->gate_db - 6.0f)) / 12.0f, 0.0f, 1.0f);
    return gain + p->makeup_db * weight;
}

// Upward gain for a talker whose speech level is speech_db.
static float boost_for_speech_db(const leveler_params *p, float speech_db) {
    if (p->boost_ratio <= 1.0f || speech_db >= p->boost_below_db) return 0.0f;
    float boost = (p->boost_below_db - speech_db) * (1.0f - 1.0f / p->boost_ratio);
    return boost > p->max_boost_db ? p->max_boost_db : boost;
}

float leveler_static_gain_db(const leveler_params *p, float level_db) {
    float boost = level_db >= p->gate_db ? boost_for_speech_db(p, level_db) : 0.0f;
    return downward_gain_db(p, level_db) + boost;
}

static void process_stereo(leveler_state *s, float *buf, unsigned frames) {
    // buf is interleaved stereo, processed in place.
    const leveler_params *p = &s->p;
    float env = s->env, ms = s->ms, peak_env = s->peak_env;
    float speech_db = s->speech_db, boost_db = s->boost_db;
    float lim = s->limiter_gain;
    const float ceiling = db_to_lin(p->ceiling_db);
    float in_peak = 0.0f, out_peak = 0.0f;
    float level_db = -120.0f, gain_db = 0.0f;

    for (unsigned i = 0; i < frames; i++) {
        float l = buf[2 * i], r = buf[2 * i + 1];
        float x = max_f(fabsf(l), fabsf(r));
        in_peak = max_f(in_peak, x);

        ms = s->rms_coef * ms + (1.0f - s->rms_coef) * x * x;
        peak_env = x > peak_env ? x : peak_env * s->peak_release_coef;
        level_db = 10.0f * log10f(ms + 1e-12f);

        // Raising quiet voices. Track the talker's level only while someone
        // is talking, so pauses hold the gain instead of ramping it up, and
        // move toward a new talker over a second or so.
        if (level_db > p->gate_db) {
            float c = level_db > speech_db ? s->speech_up_coef : s->speech_down_coef;
            speech_db = c * speech_db + (1.0f - c) * level_db;
        }
        float target = boost_for_speech_db(p, speech_db);
        boost_db = s->boost_up_coef * boost_db + (1.0f - s->boost_up_coef) * target;
        if (boost_db > target) boost_db = target;
        // The boost never pushes a peak above boost_below + 14 dB (a speech
        // crest factor), so a loud onset right after a quiet talker drops it
        // on the spot instead of being boosted into the limiter.
        float allowed = p->boost_below_db + 14.0f - 20.0f * log10f(peak_env + 1e-9f);
        if (allowed < 0.0f) allowed = 0.0f;
        if (boost_db > allowed) boost_db = allowed;

        // Taming loud voices (off unless ratio > 1 or makeup is set).
        float c = ms > env ? s->attack_coef : s->release_coef;
        env = c * env + (1.0f - c) * ms;
        gain_db = downward_gain_db(p, 10.0f * log10f(env + 1e-12f)) + boost_db;

        float g = db_to_lin(gain_db);
        l *= g;
        r *= g;

        // Peak limiter: recover over ~50 ms, but never past what keeps this
        // sample under the ceiling.
        float peak = max_f(fabsf(l), fabsf(r));
        lim = 1.0f - (1.0f - lim) * s->limiter_release_coef;
        if (peak * lim > ceiling) lim = ceiling / peak;
        l = clamp_f(l * lim, -1.0f, 1.0f);
        r = clamp_f(r * lim, -1.0f, 1.0f);

        out_peak = max_f(out_peak, max_f(fabsf(l), fabsf(r)));
        buf[2 * i] = l;
        buf[2 * i + 1] = r;
    }

    if (!isfinite(env)) env = 0.0f;
    if (!isfinite(ms)) ms = 0.0f;
    if (!isfinite(peak_env)) peak_env = 0.0f;
    if (!isfinite(speech_db)) speech_db = p->boost_below_db;
    if (!isfinite(boost_db)) boost_db = 0.0f;
    s->env = env;
    s->ms = ms;
    s->peak_env = peak_env;
    s->speech_db = speech_db;
    s->boost_db = boost_db;
    s->limiter_gain = lim;
    if (in_peak > atomic_load(&s->meter_in_peak)) atomic_store(&s->meter_in_peak, in_peak);
    if (out_peak > atomic_load(&s->meter_out_peak)) atomic_store(&s->meter_out_peak, out_peak);
    atomic_store(&s->meter_level_db, speech_db);
    atomic_store(&s->meter_gain_db, gain_db + 20.0f * log10f(lim));
}

static void run(leveler_state *s, float *stereo, unsigned frames) {
    if (atomic_load(&s->bypass)) {
        float peak = 0.0f;
        for (unsigned i = 0; i < 2 * frames; i++) peak = max_f(peak, fabsf(stereo[i]));
        if (peak > atomic_load(&s->meter_in_peak)) atomic_store(&s->meter_in_peak, peak);
        if (peak > atomic_load(&s->meter_out_peak)) atomic_store(&s->meter_out_peak, peak);
    } else {
        process_stereo(s, stereo, frames);
    }
    atomic_fetch_add(&s->frames, frames);
}

enum { CHUNK = 256 };

void leveler_process_interleaved(leveler_state *s, const float *in, float *out,
                                 unsigned frames, unsigned channels) {
    if (channels == 0) return;
    float tmp[2 * CHUNK];
    for (unsigned start = 0; start < frames; start += CHUNK) {
        unsigned n = frames - start < CHUNK ? frames - start : CHUNK;
        const float *src = in + (size_t)start * channels;
        float *dst = out + (size_t)start * channels;
        for (unsigned i = 0; i < n; i++) {
            tmp[2 * i] = src[i * channels];
            tmp[2 * i + 1] = channels > 1 ? src[i * channels + 1] : src[i * channels];
        }
        run(s, tmp, n);
        for (unsigned i = 0; i < n; i++) {
            if (in != out)
                for (unsigned c = 2; c < channels; c++) dst[i * channels + c] = src[i * channels + c];
            dst[i * channels] = channels > 1 ? tmp[2 * i] : 0.5f * (tmp[2 * i] + tmp[2 * i + 1]);
            if (channels > 1) dst[i * channels + 1] = tmp[2 * i + 1];
        }
    }
}

// Reads channel `ch` (0 = left, 1 = right) of frame `i` from the tap, which is
// either one interleaved buffer or one buffer per channel at the end of `input`.
static inline float tap_sample(const AudioBufferList *input, unsigned i, unsigned ch) {
    const AudioBuffer *last = &input->mBuffers[input->mNumberBuffers - 1];
    if (last->mNumberChannels >= 2) {
        return ((const float *)last->mData)[i * last->mNumberChannels + ch];
    }
    if (ch == 1 && input->mNumberBuffers >= 2) {
        return ((const float *)last->mData)[i];
    }
    if (input->mNumberBuffers >= 2 && input->mBuffers[input->mNumberBuffers - 2].mNumberChannels == 1) {
        return ((const float *)input->mBuffers[input->mNumberBuffers - 2].mData)[i];
    }
    return ((const float *)last->mData)[i];
}

static unsigned buffer_frames(const AudioBuffer *b) {
    if (b->mNumberChannels == 0) return 0;
    return b->mDataByteSize / (unsigned)(sizeof(float) * b->mNumberChannels);
}

static OSStatus leveler_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *input_time,
                        AudioBufferList *output, const AudioTimeStamp *output_time,
                        void *client_data) {
    (void)device; (void)now; (void)input_time; (void)output_time;
    leveler_state *s = (leveler_state *)client_data;
    if (!output || output->mNumberBuffers == 0) return noErr;

    // Each buffer carries its own capacity; process the longest and write
    // each buffer only as far as it goes.
    unsigned out_frames = 0;
    unsigned total_out_channels = 0;
    for (unsigned b = 0; b < output->mNumberBuffers; b++) {
        unsigned f = buffer_frames(&output->mBuffers[b]);
        if (f > out_frames) out_frames = f;
        total_out_channels += output->mBuffers[b].mNumberChannels;
    }

    unsigned in_frames = 0;
    if (input && input->mNumberBuffers > 0 && input->mBuffers[input->mNumberBuffers - 1].mData) {
        const AudioBuffer *last = &input->mBuffers[input->mNumberBuffers - 1];
        in_frames = buffer_frames(last);
        // A non-interleaved stereo tap also reads the buffer before the last.
        if (last->mNumberChannels == 1 && input->mNumberBuffers >= 2) {
            const AudioBuffer *prev = &input->mBuffers[input->mNumberBuffers - 2];
            unsigned pf = prev->mData && prev->mNumberChannels == 1 ? buffer_frames(prev) : 0;
            if (prev->mNumberChannels == 1 && pf < in_frames) in_frames = pf;
        }
    }

    float tmp[2 * CHUNK];
    for (unsigned start = 0; start < out_frames; start += CHUNK) {
        unsigned n = out_frames - start < CHUNK ? out_frames - start : CHUNK;
        for (unsigned i = 0; i < n; i++) {
            unsigned f = start + i;
            if (f < in_frames) {
                tmp[2 * i] = tap_sample(input, f, 0);
                tmp[2 * i + 1] = tap_sample(input, f, 1);
            } else {
                tmp[2 * i] = tmp[2 * i + 1] = 0.0f;
            }
        }
        run(s, tmp, n);

        unsigned global_ch = 0;
        for (unsigned b = 0; b < output->mNumberBuffers; b++) {
            AudioBuffer *ob = &output->mBuffers[b];
            float *data = (float *)ob->mData;
            unsigned nch = ob->mNumberChannels;
            unsigned cap = buffer_frames(ob);
            if (!data || nch == 0 || cap <= start) { global_ch += nch; continue; }
            unsigned m = cap - start < n ? cap - start : n;
            for (unsigned c = 0; c < nch; c++, global_ch++) {
                for (unsigned i = 0; i < m; i++) {
                    float v;
                    if (total_out_channels == 1) v = 0.5f * (tmp[2 * i] + tmp[2 * i + 1]);
                    else if (global_ch < 2) v = tmp[2 * i + global_ch];
                    else v = 0.0f;
                    data[(start + i) * nch + c] = v;
                }
            }
        }
    }
    return noErr;
}

OSStatus leveler_create_ioproc(AudioObjectID device, leveler_state *s, AudioDeviceIOProcID *out_proc_id) {
    return AudioDeviceCreateIOProcID(device, leveler_ioproc, s, out_proc_id);
}
