# PodCraft — rules taken from the original

Read from `/Applications/Feedcast.app/Contents/MacOS/Feedcast` (version 4.3). Ghidra could not run on this Mac
(no native decompiler built), so functions were read with the built-in lifter. Our code was written from these
notes, not copied.

## Player

| Rule | Value | Where |
|---|---|---|
| Transport order | Previous Chapter · Back 15 · Play/Pause · Forward 15 · Next Chapter | PlayerTransport view, `0x10046d2e8` |
| Skip back | 15 s ("Back 15 Seconds", symbol gobackward.15) | `0x10046d2e8` |
| Skip forward | 15 s ("Forward 15 Seconds", symbol goforward.15) | `0x10046d2e8` |
| Play/Pause shortcut | Space, no modifiers | `0x10046d2e8` (KeyEquivalent.space) |
| Previous/next chapter disabled when none | yes ("There is no next chapter.") | `0x1003878bc` |
| Speed panel | "Playback Speed" headline, slider between tortoise and hare | PlayerSpeed, `0x10045e08c` |
| Speed range | 0.5× – 3.0× | doubles at `0x10095fe90` used by `0x10045e08c` |
| Speed panel width | 320 (estimated use of the 320.0 stored at `0x10095fe88`) | estimated |
| Speed step / presets | 0.05 / 0.8, 1.0, 1.2, 1.5, 2.0 | estimated (not found) |
| Previous chapter restarts current one when more than | 3 s in | estimated |
| Lifetime metrics | listenedSeconds, speedSavedSeconds, episodes finished/processed, sponsor time removed | field names in the reflection strings |

## Episodes kept by a feed

Three choices ("Keep episodes by", EpisodeEditorView `0x1002571f8`):
- keep every episode ("kept until you delete it manually"),
- delete N days after it was added,
- keep the newest N per feed ("deleted once its feed keeps N newer episodes").
Each feed can override the app setting; each episode can be kept forever.
Defaults from the app-storage registration (`0x10022e8d8`): autoDeleteKeepCount = 10, autoDeleteRetentionDays = 30,
defaultAutoDeleteEnabled = true, autoDeletePolicy = its first case — we take that as "Delete after a set time" because
the picker lists it first (**inferred**). Other defaults there: autoSyncIntervalMinutes = 30 (PodCraft checks for new episodes
every 30 minutes), removeSponsorBlockSegments = true, generateChaptersEnabled = true, removeChapterSponsors = true,
defaultFeedLocal = false, sponsorRefreshWindowHours = 6 and youtubeRSSDelayMinutes = 180 (not used: PodCraft has no YouTube channel import).

## Processing pipeline

download → SponsorBlock → transcript → AI chapters + sponsor finding → cut → ready
(stage messages "Queued episode processing.", "Queued transcription.", "Queued chapter generation.", "Queued sponsor cuts." in `0x1003878bc`).

- **SponsorBlock** (`0x10041ef84`): GET `https://sponsor.ajay.app/api/skipSegments?videoID=…&categories=[…]&actionTypes=["skip","mute"]`.
  Nine categories: sponsor, selfpromo, interaction, intro, outro, preview, music_offtopic, filler, hook.
  Bad input message: "Enter a valid YouTube URL or 11-character video ID."
  Which categories are on by default: **estimated** (sponsor, selfpromo, interaction).
- **Chapters / ads**: the original ships a prompt (ChapterPrompt.txt): numbered transcript lines, chapter = first line
  number, first chapter at line 0, short titles in the hosts' language, every ad its own chapter "Sponsor: <what>",
  a new chapter after each ad. We wrote our own instructions with the same rules.
  Engines: original uses an on-device engine and Gemini with your key (`generativelanguage.googleapis.com/v1beta/models/`, `0x10081a05c`).
  Ours: Apple Intelligence (Foundation Models) on this Mac, or Gemini (default model `gemini-2.5-flash`, **estimated**).
- **Transcript**: original uses its own on-device models; ours uses Apple's SpeechAnalyzer/SpeechTranscriber on this Mac.
  Recogniser phrases are joined into sentences, then into blocks of at least ~8 s that the AI points at (estimated); on-device requests read 30 blocks at a time (estimated, for the small context).
- **Cut**: sponsor ranges (SponsorBlock + AI) are merged and removed from the audio; chapter and transcript times move to match.
- Chapter rule kept from the editor: "Chapter start times must be unique." (`0x1003878bc`).
- The per-show chapter-title filter is covered by `PodCraft --chapter-filter-test <audio file>`: it runs the real
  composition export, removes the matching chapter, remaps later chapters and transcript lines, and checks duration.

## Hosting

- Feed listing format follows RSSGenerator (`0x10005a158`): itunes, content, atom and podcast namespaces, `podcast:guid`,
  `itunes:type`, `itunes:explicit false`, `itunes:block yes` (keeps it out of directories).
- Audio always streams from this Mac; Apple Podcasts reads feeds from this Mac directly; other apps need the listing
  at a web address ("Most podcast apps fetch feeds from their own servers…", `0x10029c7a8`).
  The original uploads listings to its developer's own service (uploads.feedcast.org); PodCraft instead lets you give
  your own upload address (HTTP PUT). Port 8743 is **estimated**.
- Subscribe links: `castro://subscribe/`, `pktc://subscribe/`, `overcast://x-callback-url/add?url=` (`0x10010d500`);
  Apple Podcasts through `podcast://`.
- "Keep new feeds local only by default" setting (`0x10032b62c`).
- OPML import / export (`0x100089674`, `0x10008a7c8`).

## Modes (the person's request, not in the original)

Manage mode: every editing tool (feeds, shows, episodes, chapters, settings, downloads).
Listen mode: no editing — Listen Now, shows, feeds, search, transcript, and a large player.
Toggle: toolbar switch, ⌘1 / ⌘2, ⇧⌘M. The chosen mode is remembered.

## Shows on their own (the person's request)

- Adding a show adds it alone; putting it into a feed is optional (feed picker on the show page or in the feed).
- Every episode a show lists is shown. Only the newest N are downloaded and processed (N = 1 by default, set per
  show and for new shows in Settings). Older automatic downloads are removed when newer ones arrive unless half-listened
  or kept; others can be downloaded by hand or streamed.
- Feed keep rules now remove old downloads only; the episodes stay listed.
- Show and episode cover pictures are downloaded from the feed (itunes:image) and served to podcast apps.
- Video episodes (video enclosures, .mp4/.m4v/.mov) play with their picture; their sound is transcribed and sponsor cuts keep the video.
- No sample library: the app starts empty; earlier sample feeds/shows are removed on first launch.
