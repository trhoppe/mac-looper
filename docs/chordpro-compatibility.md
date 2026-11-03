# ChordPro compatibility

Audited 2026-11-02 against the official [file-format introduction](https://www.chordpro.org/chordpro/chordpro-introduction/),
[directive catalog](https://www.chordpro.org/chordpro/chordpro-directives/), and
[chord specification](https://www.chordpro.org/chordpro/chordpro-chords/).

Mac Jams supports the common lead-sheet subset of ChordPro. **It is not yet a
complete implementation of every ChordPro 6 feature.** The JSON library is a
JustChords-compatible container; each song's `rawData` holds ChordPro source.
The editor saves that source, including directives it cannot render. ChordPro
preamble metadata is authoritative for the song list, chart, editor and initial
looper BPM. The old JSON detail fields are compatibility copies, not a second
source of truth. After a backed-up one-time migration, reading a chart does not
rewrite the library. No changes to audio timing or routing are
part of this audit.

## Supported in the reader

| Feature | Behavior |
| --- | --- |
| `[chord]` before a lyric syllable | Chord above the following text; adjacent chord-only tokens retain visible spacing. Arbitrary labels are displayed without requiring a known chord name. |
| Standard chord symbols | ASCII/Unicode sharps and flats, suffixes, and slash chords display verbatim at zero transposition. The existing saved JSON transpose shifts A–G roots/bass notes; it is a relaxed root-based algorithm, not a complete strict chord validator. |
| Roman/Nashville/custom labels | Displayed verbatim. No conversion between chord systems, German/Dutch note-name transposition, or automatic chord-name correction. |
| `[*annotation]` | Removes the leading asterisk for display; preserves the text when transposing. The source asterisk remains in the editor. |
| `\[` / `\]` / `\\` in lyrics | Literal brackets/backslash. Malformed unclosed chord brackets remain visible. |
| `#` source remarks | Hidden outside explicit tab blocks. |
| Metadata directives | `title/t`, `sorttitle`, `subtitle/st`, `artist`, `sortartist`, `composer`, `lyricist`, `arranger`, `copyright`, `album`, `year`, `key`, `time`, `tempo`, `duration`, `capo`, `tag`, and arbitrary `{meta: name value}` are parsed. Repeated values are retained. |
| Metadata in the chart header | The ChordPro preamble supplies title, artist, key, capo, BPM, meter and duration; subtitle is also displayed. Song sorting and the selected song's initial looper BPM use these same values. Playlist-specific settings remain temporary presentation overrides and never rewrite the base chart. Later key/tempo/time/capo directives appear as local chart instructions; they do not control audio transport. Other metadata is parsed without adding header fields. |
| `duration` | Seconds such as `268` display as `4:28`; existing readable times stay readable. |
| Section environments | `start_of_verse/sov`, `end_of_verse/eov`, `start_of_chorus/soc`, `end_of_chorus/eoc`, `start_of_bridge/sob`, `end_of_bridge/eob`. Light-gray headings; source blank lines control section spacing. |
| Section labels | Colon or whitespace arguments, legacy plain labels, and `label="Verse 1"` / single-quoted attributes. `\n` in a quoted label creates a line break. |
| `{chorus}` / `{chorus: Final}` | Repeats the last completed chorus, optionally replacing its heading. Does not operate audio transport. A missing preceding definition produces a diagnostic. |
| Comments | `comment/c/highlight` as plain secondary text; `comment_italic/ci` italic; `comment_box/cb` boxed. Comment text is literal: no metadata substitution or inline markup expansion. |
| Explicit tab blocks | `start_of_tab/sot`, `end_of_tab/eot`, with optional label. Every intervening character/line is literal, including `#` remarks, blank lines, brackets, and brace directives. Only the tab end directive closes the block. Tabs stay grouped, monospaced, full width, horizontally scrollable. |
| Application extensions | Unsupported `x_...` directives are ignored without warning, as the specification requests. Source remains saved. |
| Existing JustChords conveniences | Short plain headings ending in `:` and unmarked guitar string tab rows still work. These are app heuristics in addition to formal ChordPro syntax. |

Directive arguments may be separated by a colon, whitespace, or both. The reader
normalizes LF, CRLF and CR line endings without rewriting stored source. The
native editor shares directive/tab recognition with the reader.

## ChordPro-backed storage and editing

Each song's `rawData` contains a complete lead sheet, for example:

```chordpro
{title: Example song}
{artist: Example artist}
{key: Am}
{tempo: 120}
{time: 4/4}
{duration: 3:45}
{capo: 2}
{start_of_verse: label="Verse 1"}
[Am]Example words [G]here.
{end_of_verse}
```

The editor's detail fields are conveniences for that preamble. They update its
directives, and typing directives directly updates the fields immediately.
`{t ...}` and `{meta: tempo ...}` work too. Clearing an optional directive removes
its compatibility copy, so an old JSON value cannot reappear on the next launch.
Cancel still leaves the file unchanged. Metadata in later sections is kept
separate from the preamble, preserving local musical instructions.

The first launch coordinates a read-modify-write on the **own** library. It seeds
missing preamble values, converts old plain headings to labeled verse/chorus/
bridge environments, wraps unmarked tab rows, and sets each converted song's
`macJamsChordProVersion` to 1. It does not change lyrics, chord symbols, saved
transposes, IDs, playlist entries, dates, trash, or unknown fields. Compatible
JSON copies of the core metadata are updated. Existing source directives take
precedence. An exact previous-file backup with a `library-before-chordpro-`
prefix is required before the atomic replacement; failed or repeated conversions
do not replace the file. The original JustChords container remains protected.

Concurrent edits merge independently by preamble directive and musical body.
Two devices changing different details can merge; conflicting changes to the
same directive or to the body keep the local draft open. Raw source and detail
fields cannot silently diverge. Reading and conversion are off the audio thread.

## Not yet implemented

These features are **preserved in source, not interpreted**. Unsupported
directive names appear below the chart with an explicit “Not rendered” message.
Inline markup and metadata substitutions also produce a diagnostic and remain
visible as literal source text. An unsupported environment may show its body as
ordinary text; it is not rendered as the intended notation.

| Family | Remaining work |
| --- | --- |
| Chord diagrams | `define`, `chord`, `diagrams`, `grid/g`, `no_grid/ng`; custom tunings/fingerings and diagram generation. |
| Chord grids | `start_of_grid/sog`, `end_of_grid/eog`; cell shapes, repeats, strum symbols, and grid-specific transposition/layout. |
| In-source transposition | `{transpose: ...}`, nested/reset transpose state, local modulation and derived key metadata. Existing saved JSON transposition is separate. |
| Inline markup | Pango-style spans, bold/italic tags, symbols, struts, bookmarks and links. |
| Substitutions | `%{metadata}` interpolation, chord-property expansions and computed metadata such as `_key` / `key_actual`. |
| Embedded resources/notation | `image`, ABC, LilyPond, SVG and textblock delegated environments. No external programs or resources are loaded. |
| Printing/layout controls | `new_song/ns`, page/physical-page breaks, `column_break/colb`, `pagetype`, `titles`, `columns/col`, and font/size/colour directives. Mac Jams uses its responsive reading layout and user font/column controls. A multi-song source is not split into library entries. |
| Conditional directives | Instrument/user/metadata selectors such as `comment-guitar` and conditional environments. |

Matching every formatting choice of the reference PDF renderer is separate from
recognizing ChordPro source. The [official directive documentation](https://www.chordpro.org/chordpro/chordpro-directives/)
explicitly leaves formatting decisions to each application. Musical features
such as grids and modulation still need actual implementation before we can
claim support.

## Library audit and validation

The pre-conversion own library was inspected read-only: **38 songs, 71 distinct
bracket labels, no brace directives**. A dry-run conversion checks title, artist,
BPM, meter, duration, saved keys/transpositions, chord/lyric fragments, tab rows and
section labels across every song. Its chord tokens all survive the reader pipeline.
This verifies the actual imported data paths, not all possible future ChordPro
files. Source labels that are not conventional chords are kept as supplied.
No private chart text is copied into this repository.

Tests cover official syntax variants, repeated metadata, label attributes,
chorus recall, literal tab content, annotations, comment styles, unsupported
features, duration, escapes, and existing lyric/chord layout behavior. An optional
read-only integration audit can be run locally:

```sh
MAC_JAMS_CHORDPRO_AUDIT_LIBRARY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Mac Looper/library.json" swift test
```

The environment variable is optional; without it only that private-library test
is skipped. All synthetic fixtures remain independent of the user's library.
