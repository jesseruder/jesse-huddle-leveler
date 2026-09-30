#include "leveler_dsp.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Declipper: finds plateaus where the audio sat at full scale (a mic that
// clipped before the audio reached Slack) and redraws each one as a smooth
// peak through the samples on either side. Works on a short delay line so a
// whole plateau is seen before any of it is played.
enum { DECLIP_RING = 128, DECLIP_DELAY = 96 };
#define DECLIP_THRESHOLD 0.97f
#define DECLIP_MAX 2.0f

typedef struct {
    float ring[2][DECLIP_RING];
    unsigned w;                 // samples written per channel
    int in_run[2], pending[2];
    unsigned run_start[2], run_end[2];
} declipper;

enum { LIM_AHEAD = 128, LIM_RING = 256 };

typedef struct {
    float dl[LIM_RING], dr[LIM_RING];  // delayed audio
    float need[LIM_RING];              // gain each sample needs to stay under the ceiling
    float held[LIM_AHEAD];             // released minimum gain, for the running average
    float sum;
    unsigned pos;
} limiter;

struct leveler_state {
    leveler_params p;      // in use by the audio thread
    // Settings handoff: leveler_set_params publishes a heap copy in mailbox;
    // the audio thread takes it whole and hands it back through retired for
    // the main thread to free (held in retire_later if retired is full).
    _Atomic(leveler_params *) mailbox;
    _Atomic(leveler_params *) retired;
    leveler_params *retire_later;
    declipper dc;
    limiter lim;
    float sample_rate;
    float rms_coef, attack_coef, release_coef, limiter_release_coef;
    float speech_up_coef, speech_down_coef, speech_fresh_coef, boost_up_coef, peak_release_coef;
    unsigned pause_frames, fresh_frames;  // turn-taking: silence so far, fast-tracking left
    unsigned turn_gap_frames, fresh_window_frames;
    float ms;            // 50 ms mean square of the input
    float peak_env;      // instant-attack peak follower, to catch loud onsets
    float env;           // ms after attack/release smoothing (downward compressor)
    float speech_db;     // running estimate of the current talker's level
    float boost_db;      // upward gain being applied
    float limiter_gain;  // current limiter gain (linear, <= 1)
    float soften_coef;   // one-pole low-pass coefficient for the treble cut
    float lp_l, lp_r;    // low-pass state for the treble cut
    atomic_int bypass;   // pass audio through untouched
    _Atomic(float *) rec_in;
    _Atomic(float *) rec_out;
    atomic_uint rec_cap, rec_pos;

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
    // Fast compression of Slack's already hot audio is audible, so the default
    // levels whole talkers with a slow gain instead: a talker 12 dB off the
    // target moves 8 dB toward it. Fast downward compression is off.
    leveler_params p = {
        .target_db = -24.0f,
        .level_ratio = 3.0f,
        .max_boost_db = 12.0f,
        .max_cut_db = 15.0f,
        .threshold_db = -20.0f,
        .ratio = 1.0f,
        .knee_db = 10.0f,
        .attack_ms = 10.0f,
        .release_ms = 300.0f,
        .makeup_db = 0.0f,
        .gate_db = -55.0f,
        .ceiling_db = -0.5f,
        .soften_db = 10.0f,
        .declip = 1,
    };
    return p;
}

static void free_params_handoff(leveler_state *s);

leveler_state *leveler_create(void) {
    leveler_state *s = calloc(1, sizeof(leveler_state));
    if (s) leveler_init(s, leveler_default_params(), 48000.0f);
    return s;
}

void leveler_destroy(leveler_state *s) {
    if (!s) return;
    free_params_handoff(s);
    free(s);
}

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

static void apply_params(leveler_state *s, leveler_params p) {
    if (p.ratio < 1.0f) p.ratio = 1.0f;
    if (p.level_ratio < 1.0f) p.level_ratio = 1.0f;
    if (p.max_boost_db < 0.0f) p.max_boost_db = 0.0f;
    if (p.max_cut_db < 0.0f) p.max_cut_db = 0.0f;
    if (p.knee_db < 0.0f) p.knee_db = 0.0f;
    if (p.soften_db < 0.0f) p.soften_db = 0.0f;
    s->p = p;
    s->attack_coef = coef_for_ms(p.attack_ms, s->sample_rate);
    s->release_coef = coef_for_ms(p.release_ms, s->sample_rate);
}

