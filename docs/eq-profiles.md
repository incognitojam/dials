# Equalizer profiles

An equalizer needs a curve, and a curve belongs to a pair of headphones rather than to
the app. Deriving one requires measuring headphones on a coupler against a target
response, which neqMac is never going to do. So the question is which existing body of
work to adopt, and what shape to store it in.

The answer is [OPRA](https://github.com/opra-project/OPRA) — Open Profiles for Revealing
Audio — a community-maintained database seeded by Roon Labs. Its schema is adopted as
neqMac's own profile format, so a profile fetched from OPRA, one pasted from AutoEq and
one edited by hand are all the same type.

## What the database contains

Measured from the published dump on 2026-08-20:

| | count |
| --- | ---: |
| vendors | 714 |
| products | 6,230 |
| EQ profiles | 12,594 |

It is distributed as `database_v1.jsonl`, one JSON object per line, about 12 MB, with a
`type` of `vendor`, `product` or `eq`. Consumers are asked to fetch it from the mirror at
`opra.roonlabs.net` rather than from GitHub, or to host their own copy if the product is
commercial.

The code is MIT. The product and EQ data is CC BY-SA 4.0, which permits commercial use and
requires attribution in two places: a browser over the database must show the OPRA logo,
a description and a link, and any preset shown must credit its creator — more prominently
than OPRA itself. That is a constraint on the profile picker, not a licence footnote.

## The profile format

A profile is a preamp and a list of bands:

```json
{
  "author": "AutoEQ",
  "details": "Measured by Super Review",
  "type": "parametric_eq",
  "parameters": {
    "gain_db": -5,
    "bands": [
      { "type": "low_shelf", "frequency": 105,  "gain_db": -0.7, "q": 0.7 },
      { "type": "peak_dip",  "frequency": 3479, "gain_db": 6.5,  "q": 2.51 }
    ]
  }
}
```

Frequencies, gains and Q values — never coefficients. That is the same conclusion
[System audio taps](audio-taps.md) reached from the other direction: the tap's format
follows the device, the two tested devices run at 48 kHz and 44.1 kHz, and biquad
coefficients depend on the sample rate, so they have to be derived at the point the
output device or its rate changes.

Two details in the schema are worth honouring rather than reinventing.

Bands are **sorted by priority**, and software with a limited number of bands is expected
to truncate the list. A fixed ten-band equalizer is therefore not a requirement, only a
truncation policy.

The preamp is **not optional**. These are corrections dominated by cuts, and the preamp is
the headroom that keeps the sum from clipping. Across the database it runs from −18.1 dB
to +0.8 dB.

## What the corpus actually uses

This bounds the filter engine. Across all 12,594 profiles:

| Filter type | Bands |
| --- | ---: |
| `peak_dip` | 97,887 |
| `low_shelf` | 12,501 |
| `high_shelf` | 12,479 |
| `low_pass` | 5 |

RBJ peaking, low-shelf and high-shelf cover 99.995% of the corpus. The schema also allows
`high_pass`, `band_pass` and `band_stop`, and the `slope` field that the pass filters use
instead of Q, but nothing in the database exercises them.

Band counts cluster hard: 11,560 of 12,594 profiles have exactly ten bands, the rest run
from 2 to 20. Q ranges from 0.15 to 12 and centre frequencies from 8.5 Hz to 20 kHz, so
the coefficient maths has to stay stable at both ends of the audio band.

## How curves are computed

`EqualizerCore` decodes an OPRA profile or imports an AutoEq paste. An unknown or
malformed band rejects the profile. Missing band gain defaults to 0 dB. Low-pass and
high-pass filters support Butterworth slopes from 6 to 36 dB/octave and default to 12.

`AutoEq.parse` turns pasted text into a preamp and a list of bands, with no author or
other credit; those come from wherever the text was found. Blank lines and a leading byte
order mark are ignored, and every other line must be one of two kinds:

- `Preamp: <gain> dB`, exactly once. The word `Preamp` is not case-sensitive; text
  without a preamp line is rejected as a whole.
- `Filter: …` or `Filter <n>: …`, where `n` is a positive whole number. A filter whose
  next word is `OFF` is skipped, whatever follows. An `ON` filter must be one of:
  - `PK`, `LSC` or `HSC`, written `Fc <f> Hz Gain <g> dB Q <q>` and nothing more, which
    become `peak_dip`, `low_shelf` and `high_shelf`;
  - `LP` or `HP`, written `Fc <f> Hz` and nothing more, which become a 12 dB/octave
    `low_pass` or `high_pass`.

Bands keep the order of the lines, not of their filter numbers. Any amount of whitespace
separates fields. A decimal comma is accepted, but a comma followed by exactly three digits,
such as `1,000`, is rejected as ambiguous. Every other filter form is rejected, including
the shelves `LS` and `HS`, and so is a band the profile format would reject, such as a
non-positive frequency or a Q below 0.1. A rejected line fails the whole import and reports
its line number. See the
[Equalizer APO filter reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/#filter).

`EqualizerPlan(profile, sampleRate: rate)` designs Double-precision sections using
the [RBJ Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/). Every band
below Nyquist is eligible. Design frequencies stop at 0.49 times the sample rate
to keep poles away from Nyquist. At or above Nyquist a low-pass is bypassed and a
low shelf applies its broadband gain. High-pass, band-pass, band-stop, high shelf
and peak bands use the clamped frequency. The plan takes whole bands in priority
order until the next one would exceed its 24 inline sections. Compilation can report
the dropped band indices to the caller.

For a thumbnail, `EqualizerPlan.thumbnail(profile)` defaults to 48 kHz.
`magnitudeDB(at: frequencies)` returns the combined response in input order, negative
infinity at filter zeros and NaN outside DC through Nyquist. The level-matched dry
gain is the square root of the mean squared magnitude, including preamp, at the
midpoints of 256 equal logarithmic intervals from 20 Hz to the lower of 20 kHz and
Nyquist. Each bin is weighted by the power response of the two BS.1770 K-weighting
stages. This estimates the change in perceived level for pink noise while giving
sub-bass less weight. A recording’s spectrum can change the result.

## Rendering a profile

Allocate one `EqualizerProcessor` for all stream channels before starting playback.
It accepts interleaved or planar Float32 buffers of any length and keeps a separate
Double filter history for each channel. The IO thread installs a copied plan between
buffers. A profile or mode change gives the incoming chain 10 ms of live input
to build its history, then crossfades the two outputs over 20 ms. Further changes
during warm-up replace the incoming chain immediately. Once both chains are audible,
the newest request waits for the fade to finish. Compare mode passes
the dry signal at the plan’s K-weighted pink-noise gain, and off mode passes it at unity.

A flowing sample-rate change uses the same crossfade. Only an explicit stream
restart (`reset()`) discards both the audible transition and the old history and
fades in over 5 ms. The 30 ms transition controls the mix. Low-bass, high-Q bands
can take hundreds of milliseconds or longer to settle as the new filter rings up.
In the synthetic bass-switch probes, high-frequency artefacts stayed at least 117 dB
below the reference peak.

A non-finite input or output silences the affected sample, clears that channel’s
histories and starts the same fade for that channel. The processing call reports the
fault to its caller while the other channels continue.

## Variants are products, not settings

OPRA models the state a headphone is worn in as part of its identity:

```
sony::wh_1000xm4                 beyerdynamic::dt_770_pro
sony::wh_1000xm4_anc_on          beyerdynamic::dt_770_pro_32_ohm
sony::wh_1000xm4_anc_off         beyerdynamic::dt_770_pro_worn_earpads
                                 beyerdynamic::dt_770_pro_dekoni_hybrid_earpads
```

This answers a question left open in [System audio taps](audio-taps.md): a published
correction targets the raw driver response, so applying one on top of a headset's own
tuning corrects twice, and a profile has to record what the headset was set to. Upstream
has already solved it by making the setting part of the product. Noise cancelling switched
on is a different product, not a modifier on one.

So a profile neqMac takes from OPRA records the product id it came from, not a headphone
name.

Some headsets will say which variant they are. [Reading headset state](headset-control.md)
measures a headset reporting its own noise cancelling mode, and pushing a notification when
it changes.

## Where the data comes from

OPRA's initial ingest was [AutoEq](https://github.com/jaakkopasanen/AutoEq), which supplies
10,784 of the 12,594 profiles under the author `AutoEQ`; `oratory1990` contributes 1,342
directly. AutoEq remains the upstream measurement project and is MIT licensed, but its
`results/` tree was last refreshed in July 2025 and its README now directs users to
autoeq.app rather than to the repository.

AutoEq's text output is nonetheless the format people paste between applications:

```
Preamp: -5.1 dB
Filter 1: ON LSC Fc 105 Hz Gain -3.0 dB Q 0.70
Filter 2: ON PK Fc 6430 Hz Gain -4.2 dB Q 0.97
```

`PK`, `LSC` and `HSC` map onto `peak_dip`, `low_shelf` and `high_shelf`, so importing a
pasted block is a small parser over a format neqMac already stores, described in
[How curves are computed](#how-curves-are-computed). It is worth supporting
as an import path and not worth adopting as the storage format.

## Fetched, not bundled

None of this is built yet; it is milestone 4 in [Equalizer](equalizer.md#milestones).

The dump will be fetched from the mirror the first time the catalogue is browsed, cached,
and revalidated with a conditional request at most weekly. Bundling it was rejected: it is
a large file to carry in the app and the repository, it would put CC BY-SA data inside an
MIT repository, and a bundled snapshot goes stale between releases.

Fetching gives up browsing before the first download, so nothing else will depend on the
network. An assignment will not point into the catalogue: it stores a copy of its profile,
credit included, and keeps working offline and after the catalogue changes or drops the
entry. Only browsing will need the network, and a stale cache will still browse.

## Nobody picks for the user

When a product has several profiles, none is pre-selected. The DT 770 Pro carries sixteen,
each from a different measurement of the same headphone, and nothing in the data says which
is better — only who measured it. Ranking by author would present a preference as a fact.
The picker will group profiles by author and measurement and overlay their curves, and the
user chooses. How that and the rest of the equalizer fit together is in [Equalizer](equalizer.md).