void leveler_init(leveler_state *s, leveler_params p, float sample_rate) {
    int bypass = atomic_load(&s->bypass);
    free_params_handoff(s);
    memset(s, 0, sizeof(*s));
    atomic_store(&s->bypass, bypass);
    s->sample_rate = sample_rate;
    apply_params(s, p);
    s->rms_coef = coef_for_ms(50.0f, sample_rate);
    s->speech_up_coef = coef_for_ms(100.0f, sample_rate);
    s->speech_down_coef = coef_for_ms(1500.0f, sample_rate);
    s->speech_fresh_coef = coef_for_ms(150.0f, sample_rate);
    s->turn_gap_frames = (unsigned)(0.25f * sample_rate);
    s->fresh_window_frames = (unsigned)(0.5f * sample_rate);
    s->boost_up_coef = coef_for_ms(50.0f, sample_rate);
    s->peak_release_coef = coef_for_ms(100.0f, sample_rate);
    s->speech_db = s->p.target_db;  // no gain change until someone has spoken
    s->limiter_release_coef = coef_for_ms(50.0f, sample_rate);
    s->limiter_gain = 1.0f;
    for (unsigned i = 0; i < LIM_RING; i++) s->lim.need[i] = 1.0f;
    for (unsigned i = 0; i < LIM_AHEAD; i++) s->lim.held[i] = 1.0f;
    s->lim.sum = (float)LIM_AHEAD;
    s->soften_coef = 1.0f - expf(-2.0f * 3.14159265f * 2500.0f / sample_rate);
    atomic_store(&s->meter_level_db, -120.0f);
}

// Main thread. Frees what the audio thread has finished with, then
// publishes the new settings; a copy the audio thread never took is freed.
void leveler_set_params(leveler_state *s, leveler_params p) {
    free(atomic_exchange(&s->retired, NULL));
    leveler_params *copy = malloc(sizeof(*copy));
    if (!copy) return;
    *copy = p;
    free(atomic_exchange(&s->mailbox, copy));
}

// Audio thread, at the start of a buffer: never allocates or frees.
static void take_pending_params(leveler_state *s) {
    if (s->retire_later) {
        leveler_params *expected = NULL;
        if (atomic_compare_exchange_strong(&s->retired, &expected, s->retire_later)) s->retire_later = NULL;
    }
    if (s->retire_later) return;  // main thread hasn't collected yet; try next buffer
    leveler_params *p = atomic_exchange(&s->mailbox, NULL);
    if (!p) return;
    apply_params(s, *p);
    leveler_params *expected = NULL;
    if (!atomic_compare_exchange_strong(&s->retired, &expected, p)) s->retire_later = p;
}

static void free_params_handoff(leveler_state *s) {
    free(atomic_exchange(&s->mailbox, NULL));
    free(atomic_exchange(&s->retired, NULL));
    free(s->retire_later);
    s->retire_later = NULL;
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

// Leveling gain for a talker whose speech level is speech_db.
static float gain_for_speech_db(const leveler_params *p, float speech_db) {
    float gain = (p->target_db - speech_db) * (1.0f - 1.0f / p->level_ratio);
    return clamp_f(gain, -p->max_cut_db, p->max_boost_db);
}

float leveler_static_gain_db(const leveler_params *p, float level_db) {
    float boost = level_db >= p->gate_db ? gain_for_speech_db(p, level_db) : 0.0f;
    return downward_gain_db(p, level_db) + boost;
}

// Replaces ring samples a..b of channel c with the cubic through a-2, a-1,
// b+1, b+2, where they bulge past the original.
static void declip_fix(declipper *d, int c, unsigned a, unsigned b) {
    float *ring = d->ring[c];
    unsigned n = b - a + 1;
    if (n < 3 || d->w - (a - 2) >= DECLIP_DELAY) return;  // too short, or already played
    float t[4] = {-2.0f, -1.0f, (float)n, (float)n + 1.0f};
    float y[4] = {ring[(a - 2) % DECLIP_RING], ring[(a - 1) % DECLIP_RING],
                  ring[(b + 1) % DECLIP_RING], ring[(b + 2) % DECLIP_RING]};
    float sign = ring[a % DECLIP_RING] < 0.0f ? -1.0f : 1.0f;
    for (unsigned k = 0; k < n; k++) {
        float x = (float)k, v = 0.0f;
        for (int i = 0; i < 4; i++) {
            float term = y[i];
            for (int j = 0; j < 4; j++)
                if (j != i) term *= (x - t[j]) / (t[i] - t[j]);
            v += term;
        }
        float *slot = &ring[(a + k) % DECLIP_RING];
        float mag = clamp_f(v * sign, 0.0f, DECLIP_MAX);
        if (mag > fabsf(*slot)) *slot = sign * mag;
    }
}

// Pushes one sample of channel c and returns the sample DECLIP_DELAY behind.
// Call for channel 0 and 1, then advance d->w.
static inline float declip_push(declipper *d, int c, float x, int repair) {
    unsigned w = d->w;
    d->ring[c][w % DECLIP_RING] = x;
    int hi = fabsf(x) >= DECLIP_THRESHOLD;
    if (d->pending[c]) {
        // Two samples past the plateau: fit and replace it.
        d->pending[c] = 0;
        if (hi) {
            // Dipped for one sample and came back: same plateau.
        } else {
            if (repair) declip_fix(d, c, d->run_start[c], d->run_end[c]);
            d->in_run[c] = 0;
        }
    } else if (d->in_run[c]) {
        if (!hi) {
            d->run_end[c] = w - 1;
            d->pending[c] = 1;
        }
    } else if (hi) {
        d->in_run[c] = 1;
        d->run_start[c] = w;
    }
    if (d->in_run[c] && w - d->run_start[c] > DECLIP_DELAY - 8) {
        d->in_run[c] = 0;  // longer than the window can fix
        d->pending[c] = 0;
    }
    return w >= DECLIP_DELAY ? d->ring[c][(w - DECLIP_DELAY) % DECLIP_RING] : 0.0f;
}

static void process_stereo(leveler_state *s, float *buf, unsigned frames) {
    // buf is interleaved stereo, processed in place.
    take_pending_params(s);
    const leveler_params *p = &s->p;
    float env = s->env, ms = s->ms, peak_env = s->peak_env;
    float speech_db = s->speech_db, boost_db = s->boost_db;
    float lim = s->limiter_gain;
    float lp_l = s->lp_l, lp_r = s->lp_r;
    const float ceiling = db_to_lin(p->ceiling_db);
    float in_peak = 0.0f, out_peak = 0.0f;
    float level_db = -120.0f, gain_db = 0.0f;

    for (unsigned i = 0; i < frames; i++) {
        float l = buf[2 * i], r = buf[2 * i + 1];
        // The delay line always runs, so turning repair on or off doesn't
        // shift the audio.
        l = declip_push(&s->dc, 0, l, p->declip);
        r = declip_push(&s->dc, 1, r, p->declip);
        s->dc.w++;
        float x = max_f(fabsf(l), fabsf(r));
        in_peak = max_f(in_peak, x);

        ms = s->rms_coef * ms + (1.0f - s->rms_coef) * x * x;
        peak_env = x > peak_env ? x : peak_env * s->peak_release_coef;
        level_db = 10.0f * log10f(ms + 1e-12f);

        // Talker leveling. Track the talker's level only while someone is
        // talking, so pauses hold the gain. Follow a louder talker within
        // ~100 ms. Within a stretch of speech, follow a quieter level over
        // ~1.5 s so soft syllables don't pump the gain; but for the first
        // half second after a pause of 250 ms or more, when a new talker has
        // likely taken over, follow it within ~150 ms.
        if (level_db > p->gate_db) {
            if (s->pause_frames >= s->turn_gap_frames) s->fresh_frames = s->fresh_window_frames;
            s->pause_frames = 0;
            float down = s->fresh_frames > 0 ? s->speech_fresh_coef : s->speech_down_coef;
            if (s->fresh_frames > 0) s->fresh_frames--;
            float c = level_db > speech_db ? s->speech_up_coef : down;
            speech_db = c * speech_db + (1.0f - c) * level_db;
        } else if (s->pause_frames < s->turn_gap_frames) {
            s->pause_frames++;
        }
        float target = gain_for_speech_db(p, speech_db);
        boost_db = s->boost_up_coef * boost_db + (1.0f - s->boost_up_coef) * target;
        if (boost_db > target) boost_db = target;
        // A boost never pushes a peak above target + 14 dB (a speech crest
        // factor), so a loud onset right after a quiet talker drops it on the
        // spot instead of being boosted into the limiter. Cuts are unaffected.
        float allowed = p->target_db + 14.0f - 20.0f * log10f(peak_env + 1e-9f);
        if (allowed < 0.0f) allowed = 0.0f;
        if (boost_db > allowed) boost_db = allowed;

        // Taming loud voices (off unless ratio > 1 or makeup is set).
        float c = ms > env ? s->attack_coef : s->release_coef;
        env = c * env + (1.0f - c) * ms;
        // Hold a cut through pauses, but fade a boost out below the gate so
        // room noise between words isn't raised.
        float applied = boost_db;
        if (applied > 0.0f) applied *= clamp_f((level_db - (p->gate_db - 6.0f)) / 12.0f, 0.0f, 1.0f);
        gain_db = downward_gain_db(p, 10.0f * log10f(env + 1e-12f)) + applied;

        float g = db_to_lin(gain_db);
        l *= g;
        r *= g;

        // Soften loud talkers: split at ~2.5 kHz and turn the top down.
        lp_l += s->soften_coef * (l - lp_l);
        lp_r += s->soften_coef * (r - lp_r);
        if (p->soften_db > 0.0f && boost_db < 0.0f) {
            float amount = clamp_f(-boost_db / 5.0f, 0.0f, 1.0f);
            float treble = db_to_lin(-p->soften_db * amount);
            l = lp_l + treble * (l - lp_l);
            r = lp_r + treble * (r - lp_r);
        }

        // Lookahead limiter. The gain each sample needs is known LIM_AHEAD
        // samples before it plays: take the lowest need in the lookahead
        // window, let it recover over ~50 ms, and average it over the window
        // so the gain glides down before a peak instead of chopping it off.
        // Every averaged value is at most the need of the sample being
        // played, so the ceiling holds.
        limiter *lm = &s->lim;
        unsigned k = lm->pos % LIM_RING;
        float peak = max_f(fabsf(l), fabsf(r));
        lm->need[k] = peak > ceiling ? ceiling / peak : 1.0f;
        lm->dl[k] = l;
        lm->dr[k] = r;
        float window_min = 1.0f;
        for (unsigned j = 0; j <= LIM_AHEAD; j++) {
            float v = lm->need[(lm->pos - j) % LIM_RING];
            if (v < window_min) window_min = v;
        }
        lim = 1.0f - (1.0f - lim) * s->limiter_release_coef;
        if (window_min < lim) lim = window_min;
        lm->sum += lim - lm->held[k % LIM_AHEAD];
        lm->held[k % LIM_AHEAD] = lim;
        if (k % LIM_AHEAD == 0) {
            // Re-add from scratch now and then so float error can't build up.
            lm->sum = 0.0f;
            for (unsigned j = 0; j < LIM_AHEAD; j++) lm->sum += lm->held[j];
        }
        float g_lim = lm->sum / (float)LIM_AHEAD;
        unsigned out = (lm->pos - LIM_AHEAD) % LIM_RING;
        l = clamp_f(lm->dl[out] * g_lim, -1.0f, 1.0f);
        r = clamp_f(lm->dr[out] * g_lim, -1.0f, 1.0f);
        lm->pos++;

        out_peak = max_f(out_peak, max_f(fabsf(l), fabsf(r)));
        buf[2 * i] = l;
        buf[2 * i + 1] = r;
    }

    if (!isfinite(env)) env = 0.0f;
    if (!isfinite(ms)) ms = 0.0f;
    if (!isfinite(peak_env)) peak_env = 0.0f;
    if (!isfinite(speech_db)) speech_db = p->target_db;
    if (!isfinite(boost_db)) boost_db = 0.0f;
    s->env = env;
    s->ms = ms;
    s->peak_env = peak_env;
    s->speech_db = speech_db;
    s->boost_db = boost_db;
    s->limiter_gain = lim;
    s->lp_l = isfinite(lp_l) ? lp_l : 0.0f;
    s->lp_r = isfinite(lp_r) ? lp_r : 0.0f;
    if (in_peak > atomic_load(&s->meter_in_peak)) atomic_store(&s->meter_in_peak, in_peak);
    if (out_peak > atomic_load(&s->meter_out_peak)) atomic_store(&s->meter_out_peak, out_peak);
    atomic_store(&s->meter_level_db, speech_db);
    atomic_store(&s->meter_gain_db, gain_db + 20.0f * log10f(lim));
}

void leveler_record(leveler_state *s, float *in_buf, float *out_buf, unsigned frames) {
    atomic_store(&s->rec_cap, 0);
    atomic_store(&s->rec_in, in_buf);
    atomic_store(&s->rec_out, out_buf);
    atomic_store(&s->rec_pos, 0);
    atomic_store(&s->rec_cap, frames);
}

unsigned leveler_recorded_frames(leveler_state *s) { return atomic_load(&s->rec_pos); }

static void record(leveler_state *s, _Atomic(float *) *slot, const float *stereo, unsigned frames, unsigned pos) {
    unsigned cap = atomic_load(&s->rec_cap);
    if (pos >= cap) return;
    float *buf = atomic_load(slot);
    if (!buf) return;
    unsigned n = cap - pos < frames ? cap - pos : frames;
    memcpy(buf + 2 * (size_t)pos, stereo, 2 * n * sizeof(float));
}

static void run(leveler_state *s, float *stereo, unsigned frames) {
    unsigned pos = atomic_load(&s->rec_pos);
    record(s, &s->rec_in, stereo, frames, pos);
    if (atomic_load(&s->bypass)) {
        float peak = 0.0f;
        for (unsigned i = 0; i < 2 * frames; i++) peak = max_f(peak, fabsf(stereo[i]));
        if (peak > atomic_load(&s->meter_in_peak)) atomic_store(&s->meter_in_peak, peak);
        if (peak > atomic_load(&s->meter_out_peak)) atomic_store(&s->meter_out_peak, peak);
    } else {
        process_stereo(s, stereo, frames);
    }
    record(s, &s->rec_out, stereo, frames, pos);
    unsigned cap = atomic_load(&s->rec_cap);
    if (pos < cap) atomic_store(&s->rec_pos, pos + frames < cap ? pos + frames : cap);
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
