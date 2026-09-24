## 1.4.15 - 2026-09-20 (build 147)
Long titles scroll on the TV, and the letter g keeps its tail.

**Cast**
- Title, artist and album on the TV are one line each. Text too long for
  its row now scrolls: a short hold, a steady glide left, a seamless loop,
  the same feel as the app. Text that fits stays centred and still. Long
  titles used to wrap onto a second line and push the layout down; long
  album names were cut off with an ellipsis. The lyrics-view header does
  the same.
- Descenders (g, y, p) are no longer clipped on the TV's text rows.

**App**
- Scrolling titles no longer slice the bottom off letters like g. The
  scrolling-title box was sized from a bare measurement that ignored the
  app's line height and your system font size, so it came out a few pixels
  short. One widget, so the phone, desktop, TV layout and mini player are
  all fixed.

## 1.4.14 - 2026-09-15 (build 146)
Claude can add to a cast you started, and Frankie got his stripes back.

**Cast**
- Ask Claude to queue a track while you're casting from the phone and it
  lands in your queue instead of replacing your cast. The backend now
  joins the running session as a guest; the request rides through the TV
  to the phone, which inserts it for real, re-sends the up-next list and
  acks. Skip, pause, resume and "what's playing" work the same way. The
  TV shows the usual "added up next, by Claude" toast. "Play something"
  still replaces the cast, on purpose.
- If the phone doesn't answer within a few seconds you get an honest
  "the owner didn't respond" instead of a takeover.

**Artist page**
- Van Halen's header is a Frankenstrat again: bold black slashes at any
  angle, thinner white ones crossing them, red showing through. The old
  layout squeezed 23 fat stripes into a phone width and left no red.

## 1.4.13 - 2026-09-13 (build 145)
Every release an artist ever put out, on the artist page.

**Artist page**
- The Discography is now the default view: tabs for Albums, EPs, Singles,
  Compilations, Live, Bootlegs and Other, in release order, with an
  owned/total count on each tab. Albums you have are the usual tiles;
  the rest are greyed out with their Cover Art Archive thumbnail.
- Tap a greyed album to open it: cover, year, type, MusicBrainz tracklist,
  and three ways to get it - Search Prowlarr, Search YouTube, or Import
  files (pick files, or a whole folder on desktop). Import files uploads
  them to the NAS and opens the normal import page with the artist,
  album, year and MusicBrainz IDs already filled in.
- Ownership is matched by MusicBrainz release-group ID first, so imports
  and merges light up the right tile immediately; older rips fall back to
  a title match that ignores edition suffixes.
- The release list is cached on the server per artist, fetched in the
  background the first time you open an artist (a spinner shows until it
  lands), and refreshed monthly or with the refresh button.

## 1.4.12 - 2026-09-12 (build 144)
The phone can join a cast it didn't start.

**Cast**
- Tapping a TV in the cast picker now asks it what's playing before
  launching anything. If NASRadio is already casting there, from Claude
  or from another phone, the app joins that session instead of replacing
  it. The TV keeps playing, the app shows the TV's current song and
  follows along as the queue advances, and play, pause, next and previous
  drive that queue.
- Two new buttons in the picker while joined: "Take over with my queue"
  does what the picker used to do on every connect, and "Leave (TV keeps
  playing)" drops the phone off without stopping the TV. The red
  Disconnect still stops the TV.
- The idle "Ready to cast" rings on the TV no longer stutter: they were
  animating a colour the GPU can't composite. The scrubber's playhead now
  fizzles and throws sparks on every track, not just the special skins,
  and its glow no longer clips flat at the bar ends.

**Library (server side, no app change needed)**
- Genres. Every album and artist now carries its MusicBrainz genres,
  filled in by a backfill that runs in the background. Albums MusicBrainz
  has no votes for inherit their artist's.
- Artist images are fetched automatically when a new artist is imported,
  and the album-art auto-pick uses the same digital-first, US-first
  ranking as the manual picker.
- Essentia analysis and batch transcoding are back: both sidecars now run
  on the NAS next to the backend. Nothing had been analyzed since July 9.

## 1.4.11 - 2026-09-11 (build 143)
YouTube album imports that curate themselves.

**YouTube**
- Search for an album right in the YouTube screen ("Artist Album") and
  get playlists back, label ones first. Tap one and it loads. No more
  opening YouTube and copying share links.
- Pasting a full watch URL is safe now. Anything with a playlist in it
  gets stripped to just the playlist, so the 300-video Mix stays out.
- When a playlist loads, every video is checked against the album's
  MusicBrainz track lengths. Videos from the label, or within 10 seconds
  of the album cut, pass. Anything longer or shorter, or with "live",
  "cover" or "remix" in the title when the album track isn't, is a
  suspect.
- Suspects get replaced automatically with a clean upload: YouTube and
  YouTube Music are searched, label audio that matches the album length
  wins, other artists' tracks with the same name are ruled out. Replaced
  rows show a green badge; tap it to see the alternatives, revert, search
  again, or paste your own URL. Suspects with no clean match load
  unticked with an amber badge and the same sheet.
- Bulk tagging starts with the real artist, album, year and track titles
  from MusicBrainz instead of the uploader name and "YouTube Downloads".

**Downloads**
- "Try YouTube Instead" on an empty Prowlarr search now runs the search
  for you. The same button shows up as a banner when results are thin:
  fewer than three, or none with a seeder.

## 1.4.10 - 2026-09-11 (build 142)
Seeder counts you can trust. The app now asks the trackers, not the indexer.

**Downloads**
- Tapping Download on a search result now checks the swarm first
  ("Checking..."). The backend scrapes every tracker on the link, plus
  the public ones, and reports what they say right now. If nobody is
  seeding, or no tracker answers, you get "No seeders found. Add anyway?"
  before it lands in Transmission.
- Search result badges say `~5 seed` for the indexer's number, which is
  a stale scrape and often wrong, and switch to `1 seed ✓` once the
  trackers have been asked. Same rule for leechers.
- The Downloads screen's seeder count is the largest any single tracker
  reports instead of the sum. Three trackers each seeing one seeder used
  to show "3 seed"; it's one seeder.
- Download cards always show connected peers now. "0 peers" turns red on
  a torrent that's actively trying, because that's the number that
  proves nobody has shown up.
- The Downloads screen only lists torrents in NASRadio's own download
  folder. Sonarr and Radarr's movie and TV torrents share the same
  Transmission and used to appear here, and worse, auto-stop and Clear
  Completed used to act on them.

**Cast**
- Waking the room uses the Denon's main-zone power instead of system
  power, so Zone 2 stays off and the receiver can actually reach
  standby afterward.

## 1.4.9 - 2026-09-01 (build 141)
Navigation, rebuilt. The back button finally knows where you came from.

**Navigation**
- One shared bottom bar (phone) and rail (desktop) for the whole app.
  The 16 copied bars that every detail page painted for itself are gone,
  so the highlighted section is always the one you're actually in.
- Each section - Home, Library, Search, Playlists, Favorites - now keeps
  its own page history and scroll position. Drill three levels into
  Library, hop to Search, come back, and you're still on that album.
- Tapping the section you're already in returns it to its top page.
- The Android back button walks back through the section you're in,
  then to the previous section you visited, and only leaves the app
  from Home. Mouse back/forward buttons and the browser-back key do
  the same thing. Desktop rail has back and forward arrows now.
- Opening Now Playing no longer throws away the page you were on.
  It slides up over everything and closing it lands you right back.
  Artists, albums and playlists opened from the player open in the
  section beneath it, bar intact.
- Breadcrumbs stopped guessing. The first crumb goes to the top of the
  section; the artist crumb goes back to the artist page if it's in your
  history, or opens it if it isn't (Search → album → tap the artist).
- Sections slide and fade into place when you switch, on phone and
  desktop alike.

## 1.4.8 - 2026-09-01 (build 140)
The cover is the hero again, and the artwork picker stopped taking coffee breaks.

**Album page**
- On phones the cover now fills about three quarters of the screen width
  instead of the 175px postage stamp it shrank to in July. The hero
  height follows the cover instead of a fixed number, so no more dead
  gradient between the art and the title.
- The cover casts a soft glow in the album's dominant color, plus a
  proper drop shadow, and the background glow sits behind it instead of
  off to the left where the old layout used to put the cover.

**Artwork picker**
- Searching MusicBrainz went from up to a dozen throttled calls to one or
  two. A typical search comes back in 2 to 7 seconds instead of a minute.
  Same results, same ordering.

**Cast**
- Long queues no longer stall after track 11 on the TV. The backend now
  tops up the receiver's up-next list every time a track changes, and
  refreshes the media token with it so multi-hour queues outlive it.
- Cast status now reports what's playing (title, artist, album, position)
  and the next five tracks, so Claude can tell you what's on.

## 1.4.7 - 2026-08-25 (build 139)
Made the MusicBrainz modal presentable.

**MusicBrainz**
- Polished the submission modal: sectioned layout, proper field styling,
  numbered tracklist chips - and the top of the form is no longer cut off.

## 1.4.7 - 2026-08-25 (build 138)
If MusicBrainz doesn't know your album, introduce them.

**MusicBrainz**
- New on the Import Album screen: "Not listed? Add it to MusicBrainz."
  Opens a submission form prefilled from your actual files - title,
  artist, tracklist with durations, barcode, label, release date, even
  the store link for web rips. Edit anything, hit continue, and the
  MusicBrainz release editor opens with it all staged; one click there
  submits it under your account, and NASRadio automatically captures
  the new release ID on the way back.
- MusicBrainz results now show a "See more" button instead of silently
  stopping at five.

**Updates**
- Fixed the empty terminal window that appeared during every desktop
  update and sat there forever until you closed it. It was a wait loop
  suffocating in a console-less window; updates now run in a real
  console that shows progress and closes itself. (You'll see the old
  window one final time while updating TO this version.)

## 1.4.6 - 2026-08-24 (build 137)
Owning the album is not the same as owning the mix.

**Search**
- The "IN LIBRARY" badge is now mix-aware: when a search result is a
  surround or Atmos release but your library copy is stereo-only, it
  shows an amber "STEREO IN LIBRARY" badge instead of green - so you
  can tell at a glance that this is an upgrade, not a duplicate.

## 1.4.6 - 2026-08-24 (build 136)
Your library knows which albums surround you now.

**Surround & Atmos**
- Casting now delivers real surround sound: Dolby Atmos albums pass
  straight through to the receiver, and multichannel SACD-style rips
  (Piano Man, Dark Side of the Moon, and friends) cast as Dolby
  Digital Plus 5.1 instead of being folded down to stereo.
- New ATMOS and 5.1/5.0 badges throughout the app - track lists,
  Now Playing, the queue, search, playlists, and the mini player all
  show which recordings are spatial, matching the badges on the TV.

**Search**
- New quality filters on the download search: Lossless, 24-bit+,
  Surround, and No MP3/AAC. They remember your picks between
  sessions, and a counter shows how many results a filter hid.
- Search results now carry quality badges (format, bit depth, sample
  rate, source) parsed from each release, plus surround/stereo tags.
- Prefix a search with `surround:` to hunt multichannel releases
  directly - stereo-tagged results drop out and surround floats up.

**Library**
- Fixed 50+ tracks that were filed under the wrong album (compilation
  swaps, double imports, stray singles) - queues no longer play
  impostor copies or repeat tracks.

## 1.4.5 - 2026-08-13 (build 134)
Exorcised the phone's mystery static.

**Casting**
- Fixed the phone occasionally blasting static while casting: a
  connectivity blip (or reopening the app) could trick the app into
  starting local playback of the station on top of the cast, and the
  phone's decoder turned it into white noise with no working stop
  button. Local playback is now completely disabled while casting  - 
  the moment a cast connects, the phone's player is fully released.

## 1.4.5 - 2026-08-13 (build 133)
Stations on the TV, without the wait.

**Stations**
- Casting a station now goes through the server's new relay, which keeps
  a rolling buffer of the broadcast and hands the TV a head start. First
  play of a quiet station takes ~20 seconds; after that (and for any
  station played in the last 10 minutes) playback starts instantly.
  This fixes stations that used to take minutes to start - or never
  started at all.

## 1.4.5 - 2026-08-13 (build 132)
Discovery is now optional.

**Casting**
- New "Connect by IP address" option in the cast picker - connects
  straight to the TV even when it's invisible to network scans.
  Connect once and the address is remembered forever.

## 1.4.5 - 2026-08-13 (build 131)
For the night the TV played hide-and-seek.

**Casting**
- Recent devices now remember their network address. If your TV doesn't
  show up in a scan (it happens - TVs get weird), its entry offers
  "tap to connect directly" instead of a useless Offline row.

## 1.4.5 - 2026-08-12 (build 130)
🎉 Party Mode arrives (host side).

**Party Mode**
- New party button in the Queue screen: start a party and a QR code +
  join code appear - on your phone, and on the TV if you're casting.
- Guests who join can search your library and add songs to the queue;
  their picks show up marked "added by ‹name›".
- Ending the party instantly locks all guests out.
- (Guest-side app screens land in the next build - for now guests join
  through the web link.)

## 1.4.5 - 2026-08-12 (build 129)
The TV learns to DJ for itself.

**Casting**
- The queue no longer dies with the phone: the app hands the TV its next
  ten tracks, so if a song ends while the app is closed, the phone is
  asleep, or the Wi-Fi hiccups, the TV just plays on through the queue.
- When the app comes back (reopen or reconnect), it syncs to whatever
  the TV advanced to - no more snapping back to an old song.

## 1.4.5 - 2026-08-12 (build 128)
One for the night owls.

**Casting**
- Swiping the app away no longer orphans your cast: the TV keeps playing
  (as before), and reopening the app now silently reconnects to the
  running session - position, play state, and controls all pick up where
  they were. If the song ended while the app was closed, pressing play
  resumes the queue on the TV.

## 1.4.5 - 2026-08-12 (build 127)
Two more station wins.

**Stations**
- Stations served over plain HTTP now actually make sound on the TV  - 
  their streams are relayed through the server's secure connection (the
  TV's browser silently blocks insecure audio, which is why some
  stations "played" in total silence).
- The station search now remembers your last 8 searches as tappable
  chips under the search box. Long-press a chip to remove it, or Clear
  to wipe them all.

## 1.4.5 - 2026-08-12 (build 126)
Radio station polish, hot on build 125's heels.

**Stations**
- Casting an AAC/AAC+ station to the TV now actually plays - the cast
  used to assume every station was MP3 and hand the TV the wrong decoder.
- The track playing on a station now shows on the TV when you tune to a
  station mid-cast (it used to get wiped by the station name until the
  broadcast changed tracks).
- Station format badges show a clean "RADIO" (or the real codec) instead
  of URL gibberish like "202:9073/".
- Station search now tests each stream from your own network before
  showing it, so dead stations get filtered out of results.

## 1.4.5 - 2026-08-12 (build 125)
The great casting bug hunt. Root cause of the "cast dies after a few songs"
mystery found and fixed (it was the phone's battery saver cutting the app's
network, not the TV or the Wi-Fi).

**Casting**
- The app now asks Android for unrestricted background use when you cast, so
  Doze can't silently cut the cast's network mid-session.
- If a cast still drops, auto-reconnect now keeps trying for up to 30 minutes
  (was ~5) and checks the TV is reachable before each attempt - playback
  resumes where it left off as soon as the connection returns.
- Pausing from the TV remote or the phone actually pauses now (a stale-state
  toggle bug was instantly un-pausing it).
- Disconnecting the cast from the phone hands playback straight back to the
  phone, playing, from where the TV left off.
- After a drop or killing the cast from the TV remote, the phone UI no longer
  pretends the music is still playing.
- Radio station artwork finally shows on the TV.
- Songs without a cached waveform now get their real waveform pushed to the
  TV once it finishes generating (no more flat bar forever).

## 1.4.5 - 2026-07-21 (build 124)
Bug fixes.

- Fixed the album page cover art overlapping the album title.
- The album type (Single / EP / Compilation / ...) now shows on the album page and updates immediately when you change it.
- Fixed a bug where opening the Last.fm stats screen could bog down the whole app.

## 1.4.4 - 2026-07-21 (build 123)
A batch of library and Last.fm improvements.

**Artwork**
- The album artwork picker now also pulls covers from Spotify and the original YouTube thumbnail, so obscure releases that aren't on MusicBrainz can finally get art.

**Release types**
- Your artist pages now sort releases by type: filter between Albums, Singles, EPs, Compilations, and Live.
- New "Change Type" option in the album menu to correct a release's type.
- One-song YouTube rips are recognized as Singles instead of fake full albums.

**Last.fm**
- New in-app Last.fm screen: top artists and tracks (7 days to all-time), recent scrobbles, and your profile totals. Settings -> Last.fm -> View My Stats.
- New per-album / per-artist "Don't scrobble" toggle, so personal recordings stay off your Last.fm profile.

**Fixes**
- Fixed the album header being scrunched under the status bar on tall phones.

## 1.4.3 - 2026-07-15 (build 122)
Your music has a new home. The whole backend now lives on the new TrueNAS
server, right next to the music files - no more network share between the
app and your library.

**Server move**
- **New server address** - the app now finds the server at its new home on
  the local network automatically. If you'd previously set a custom server
  address in the login-screen gear, you can clear it; the built-in default
  is correct again.
- **Faster local playback** - songs are read straight off the server's own
  disks instead of over a network share, which eliminates the occasional
  long pause before a track started.
- Under the hood: the backend now runs in Docker on TrueNAS (PostgreSQL 17,
  supervised, starts with the server), the music library database was
  migrated to the new storage layout (41,806 paths), and artwork + waveform
  caches moved over intact.

## 1.4.3 - 2026-07-10 (build 121)
Ever hear a great song on a station and lose it forever? Never again.

**Stations**
- **Previously Played** - While a live station is playing, the queue button
  opens the station's play history instead: the last ~30 tracks with artwork
  and "how long ago" times, auto-refreshing as the station rotates. Works on
  every station whose broadcaster publishes history (all Nightride FM
  stations, SomaFM); others show a friendly empty state.
- Tracks you already own are marked and play instantly on tap. Tracks you
  don't get one-tap **Search on Prowlarr** (opens pre-filled and searching)
  or **Search on YouTube**.
- Library matching runs server-side with the same fuzzy + artist-alias
  smarts as the music search, so "A & B feat. C" credits still find your
  copy.

## 1.4.3 - 2026-07-08 (build 120)
Casting a radio station finally looks alive on the TV.

**Casting (stations)**
- The TV now shows the actual track a station is broadcasting the moment you
  start casting - title, artist, and the track's artwork (when the station
  provides it), with the artwork doubling as the screen background.
- Live streams get a proper LIVE indicator instead of a broken scrubber and
  the infamous "Infinity:NaN:NaN" duration. Elapsed listening time stays.

## 1.4.3 - 2026-07-07 (build 119)
Pristine desktop playback - fixed the warble on high-resolution files.

**Playback (desktop)**
- Fixed a wavering/warbling sound on desktop playback, most audible on
  vinyl-ripped and other high-resolution FLACs. A time-stretching audio filter
  was silently active even at normal speed; playback at 1.0x now bypasses it
  entirely for bit-clean output. The speed control and vinyl mode still work
  exactly as before. Phones were never affected.

## 1.4.3 - 2026-07-06 (build 118)
Live station track everywhere it should be - plus smoother back navigation.

**Stations**
- The currently-playing track now updates live on the full now-playing screen
  (fullscreen included), on the lock screen / Android Auto, and when casting to
  a TV - following the broadcast as songs change, not just inside the app.

**Navigation**
- Fixed the mouse back button jumping straight to Home - it now steps back one
  screen (or one tab) per press.

## 1.4.3 - 2026-07-05 (build 117)
Live "now playing" for radio stations - see what's actually on the air.

**Stations**
- The now-playing screen and mini player now show the CURRENT track a station is
  broadcasting (title + artist), updating live as songs change - pulled straight
  from the broadcaster (Nightride, SomaFM, and most Icecast/SHOUTcast stations).
- Tapping a station's artwork now shows its logo instead of a placeholder.
- The station name and genre stay visible for context, and "Playing from Stations"
  links back to the Stations page.

## 1.4.3 - 2026-07-05 (build 116)
Station & podcast artwork now shows up everywhere it should.

**Stations**
- The mini player shows the station's artwork instead of a blank placeholder.
- The full now-playing screen uses the station's artwork for its glassy blurred
  background, instead of falling back to the plain blue.

**Podcasts**
- Fixed the now-playing background for podcasts too - in the standard layout it
  was also falling back to plain blue; it now uses the podcast's artwork.

## 1.4.3 - 2026-07-02 (build 115)
Station favorites, and songs always play - even brand-new imports.

**Stations**
- **Favorite a station** - the ♥ on the now-playing screen works for live stations now (and saves the station to your list automatically if it wasn't already).
- **Stations tab in Favorites** - your favorited stations get their own tab: artwork, LIVE badge, genre, tap to play, heart to remove.

**Playback**
- **New imports play immediately on mobile** - a song without a mobile-optimized copy used to stall and skip; it now plays right away in original quality while the optimized copy is prepared in the background for next time. (Server-side fixes also unstuck the pipeline that prepares those copies - the library is re-filling automatically.)

## 1.4.3 - 2026-07-02 (build 114)
Stations arrive on desktop, and you can cast them to the TV.

**Stations**
- **Stations on desktop** - the Stations card and full discovery screen now ship in the Windows build (they were mobile-only until now), and the desktop now-playing shows proper LIVE mode for a station: red ● LIVE badge, station artwork, no dead seek bar.
- **Cast a station** - casting now sends the live stream straight to the TV instead of a broken song URL. First cut: give it a try and expect rough edges.

**Under the hood**
- Server-side fixes for the recent slowness: music-library lookups on the server were taking 7-45 seconds due to a DNS misconfiguration (not the app). Connects, skips, and casting should feel instant again.

## 1.4.3 - 2026-06-28 (build 113)
**Casting**
- **Fixed double audio when skipping back** - pressing Previous while casting could start playback on your phone *on top of* the TV (with the controls still only driving the TV). It now stays on the cast where it belongs.

## 1.4.3 - 2026-06-27 (build 112)
Casting survives a locked phone.

**Casting**
- **No more drops when you lock the phone** - locking put the Wi-Fi radio into power-save, which killed the (LAN-only) connection to the TV within seconds. The app now holds a Wi-Fi lock while casting so the connection stays up with the screen off.
- **Rides out brief network blips** - if connectivity does drop, casting now keeps trying to reconnect for ~10 minutes (was ~4) and resumes on its own instead of needing a manual re-cast.

## 1.4.3 - 2026-06-25 (build 111)
Remote-control takeover keeps up with the controlled device now.

**Multi-device**
- **Updates when the track changes** - when the controlled device advances to the next song, your phone now follows along (title, artwork, format) instead of freezing on the first track.
- **Correct file format** - the format badge now shows the real format instead of "UNKNOWN".

## 1.4.3 - 2026-06-25 (build 110)
More of the now-playing controls now drive the device you're controlling.

**Multi-device** (controlling another device behaves more like casting)
- **Lyrics** → toggles on the *controlled* device's screen (like casting lyrics to a TV), not your phone.
- **Black screen** → blacks out the controlled device.
- **Sleep timer, A-B loop, and playback speed** → all now apply to the controlled device.

(Queue and play-from-a-playlist/album are still coming next.)

## 1.4.3 - 2026-06-25 (build 109)
Remote-control takeover polish.

**Multi-device**
- **Mirrors the right device** - the takeover now shows the *controlled* device's track from the moment you hit Control (it briefly fell back to showing your own song).
- **Badge no longer overlaps the artwork** - the "Controlling …" badge now sits above the album art instead of on top of it.

## 1.4.3 - 2026-06-25 (build 108)
The remote-control takeover now uses your real Now Playing screen.

**Multi-device**
- **Full controls when controlling** - controlling another device now takes over your *actual* Now Playing screen (not a stripped-down panel), so you get everything: artwork, a live scrubber, **shuffle, repeat, seek, favorite, lyrics, add-to-playlist** - all driving the device you're controlling.
- **Tap the "Controlling" badge to stop** handing back control.

_Known gap (coming next): the queue button still shows this device's queue while controlling, and starting playback from a playlist/album on the controller doesn't route to the target yet._

## 1.4.3 - 2026-06-25 (build 107)
Remote control becomes a proper "cast to another device" experience.

**Multi-device**
- **Remote control actually works now** - control another device's playback from this one (it was silently failing before). Open Devices, hit Control, and the buttons drive the other device.
- **Now Playing takeover** - when you're controlling another device, your Now Playing screen mirrors *that* device: its artwork, title, and a **live-moving scrubber**, with play/pause, previous, next, and seek all driving it. Just like casting, but pointed at another NASRadio.
- **"Controlled by" badge** - the device being controlled now shows a clear cyan badge ("Controlled by <name>") on its now-playing, fullscreen, mini player, and TV views, so it's obvious it's being driven from elsewhere.

**Fixed**
- **Missing scrubber** - a track whose cached waveform had gone bad showed no progress bar at all (not even the fallback). The player now always falls back to a working slider, and bad/silent waveforms are no longer cached.

## 1.4.3 - 2026-06-24 (build 106)
Multi-device remote control that actually works, plus desktop polish.

**Multi-device**
- **Remote control works now** - open Devices on a song and any device that's actually online gets a **Control** button. Controlling it gives you working **play/pause, previous, and next** that drive that device's playback. Offline devices are clearly marked and no longer pretend to be controllable.
- **Clearer device list** - long device names aren't cut off anymore, and if a control attempt fails it tells you why instead of silently doing nothing.

**Desktop**
- **No more sleeping mid-song** - the Windows app now keeps the machine awake while music is actively playing, and lets it sleep normally when paused.

**Fixed**
- **Up Next countdown** - the full-screen "Up next" ring now counts down to when the song *actually* changes (accounting for crossfade), instead of finishing a few seconds after the next track already started.
- **Smoother crossfades** - eliminated a background-transcode traffic jam that could make some songs stall ~10 seconds (or skip the fade-in and just pop in) when crossfading on the desktop.

## 1.4.3 - 2026-06-20 (build 105)
Multi-artist imports, album-style podcast chapters, and big reliability fixes.

**Podcasts**
- **Chapters fill in automatically** - new episodes (like A State of Trance) now pick up their tracklist chapters as soon as the publisher adds them, without you having to replay the episode. Recent episodes you haven't opened get theirs too.
- **Album-style controls** - for podcasts with chapters, the player now has **previous/next track** buttons and a **loop-this-track** button, so you can jump between tracks in a long mix and put your favorite on repeat. (Tapping a chapter to jump already worked.)
- **A State of Trance is updating again** - an expired-certificate issue had silently stopped some feeds from refreshing for weeks; fixed.
- **Per-feed auto-download** - feeds set to auto-download now pull new episodes in the background (with a progress bar on the player).

**Library & imports**
- **Multi-artist tracks import correctly** - every credited artist is saved now, not just the first, so featured and guest artists show up. Compilations file under "Various Artists" while each track keeps its own real artist.
- **MusicBrainz tagging pulls per-track artists** - tagging an album from MusicBrainz now captures each track's individual artists.

**Fixed & faster**
- **No more "two songs then it dies" over Bluetooth** - playing to a Bluetooth speaker was making the app fire a status message to the server every fraction of a second; over a long session that flood overwhelmed the server and crashed it. Fixed at the source.
- **No more freezes on big lists** - opening a long list of songs could exhaust the server's database connections (every heart button fired its own request); those are now batched into a single request.
- **Smoother under load** - the backend no longer blocks on each database query, so it stays responsive when a lot is happening at once.
- **More reliable** - the backend now restarts itself nightly to head off a rare crash that could happen after very long uptime.
- **Settings** - the music-folder picker now strips any server path prefix generically, not just specific hostnames.

## 1.4.2 - 2026-06-17 (build 104)
Search & Playlists, redesigned - plus full-screen freeze/stutter fixes and lyrics, Shazam, and casting fixes.

**Search**
- **Fresh look** - artists and albums show as artwork rails (a grid on desktop) with a cleaner song list.
- **Nicknames now work** - searching shorthand like "IZ" finds the right artist.

**Playlists**
- **Redesigned** - a pinned showcase, a recently-played row, and a cover-art grid, with a reserved spot for upcoming auto-generated mixes.

**Fixed**
- **Lyrics** load again - they were failing instantly.
- **Shazam** song recognition works again.
- **Casting** - the waveform and lyrics now show on the TV when casting.
- **Artist page** - Spotify top tracks load again.
- **Full-screen freeze fixed** - the full-screen player could lock up (progress bar stuck at 0:00 while the song kept playing); the background blur was overworking the graphics and is now far lighter. Also covers track auto-advance.
- **Smoother scrubber** - the progress bar no longer hitches every few seconds (the app was needlessly re-saving the entire queue every 3s; now it just saves your spot).
- **Full-screen** - artist, album, and track names are now tappable (jump to the artist/album), and the audio-format badge (FLAC/MP3…) is now shown here too.
- **Full-screen "Up next"** - near the end of a track, a card slides into the corner with the next song's artwork and a countdown ring; tap it to skip ahead.
- **Full-screen actions** - favorite (heart) and add-to-playlist are now available right on the full-screen player, and the phone-landscape view now matches desktop (tappable names, format badge, and the same actions).
- **0:00/0:00 scrubber fixed** - on some tracks the full-screen progress bar stayed pinned at 0:00 the whole song (the audio engine wasn't reporting the track length); it now falls back to the known song length so the bar and times always work.
- **Up next** card now floats above the scrubber (right-aligned) and fades in/out, without nudging the rest of the screen.
- **Lyrics on full-screen** - a lyrics button now lives on the full-screen player; tapping it fades in a lyrics overlay over the player (tap the close button or background to dismiss).
- **Search stability** - large searches no longer load every result's artwork at once (that burst could overload and crash the backend); art now loads as you scroll.
- **Lighter on the backend** - removed temporary per-second diagnostic logging from the now-playing screen that was adding needless load on the server.

## 1.4.1 - 2026-06-17 (build 89)
Now Playing scrubber fixes.

**Now Playing**
- **Fixed the progress bar sometimes freezing at 0:00** - on some machines the scrubber would stay stuck at the start until you backed out and reopened the screen. It now starts tracking on its own.
- **Full-screen now shows the waveform scrubber** - full-screen uses the same waveform progress bar as the normal view (surprises included) instead of a plain slider.

## 1.4.0 - 2026-06-15 (build 88)
Self-hosting groundwork, steadier mobile reliability, and smarter update notes.

**Connectivity**
- **Set your server address right in the app** - tap the gear on the login screen to point NASRadio at any backend (a local address plus an optional remote one). No more rebuilding the app to change servers.
- **Faster reconnect when your signal changes** - leaving WiFi for cellular (or coming back) now triggers an immediate re-check of the best route to your server, instead of stubbornly retrying the old one. Far fewer "can't reach the server" hangs when you're on the move.

**Updates**
- **"What's New" now shows everything since your version** - if you skipped a few releases, the update screen lists all the changes between your installed version and the latest, not just the newest one.

**Behind the scenes**
- Audio analysis and mobile pre-transcoding now run on the NAS instead of the desktop PC, so they keep working around the clock.
- YouTube downloads now save as MP3, so they analyze and play everywhere.
- Very long mixes (30+ min) and undecodable files are skipped during analysis instead of stalling it.

## 1.3.2 - 2026-06-10 (build 87)
- Link/relink actions for missing tracks are now scoped to your own playlists.
- Fixed the Android home-screen widget not loading artwork under the new auth.

## 1.3.1 - 2026-06-10 (build 86)
- Fixed missing artist images and album covers on the artist/album detail screens. The cache-buster was appended with a second `?`, which corrupted the auth token in the image URL. (Broken since the 1.2.0 auth change; Now Playing and list thumbnails were unaffected.)

## 1.3.0 - 2026-06-10 (build 85)
Multi-user is complete - manage accounts right in the app.

**Accounts**
- **User management** in Settings → Account (admin only): add users, reset passwords, switch a user between Admin and User, log a user out of all their devices, or delete an account. No more command line.
- **Separate libraries per user** - each person's playlists and favorites are now their own; the music library itself stays shared.

## 1.2.2 - 2026-06-10 (build 84)
Full-screen login - the sign-in screen now fills the display: signal-rings sweep outward across the whole window from behind a larger, glowing NASRadio logo, over a soft radial-gradient backdrop.

## 1.2.1 - 2026-06-10 (build 83)
Hotfix for 1.2.0 auth, plus a fancier login.

**Fixes**
- **Fixed screens failing to load after login** (e.g. "Failed to load analytics stats"). Several API calls weren't sending the auth token - they slipped through the 1.2.0 conversion because they were line-wrapped in the code - so they came back unauthorized. All API calls now carry the token.

**Login screen**
- The logo now matches the Chromecast idle screen: signal-rings pulse outward from behind a gently breathing NASRadio logo.

## 1.2.0 - 2026-06-10 (build 82)
Accounts & login - NASRadio now requires sign-in, and the API is locked down.

**Accounts**
- **Login screen** - the app now requires a username and password. Your session is remembered securely on the device.
- **The whole API now requires authentication** - previously every endpoint was open to anyone who could reach the server. Now nothing responds without a valid login. Streaming and artwork stay protected too, via a read-only media token that can play music but can't touch your library.
- **Account tab** in Settings - see who you're signed in as and sign out. (Admin user-management UI is coming next; for now, manage users on the server with `manage_users.py`.)

**Missing-track album picker (carried over from the in-progress 1.1.x work)**
- The orange search button on a missing track opens a **grid of album covers** to choose from, each tagged Studio Album / Compilation / Live / Single / EP, with a "Studio only" filter.
- Smarter album lookup that also finds title-track albums and original singles (e.g. "(Sittin' On) The Dock of the Bay").

**Under the hood**
- Albums now track their full MusicBrainz type (Compilation/Live/Soundtrack), groundwork for an artist-page overhaul.

## 1.1.3 - 2026-06-10
- TODO: release notes

## 1.1.2 - 2026-06-09 (build 80)
Smarter missing-track downloads - pick the right album instead of guessing.

**Missing tracks**
- The orange search button now opens an **album picker**: it lists every album that track appears on, each tagged **Studio Album / Compilation / Live / Single / EP / Soundtrack**, sorted studio-first, with a "Studio only" filter. Pick one and it searches Prowlarr with a cleaned query (drops featured artists and "(Deluxe Edition)"-style suffixes that broke searches before).
- Better automatic album matching - fixed a bug where albums with no MusicBrainz date were unfairly ranked below obscure reissues.

**Behind the scenes**
- Albums now track their full MusicBrainz type (including Compilation/Live/Soundtrack), and existing albums were backfilled - groundwork for an upcoming artist-page overhaul with Studio / Singles / Compilations / Live sections. Also recovered MusicBrainz IDs for hundreds of albums whose deluxe/anniversary-edition titles previously failed to match.

## 1.1.1 - 2026-06-09 (build 79)
Playlist file import, smarter library matching, and a self-healing Transmission.

**Playlists**
- Import custom `.m3u8` / `.m3u` playlist files - tracks are matched against your library, and anything you don't own yet is saved as a "missing" track so the playlist still shows the full picture.
- Missing tracks now get an automatic MusicBrainz album lookup, so the orange search button can find them in Prowlarr even when the file listed no album.
- Smarter matching - now handles the Hawaiian ʻokina, accents, and "/" vs "," differences, so tracks like Israel Kamakawiwoʻole's match instead of being flagged missing.

**Fixes**
- Playlist thumbnails no longer fall back to the placeholder icon when a playlist contains missing tracks.

**Behind the scenes**
- Transmission now self-heals: if the container hangs, the app restarts it automatically and retries the request, so downloads stop erroring out.

## 1.1.0 - 2026-06-06 (build 78)
A major release - a rebuilt playback engine plus a top-to-bottom podcast overhaul.

**Playback**
- Rebuilt the audio engine from the ground up for rock-solid gapless playback, skipping, repeat, and shuffle - no more random regressions
- **Crossfade now works on desktop** - songs smoothly overlap and dissolve into each other
- Resume holds its exact position instead of restarting the track
- Large / hi-res tracks no longer get skipped while they load
- Scrubber, chapter taps, and the previous button work the instant you reopen the app - no need to press play first

**Podcasts (overhauled)**
- First-play is **5-7× faster** - resolves and caches the episode URL instead of re-chasing it every time
- **Auto-download for instant seeking** - episodes save to your NAS as you listen (with a progress bar); once saved, resume and chapter-jumps are instant. Storage is hands-off - finished episodes clean up automatically
- The play queue now follows **your** sort order (newest-first or oldest-first), so "next episode" goes the right way
- Chapter highlight tracks the current position as you listen
- Resume reliably picks up the **right episode** where you left off

**Stability & speed**
- Fixed the crash when clicking back onto the app window
- Much faster, more reliable NAS streaming - local routing + a keepalive that stops cold-connection stalls
- Weather voice alerts now announce **once** instead of replaying the same alert every time you open the app

## 1.0.31 - 2026-06-05 (build 75)
- **Crossfade now works on desktop** - songs smoothly fade into each other instead of hard-cutting
- **Fixed the crash** when clicking back onto the app window after using another window
- **Fixed song-skipping** on large / hi-res tracks that were slow to load
- **Fixed resume** restarting a song from the start instead of continuing where you paused
- **Much faster, more reliable streaming** - talks to the server locally and keeps the NAS connection warm so playback starts instantly
- Rebuilt the playback engine under the hood for rock-solid track transitions (gapless, skip, repeat, shuffle)

## 1.0.31 - 2026-05-28
- TODO: release notes

## 1.0.31 - 2026-05-28
- TODO: release notes

## 1.0.31 - 2026-05-28
- TODO: release notes

## 1.0.31 - 2026-05-26 (build 67)

### Bug fixes (path to v1.1.0, Milestone 1)
- **Search recent searches no longer captures mid-typing prefixes.**
  Typing "whitesnake" with brief pauses used to save "w", "wh", "whi"
  as separate entries. Now any existing entry that's a strict prefix
  of a new query gets removed; longer entries that aren't a prefix
  stay put.
- **Playlists "+" FAB no longer covers the last row.** Bottom padding
  bumped to clear FAB + mini player + bottom nav (160dp).
- **Queue trash + drag handle no longer overlap.** Disabled the
  auto-appended drag handle, added an explicit drag handle in the
  trailing row with proper spacing between the delete icon.
- **Empty song titles no longer render as blank rows.** Songs whose
  TITLE tag was missing from metadata (looking at you, Dio Sacred
  Heart CD 02 bootleg rip) now show the filename stem in italic gray
  instead of leaving a row with just "Unknown Artist . " visible. The
  scanner also derives a title from the filename pattern when the tag
  is empty, so future imports never insert blank rows.
- **Artists with only featured/compilation tracks now show their
  music** - albumless artists like +44 previously showed "No music
  found" even though they had 1 song on a compilation album. The
  query now includes songs where the artist is primary but the
  album belongs to a different artist.
- **Continue Listening on Podcasts page no longer goes stale.** When
  an episode completes (green checkmark appears), the Resume banner
  and Continue Listening list now refresh to reflect the new
  current episode instead of staying stuck on the previous one.
- **Weather widget no longer silently disappears on desktop with no
  manual location set.** Shows "Set location in Settings to see
  weather" instead of vanishing. Three other previously-silent NWS
  API failure paths also surface an error now.

### Quality of life (Milestone 2)
- **Expanded song context menu everywhere.** Every song's 3-dot menu
  now includes Go to Album, Go to Artist, Play Next, Add to Queue,
  Add to Another Playlist, Favorite, Analysis Details, Show File
  Location, Edit Metadata, and (in playlist context) Move to
  Position, Replace Song, Remove from Playlist. Consistent across
  Now Playing, Album detail, Library, Playlist detail, Favorites,
  Search - same widget, same actions, same ordering.

### Queue UX (Milestone 3a)
- **Played tracks dimmed** to 55% opacity. Scanning the queue, you
  see history -> current (cyan highlight) -> upcoming as a clear
  visual gradient.
- **Auto-scroll to current track** on Queue open. With a 768-track
  queue you no longer have to manually hunt for position 123  - 
  the queue lands the playing row near the top with a bit of
  recently-played context visible above.
- **Sticky "Jump to: [song]" pill** appears at the top of the queue
  when the playing track is off-screen. Tap to smooth-scroll back.
  Auto-follows the playing track across changes unless you've
  manually scrolled away.

## 1.0.31 - 2026-05-26 (build 66)

### Ultrawide layout (continued)
- **Continue Listening / Most Played / Recently Added carousels**  - 
  the dashboard was requesting only 5, 10, and 10 items respectively
  from the backend, capping the rows at well below the visual width
  of an ultrawide. Bumped to 20 / 30 / 30. Backend API supports up
  to 50 per request natively.

## 1.0.31 - 2026-05-26 (build 65)

### Ultrawide layout
- **Coming Soon / Recently Released carousels** - cap raised from 8 to
  30. The 8-tile cap left a wide chunk of dead horizontal space on
  ultrawide displays where 12-15 tiles fit comfortably; rows are
  horizontal-scrollable so the higher cap doesn't crowd mobile either.
- **Van Halen artist page background stripes** - the Frankenstrat
  pattern was hardcoded for a ~1400-px design canvas, leaving plain
  red on the right half of ultrawides. Now scales x positions by
  `width / 1400` so the pattern spreads to fill the full SliverAppBar
  width. Same treatment that fixed the waveform scrubber yesterday.
- **Quick Access tiles** - was hardcoded to 3 columns on desktop,
  which made each tile span ~800px on ultrawide and felt sparse.
  Now adapts: 5 columns >2000px wide, 4 columns 1400-2000px, 3 below.
  The 7 quick-access tiles condense from 3 rows to 2 on a 4K or
  ultrawide screen.

## 1.0.31 - 2026-05-26 (backend changes since build 64)

### Performance
- **Essentia model caching.** The analysis service was reloading all 14
  TF graph files from disk on every single `/analyze` call. Now models
  are loaded once at service startup and reused across requests.
  Measured per-song analysis time dropped from ~5-10s to ~3s. Memory
  usage stabilized (no more allocate/free thrash, which was a likely
  contributor to the silent crashes).
- **`/api/health` sidecar status cache.** Was making two sequential
  5-second-timeout probes to Essentia + transcode on every health check,
  worst case 10s response. The desktop client gives up at 8s - when
  both sidecars were slow, the "Server unreachable" banner false-fired
  during normal operation. Sidecar status is now cached for 10 seconds;
  back-to-back health probes return in ~15ms instead of seconds.

### Resilience
- **Essentia auto-restart watchdog.** When the backend's batch analyzer
  hits a connection error talking to Essentia, it now invokes the same
  launcher script the in-app "Start Essentia Service" button uses,
  waits up to 90s for the service to come back online, and retries
  the song. The batch keeps grinding instead of silently failing every
  remaining song. Fixes the "Essentia crashed two days ago and nobody
  knew" failure mode.
- **Per-extractor try/except inside Essentia's `/analyze`.** A failure
  in any single extractor (e.g. RhythmExtractor2013's known "output
  buffer is full" bug on certain files) used to lose the entire song's
  analysis. Now BPM, key, and loudness each fail independently - the
  song still gets stored with whatever the other extractors produced,
  and the failed field is null.

## 1.0.31 - 2026-05-26 (build 64)

### Diagnostics
- **Mobile player decision-point logging.** Every advance, completion,
  buffering transition, repeat-all wrap, container refill, loop-mode
  change, stream retry, and initial container build now ships a tagged
  line to the server-side combined.log via AppLogger. Tagged with
  `[player.<topic>]` so all related lines are greppable from a single
  query. Targets the long-standing "song finishes, next one hangs in
  buffer" bug - the next time it fires we can reconstruct the full
  decision chain from logs instead of guessing.

## 1.0.31 - 2026-05-25 (build 63)

### Volume normalization (the big one)
- **Real EBU R128 LUFS-based volume normalization.** The old "loudness"
  values stored by Essentia were Steven's power-law units (arbitrary
  positive scale, not LUFS) and the dialog mislabeled them as such.
  Now the Essentia service computes proper integrated LUFS, loudness
  range (LU), and true-peak (dBFS) per song. Volume normalization in
  the player switched from `gain = target/actual` (ratio) to proper
  dB math: `gain_dB = target_LUFS - actual_LUFS; linear = 10^(gain_dB/20)`.
  Default target is -14 LUFS (matches Spotify's normalization).
- **Backward compatible.** Songs not yet re-analyzed fall back to the
  legacy Steven's-law math so playback sounds identical to before the
  upgrade for them. As the analyzer backfills LUFS, songs transparently
  transition to the new math.
- **Fast-path LUFS backfill.** New `/analyze-loudness` Essentia endpoint
  measures just EBU R128 + true-peak without running the expensive
  Discogs-Effnet inference. The batch detects songs that have full
  analysis but no LUFS yet and uses the fast path - roughly 10x faster
  than re-running everything. 11,882 already-analyzed songs at session
  start will backfill quickly.
- **Per-song analysis dialog** now correctly labels LUFS, shows loudness
  range and true peak as separate rows, and clearly distinguishes legacy
  loudness values from real LUFS for un-backfilled songs.
- **Live feed** in the analysis settings section now includes the LUFS
  value inline alongside BPM/key/genre/mood for each just-finished song.

### Schema
- Three new columns on `song_analysis`: `integrated_loudness_lufs`,
  `loudness_range_lu`, `true_peak_dbfs`. Migration is idempotent (uses
  `ADD COLUMN IF NOT EXISTS`); runs automatically on Flask startup.

## 1.0.31 - 2026-05-25 (build 62)

### Audio analysis visibility
- **Live "Recent Analyses" feed in Settings → Audio Analysis.** While the
  batch runs, you see a scrolling list of the last 30 analyzed songs with
  the key results inline - BPM, key, top genre, top mood - updated in
  real time over websocket as each song finishes. No more flying blind.
- **Per-song analysis dialog** accessible from the song 3-dot menu (now
  playing screen, album detail, playlist detail - anywhere `MusicContextMenu`
  appears). Tap "Analysis Details" to see the full Essentia output for
  that song: tempo, key, loudness, dynamic range, top genres, mood
  probabilities, voice gender split, top instruments. If the song hasn't
  been analyzed yet, the dialog tells you that with a hint to run analysis
  from settings.

### Bug fixes
- Fixed `/api/health` reporting `essentia: false` even when Essentia was
  fully responsive - the 1.5s timeout was too aggressive for WSL2 networking
  jitter (same root cause we fixed in transcode earlier today). Now 5s,
  with per-failure-mode logging so future "service is up but app says
  it's down" debugging takes seconds instead of minutes.

## 1.0.31 - 2026-05-25 (build 61)

### Quality of life
- **New "Start Essentia Service" button** in Settings → Audio Analysis.
  When Essentia is offline, the button appears under the status indicator.
  Clicking it triggers the WSL2 mount + service launch from the app - no
  more "open a terminal, run a script, hope the credentials work" dance.
  Shows a spinner with progress text while starting, and disappears once
  Essentia comes online.

### Bug fixes
- Fixed audio analysis hammering Essentia with 400s for songs whose DB
  path still uses the pre-migration NAS IP (`\\nas\Music`
  instead of the new `\\nas\Music`). The WSL2 path mapper
  now handles both prefixes.
- Rewrote the WSL2 Essentia launcher script to read SMB credentials
  inline in bash rather than via `mount -o credentials=<file>`. The
  kernel CIFS credentials parser was rejecting valid files for opaque
  reasons; bash parsing is far more reliable. One-time fix, future
  starts (whether from the new button or manually) just work.

### Playback reliability
- Fixed long-running "UI shows one song while audio plays a different one" bug
  (the stream-error retry was corrupting media_kit's internal playlist)
- Fixed play button stuck on the buffering spinner after a crossfade transition
  (the buffering listener was missing the new player's buffer-went-false event)
- Fixed track restart instead of advance to next on mobile
- Fixed repeat-all not wrapping back to track 1 at end of queue (mobile + desktop)
- Fixed repeat-all backward wrap on desktop (previous at track 1 now wraps to last)
- Fixed tapping a song from an album loading only the single song instead of
  the full album playlist on desktop
- Tapping arbitrary queue items on mobile now actually plays that song
- Crossfade no longer leaks stream subscriptions over long listening sessions
- Skip and Previous can no longer hang the UI indefinitely on stalled streams
- First-play after app open no longer permanently hangs the UI if a stream fails

### Performance
- App opens **much faster** - first play after open primes the backend's SMB
  connection during state restore, eliminating the 10-15 second cold-start lag
- Van Halen Frankenstrat waveform stripes now extend across ultrawide displays
- Capped waveform pre-fetch cache to prevent unbounded memory growth

### Bug fixes
- Fixed Now Playing screen freezing when expanding artwork on high-DPI displays
  (was decoding ~16MB RGBA at full screen size - now caps decode to screen
  pixels via `memCacheWidth`/`memCacheHeight`)
- Reduced transcode-service health check timeout spam during normal WSL2
  jitter; failures now log the specific cause (connect timeout, refused,
  bad status, non-JSON) instead of being silently swallowed
- Fixed multiple "Null check on null" crashes across screens (favorite button,
  playlist detail, import queue, Prowlarr search, YouTube download, album
  detail, artist detail, home, downloads)
- YouTube import-to-existing-album now correctly puts the track in the chosen
  album instead of creating a phantom duplicate
- Album/artist deletion is now safer: won't destroy unrelated audio files
  that share a folder, and won't leave orphan DB records on failure
- Editing the queue (remove/reorder) now syncs with the desktop player
- YouTube import errors show the real backend error instead of "Failed to import"
- Shuffle button reloads the song on Chromecast (was leaving the device on the
  old song) and no longer silently substitutes wrong songs

### Under the hood
- Migrated home network from OpenVPN to Tailscale after the ISP moved us
  behind CGNAT - broke inbound port forwarding
- External access (sister, friends, Chromecast receiver) now routes through
  Cloudflare Tunnel terminating at the backend host
- Backend reaches the NAS via the NAS's hostname
- Fixed eventlet's greendns resolver bypassing Windows' Tailscale DNS rules
  inside the Flask process

## 1.0.30 - 2026-05-24
- TODO: release notes

## 1.0.30 - 2026-05-23
- TODO: release notes

## 1.0.30 - 2026-05-20
- TODO: release notes

## 1.0.30 - 2026-05-20
- TODO: release notes

## 1.0.30 - 2026-05-15
- TODO: release notes

## 1.0.30 - 2026-05-15
MEGA-bug-list session. Eleven bugs simpson1045 flagged at once across cast, mobile playback, podcasts, yt-dlp, and the audio transcode sidecar - plus a twelfth (desktop in-app updater silently failing), a thirteenth chunk of work (Linux desktop as a first-class release target), and a fourteenth (early-init crash logging, added after build 51 produced a no-trace crash during cast testing). Cast receiver `?v=21`. Build 51 shipped the original 11 + Linux work; build 52 adds the crash-recovery flow so the NEXT silent crash leaves a forensic trace.

- **Linux desktop is now a first-class release target.** simpson1045 set up a Linux Mint 22.3 dev box this session and asked for the in-app update pipeline to ship a Linux artifact alongside the existing Windows/Android ones. End-to-end plumbing landed:
  - **Backend** `update_routes.py` now accepts `linux` as a third platform on `/api/update/download/<platform>`, mapping to `backend/updates/nasradio-linux.tar.xz`. `/api/update/check` returns a `linux_size` field (0 when no Linux artifact has been packaged for the current release). Existing `android_size`/`windows_size` slots are unchanged so Windows + Android updaters keep working.
  - **Frontend** `update_service.dart` gains a `Platform.isLinux` branch: `checkForUpdate` picks the `linux_size` key, `downloadUpdate` picks platform=`linux` + extension=`.tar.xz`, and a new `_applyLinuxUpdate` extracts the tar.xz to a staging dir and runs a bash script that polls for the running process to exit, copies the bundle contents over the install dir (Linux allows overwriting a running ELF - the kernel keeps the old inode for the running process via the still-open exec fd, so this is straightforward; no Windows-style "wait for locks to release" dance is needed), then `nohup`-relaunches the new binary and self-deletes. Log goes to `$TMPDIR/nasradio-update.log` for forensics; same pattern as the Windows fix.
  - **New `backend/release-linux.sh`** mirrors what `release.bat` does for the Windows/Android side. Bumps pubspec (optional), rsyncs the project off CIFS to `~/development/NASRadio-frontend-linux/` (CIFS strips the leading slash from absolute symlinks, so Flutter's plugin_symlinks layout breaks if the build happens directly on the mounted project - this is non-negotiable; the rsync is the workaround), runs `flutter build linux --release`, packages `bundle/`'s CONTENTS (no enclosing dir, so extract straight into install dir works) into `nasradio-linux.tar.xz`, then merges `linux_size` + version metadata into `version.json` while preserving any `android_size` / `windows_size` already set by `release.bat`. Workflow: run `release.bat` on Windows first, then `bash backend/release-linux.sh` on Linux, and version.json ends up with all three artifact-size fields. Script invokes via `bash` because the CIFS mount forces file_mode=0644 so the script's exec bit can't be set; not a real obstacle, just a quirk to remember.
  - **Build-environment setup for the Linux dev box** (one-time, documented in HANDOFF.md): Flutter 3.41.9 stable installed to `~/development/flutter/`, PATH added to `~/.bashrc`. System deps: `libmpv-dev` (media_kit audio backend), `clang cmake ninja-build libgtk-3-dev pkg-config` (Flutter Linux toolchain), `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev` (audioplayers_linux backend for Spotify previews). VS Code 1.120.0 and Notepadqq 2.0.0-beta also installed (general dev tooling, not strictly project deps).
  - **First Linux build dropped at `~/Apps/NASRadio/`** + Cinnamon .desktop launcher at `~/.local/share/applications/nasradio.desktop` (icon from `~/.local/share/icons/hicolor/256x256/apps/nasradio.png`, sourced from `data/flutter_assets/assets/images/nasradio_logo.png`). App shows up in the Cinnamon menu / app picker as "NASRadio" and launches the binary at `~/Apps/NASRadio/frontend`. The binary is named `frontend` rather than `nasradio` because that's the pubspec `name:` field; renaming would mean rewriting every internal `package:frontend/...` import. Not worth it - the user-facing name in the launcher is correct, the binary name is implementation detail.
- **Caveat on this build for the Linux-installed copy at ~/Apps/NASRadio:** the bundle currently in `~/Apps/NASRadio/` is the build that pre-dates this Linux-updater work. To get the latest updater into that install, re-run `bash backend/release-linux.sh` (or the dev workflow: rsync + `flutter build linux --release` + `cp -a` to ~/Apps), then either re-launch from the bundle dir or rely on the in-app updater going forward.

### Early-init crash logging (added during build-51 cast verification)

simpson1045 observed a "music finished and never advanced + black screen → bounced to home" pattern while testing build 51's cast fixes. The backend log showed NO crash signature at all - the app died before its debounced log-save tick fired, so the failure left zero trace in `combined.log`. To diagnose recurrences, three uncaught-error handlers now feed a flush:true forensic file:

- **`FlutterError.onError`** for framework errors during build/layout/paint
- **`PlatformDispatcher.instance.onError`** for top-level async errors that escape the framework's zone (returns `true` to suppress engine-level termination)
- **`runZonedGuarded`** wrapping `_mainGuarded()` for synchronous + zone-local async errors

All three funnel through a new `AppLogger.recordCrash(error, stack, where:)` that synchronously appends to `<docs>/nasradio_crash.log` (with `FileMode.append, flush: true`) before returning, so even an immediate process exit preserves the trace. The `where:` marker (`FlutterError` / `PlatformDispatcher` / `runZonedGuarded`) identifies which handler caught it so we can tell which code path failed.

On the NEXT successful boot, `AppLogger.init()` now also calls `_flushPendingCrashFile()` BEFORE logging the session-start line - reads the crash file, ships its contents to the backend as an `error()` entry (which the existing ship-on-error path flushes immediately within ~1s instead of waiting the 30s periodic tick), then deletes the file so we don't re-ship on every boot. The crash entry shows up in `combined.log` chronologically attached to the dead session rather than to the new one.

Net effect: next time the "black screen → bounced to home" happens, `combined.log` should contain a `🔥 Recovered crash from previous run:` line with the actual exception + stack trace. Without this, we'd be guessing forever - the original failure leaves no breadcrumb.

### MEGA-bug-list fixes (carried over from the earlier pass of build 51):

- **Desktop in-app update: actually replaces the old binary now.** simpson1045 reported "downloads and 'installs', but the update banner is still there after the app restarts" on Windows. Root cause: the post-extract `update.bat` used `timeout /t 2` followed by `xcopy /Y` to copy the unzipped Release folder over the install dir. Windows holds an exclusive lock on a running .exe, so the 2-second delay (often too short for Flutter to fully tear down its audio service + plugin DLLs) meant xcopy silently skipped the locked `nasradio.exe` and several DLLs - but returned exit code 0 anyway. The restart launched the OLD binary, version string was unchanged, update banner reappeared. Reproducible on any Windows install. Fix in `frontend/lib/services/update_service.dart`'s `_applyWindowsUpdate`:
  - **Poll for process exit** before copying, instead of a fixed-duration `timeout`. Bat loops `tasklist /FI "IMAGENAME eq nasradio.exe"` once per second, cap 30s. Proceeds the instant the process has actually exited, so it's not slower than the old script in the common case.
  - **`robocopy /E /R:30 /W:1`** replaces `xcopy /Y`. Built-in retry semantics handle the residual case where a DLL handle hasn't been released yet; robocopy will retry the same file 30 times with a 1s pause between, so a slow tear-down extends the copy by seconds rather than silently corrupting the install.
  - **Surfaces failures.** robocopy exit codes 0–7 are success (0=nothing copied, 1=files copied OK, 2–7=harmless extras like extra files at destination); 8+ are real errors. Script checks `if errorlevel 8 GEQ 8` and shows a pause-on-error message + writes the failure details to `%TEMP%\nasradio-update.log` instead of silently moving on. Even on success, the script writes a one-line "OK" entry so the user can confirm the update applied. The log file is intentionally NOT deleted at the end - kept for forensic inspection of the most recent update attempt.
  - **Honors renamed install dirs.** `installDir` is still derived from `Platform.resolvedExecutable.parent.path`, so simpson1045's pattern of "copy the Release folder to my desktop and sometimes rename it to NASRadio Release" works unchanged - the path comes from the actually-running exe regardless of what the folder is called.
  - **Already in build 51; future desktop updates work correctly from this build onward.** Build 51 → build 52 update path will be the first one to use the new script. Build 49 → build 51 (this build) still needs simpson1045's manual copy-the-Release-folder workflow because the old broken updater is still on disk for that hop.

- **Cast: removed on-TV diagnostic HUD overlay.** The cyan monospace `K:N I:N S:N E:N B:N D:N T:N M:N state:PLAYING` strip in the bottom-left corner of the receiver was covering simpson1045's timestamp readout. Receiver-side diag counters and `DIAG_HEARTBEAT` reporting back to the sender are unchanged - the data still lands in `combined.log` for drop-incident analysis, just no on-screen overlay. `_renderDiagHud` is now a no-op so the existing call sites elsewhere in the file don't need editing. Receiver bumped to `?v=20` (and again to `?v=21` for the waveform-request fix below).
- **Cast: stale-heartbeat force-close.** Heartbeat tx/rx tracking in `cast_session.dart` previously only emitted a periodic log line - it never acted on a growing tx-rx delta. New `staleThreshold = 6` ticks (~30s of unanswered PINGs) triggers an immediate `_socket.close()` from inside the heartbeat timer, which short-circuits the half-open TCP state that develops when the phone's WiFi power-saves while the screen is off. The onDone handler then fires CastSessionState.closed and the existing auto-reconnect plumbing in `cast_service.dart` takes over. This addresses simpson1045's "cast stops after a few songs unless I keep my screen on" complaint: even if the OS-level TCP keepalive takes minutes to notice a dead connection, our app-level heartbeat-loss detection now flips to reconnect in seconds.
- **Cast: waveform request-retry from receiver.** Two existing paths sent the waveform on song change (deferred-send after LOAD, plus a 3-second fallback), but both could lose on a state-transition race: if the receiver skipped PLAYING/BUFFERING because of a quick BUFFERING→PAUSED→PLAYING jitter or a sender restart mid-session, no waveform ever arrived and the scrubber stayed blank. Fix is bidirectional: sender's LOAD message now carries `customData.songId`; receiver tracks `currentSongId` from that customData, and `PLAYER_LOAD_COMPLETE` calls a new `_ensureWaveform()` that sends a `WAVEFORM_REQUEST` to the sender with the songId, retried with exponential backoff (1/2/4/8/16s) until either a waveform arrives or we've made 5 attempts. Sender's `cast_service.dart` adds a `WAVEFORM_REQUEST` handler that calls `_sendWaveformAndLyrics(songId)`. Receiver bumped to `?v=21`. Idempotent: a successful WAVEFORM message cancels the in-flight retry; MEDIA_FINISHED resets the retry state for the next song.
- **Mobile playback: OPUS (and other already-compressed formats) now pass through on cellular.** Previously the `/api/stream/<id>` endpoint forced ALL non-lossless requests into the AAC transcode path. For files that are already compressed (mp3/m4a/aac/opus/ogg/oga), re-encoding to AAC is pointless - they're already small, and the generation loss costs quality. New passthrough check at `routes.py:1248`: if `quality != "lossless"` AND the file extension is in `_passthrough_compressed = {".mp3", ".m4a", ".aac", ".opus", ".ogg", ".oga"}`, skip the transcode path entirely and serve the original. Lossless inputs (FLAC, WAV, AIFF, APE, WV, DSF, DFF) still transcode for the bandwidth savings on cellular. This unblocks simpson1045's OPUS files which were failing to stream entirely on cellular.
- **Podcast: quick-resume picks the right episode, with the right timestamp.** Three related fixes:
  - **Schema:** `rss_episodes` gets a new `last_played_at TIMESTAMP` column (with index). Set by `rss_update_progress` on every progress save, so we can rank in-progress episodes by "most recently played" instead of "first in list order with progress > 0" - which was the previous, broken behavior that returned whichever in-progress episode happened to be earliest published.
  - **Progress save now mirrors to `songs` table.** Migration `migrate_podcasts_to_songs.py` made every podcast episode also a `songs` row (source_type='podcast'), but the 15-second progress save was only updating `rss_episodes.played_position` - `songs.played_position` stayed stale. The mirror update is best-effort (try/except so pre-migration DBs still work) and uses `WHERE podcast_episode_id = %s`.
  - **`/api/rss/feeds/<id>/current-episode` uses `last_played_at` as the primary source of truth** (falls back to play_history join, then published_at). `/api/rss/recently-played` previously ordered by `e.id DESC` (insertion order!) - now by `e.last_played_at DESC NULLS LAST, e.id DESC`. Episode-list/get-episode endpoints serialize the new column to ISO-8601.
  - **Frontend:** `RssEpisode` model gains `lastPlayedAt` field. `_resumeEpisode` getter in `rss_feed_detail_screen.dart` switches from `_episodes.firstWhere(...)` to a sort-by-lastPlayedAt, with a NEW two-tier strategy: authoritative `_resumeEpisodeFromApi` fetched from `/api/rss/feeds/<id>/current-episode` on screen open (works even when the resume episode lives on page 3+ of a paginated feed), falling back to the in-memory scan. The scan still wins if it has a strictly-newer lastPlayedAt than the API result, so cross-device updates from `globalDeviceSyncService` keep the banner fresh.
- **Podcast: rebuffer no longer restarts from byte 0.** Many podcast CDNs ignore HTTP Range requests entirely - they respond 200 + the full body to a `Range: bytes=N-` request. Previously our `/api/rss/stream/<id>` proxy passed that response through unchanged but ALSO advertised `Accept-Ranges: bytes`, which made just_audio re-request with Range on every rebuffer, get 200 + full body each time, and restart playback from byte 0. Fix in `rss_stream_episode()`: when upstream returns 200 to a Range request, synthesize the 206 ourselves by skipping bytes off the upstream stream before yielding to the client. Uses upstream's Content-Length to compute a valid `Content-Range` header; falls back to passthrough when Content-Length isn't available. Also adds a proper HEAD response (was previously falling through to GET, which is wasteful for the just_audio probe-before-stream pattern). All paths now close the upstream connection in a `finally` so a client-side disconnect mid-stream doesn't leak the upstream socket.
- **yt-dlp: persist jobs across screen navigation + rejoin on revisit.** Previously navigating away from the YouTube Download screen mid-download disconnected the websocket (in `dispose()`); the backend subprocess kept running but the frontend had no way to discover or re-subscribe to it. Now the backend's `youtube_download.py` keeps a `_job_state` dict mirroring the latest `_emit_progress` event per operation_id, retired ~30 seconds after a terminal status (so a screen-revisit right after completion still sees the final 'done!' state). New `GET /api/youtube/active-jobs` returns the list. `_YouTubeDownloadScreenState.initState()` calls a new `_rejoinActiveJob()` that fetches the freshest non-terminal job, restores `_currentOperationId / _isDownloading / _downloadStatus / _downloadProgress`, and triggers `_scrollToProgress()`. The websocket subscription was already wired up by operation_id, so progress events flow straight back into setState as if the user never left.
- **yt-dlp: auto-scroll to live progress when a download/import starts.** New `_scrollController` on the body's `SingleChildScrollView`, plus a `_progressKey` GlobalKey on `_buildDownloadProgress` so a `Scrollable.ensureVisible` call brings it onto screen. Fires from a `WidgetsBinding.addPostFrameCallback` (because the progress widget doesn't exist in the tree until the setState that toggled `_isDownloading` finishes rebuilding) - called from all four start sites: `_downloadSingleVideo`, `_downloadPlaylist`, `_applyTagsAndImport`, and the bulk-import path. Progress widget now also renders inside the tagging-branch of the body, gated on `_isDownloading || _isImporting`, so import websocket updates are visible too.
- **yt-dlp: mobile layout no longer overlaps the AppBar.** Title `Row` used `mainAxisSize: MainAxisSize.min` with no `Flexible` - when the version chip was visible on a narrow phone, the chip + 'Torrents' TextButton.icon visually overlapped the title text. Width-aware redesign: `MediaQuery.of(context).size.width < 480` is the "narrow phone" threshold. On narrow screens, the AppBar shows just `Text('YouTube Download')` as the title with an `IconButton(Icons.swap_horiz)` and tooltip 'Switch to Torrents' instead of the wider TextButton.icon; the version chip is hidden (still visible in the update-banner when an update IS available). On wider screens (tablet portrait + desktop), the chip and the labelled 'Torrents' button render unchanged. Also added `Flexible` + `TextOverflow.ellipsis` around the URL-input status row's "Playlist detected" / "Video detected" text so it can't blow out the right edge of the field.
- **Transcode service: configurable URL + visible failures.** The desktop transcode service URL was hardcoded to `http://<desktop>:5006` - now reads from `NASRADIO_TRANSCODE_URL` env var with that as the fallback default. More important: `check_transcode_service`, `get_transcode_status`, and `cancel_transcode` previously caught all exceptions with `except Exception: return None/False` and emitted no log - so when simpson1045's transcode service was up on his desktop but the backend couldn't reach it ("transcription not working but health check returns 200 OK from my desktop"), there was no way to tell whether it was a connection refused, a firewall block, a service-bind-to-localhost issue, or a wrong port. Now each failure path logs the specific exception type + message + the URL we tried, so the next "transcode service not working" can be diagnosed by tailing the backend log instead of guessing.
- **Schema migration:** `rss_episodes.last_played_at TIMESTAMP` column + `idx_rss_episodes_last_played` index added to `models.py` initialization. Existing databases get the column on next backend start.

## 1.0.29 - 2026-05-09
Slice 2 of the TV UI tree: Library + Now Playing layout sized properly for a real Firestick. Library was the bigger feature (one of simpson1045's flagged-urgent asks), but the more impactful change is the layout math fix in `TvNowPlayingScreen` - every previous build's Now Playing rendered with the title text overlapping the waveform on simpson1045's actual hardware because the layout was sized for a 1080dp logical-pixel screen and a Firestick 4K at density 2.0 reports `MediaQuery.size.height ≈ 540dp`.

- **New: TV Library screen** (`frontend/lib/screens/tv/tv_library_screen.dart`, ~430 LOC). The Library rail item now lands on a real screen instead of a "Coming soon" placeholder. Four sub-tabs along the top - **Albums / Playlists / Artists / Podcasts** - each rendered as a responsive grid via `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 260)` so card columns fluid-size to whatever the TV reports as content-area width. Each tab is **lazy-loaded** the first time it's shown (Albums on initial display, the other three on first tab-tap) - `getAlbums()` and `getArtists()` can return thousands of rows on a large library, no point fetching all four upfront. Tabs above are `TvFocusable` chips with cyan-tinted bg + border on the selected tab; first card on the active grid autofocuses on entry.
- **Tap behaviour: detail screen, not auto-play.** Per simpson1045's preference for fine-grained control over auto-queue convenience. Tap a playlist → push the new TV-variant `TvPlaylistDetailScreen`; tap a podcast feed → the new TV-variant `TvRssFeedDetailScreen`. Tap an album → existing phone `AlbumDetailScreen`; tap an artist → existing phone `ArtistDetailScreen` (those two retain phone screens for now - simpson1045's flagged-urgent path was specifically playlists + podcasts).
- **New: `TvPlaylistDetailScreen`** (`screens/tv/tv_playlist_detail_screen.dart`, ~280 LOC). Header with playlist name + song count + total duration; vertical list of d-pad-focusable track rows (track number + 48px album art + title + "artist · album" + duration). First row autofocuses. Tap a row → `setQueue(songs, index, sourceType: 'playlist', sourceId: playlist.id, sourceName: playlist.name)` and push Now Playing. Spotify-import placeholder rows (where `available == 0`) are filtered out - TV layout can't usefully act on un-resolved tracks anyway, and showing them greyed out would clutter the d-pad path.
- **New: `TvRssFeedDetailScreen`** (`screens/tv/tv_rss_feed_detail_screen.dart`, ~310 LOC). Header with feed artwork + title + author + episode count; vertical list of d-pad-focusable episode rows (56px artwork + title (max 2 lines) + relative published date + duration + status indicator). Status indicator on the right is either a green checkmark (completed) or a tiny cyan progress bar (resumed mid-episode), mirroring the receiver's "where you left off" affordance. First row autofocuses. Tap → `playPodcastEpisode(ep, streamUrl, ...)` with `allEpisodes: _episodes` so auto-advance threads through the feed in the user's chosen sort order. Uses the direct `episode.audioUrl` when available, falls back to `apiService.getRssStreamUrl(ep.id)` (the backend proxy that re-resolves on every request, dodging the CDN-URL-TTL bug from v1.0.22).
- **Card design per content type:**
  - **Albums:** square artwork from `apiService.getArtworkUrl(album.id)`, title (1 line), artist name as subtitle.
  - **Artists:** circular image from `apiService.getArtistImageUrl(artist.id)` (so they look distinct from albums in the grid), name + "$N albums" subtitle.
  - **Playlists:** fallback `playlist_play` icon tile (no public artwork URL; polish in a later slice), name + "$N songs · $duration" subtitle.
  - **Podcasts:** square artwork from `feed.artworkCached ?? feed.artworkUrl`, title + author subtitle (or "$N episodes" if author is empty).
- **Hotfix on top of slice 1: Now Playing layout sized for 540dp screens.** Build 39 still rendered the title text overlapping the waveform on simpson1045's Firestick 4K (a Samsung 45" 1080p TV → density 2.0 → 940×540 dp logical). Root cause: every dimension in `_buildCenterPanel` was a fixed pixel value (artwork 460, title 30pt, spacing 24/8/4/14) sized for a 1080dp-height TV. With the 1.25× TV-mode font scaler stacked on top, the panel needed ~657dp vertical and only had ~300dp. Center+SingleChildScrollView didn't clip the overflow - Column children rendered past the box and into the waveform's space. Build 40 rewrites the panel with **screen-height-relative sizing**: artwork = `(h * 0.30).clamp(140, 320)`, title = `(h * 0.048).clamp(18, 26)pt`, artist/album/spacers similarly proportional. On a 540dp screen the artwork lands at 162dp and the title at 26pt; on a 1080dp screen they hit the upper clamps at 320dp / 26pt. Title is now `maxLines: 1` (down from 2) - long titles ellipsis-truncate; the full title is still readable in the mini player at the bottom of the screen. Bottom padding 24 → 12, control slot height 88 → 72, waveform vertical padding 8 → 4 - every dp of headroom recovered.
- **Hotfix: Now Playing scrim 70% → 82%.** Build 38's 70% wasn't dark enough on bright album covers. Build 40's 82% fully knocks down even the brightest blurred bg so title / artist / album text reads cleanly without competing against the bg's color palette. Drop shadows on each text element bumped to `blurRadius: 12` for an extra contrast boost.
- **Hotfix: TV side-rail logo now uses the actual NASRadio brand.** Build 38 sourced `frontend/assets/images/nasradio_logo.png` from `frontend/web/icons/Icon-512.png` thinking it was the brand icon - turned out to be the default Flutter F (web icons were never rebranded). Build 39 switched to `frontend/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` - same problem (iOS app icon was also never rebranded; 10KB at 1024² compresses that small only because the geometric F has so few unique pixels). Build 40 sources from `frontend/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` - the Android launcher icon simpson1045 sees on his Fire TV home screen, 23KB at 192² which is the right magnitude for a non-trivial branded image. **Followup for someone:** the web (`frontend/web/icons/`) and iOS (`AppIcon.appiconset/`) launcher icons are still the default Flutter scaffolding. Should be rebranded to match Android the next time someone touches those platforms.
- **Cast: auto-reconnect on unexpected drop with resume-position.** The remaining cast reliability problem after the yt-dlp fix: the cast session occasionally dies mid-playback even with no concurrent backend work - most likely LG webOS killing the receiver app for reasons we can't observe from the sender side (memory pressure, app lifecycle, etc.). Fixing the kill itself isn't possible from our code; making the user not notice IS. New plumbing in `cast_service.dart`: track whether the current disconnect was user-initiated (`_intentionalDisconnect` flag set by `disconnect()`). When the cast session's `state.closed` fires WITHOUT that flag set AND we have a `_lastConnectedDevice` we'd previously connected to, schedule an auto-reconnect with 2/4/8-second exponential backoff (capped at 3 attempts so a genuinely-off cast device doesn't get spammed). On success, fire a new `onAutoReconnect` callback wired in `main.dart` to invoke `audioPlayerService.startCasting()` - which re-LOADs the current song with `currentTime` set to the cached position (`_position` was preserved across the disconnect by the earlier `_onCastStateChanged` no-overwrite-when-cast-has-no-media gate). User hears a 2-4 second gap, then playback continues from where it dropped without any manual re-cast tap. Auto-reconnect is cancelled when the user explicitly disconnects, OR when the user manually re-casts (cleared in the `disconnect()` path). **TV-remote-kill suppression:** from the sender's perspective, a user killing the cast app via the TV remote looks identical to a spontaneous receiver drop - both fire `state.closed` with no metadata. Without suppression, auto-reconnect would immediately re-launch what the user just stopped (and there's no good heuristic from sender-side state alone - gating "second drop within N seconds = give up" would force the user to kill twice every time, which is unacceptable UX). Fix: the receiver tells the sender it's going down BEFORE the disconnect fires. `backend/cast/receiver.js` (`?v=17`) adds three tear-down listeners that all funnel through a one-shot `_sendShutdownSignal()`: `cast.framework.system.EventType.SHUTDOWN` (CAF's primary signal - fires when the cast app exits for any reason), `window.beforeunload`, and `window.pagehide` (browser-level unload events as belt-and-braces for the case where the receiver gets reaped without SHUTDOWN firing). Each fires a `DIAG_RECEIVER_SHUTDOWN` custom message; the sender's `_handleCastMessage` stamps `_receiverShutdownAt = DateTime.now()`. Then in `_handleDisconnect`, if that stamp is younger than 3 seconds, log `🛑 Receiver SHUTDOWN signal - user killed cast from TV, skipping auto-reconnect` and return without scheduling. **Race risk:** if the cast socket tears down before the SHUTDOWN message makes it through Google's infrastructure to the sender, `_handleDisconnect` fires first with `_receiverShutdownAt` still null, and auto-reconnect runs anyway - user has to dismiss the relaunch once. In practice CAF fires SHUTDOWN early enough in the tear-down sequence that the message usually arrives first. The failure mode is "user occasionally has to kill twice" - strictly better than the rejected heuristic-based approach where the user ALWAYS has to kill twice.
- **Cast: receiver-side artist-image leak - likely root cause of "drops on the second song" pattern.** Two consecutive drops today (12:50:36 and 13:09:47, both with the user sitting next to the router, both with music continuing to play on the TV) showed an unmistakable signature: 6 minutes of clean heartbeats with tx-rx=1, then the SECOND song's LOAD fires, then heartbeats start backing up (tx-rx grows from 1 to 5 to 7), then ~30 seconds later the LG TV's TCP stack sends `Connection reset by peer` from the TV. The receiver's JS event loop was blocked long enough that PING/PONG on the cast heartbeat namespace couldn't drain - but music kept playing because the audio decoder runs on a separate native thread. Found it: `updateMediaInfo()` in `backend/cast/receiver.js` fires on every `playerManager` MEDIA_STATUS event (CAF dispatches several per second during state changes, buffering, and song loads), and the artist-image background loader at the bottom of the function allocated `new Image()` on EVERY call without a URL-change guard - unlike the album-art loader 30 lines above which already had `if (artUrl !== currentArtworkUrl)`. So every MEDIA_STATUS during the song-2 LOAD burst spawned another `Image` object holding onload/onerror closures referencing the URL string. On a resource-constrained webOS, the GC pauses to reclaim them grew long enough to block the heartbeat handler. Fix is the obvious one: added `let currentBgImageUrl = ''` mirroring `currentArtworkUrl`, gate the artist-image allocation on `artistImgUrl !== currentBgImageUrl`, and add a "URL has been superseded" check inside the onload/onerror so a late-arriving image from a previous song doesn't overwrite the current bg. Also added `_diag.M` (updateMediaInfo call counter) to the receiver-side heartbeat counters payload so the next DIAG_HEARTBEAT will tell us empirically whether MEDIA_STATUS bursts are still happening at the rate suspected. Receiver bumped to `?v=19`.
- **Cast: drop-incident telemetry - one consolidated log line per disconnect.** Background: we've accumulated a lot of cast diagnostic plumbing over the past few sessions (heartbeat tx/rx, receiver HUD counters K/I/S/E/B/D/T, DIAG_BOOT / DIAG_PLAYER_STATE / DIAG_STUCK_BUFFERING / DIAG_SENDER_DISCONNECTED / DIAG_RECEIVER_SHUTDOWN / DIAG_KEY / DIAG_MSG). All of it lands in combined.log, but figuring out WHY a particular drop happened still required scrolling back through the surrounding 60 seconds of log and stitching events together by hand - a tax high enough that we'd been treating drops as opaque and building mitigations (auto-reconnect) instead of root-causing them. Fix: two pieces of new plumbing make the diagnosis a single grep. **(1) Receiver heartbeat push.** `backend/cast/receiver.js` (`?v=18`) extends the existing 1-second watchdog to fire a `DIAG_HEARTBEAT` to the sender every 5 ticks (~5 seconds) containing `{tick, playerState, currentTime, bufferingMs, timeUpdateAgoMs, counters:{K,I,S,E,B,D}}`. New tracker watches `playerManager.getCurrentTimeSec()` per tick and stamps `_lastCurrentTimeChangedAt` whenever the value actually moves - so `timeUpdateAgoMs` exposes "audio is stalled but state still claims PLAYING" as a distinct signature from genuine BUFFERING. `cast_service.dart` stashes the latest heartbeat into `_lastReceiverHeartbeatAt` / `_lastReceiverTick` / `_lastReceiverState` / `_lastReceiverCurrentTime` / `_lastReceiverBufferingMs` / `_lastReceiverTimeUpdateAgoMs` / `_lastReceiverDiagCounters` (no log line per heartbeat - would be too noisy). **(2) Drop-incident report.** New `_logDropIncident(wasIntentional)` runs at the TOP of `_handleDisconnect`, before any state is cleared. Reads heartbeat tx/rx from new public getters on `CastSession` (`openedAt`, `heartbeatsSent`, `heartbeatsReceived`), reads the stashed receiver heartbeat, reads the disconnect-event flags (`_senderDisconnectedSeen` flipped from the `DIAG_SENDER_DISCONNECTED` handler, `_stuckBufferingMaxSec` from `DIAG_STUCK_BUFFERING`, `_receiverShutdownAt` from `DIAG_RECEIVER_SHUTDOWN`), and writes ONE line: `🚨 [Cast] DROP intentional=X uptime=123s hbTx=24 hbRx=24 hbLost=0 lastRxHb=4200ms ago rxState=PLAYING rxTick=120 rxCurTime=87.3s rxTimeUpdateAgo=200ms rxBufferingMs=n/a senderDisc=no shutdown=no stuckBufMaxSec=n/a rxCounters={K:0,I:6,S:48,E:0,B:1,D:0}`. Intentional disconnects and shutdown-signaled disconnects log as info; unexpected drops log as warning so they stand out. All telemetry resets in `_resetDropTelemetry()` on each new successful connection. Patterns it lets us see at a glance: `hbLost > 0` → heartbeat channel was already broken before drop. `lastRxHb > 10s ago` → receiver JS had stopped ticking. `rxState=BUFFERING` + high `rxBufferingMs` → drop was the receiver finally giving up after a long stall. `rxState=PLAYING` + high `rxTimeUpdateAgo` → media element froze while CAF didn't notice. `shutdown=yes` → user killed it from TV. `senderDisc=yes` + clean state → graceful cast tear-down. With this one line we should be able to bucket drops into categories rather than guessing.
- **Backend: yt-dlp no longer freezes the entire backend during downloads.** Root cause: `youtube_download.py` called `subprocess.run()` and `subprocess.Popen()` + `process.stdout.readline()` directly on the eventlet hub. Eventlet monkey-patches socket I/O but NOT subprocess pipe I/O - so every blocking read froze the entire hub: no HTTP responses, no log writes, no cast/phone stream serving. A single 13-track yt-dlp playlist download (simpson1045's repro) made the backend appear dead for minutes at a time and broke any active cast session in the middle of buffering (cast TCP heartbeats stayed alive - those go through Google's infrastructure, not the backend - but the cast device's audio fetch and the phone's waveform/lyrics/state-save HTTP requests all timed out). Fix: every `subprocess.run` / `subprocess.Popen` blocking call in `youtube_download.py` is now wrapped in `eventlet.tpool.execute(...)` so a real OS thread blocks on the pipe and the eventlet hub stays free. The Popen+readline loop's per-line `readline()` goes through tpool individually so the loop body itself (socketio progress emits, cancel-tracking, etc.) still runs on the hub. Three call sites fixed: `get_video_info` (subprocess.run timeout=30), `get_playlist_info` (subprocess.run timeout=120), and the main download loop (Popen + readline + process.wait).
- **Backend: yt-dlp YouTube cookies via browser profile.** Age-gated videos and a few other YouTube responses fail for anonymous clients with `Sign in to confirm your age` - yt-dlp's standard fix is `--cookies-from-browser <browser>` which reads cookies directly from an installed browser's profile DB on the same machine. New `YT_DLP_COOKIES_FROM_BROWSER` env var (set in `backend/.env` to e.g. `chrome` / `firefox` / `edge`) flows through `Config` to a `_cookie_args()` helper on `YouTubeDownloader` that's spliced into all three yt-dlp invocations (single-video metadata, playlist enumeration, audio download). Empty / unset → no cookie passing, anonymous downloads only (current behaviour, age-gated videos still fail). Browser doesn't need to be running but its profile must exist on Desktop-alpine and the user account must be signed into YouTube there.
- **Backend: SMB circuit breaker.** v1.0.27's per-call timeout + tpool dispatch fixed the "one stale syscall hangs the entire eventlet hub" failure mode but left a deeper one in place: tpool's pool size is 20, and during a real SMB outage every stream / list / health-touch request that traverses the share generates a stuck OS thread that holds its slot for ~5 seconds before the timeout fires. With ~4 SMB-touching requests/second hitting a dead share, tpool saturates in ~5 seconds - and once saturated, totally unrelated tpool work (image fetches, ffmpeg transcodes, ShazamIO subprocesses) queues arbitrarily long behind the zombies. Recurred in this session's combined.log: `(26.089s)` stream → `🔴 SMB share unreachable` x3 → frontend perceived "backend locked up" because every new request stalled. New `_SmbBreaker` class in `backend/app/routes.py` watches `_smb_call`'s outcomes - after 3 timeouts within a 30-second window the breaker opens, after which every subsequent `_smb_call` raises `SmbUnavailable` immediately (microseconds, no tpool slot consumed). After a 10-second cooldown the next call is allowed through as a probe; success closes the breaker, failure re-opens it for another 10s. State transitions are logged to combined.log with `🔴 OPEN` / `🟠 re-OPENED` / `🟢 CLOSED` markers. Net effect: during an SMB outage the first ~3 requests pay the full 5s timeout each, then traffic drains in microseconds; unrelated tpool work keeps flowing; backend recovers on its own when the share comes back, no restart needed. **Backend restart required to pick this up.**
- **Hotfix in build 41: TV layout polish round 3, plus playlist/podcast quick-actions.** Build 40 device test on simpson1045's Firestick surfaced: scrubber stuck at 0:00 (advanced only every ~2 minutes), dashboard headers still scrolled off the top, plus two missing affordances for the podcast/playlist flow.
  - **TV Now Playing scrubber stuck at 0:00.** Build 38's `setState` gating fixed the rebuild-per-tick lag but cut off the position/time data the `WaveformProgressBar` needed to keep its internal smoother fed. The smoother extrapolates from `_lastKnownPosition + (now - _lastUpdateTime)` - fine in principle, but `_lastKnownPosition` only updates when `widget.position` changes, and gating the parent rebuild meant `widget.position` only refreshed on song / play-state change. Wrapped just the waveform + time-display subtree in a `ListenableBuilder(listenable: audioPlayerService)` so it re-renders on every notify (cheap subtree - no blurred bg, no Stack, no artwork CachedNetworkImage), while the rest of the screen stays gated. Scrubber now advances every second.
  - **Dropped the 1.25× TV font-scaling builder entirely.** v1.0.27 added it because the phone-screen-on-TV had text too small to read at 10 ft. The new `screens/tv/...` tree sizes its text explicitly for TV viewing distance, so the global 1.25× was double-counting - and on simpson1045's Firestick (940×540 dp logical) it pushed the dashboard's "Recently Played" section header past the viewport top no matter how tightly we trimmed the layout. Removing it lets the TV layouts render at their designed sizes (26pt title, 22pt section headers, etc.); phone is unaffected because the builder only ever ran for `isFireTvLike`. Same change drops the visible cropping on Now Playing - the panel now has comfortable headroom even with the explicit `Wrap` row of badges.
  - **TV Now Playing: format / HDCD / Explicit badges hidden during podcast playback.** Mirrors the phone Now Playing's `if (!song.isPodcast)` guard around the format chunk. For a podcast episode the `fileFormat` is the audio container the episode happens to ship in (mp3 / m4a / opus) - noise to the user - and frequently empty, which renders as a useless empty chip. Hiding it is unambiguously cleaner.
  - **`TvPlaylistDetailScreen`: Play + Shuffle action buttons in the header.** Right-aligned in the row with the playlist info - Play is the primary cyan-filled button (autofocuses on entry, so the d-pad's natural action is "play this whole playlist from track 1"), Shuffle is the dark-surface secondary button next to it. Shuffle picks a random starting index, queues from there, and ensures `audioPlayerService.isShuffled == true` so the queue continues to randomize as it advances - same pattern as the phone playlist screen's Play/Shuffle row. First track row no longer autofocuses (would compete with the Play button).
  - **`TvRssFeedDetailScreen`: Resume button in the header.** Visible only when there's an in-progress episode (`playedPosition > 0 && !isCompleted`) - first such episode is the resume target, matching the phone podcast detail's `_resumeEpisode` getter. Renders as a cyan-filled button showing the episode title and a mini progress bar of where the user left off; tap → `playPodcastEpisode(...)` resumes from that position. Autofocuses when present (so the natural d-pad action on entry is "keep listening to where I left off"), in which case the first episode row does NOT autofocus.
- **Hotfix in build 42: control alignment + playlist artwork.**
  - **TV Now Playing control row was rendering left-aligned.** Build 41 used a single `Row(mainAxisSize: MainAxisSize.max, mainAxisAlignment: MainAxisAlignment.center)` to lay out the 5 playback controls - which on every layout I'd reasoned through SHOULD have centered the slots. On the actual Firestick it didn't (simpson1045 could only see 3 of the 5 controls because they were jammed against the left edge with the favorite + black-screen slots clipped off the right). Suspect cause: some upstream constraint path in the SafeArea > Column tree was passing tight-width-but-not-full-screen-width constraints and `MainAxisAlignment.center` was centering within that smaller width while the slots overflowed. Switched to `Center(child: Row(mainAxisSize: MainAxisSize.min, ...))` - Row sizes to the 5 slots (480 dp), Center positions that 480 dp dead-center in whatever width is available. Unambiguous, no alignment surprises possible.
  - **TV Library - Playlists tab: artwork now displays.** Build 41 rendered the fallback `playlist_play` icon on every playlist tile because the imageUrl was `null` - I'd commented that "playlists don't have a stable artwork URL," missing that the backend has had a dedicated `GET /api/playlist-artwork/<int:playlist_id>` route the whole time (separate from `/api/artwork/<album_id>` because playlist art is often a 2x2 composed collage, stored under its own path). The url is now constructed via `${ApiService.baseUrl}/playlist-artwork/${playlist.id}`. CachedNetworkImage's errorWidget still falls back to the `playlist_play` icon for playlists that don't have artwork yet, so empty-art playlists keep working.
- **Cast receiver: DIAG_BOOT signal + explicit senderId routing for the receiver→sender diagnostic relay.** simpson1045's v=11 remote-key test produced zero `🎮 [Cast] Receiver msg` lines, even though skip-forward visibly worked (so commands ARE reaching the cast SDK). Two possible causes: (a) the LG cast device cached an older `receiver.js` and never fetched v=11, OR (b) `context.sendCustomMessage(NASRADIO_NS, undefined, ...)` is silently failing - some CAF SDK versions don't accept `undefined` as senderId. To disambiguate, added a `SENDER_CONNECTED` event listener that captures the sender's ID into `_activeSenderId` and fires a one-shot `DIAG_BOOT` custom message back to the sender immediately on connect. If `combined.log` shows `🚀 [Cast] Receiver booted: v12 …` at session start, the new receiver IS running AND the message routing works - meaning the message-interceptor diagnostic itself was broken. If no BOOT line appears, the cast device is serving a stale cached file regardless of cache busting. All existing diagnostic relays (DIAG_KEY, DIAG_MSG) now route through a `sendDiagToSender()` helper that uses the captured `_activeSenderId` instead of `undefined`. Bumped to `?v=12`.
- **Cast receiver: cast-protocol message interceptors for play/pause/seek diagnosis.** simpson1045's test confirmed: pressing LG remote media keys produces NO `🎮 [Cast] Receiver keydown` lines (the DIAG_KEY relay caught zero presses) - webOS doesn't forward those keys as `window.keydown` events. BUT skip-by-10 actually moved the playback position, meaning the commands DO reach the cast SDK, just through the cast protocol (`MESSAGE TYPE: SEEK`) rather than as raw key events. Play/pause presses theoretically should arrive the same way (`MESSAGE TYPE: PLAY/PAUSE`) - but simpson1045's test showed they don't actually pause the music. To find out where the chain breaks, added `playerManager.setMessageInterceptor` for PLAY / PAUSE / STOP / SEEK. Each interceptor relays `{type:'DIAG_MSG', msgType:'PLAY', currentTime:N}` back to the sender for `combined.log` capture via a new `DIAG_MSG` handler in `_handleCastMessage`. Interceptor passes the request through untouched, so default behaviour still runs. Next test will reveal whether PLAY/PAUSE messages reach playerManager at all (and we need to dig into why music doesn't actually pause) or whether webOS filters them entirely (genuine OS-level dead end). Receiver bumped to `?v=11`.
- **Cast receiver: remote-key diagnostic + best-effort media-key handling.** simpson1045's LG remote test surfaced that the OK key toggles play/pause (CAF SDK's default key-handler path) but the media-play-pause key brings up webOS's default cast overlay and DOESN'T actually pause music. Two possibilities: (a) the key event reaches our receiver but we don't act on it, or (b) webOS intercepts the key at the TV OS level and never forwards it. To distinguish: receiver.js now has a `window.addEventListener('keydown', ...)` that relays every keydown back to the sender via a new `DIAG_KEY` custom message on the `urn:x-cast:com.nasradio.custom` namespace. Sender-side `_handleCastMessage` adds a case for `DIAG_KEY` that logs `🎮 [Cast] Receiver keydown: key="X" code="Y" keyCode=Z` via AppLogger so it lands in combined.log. If a user reports "I pressed media-play-pause and nothing happened" and we see NO DIAG_KEY line for that press, webOS intercepted it and there's nothing more we can do receiver-side. If we DO see the line, our handling logic is wrong. Same listener also best-effort drives `playerManager.play()` / `.pause()` on `MediaPlayPause` keydown - if the key reaches us, it'll just work. Cache buster bumped `?v=9 → ?v=10`.
- **Cast receiver: smooth waveform fill - drop the playhead line, split-fill the boundary bar instead.** The v8 white vertical playhead line worked but felt artificial; simpson1045 wanted the waveform itself to gradually fill as time progresses. The bar quantization problem still has to be solved (each bar = 1/barCount of the total, so the played/unplayed colour boundary used to step ~180ms per bar). New approach: for the one bar the playhead is currently inside, draw the LEFT portion (width = `cursorX - bar.x`) in played colour and the RIGHT portion in unplayed colour. The split shifts smoothly through that bar at RAF rate. From outside the boundary bar everything looks the same (fully played or fully unplayed). Net effect: the fill edge slides through the waveform continuously, no white line, no visible step at bar transitions. Subtle radial glow at `cursorX` retained as a visual cue. Bumped `receiver.js?v=8 → ?v=9` and updated the startup-marker `console.log` so `chrome://inspect` shows whether the new version is loaded.
- **Cast receiver: continuous playhead cursor + cache-bust + startup marker.** First attempt at smoothing the receiver scrubber (`smoothedCurrentTime` + bumping `?v=7`) didn't visibly help on simpson1045's LG C2. Two reasons it didn't:
  - **Bar quantization dominated.** Even with perfectly smooth `currentTime` extrapolation, `drawWaveform` computes `playedBars = Math.floor(progress * barCount)` - for a 1000-sample waveform over a 3-minute song that's 0.18s of audio per bar. The played/unplayed colour boundary only crosses a bar threshold every ~180ms regardless of how fine-grained the time data is, so the scrubber visually steps in 180ms increments. Added a continuous playhead - thin 2px-wide white vertical line at exact `progress * w` x-position (continuous float), drawn on top of the bars. The cursor glides between bar boundaries at RAF rate while the per-bar colouring quantizes behind it. The glow effect was also moved from `playedBars * barWidth` (quantized) to `cursorX` (continuous).
  - **No way to verify a cached receiver was running.** Bumped `receiver.js?v=7 → ?v=8` and added a `console.log('[NASRadio] Receiver loaded: …')` startup marker. If you open Chrome's `chrome://inspect` against the cast device and don't see that line in the console at session start, the receiver is running a cached older copy and the cache buster needs another bump.
- **Cast receiver: smooth scrubber on the TV side.** The receiver's progress bar updated at ~4Hz (250ms-ish steps) instead of vsync rate on simpson1045's LG C2. The receiver was already using `requestAnimationFrame` for the tick (`startProgressPolling`), so the loop was running at 60-120fps - but inside the tick it read `playerManager.getCurrentTimeSec()`, which the CAF SDK derives from `HTMLMediaElement.currentTime` updated only on the browser's `timeupdate` event (~4Hz per HTML5 spec). So the RAF loop was correctly firing at vsync, but reading the same stale value across most ticks. Added `smoothedCurrentTime()` in `backend/cast/receiver.js`: caches the last "new" raw value + monotonic timestamp, and when subsequent ticks see the same raw value WHILE the player is in the PLAYING state, extrapolates forward as `lastRaw + (now - lastRawAt)`. When the raw value updates or the player isn't PLAYING (paused, buffering, idle), resyncs to authoritative. Same pattern as the Flutter `WaveformProgressBar._smoothPosition`. Bumped `receiver.js?v=6 → ?v=7` in `receiver.html` so the Chromecast / TV cache fetches the new file on the next cast session.
- **Bug fix: cast resume position always sent as 0.** Mid-song-cast and cast-reconnect-after-drop both started the song from 0 instead of resuming. Two separate bugs in the resume path, both surfaced by build 45's new logs:
  - **`_onCastStateChanged` clobbered `_position` with 0 from a fresh cast session.** New cast sessions report `position=0` with no media loaded yet; the listener was unconditionally writing that to `_position`. If you'd been casting and the session died (no media-cleanup on dropout) and you reconnected, the previous session's actual playback position would have been preserved in `_position` - but the new session's `position=0` overwrote it before `startCasting` could read it. Now gated: only sync `_position` from cast when `_castService.duration > 0` (proxy for "cast has media loaded"). The clobber only happens once LOAD has been processed and the receiver returns MEDIA_STATUS with actual media, by which point the cached position no longer matters.
  - **`startCasting`'s null-coalescing fallback never fired.** The code `_justAudioPlayer?.position ?? _position` only falls back to `_position` when the player REFERENCE is null. `position` itself is non-nullable Duration - if the local player exists but is at zero (you weren't playing locally, e.g. you were already casting), `position` returns `Duration.zero` and `??` doesn't trigger. Intent was "use `_position` if local player is at 0," but the operator semantics didn't match. Replaced with explicit `localPos.inMilliseconds >= _position.inMilliseconds ? localPos : _position` - pick whichever source has the larger position, on the theory that the larger one is the authoritative playback position.
  - **Plus much more detailed `startCasting` logging.** Now logs `localPos`, `cachedPos`, `slot`, `playerA.position`, `playerB.position` so if this misfires again we have full visibility into which source is wrong and which is right.
- **Log viewer: opens at the latest entries + top/bottom jump buttons.** Both System Logs and Frontend Logs viewers (`system_logs_screen.dart`, `frontend_logs_screen.dart`) used to land at the very top of a 500-entry list on open, requiring a manual scroll to find what just happened. They DID call `_scrollController.jumpTo(maxScrollExtent)` on initial load - but `ListView.builder` is lazy, so `maxScrollExtent` only reflects the items currently built into the viewport (~10-15 of the 500), not the full list extent. The single `jumpTo` barely moved past the first screen of items. Fixed with a recursive `_scrollToBottom()` helper that jumps, schedules a post-frame check, and re-jumps if more items got built (i.e. `maxScrollExtent` grew); stops when the position is stable. Both screens now open at the most recent entries. Also added two dedicated app-bar buttons in each viewer: a top arrow (`Icons.vertical_align_top`) for one-shot jump-to-oldest, a bottom arrow (`Icons.vertical_align_bottom`) for one-shot jump-to-newest. The existing auto-scroll toggle is now a separate play/pause icon - pressing the bottom-jump button also flips auto-scroll back on (you're back to following the tail), pressing top-jump pauses auto-scroll (you wanted to be away from the tail).
- **Cast receiver: continuous playhead cursor + cache-bust + startup marker.** Four recurring symptoms surfaced during multi-day cast testing - cast dropping after a few songs, waveform stopping after 1-2 songs (scrubber degrades to a line + dot), lyrics-load freezing the receiver UI, and the cast-side scrubber updating at 500ms-1s instead of vsync rate. None reliably reproduce on a fresh session and the existing logging is mostly `print()` calls which only reach the local debug console, not `combined.log` (per the v1.0.25 lesson - the backend ring buffer / `combined.log` is fed exclusively by `AppLogger.instance`). This build adds AppLogger-routed instrumentation in four places, NO behavior changes:
  - **`cast_session.dart`:** opened-at timestamp + tx/rx counters on the sender heartbeat. Every 6 PINGs (~30 seconds) emits a `💓 Heartbeat tx=N rx=M uptime=Xs state=Y` summary line. Socket `onDone` and `onError` now log uptime + tx/rx counts so we can see "session closed after Xs with M PONGs missed" patterns. Receiver-initiated `CLOSE` is logged with the same uptime context. `LAUNCH_ERROR`, `Stream error`, and session-connected transitions also routed to AppLogger. PING / PONG / RECEIVER_STATUS per-tick messages stay as `print()` - too noisy for the backend log, available in the debug console when needed.
  - **`cast_service.dart`:** `_sendWaveformAndLyrics` now logs start, per-fetch elapsed ms, sizes (sample count for waveform, char count for synced + plain lyrics), and total elapsed. So if the waveform / lyrics stop reaching the receiver after a few songs we'll see WHERE it broke (fetch failed, session was null, session disconnected, etc.). Connect / disconnect / LAUNCH_ERROR / LAUNCH timeout / connection-failed paths also routed to AppLogger.
  - **`now_playing_screen.dart` - `_loadWaveform`:** START / DONE (with sample count) / FAILED (with elapsed ms and the error). Cache hits are explicitly noted. Same shape as the cast-side waveform log so we can cross-reference whether phone-side and cast-side fetches are working in parallel or diverging.
  - **`lyrics_view.dart` - `_loadLyrics`:** START / DONE (with character counts) / aborted-by-supersede (when the song changes mid-fetch) / FAILED. Additionally, the synchronous `LyricLine.parseLrc()` call is now bracketed with its own start/end log so we can see how much of any UI freeze is from network fetch vs from the main-thread LRC parse for long lyrics - the "loading lyrics on cast freezes the UI" complaint may turn out to be a parse-time issue.
- **Hotfix in build 43: control alignment (round 2) + playlist collage.**
  - **Now Playing controls - `MainAxisAlignment.spaceEvenly`.** Build 42's `Center(child: Row(mainAxisSize.min, ...))` rendered exactly the same as build 41 on the Firestick - slots still appeared bunched on the left of the row. Whatever upstream constraint chain is causing the row to perceive a narrower-than-screen width is something I haven't traced. spaceEvenly side-steps the issue: it's a Row layout policy that distributes equal space before, between, and after children regardless of how the row was laid out, computing slot positions purely from main-axis-extent ÷ slot-count. If even spaceEvenly fails to center, the row genuinely isn't getting any width and we'd see all 5 slots stacked at x=0 - at which point we'd need a screenshot to debug further.
  - **TV Library playlists - 2×2 album-cover collage.** Build 42's `/api/playlist-artwork/<id>` route only returns the FIRST song's album art (single image) - the phone's 2×2 collage is built CLIENT-side by fetching the playlist's songs, taking the first 4 unique `album_id`s, and rendering a `GridView.count(crossAxisCount: 2)` of `getArtworkUrl(albumId)`. Mirrored that on the TV side: new `_getPlaylistAlbumIds(int)` cache + helper, and a new `_TvPlaylistCard` widget that uses a `FutureBuilder` to lazily fetch its tile's collage as the user scrolls. 1-3 unique albums → single image; 4+ → 2×2 collage; empty/error → `playlist_play` icon fallback. Cache survives tab switches because `IndexedStack` keeps the Library mounted.
- **Caveats / known scope of slice 2:**
  - Album and artist detail screens are still the phone versions - functional via Material's default `ListTile` focus, but no cyan focus rings, no big-text TV polish. Slice 3 if/when needed.
  - Search and Settings rail items still show "Coming soon" placeholders. Search lands in slice 3 with the Fire TV remote app keyboard / Alexa voice path; Settings lands when there's actual TV-relevant settings to expose.
  - Playlists with custom artwork render as the fallback tile in the Library grid because there's no public URL endpoint for `playlist.artworkPath`. Cosmetic - playlist name + song count is still readable, and tapping into the TV playlist detail works the same.


## 1.0.28 - 2026-05-08
First slice of a separate Fire TV / Android TV UI tree (Option C from the v1.0.27 handoff). v1.0.27's Fire TV polish pass tried to retrofit d-pad navigability onto the existing phone screens by wrapping them in `TvFocusable` / `TvIconButton`. Two sessions of debugging confirmed the retrofit didn't work - Flutter focus bugs #115550 (equal-bounds traversal), #96860 (`IconButton.focusNode` doesn't attach), and #43719 (`KEYCODE_DPAD_CENTER` not bound to `ActivateIntent`) interacted in ways the wrapper widgets couldn't fix from the outside. This release flips the strategy: a greenfield `frontend/lib/screens/tv/` tree designed d-pad-first, with the phone screens reverted to their pre-v1.0.27 shape. Slice 1 covers the routing shell + dashboard + Now Playing - Library / Search / Settings show "Coming soon" stubs in the side rail and land in slices 2 and 3. Tested target: Fire TV bedtime music. **Phone behaviour should be identical to v1.0.27 build 35** - verify after install.

- **New: Fire TV / Android TV detection and routing.** `main.dart` now exports a top-level `bool isFireTvLike(BuildContext)` predicate (Android + screen width ≥1280 + shortest side ≥600 - same heuristic that already drove the v1.0.27 TV-mode font scaler). A new `_RootRouter` widget wraps `MaterialApp.home`, decides between `MainNavigationScreen` and `TvMainNavigationScreen` on the first build, and caches that decision for the rest of the session - without caching, the entire navigation tree would remount on rotation if the heuristic ever flipped, losing all in-flight async, scroll positions, and route state.
- **New: `TvMainNavigationScreen` - TV side-rail shell** (`screens/tv/tv_main_navigation_screen.dart`, ~310 LOC). Vertical 260px-wide rail on the left with 4 items (Home / Library / Search / Settings) above an `IndexedStack` of section screens. Rail items are `TvFocusable`-wrapped Containers that traverse cleanly via d-pad up/down because they're a Column of differently-sized rows - none of the equal-bounds-Expanded-children pattern that triggered #115550 in the navbar retrofit. Selected item is highlighted with a cyan-tinted background + bold label. Health/update banners and the existing `MiniPlayer` strip stay in their familiar positions (top + bottom of the screen).
- **New: `TvDashboardScreen`** (`screens/tv/tv_dashboard_screen.dart`, ~280 LOC). Vertical scroll of horizontally-scrolling rows - the standard 10-foot UX pattern. Two rows in slice 1: Recently Played and Most Played. Each row is a `ListView.separated` of `_TvSongCard`s (200px square album art + title + artist). First card on the first non-empty row autofocuses on entry so the d-pad lands on something immediately. Tapping a card mirrors the phone dashboard's `_playSong`: fetches the full album so prev/next work in the queue, falls back to single-song play if the album fetch fails. Listens to `audioPlayerService` and refetches Recently Played whenever a new song starts - `IndexedStack` keeps the dashboard mounted across rail switches, so a one-shot `initState` load would have stayed stale forever.
- **New: `TvNowPlayingScreen`** (`screens/tv/tv_now_playing_screen.dart`, ~580 LOC). Models on the cast receiver's left-panel layout (`backend/cast/receiver.html` / `receiver.css`): full-bleed blurred album art background (`ImageFilter.blur(30, 30)`) with a 55% black scrim, centered ~42vh artwork (rounded 12px, drop shadow), title (with `MarqueeText` for overflow), artist, album, format/HDCD/explicit badges, full-width `WaveformProgressBar` at the bottom, and a horizontal row of 5 `TvIconButton` controls - prev / play-pause (autofocus on entry) / next / favorite / black-screen. Top-right shows the wall clock + sleep timer countdown when the timer is active. Black-screen overlay is a separate render branch (full-screen black `TvFocusable` with `autofocus: true`) so an active black screen renders only the dismiss target - no off-screen focusable controls competing for d-pad input. Background album art is its own widget so it doesn't re-blur on every position-tick rebuild of the parent.
- **New: TV-friendly inline favorite button.** The phone `FavoriteButton` widget is a `StatefulWidget` with a private `_toggleFavorite` and an internal `IconButton` - there's no public hook for the d-pad `ActivateIntent`, and wrapping it in `TvIconButton` would route the OK press to the wrapper, not to the inner toggle. Built a small `_TvFavoriteButton` inside `tv_now_playing_screen.dart` that calls the same three `ApiService` endpoints (`checkFavorite` / `addFavorite` / `removeFavorite`) but renders through `TvIconButton` so the cyan focus ring is consistent with siblings.
- **`NowPlayingScreen.open(...)` now branches on Fire TV.** All 47 existing call sites across the app keep working unchanged - only the static helper changes. After the `popUntil` dedupe, it checks `isFireTvLike(context)` and pushes `TvNowPlayingScreen` instead of `NowPlayingScreen`, both with the same `RouteSettings(name: 'now_playing')` so subsequent calls dedupe against either variant correctly.
- **Reverted: phone-screen retrofit from v1.0.27.** v1.0.27 wrapped d-pad-relevant widgets in `TvFocusable` / `TvIconButton` across six phone screens - that retrofit didn't actually solve d-pad navigation (per the v1.0.27 handoff and simpson1045's testing). 29 wrapper sites stripped: 16 in `now_playing_screen.dart` (playback rows, secondary controls, sleep timer dialog presets), 5 in `dashboard_screen.dart` (recently-played, most-played, recently-added, release tiles), 2 in `library_screen.dart`, 2 in `search_screen.dart`, 1 in `album_detail_screen.dart`, 3 in `artist_detail_screen.dart`. Six `tv_focus.dart` imports removed. The `mini_player.dart` `TvFocusable` wrap stays - its inner `GestureDetector` handles touch on phone, and it gives the TV layout d-pad reachability of the bottom strip without an extra wrap from `TvMainNavigationScreen`.
- **Reverted: custom navbar Row in `MainNavigationScreen`.** v1.0.27's `FocusTraversalGroup(OrderedTraversalPolicy())` + per-child `FocusTraversalOrder` + `TvFocusable` Row replacement for `BottomNavigationBar` didn't fix the focus traversal it was supposed to fix on Fire TV, and the bottom-nav pattern is now Fire-TV-irrelevant anyway (Fire TV uses the side rail). Reverted to plain `BottomNavigationBar` - phone gets its native bottom nav back, with all the Material affordances (animation, ink wells, accessibility) that the custom Row didn't replicate.
- **Reverted: `FocusManager.instance.highlightStrategy = alwaysTraditional`.** Forced focus rings to always show regardless of input mode - added during the v1.0.27 retrofit to make rings visible on Fire TV. Side effect: on phone, tapping a button could briefly flash a cyan ring during/after touch (visible whenever a focus event ever fired on a Material widget), which looked off. Default Flutter behaviour (`FocusHighlightStrategy.automatic`) hides rings during touch and shows them during keyboard/d-pad input - exactly what we want now that Fire TV runs in a separate widget tree where every focusable already gets explicit ring rendering via `TvFocusable` / `TvIconButton`. Phone returns to standard touch UX.
- **Kept: `LogicalKeyboardKey.select → ActivateIntent` shortcut at `MaterialApp` level.** Fire TV's d-pad center sends `KEYCODE_DPAD_CENTER` which Flutter maps to `LogicalKeyboardKey.select` - the default `ActivateIntent` shortcut map binds Enter / Space / gameButtonA but NOT select (Flutter Issue #43719). Without this binding, OK on the Fire TV remote does nothing on a focused button. Useful in the new TV tree; harmless on phone.
- **Kept: TV-mode font scaling builder.** When running on Android with a TV-class screen, wraps the app in a `MediaQuery` with `textScaler` bumped 1.25× (clamped at 1.5×). Now applies to the new TV screens too, since they sit inside the same `MaterialApp`.
- **Cleanup: `widgets/tv_focus.dart`.** Added `autofocus` parameter to `TvFocusable` (was already on `TvIconButton`) so TV screens can claim initial focus on the right widget without an explicit `FocusNode`. Dropped the `AppLogger` debug log spam from both widgets - the v1.0.27 build-31-34 focus-debugging traces are no longer useful and were filling `combined.log` on every navigation event. Dropped the `Scrollable.ensureVisible` call from `TvIconButton` (kept on `TvFocusable` for horizontal carousels in the dashboard) - control rows don't scroll, so the call was a no-op fighting the existing focus tree.
- **Cast heartbeat fix carries forward unchanged.** v1.0.27 build 35's sender-initiated `PING` every 5 seconds in `cast_session.dart` is still in place. If "casting plays a few songs then stops" was the symptom on phone before this build, it should remain fixed.
- **Hotfix in build 37: Fire TV detection predicate loosened.** Build 1's `isFireTvLike(context)` required `size.width ≥ 1280 dp AND shortestSide ≥ 600 dp` - the same predicate that drove v1.0.27's TV-mode font scaler. Empirically that didn't fire on simpson1045's Firestick - build 36 still showed the phone-screen layout on the TV. Fire TV / Android TV report widely varying logical-pixel sizes depending on display density: older sticks at density 1.0 give 1920×1080 dp, newer 4K sticks at density 2.0 give 960×540 dp, some smaller. The shortest side is always ≥540 dp on a TV, and no phone has `shortestSide` above ~411 dp, so a single `shortestSide ≥ 540` check catches every TV-class device without flipping any phone. Tablets get bucketed with TVs by this rule too - known false positive for slice 1, will be revisited if anyone actually runs NASRadio on a tablet. Build 37 also added a one-shot `AppLogger.instance.info` line from `_RootRouter` that logs the actual `MediaQuery` size + DPR + `isTvLike` decision once at startup - visible in `combined.log` within ~30s of app launch - so this kind of detection failure can be diagnosed from the backend log without an `adb logcat` session against the Firestick. Same predicate change refactored the TV-mode font scaler builder to call `isFireTvLike(context)` instead of duplicating the inline check.
- **Hotfix in build 38: TV layout polish round 1.** First device test of the TV layout (build 37 on Firestick) surfaced five issues, fixed in build 38:
  - **NASRadio brand logo in the side rail.** Build 37 used a generic `Icons.radio` Material icon as a placeholder. The actual logo files were already in the project - just scattered across platform-specific locations (`backend/cast/nasradio_logo.svg`, `frontend/web/icons/Icon-{192,512}.png`, Android mipmap launcher PNGs, iOS Assets.xcassets, Windows app_icon.ico) and not collected in `frontend/assets/` where Flutter's `Image.asset` looks. Copied `frontend/web/icons/Icon-512.png` to `frontend/assets/images/nasradio_logo.png`, registered it in `pubspec.yaml`, swapped the `Icon(Icons.radio)` in `tv_main_navigation_screen.dart` for `Image.asset(...)`. No new dependencies (would have needed `flutter_svg` for the SVG path, and simpson1045 has flagged dependency upgrades as a separate scheduled session).
  - **TV Now Playing - title / artist / album / badges were rendering invisibly.** Build 37's 55% black scrim over the blurred album art wasn't dark enough - bright album covers (e.g. light skin / white-shirt portraits) blurred to a near-white smudge that the scrim only knocked down to ~45% brightness, and white text rendered on top was effectively invisible. The clock in the top-right was readable because it had an explicit `Shadow` baked into its `TextStyle`; the body text had none. Fixed two ways: scrim bumped to 70% (matches what the receiver's idle screen does on a dark gradient bg), and added `Shadow(color: Colors.black87, blurRadius: 8-10, offset: (0, 2))` to title, artist, and album text styles. Title's `SizedBox` height also bumped from 42 → 48 so 1.25× TV font scaling on the 30pt MarqueeText doesn't get clipped.
  - **TV Now Playing was visibly laggy.** `_onPlayerChange` was calling `setState(() {})` on every `audioPlayerService` notify - including the 1Hz position ticks during playback. With the screen's `_BlurredArtBg` (`ImageFiltered(blur sigma 30)`) + the full Stack of overlays + the artwork CachedNetworkImage all in the rebuild path, that's a non-trivial repaint every second. Same root cause as the v1.0.27 build-29 dashboard rebuild fix. Now gated to song / play-state / loading / sleep-timer-active / duration changes only. `WaveformProgressBar` already does its own 60fps position smoothing internally, so dropping position-tick rebuilds doesn't make the progress bar look stale.
  - **Dashboard "Recently Played" header invisible on first build.** The 38pt "Home" page-title at the top of the dashboard was redundant (the rail already shows the selected section as "Home" with cyan highlight) and ate enough vertical space that the section header below it scrolled past the viewport on first render with autofocus on the first card. Dropped the page title, tightened the top padding (28 → 16), reduced inter-row spacing (36 → 24), reduced row height (290 → 270). Content now fits in the viewport without needing to scroll, so the per-row section headers stay visible above their cards.
  - **Black-screen mode showed a cyan ring around the entire screen.** The dismiss target was wrapped in `TvFocusable(autofocus: true)` - which then drew its 3px cyan focus border around the full-screen black `Container` the moment it claimed focus. Defeats the whole point of black-screen mode. Replaced with `Focus(autofocus: true) + GestureDetector` directly: claims focus invisibly, dismisses on any `KeyDownEvent` (so any d-pad direction OR OK on the remote works) or any tap. No focus ring drawn.
- **Hotfix in build 39: TV layout polish round 2.** Build 38 didn't fix three of the four issues it tried to fix (only the black-screen ring landed). Root causes turned out to be deeper than just text shadows / scrim opacity / "Home" header height:
  - **Logo: build 38 used the wrong source PNG.** I copied `frontend/web/icons/Icon-512.png` thinking it was the NASRadio brand mark - turns out it's the default Flutter scaffolding icon that never got replaced when the rest of the app was branded. The real brand icon lives in the platform-specific app-icon directories (Android mipmaps, iOS `Assets.xcassets`, Windows `app_icon.ico`). Build 39 sources `frontend/assets/images/nasradio_logo.png` from `frontend/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` - same brand asset the iOS launcher already uses, at 1024×1024 so it scales cleanly to the rail's 44×44 widget.
  - **TV Now Playing - title / artist / album / badges still invisible.** Build 38 tried to fix this by darkening the scrim and adding text shadows, on the assumption the text was rendering but had low contrast. Wrong diagnosis: the text wasn't rendering at all, because `MarqueeText` was wrapped in a `Padding` whose width came from a Column with default `crossAxisAlignment.center`, leaving `MarqueeText` with effectively unbounded horizontal constraints. Build 39 rewrites `_buildCenterPanel` to take `availableWidth` from a `LayoutBuilder` and wrap each text line in an explicit `SizedBox(width: textWidth)` (computed as `availableWidth - 120` clamped to `[300, 1100]` dp). Switched from `MarqueeText` to plain `Text` with `maxLines: 2` (title) / `maxLines: 1` (artist, album) and `TextOverflow.ellipsis` - simpler, no third-party widget dependency, no overflow surprises. Badges row swapped from `Row` to `Wrap` so format / HDCD / explicit badges flow onto a second line gracefully if the album cover has all three.
  - **Dashboard headers still scrolling off when first card is selected.** Build 38 dropped the giant "Home" header thinking content height was the only cause - wrong, the deeper root cause was `Scrollable.ensureVisible(ctx, ...)` walking the entire ancestor scrollable chain. For a card inside a horizontal `ListView` inside the dashboard's outer vertical `SingleChildScrollView`, both scrolled - the outer scroll pulled the "Recently Played" section header off the top. Build 39 changes `TvFocusable._onFocusChange` to call `Scrollable.maybeOf(ctx)?.position.ensureVisible(renderObject, ...)` directly - that scopes the scroll to ONLY the nearest enclosing scrollable (the inner horizontal `ListView` for d-pad-through-cards, which is what we actually want), and leaves the outer vertical scroll alone. Section headers now stay put.
- **Caveats / known scope of slice 1:**
  - Side rail Library / Search / Settings tabs land on a "Coming soon" placeholder. Tabs work for d-pad navigation; tapping just shows the stub.
  - Search input on Fire TV deferred - the on-screen-keyboard story is rough; will use the Fire TV remote app's keyboard or Alexa voice in the slice that adds search.
  - TV settings will be a TV-oriented subset, not a port of the phone settings dialog.
  - TV side does not yet support album-detail / artist-detail / queue-management / sleep-timer-set-from-TV screens. For now, set the sleep timer on the phone before reaching for the Firestick remote.
  - Side rail is always-expanded at 260px. Auto-collapse-on-blur (the standard Android TV pattern) is a polish item for a later slice if it's a problem in practice.


## 1.0.27 - 2026-05-08
Backend SMB resilience + first Fire TV polish pass. The SMB fix is the real conclusion to the session-opening backend wedge; v1.0.23-v1.0.26 fixed everything else but the original spinner-of-death symptom was never addressed at the code level until now. The Fire TV pass landed alongside because simpson1045 sideloaded the APK on a Firestick mid-session for bedtime music - the existing UI was *mostly* navigable but the dashboard cards and Now Playing controls were unreachable with the d-pad. **Backend restart required** to pick up the SMB fix; everything else ships in the APK.

- **Backend: UNC stat calls in `stream_song` now run on a tpool thread with a 5-second wall-clock timeout.** New helpers `smb_exists()` and `smb_getsize()` route every `os.path.exists` / `os.path.getsize` against `\\nas\Music\…` through `eventlet.tpool.execute` (so the hub thread stays free for `/api/logs`, `/api/health`, and other streams) wrapped in `eventlet.Timeout` (so a stale SMB session can't pin a request indefinitely). On timeout the helpers raise `SmbUnavailable` and `stream_song` returns `503 Service Unavailable` immediately - phone gets a fast error and either retries or shows "song unavailable", instead of an indefinite spinner. Six SMB-touching call sites in `stream_song` converted: original-file existence check, cache-file existence check, two `getsize` calls (cache-hit and post-transcode), opportunistic-prefetch existence check (degrades to "skip prefetch"), and final original-file `getsize`. `send_file` itself wasn't wrapped - its file open is bounded inside Werkzeug.
- **Backend trade-off documented:** tpool default size is 20 and we can't kill an OS thread cleanly from Python - so under prolonged SMB outage tpool can fill up with stuck threads. Once exhausted, new tpool calls queue. In practice once 20 stream requests are stuck a backend restart is the right answer anyway, and at least the hub keeps serving non-streaming requests until then. Worth raising tpool size or implementing a circuit breaker if this becomes a recurring problem.
- **Fire TV: dashboard cards are now d-pad navigable.** New `_TvFocusable` wrapper widget at the top of `dashboard_screen.dart` adds `FocusableActionDetector` + a 3px cyan border overlay (via `Stack`, no layout shift) around any tappable region. Maps d-pad center / Enter / Space to the existing `onTap` callback via the standard `ActivateIntent`. Replaced 5 bare `GestureDetector(onTap:…)` cards with `_TvFocusable`: the weather widget, recently-played row tiles, most-played row tiles, recently-added album tiles, and upcoming/recent release tiles. The Quick Access row was already using `InkWell` so it was reachable; everything else on the dashboard is now too. Touch behavior unchanged.
- **Fire TV: Now Playing playback controls show a visible focus ring.** New `_TvIconButton` wrapper at the top of `now_playing_screen.dart` overlays a 2px cyan circle around any focused `IconButton`. Default Flutter focus highlight on `IconButton` is a faint hover-color overlay that's basically invisible at 10-foot Fire TV viewing distance - no way to tell which control the d-pad is currently pointing at. Both portrait and landscape playback rows updated: shuffle, skip-previous, play/pause, skip-next, repeat - five focus rings each, sized to match each button's hit target. The buttons themselves were always focusable; the user just couldn't see it. Hardware play/pause key on the Fire TV remote keeps working via the v1.0.23 MediaSession integration (separate path from focus-based activation).
- **Fire TV: secondary control row in the landscape immersive layout.** The immersive layout (used on phone landscape and full-screen TV) hides the regular app bar - which on Fire TV meant lyrics, sleep timer, queue, and info buttons were entirely inaccessible. Added a five-button row underneath the main playback controls: lyrics toggle, **bedtime/sleep timer**, black-screen toggle, queue, info. All `_TvIconButton` for d-pad navigability + visible focus rings. Sleep timer was already wired to local playback via `audioPlayerService.startSleepTimer()` regardless of cast state - simpson1045 just couldn't reach it on the Firestick because the button didn't exist in landscape.
- **Fire TV: native black-screen overlay (sleep mode for Fire TV).** Mirrors the cast-receiver-side BLACK_SCREEN feature so users without a Chromecast in the chain still get OLED-friendly bedtime mode. Wraps the entire Now Playing widget tree in a `Stack`, with a full-screen opaque black `GestureDetector` overlay that activates from the new dark-mode button and dismisses on tap or d-pad center (`FocusableActionDetector` autofocuses on activate so OK on the remote works the moment the screen goes black). Music keeps playing through HDMI; only the visual is suppressed. When casting, also forwards the toggle to the existing cast receiver via `globalCastService.setBlackScreen()`.
- **Fire TV: TV-mode font scaling.** Hooked into `MaterialApp.builder` - when running on Android with a screen ≥1280px wide AND shortest side ≥600px (catches Fire TV / Android TV boxes, leaves phone landscape alone), wraps the app in a `MediaQuery` with text scaler bumped 1.25× over whatever the user already has set. Clamped at 1.5× total so accessibility users with already-large text don't blow up the layout. Default phone sizes target ~30 cm viewing; 10-ft TV viewing needs the bump for comfortable reading.
- **Fire TV: shared `TvFocusable` + `TvIconButton` widgets in `widgets/tv_focus.dart`.** Extracted the dashboard + Now Playing private wrappers into one public file so other screens can pick them up without duplication. Same behavior - focus ring on d-pad navigation, `ActivateIntent` wired to `onTap` - just reusable.
- **Fire TV: library, search, album detail, and artist detail screens d-pad audited.** Library: the "tap to load songs" empty-state hint and the Year-decades toggle chips use `TvFocusable` now. Search: song and album result cards in the horizontal carousel rows. Album detail: the tappable artist-name link under the album header. Artist detail: artist photo (tap-to-zoom), the "My Stats / Global" tab toggles in the Popular section. The artwork-zoom dialog itself now dismisses on d-pad center via `FocusableActionDetector(autofocus: true)` - without that, the fullscreen overlay had no focusable widget and was a dead end on Fire TV. ListTiles across all four screens were already focusable by default. Means you can now navigate Browse → Library → an album → its artist → zoom artist photo → dismiss → all with the remote alone.
- **Fire TV: focused items now auto-scroll into view in horizontal carousels.** Both `TvFocusable` and `TvIconButton` call `Scrollable.ensureVisible(ctx, alignment: 0.5)` in a post-frame callback when they receive focus. Without this, d-pad navigation through the dashboard's recently-played / most-played / recently-added rows moved focus to off-screen items - the cyan ring would leave the viewport with no way to tell what was selected. Default Flutter focus traversal does NOT call `ensureVisible`, so this was a hard prerequisite for usable d-pad navigation in any horizontally-scrolling list.
- **Fire TV: sleep timer dialog presets show the cyan focus ring.** `_buildTimerOption` was returning bare `ListTile`s; ListTile is focusable but Material's default focus highlight is invisible at TV viewing distance - simpson1045 couldn't tell which preset the d-pad was on. Replaced with `TvFocusable` wrapping a custom Padding+Row that mimics ListTile layout. Double-focus avoided by NOT nesting an InkWell inside (would create competing focus nodes).
- **Hotfix in build 29: dashboard no longer rebuilds on every position tick.** `_DashboardScreenState._updateState` was calling `setState(() {})` on every `audioPlayerService` notification, including 1Hz position ticks during playback. Tolerable before the Fire TV pass but visibly sluggish once each card became a `TvFocusable` Stack - pause/play and screen change felt laggy. Now gated to fire only when the current song or play state actually changes; position ticks no longer rebuild the dashboard at all. Behavior preserved (the dashboard still refreshes on song changes, still updates highlights when playback toggles).
- **Hotfix in build 29: Now Playing screen is now d-pad navigable.** Build 28's `KeyboardListener` had `autofocus: true` unconditionally, which on Android claimed focus on an invisible widget - d-pad presses bounced off it and never reached the playback buttons. Now `autofocus: !_isMobile` so desktop keeps F11 / Escape handling but Android (phone + Fire TV) lets the natural focus tree pick the first real `FocusableActionDetector` (typically the back button or a `TvIconButton`). Fire TV remote now navigates the screen as designed. F11 / Escape on desktop unchanged.
- **Hotfix in build 29: bottom navbar replaced with focusable `TvFocusable` row.** Flutter's `BottomNavigationBar` is a single focus node - d-pad inside it doesn't traverse between items reliably on Android TV. simpson1045 reported only Home / Library / Search would highlight before focus disappeared entirely. Replaced with a `Row` of six `TvFocusable` items in `MainNavigationScreen`, each its own focus target with the cyan ring. All six tabs (Home, Library, Search, Playlists, Favorites, Playing) are now individually reachable via d-pad. Touch behavior preserved on phone.
- **Hotfix in build 29: auto-scroll-on-focus is less aggressive.** Build 28 used `Scrollable.ensureVisible` with `alignment: 0.5` + `ScrollPositionAlignmentPolicy.explicit`, which always re-centered the focused item even when already fully visible - every focus change triggered a 200 ms animated scroll. Switched to `keepVisibleAtEnd` policy: no-op when the item is already in the viewport, scrolls only when the item is below/right of the visible area. Helps general snappiness across all d-pad navigation.
- **Hotfix in build 30: Slider on Now Playing no longer steals d-pad focus.** Build 29 made Now Playing's `KeyboardListener` not autofocus on Android, expecting Flutter's focus tree to land on the play/pause button. Instead it landed on the Slider above the controls (Slider is focusable by default and has built-in d-pad-left/right semantics that intercept arrow keys to decrement/increment value). Slider's focus indicator is invisible, so the user saw nothing happen and assumed the screen wasn't navigable. Wrapped the Slider in `ExcludeFocus` - still draggable by touch on phones, just removed from d-pad traversal. Added `autofocus` parameter to `TvIconButton`; Now Playing's play/pause button uses `autofocus: _isMobile` so initial focus on Android lands there.
- **Hotfix in build 30: navbar d-pad traversal scoped to the navbar.** Build 29's custom `TvFocusable` row replaced Flutter's `BottomNavigationBar` but didn't isolate traversal - d-pad right past Search would find the closest geometric focusable, which on the dashboard was a card in the Recently Added row above the navbar (not Playlists). Looked like "highlight disappears" because the focus ring jumped up to a different region. Wrapped the navbar Row in `FocusTraversalGroup(policy: OrderedTraversalPolicy())` so left/right keys step through the six tabs in order and don't escape into the body's focusables. All six tabs (Home, Library, Search, Playlists, Favorites, Playing) now reachable; right-of-Playing and left-of-Home are no-ops.
- **Fire TV: mini player at the bottom of every screen is d-pad-tappable.** The strip showing current song + spark progress bar (visible from dashboard / library / search etc.) was a `GestureDetector(onTap: NowPlayingScreen.open)` - invisible to focus traversal. Now `TvFocusable` so the remote can navigate to it and OK to open the full Now Playing view. Useful path: dashboard → music plays → mini player at the bottom is the natural way to open Now Playing without leaving the current screen.
- **Caveat:** still not d-pad-friendly: artwork tap (zoom), progress bar drag (seek), inline song badges, the chapters strip, queue tile reordering, settings dialog, podcast / Spotify / Prowlarr / RSS detail screens, artist detail mini-buttons, and the artwork-zoom dialog dismiss. ListTile-based screens generally work but lack the visible focus ring (Material's default focus highlight is subtle). Staged for follow-up.
- **Hotfix in build 35: cast session no longer drops mid-playback after a few songs.** The sender side wasn't initiating its own `PING` on the heartbeat namespace - it only responded to receiver-initiated pings. The cast receiver expects bidirectional liveness on `urn:x-cast:com.google.cast.tp.heartbeat`; if the sender goes quiet for too long the receiver idle-times-out the connection, which manifested as casting plays a few songs then mysteriously stops in the middle of the queue. `cast_session.dart` now sends a sender-initiated `PING` every 5 seconds, cancelled on `close()` and on the underlying TLS socket's `onDone` callback. The receiver answers with `PONG` (the existing message-pump already drops unrecognized payloads silently) and the session stays alive across the full queue.


## 1.0.26 - 2026-05-08
Honest UX for cast volume on AVR/eARC chains. v1.0.24/25's diagnostic confirmed the receiver reports `volume.controlType: 'fixed'` - the Chromecast → TV → Denon → eARC chain has the AVR as master volume controller, and the cast device cannot affect it. Considered HEOS API integration to talk to the Denon directly; rejected on grounds that direct LAN protocol against a third-party device has too many failure modes for the value delivered. This release stops lying to the UI and accurately reflects what the system can and can't do.

- **`RemoteAndroidPlaybackInfo` now picks `AndroidVolumeControlType.fixed` when the receiver says so.** Audio handler reads `castService.castVolumeControlType` and maps `'fixed'` → `AndroidVolumeControlType.fixed`, anything else → `.absolute` (original behavior preserved for non-AVR setups). On a fixed-mode cast session, Android stops calling our `androidSetRemoteVolume` / `androidAdjustRemoteVolume` callbacks, the lock-screen slider becomes inert (or hides depending on Android version), and phone hardware volume keys do nothing for the cast session - instead of the v1.0.23 behavior where the slider visibly moved, our code dutifully sent `SET_VOLUME` requests, the receiver silently ignored them, and the user couldn't tell from on-screen feedback that nothing was actually happening.
- **`setCastVolume` and `adjustCastVolume` short-circuit when `controlType == 'fixed'`.** Belt-and-suspenders - Android shouldn't be calling our handler in that mode, but if anything else in the app calls `setCastVolume` directly we still skip the send and the optimistic local update. No more lying to the slider when nothing physical can change.
- **`controlType` changes now trigger `notifyListeners()`.** Previously only level/muted changes propagated, so the audio handler wouldn't see the receiver's first volume report (which is what tells us whether to use fixed or absolute mode) until the level happened to change too. Now any change to `controlType`, `level`, or `muted` flushes through the listener chain, and the audio handler republishes the right `AndroidPlaybackInfo` immediately.
- **Audio handler tracks `_lastRemoteVolumeControlType` for change detection.** Without this, the handler would skip republishing when only the control type changed (initial connect: published `absolute` before the first RECEIVER_STATUS arrived; first RECEIVER_STATUS reports `fixed`; we'd want to republish but the volume index hadn't moved). Three-axis change detection now: casting state, volume index, control type.
- **Verdict on the AVR chain:** for setups where Chromecast feeds an AVR via TV/eARC, app-side volume control is permanently impossible without integrating the AVR's own LAN protocol (HEOS, AVR control, etc.). Decided not to ship that. Use the Denon remote (or the Denon HEOS app) for volume during cast - the rest of v1.0.23's wins (no audio focus pause, lock-screen play/pause/skip, INTERRUPTED resume) still apply.


## 1.0.25 - 2026-05-08
Hotfix for v1.0.24 - the diagnostic logging that release added didn't actually reach `combined.log` because it used `print()`, which on Flutter only goes to the local debug console. The frontend's log-shipping pipeline (`/api/logs/ingest` → backend ring buffer → `combined.log`) is fed by `AppLogger.instance.info/warning/error` exclusively. Caught when the next round of "press the volume keys, check the logs" produced zero matches in `combined.log` even though the phone confirmed it was running v1.0.24.

- **Cast diagnostic prints converted to `AppLogger.instance.info(...)`.** Six call sites: `cast_service.dart`'s `controlType` change line, the per-update `RECEIVER_STATUS volume:` line, the `SET_VOLUME →` line at the send site, the `INTERRUPTED → resume` line; and `audio_handler.dart`'s `MediaSession → REMOTE/LOCAL` lines plus the two `androidSetRemoteVolume` / `androidAdjustRemoteVolume` lines. All six now ship to the backend within ~30s of being emitted (the AppLogger ship interval).
- **No behavior changes.** The actual cast volume forwarding logic from v1.0.23 and the diagnostic content from v1.0.24 are unchanged - only the channel they log through.
- **Lesson:** going forward, anything we want to read from `combined.log` on the server side has to go through `AppLogger`, not `print`. Most of the existing cast-service log lines are also `print`-only and would be invisible if we ever needed them for debugging - staged a follow-up to convert the high-signal ones (cast connect/disconnect, LAUNCH errors, MEDIA_STATUS state transitions) on the next pass.


## 1.0.24 - 2026-05-08
Diagnostic-only release for v1.0.23's TV-volume-control feature. v1.0.23 wired the phone's hardware volume keys + lock-screen slider to the cast receiver, the cast icon shows up in the system volume slider correctly, the slider physically moves - but the TV's audio level doesn't change for simpson1045's setup (Chromecast → TV → Denon AVR via eARC). Most likely cause is the receiver reporting `volume.controlType: 'fixed'` because the AVR is downstream of the cast device and is the actual master volume controller; we need a log line to confirm before deciding what to do (live with it, integrate Denon HEOS API, or try CEC step-based commands).

- **Added log lines for receiver volume capability + every SET_VOLUME attempt.** On every `RECEIVER_STATUS` carrying volume info, prints `controlType=<x>, stepInterval=<y>` (once per change) and `level=… muted=… controlType=…` on every level/muted update. On every outbound `setCastVolume`, prints `SET_VOLUME → level=<x> (controlType=<last-known>)`. After a phone-volume-key press during cast, the order of those lines should tell us whether the cast accepted the change and how far down the AVR chain it reached.
- **Caveat - this release didn't actually work.** The diagnostic logs were emitted via `print()`, which on Flutter goes to the local debug console only. The backend's `combined.log` only receives entries shipped through `AppLogger.instance` and its periodic ingest call. So in practice v1.0.24's diagnostics were invisible from the server side. v1.0.25 fixes that.
- **No behavior changes.** v1.0.23's REMOTE MediaSession routing and lock-screen volume handling are unchanged.


## 1.0.23 - 2026-05-08
Cast-side robustness pass. Three real bugs and one tracker-noise fix, all tied to what happened when phone audio focus went sideways while casting.

- **Casting to the TV now ignores phone audio focus entirely.** The MediaSession was registered as a *local* playback type, so when another app on the phone (YouTube, navigation prompt, anything) requested audio focus, Android dutifully sent NASRadio a `pause()` - which `togglePlayPause()` then forwarded to the Chromecast because `isCasting == true`. TV stops. Worse: when focus returned, `audio_session`'s `interruptionEventStream` listener called `_justAudioPlayer?.play()` unconditionally, restarting the local player while the cast also resumed - both phone and TV playing the same song at slightly different positions. Fix: `NASRadioAudioHandler` now publishes `RemoteAndroidPlaybackInfo` to `audio_service`'s `androidPlaybackInfo` subject whenever a cast session is active, and `LocalAndroidPlaybackInfo` otherwise. That marks the MediaSession as `PLAYBACK_TYPE_REMOTE` - Android no longer arbitrates audio focus against us during cast, no `pause()` call arrives, lock-screen controls stay visible and route to the TV. The `interruptionEventStream` and `becomingNoisyEventStream` listeners also early-return when `isCasting`, as defense-in-depth.
- **Phone hardware volume keys + lock-screen slider now control the TV during cast.** Side benefit of the REMOTE MediaSession: Android delivers volume changes via `androidSetRemoteVolume` / `androidAdjustRemoteVolume` instead of adjusting `STREAM_MUSIC` locally. Implemented both: absolute volume sets the cast level directly (0–100 → 0.0–1.0), volume keys nudge by 5% steps. `RECEIVER_STATUS` messages from the Chromecast are now parsed for `volume.level` and `muted` and mirrored back into `_castVolume`/`_castMuted` so the lock-screen slider tracks TV-remote volume changes within a beat.
- **Cast queue no longer permanently stalls on `idleReason: INTERRUPTED`.** The cast `MEDIA_STATUS` handler treated FINISHED / ERROR / CANCELLED as "advance the queue" but silently ignored INTERRUPTED - which is what Chromecast emits when a different sender takes over the session, the receiver loses audio focus, or other transient preemption. Net effect: cast got stuck mid-album and wouldn't recover without a reconnect. Now sends a single `PLAY` to attempt resume on the existing `mediaSessionId`. If the receiver session is gone, the message is a harmless no-op; if it's alive, playback picks back up where it stopped.
- **Backend console no longer floods with benign `ConnectionAbortedError` tracebacks.** These fire constantly during normal streaming - every time a media player cancels an in-flight range request to reopen at a different offset, the server is mid-`send()` and gets `[WinError 10053]`. `log_service.py` already classified them as suppressible for the in-memory ring buffer and `combined.log`, but `_TeeWriter` was forwarding bytes to the original stdout/stderr *before* the suppression decision ran. Refactored to buffer per-line and decide before forwarding - both the log buffer AND the raw PowerShell window now skip the noise. Real tracebacks (anything not in `_SUPPRESS_TRACEBACK_EXCEPTIONS`) still print verbatim. **Backend restart required** to pick this up; everything else ships in the APK.

Sidebar on what triggered this whole pass: a stale SMB session on the desktop hung every `os.path.exists` call inside `stream_song` for an hour after the share recovered, jamming the eventlet hub for streaming requests while leaving `/api/health` and metadata routes responsive. Fixing that needed a backend restart, but the diagnosis surfaced the cast bugs above as separate latent issues that finally got fixed in this release.


## 1.0.22 - 2026-04-29
Three real podcast bugs fixed. The first two are the actual issues you'd been reporting for sessions; the third is the multi-instance leak I should have caught in the audit but missed.

- **Tapping a different episode in the queue now actually plays that episode.** `playFromQueue` was calling `_justAudioPlayer!.seek(Duration.zero, index: index)` for every queue tap - which works for **music** because the just_audio player has a `ConcatenatingAudioSource` containing all queued songs, so seeking with an index jumps to that source. But **podcasts** load via `setAudioSource(ja.AudioSource.uri(...))` - a single source, no playlist. `seek(Duration.zero, index: 5)` against a single-source player silently ignores the `index` parameter and just resets position to 0 on the **current** episode. UI flickered to the new episode (because `_currentSong` was reassigned in service state) but audio kept marching on the old episode, then the next player event re-synced the UI back to the actually-playing source. Now: if the target song is a podcast, `playFromQueue` does the same thing `playPodcastEpisode` does - `setAudioSource` with a fresh proxy URL, fetches the episode's `played_position` from the backend, seeks to that position, plays. Same fix applied to the desktop `media_kit` path (was using `_player.jump(index)` against a single Media - also broken).
- **Forever-spinner when an episode auto-advances no longer happens.** `_advanceToNextPodcastEpisode` was using `nextSong.filePath` from the queue Song to feed `setAudioSource`. That `filePath` was populated at queue-build time (back in `playPodcastEpisode.episodeToSong`) as `ep.audioUrl ?? getRssStreamUrl(ep.id)` - which means if the backend had pre-resolved a CDN URL with a TTL, that URL got baked into the Song's `filePath`. By the time the previous episode actually finished playing (could be 30+ minutes later for long podcasts), the resolved URL had expired, `setAudioSource` got a 403/404, the player entered buffering=true and never came out. Scrubber stuck at 0:00, audio dead, spinner forever. Now: advance always uses `_apiService.getRssStreamUrl(episodeId)` - the proxy endpoint that re-resolves server-side on every request, so the URL is always fresh. Also: the catch block now explicitly resets `_isBuffering = false` and notifies if the source-swap throws, so a failed advance can never lock the UI in a buffering state.
- **`NowPlayingScreen` no longer accumulates duplicate instances on the navigator stack.** This was caught by reading the heartbeat logs from v1.0.19 - three independent `_NowPlayingScreenState` instances were running at the same time (three independent build/ticker/listener counters all reporting the same audio state), each with its own listener attached to `audioPlayerService`, each rebuilding on every position tick. Cause: every screen that opens Now Playing was doing an unguarded `Navigator.push(MaterialPageRoute(builder: (_) => NowPlayingScreen(...)))`. With the natural drill-down pattern (Now Playing → Artist → song → Now Playing → Album → song → Now Playing), three or more instances accumulate on the stack. Fixed by adding a `NowPlayingScreen.open(context, audioPlayerService: ...)` static helper that uses `RouteSettings(name: 'now_playing')` + `popUntil` - if Now Playing is already on the stack, it pops back to it; otherwise pushes a fresh route. Mechanically replaced **35 push call sites across 24 files** to use the helper.
- **Honest mea culpa on this last one:** I should have caught the multi-instance leak during the comprehensive audit. The audit was scoped to the Now Playing file's *internals*, but the multi-instance bug is caused by *how the file is instantiated from outside* - and a good audit would have flagged "this widget has no singleton/once-only guarantee" as a concern even in a self-scoped audit. I prompted the audit agent narrowly. Won't happen again.

## 1.0.21 - 2026-04-22
Cleanup pass from the comprehensive audit. No user-visible bug fixes beyond what v1.0.18–v1.0.20 already shipped - this one's hygiene, defense-in-depth, and the audit findings that were safe + high-value enough to land in a single release.

- **Mobile album artwork decodes at rendered resolution, not source resolution.** `_MobileArtwork` `Image.network` now specifies `cacheWidth`/`cacheHeight = (size × MediaQuery.devicePixelRatio).ceil()`. Previously Flutter was decoding whatever the source image was - often 2000×2000 FLAC-embedded artwork - and holding ~16 MB in memory for a 280 dp tile on the phone's Now Playing screen. Desktop (`_ArtworkWithHover`), the tap-to-zoom full-artwork dialog, and the immersive fullscreen blurred background layer are ALL untouched and still decode at full resolution - simpson1045 wants max quality on the TV cast + desktop, and casting pulls artwork directly from the backend URL without going through this widget anyway.
- **Podcast artwork URL now gates on the song, not the service.** `_artworkUrlForSong()` was checking `audioPlayerService.isPlayingPodcast` (service-level state about what's currently playing) rather than `song.isPodcast` (the song's own type). The two can drift out of sync when rendering the previous/next swipeable artwork tiles, mid-transition, or in the queue sheet - leading to a music track sometimes getting the podcast artwork URL or vice-versa. Gate is now per-song.
- **Desktop back button has a tooltip now.** Mobile's had "Back" for a while; desktop was missing it. Same label now on both.
- **`_loadDiscNames` error catch logs instead of swallowing.** Was a silent `catch (e) { /* silently fail */ }`; now `AppLogger.instance.warning(...)` so multi-disc albums failing to load their disc names surfaces somewhere.
- **`_navigateToPodcast` shows a snackbar + logs on error instead of silent `print`.** The "Playing from <podcast>" link, the album link, and the artist link on a podcast all tap through this path. If the underlying feed-fetch fails, you now get a "Couldn't open podcast feed - try again." snackbar plus a warning line in combined.log.
- **`_lastIsPlaying` / `_lastIsBuffering` are non-null bools now** (primed from the service in `initState`). Cosmetic - the previous nullable comparisons were confusing and the first rebuild pattern was slightly off.
- **Fullscreen toggle race - F11 / ESC can no longer fire concurrent toggles.** Added a `_fullscreenInFlight` flag and `mounted` checks across the `await`s in `_toggleFullScreen` / `_exitFullScreen`. Rapid-press was previously able to interleave two in-progress `windowManager.setFullScreen + setSize + delay + setSize` chains and leave the window in a weird state.
- **False-positive audit items that I validated and skipped:** artist-ID null guard (`Song.artistId` is already non-nullable in the model); `FocusNode` desktop-only gate (it's wired into the `KeyboardListener` that wraps the whole tree regardless of platform); `MouseRegion` hover 60Hz `setState` (the code uses `onEnter`/`onExit` which fire once per boundary crossing, not `onHover` which would fire every pixel).
- **Staged for future refactoring sessions** (not in v1.0.21): code deduplication between portrait/landscape and mobile/desktop paths (~4× copy-pasted slider logic, navigation handlers, control-button layouts); full accessibility pass (Semantics on the waveform slider, consistent tooltips across IconButtons, alt text on artwork, overflow tooltips on song titles); `globalCastService` decoupling from `main.dart`; `ApiService` dependency injection for testability. These are proper refactor projects, not one-off fixes.

## 1.0.20 - 2026-04-22
Defensive-fix pass informed by a full Explore-agent audit of `now_playing_screen.dart`. simpson1045 asked for preemptive cleanup rather than waiting for the freeze to recur - the heartbeat logger from v1.0.19 stays in place as a safety net in case anything still surfaces.

- **Smooth ticker is gated now.** Previously `createTicker((_) { if (mounted) setState(() {}); })` fired on every vsync frame (60 Hz) forever, regardless of play state - so while paused or buffering, the whole widget tree rebuilt 60 times a second including a fullscreen `BackdropFilter(sigma=30–80)` over the blurred background layer. Strong suspect for the desktop "freeze" symptom simpson1045 reported: the UI thread was saturated repainting the blur on every frame, so one slow frame (GC, network hiccup, whatever) cascaded into permanent lag. The ticker now only calls `setState` when `isPlaying && !isBuffering && !_isSeeking`. The per-event `_onPlayerStateChanged` listener still rebuilds the tree whenever position genuinely advances, so the progress bar stays smooth during playback.
- **Dispose hygiene - `_exitFullScreen` no longer fire-and-forgets from `dispose()`.** It was being called without `await`, so its internal `setState` + `windowManager` awaits continued running after the widget was gone - late setState against a disposed State object is a source of intermittent "something is weird" behavior. Replaced the call with a minimal `Future.microtask` that just does the platform-side cleanup (`windowManager.setFullScreen(false)` on desktop / `SystemUiMode.edgeToEdge` on mobile) and never touches widget state.
- **`Future.delayed` now checks `mounted` before mutating state.** The 150 ms reset of `_isAnimatingPage` after an artwork page swipe could fire after the screen was dismissed, leaving the flag stuck true.
- **`_loadWaveform`, `_loadChaptersFor`, and `_loadDiscNames` no longer called from `build()`.** They lived there as "init if the screen opens with a song already playing" primes, gated by internal caches, but called from `build()` they could fire on every frame's rebuild attempt. Moved to `_onPlayerStateChanged` on song change, with a one-shot prime in `initState` for the "screen opens with a song already playing" case.
- **Audit items staged for later releases** (not bugs simpson1045 has hit yet, just architectural): ESC key handler async race, widespread code duplication between portrait/landscape and mobile/desktop paths, a11y (Semantics labels, tooltips on buttons), `CachedNetworkImage` without `cacheWidth`/`cacheHeight` decoding artwork at full resolution, `MouseRegion` hover callbacks calling `setState` on desktop.

## 1.0.19 - 2026-04-22
Diagnostic release targeting the desktop-only Now Playing bugs that v1.0.18 didn't actually fix. One concrete fix, one set of instrumentation.

- **Fix: play/pause icon no longer stuck on "play" while audio is playing (desktop).** The `media_kit` playing-state listener in `audio_player_service.dart` had a guard that filtered out `playing == true` events whenever `_isInitializingPlayer` was set - intended to hide spurious playing signals during source load, but in practice it permanently lost the true-playing transition if it fired during the init window. Nothing re-read the player state when `_isInitializingPlayer` later flipped to false, so `_isPlaying` stayed `false` forever and the button icon matched. Replaced the guard with a value-change dedupe (`if (playing == _isPlaying) return;`) so every transition is always captured. Added a log line on every flip so we can see transitions in `combined.log`.
- **Diagnostic instrumentation for the Now Playing UI freeze.** Added a 1-Hz heartbeat logger to the Now Playing widget. Tracks three counters - `builds` (how many times `build()` fires), `ticks` (how many times the smooth ticker fires), `listener` (how many times the service's `_onPlayerStateChanged` fires) - and dumps them to `combined.log` once per second along with the current `isPlaying` / `isBuffering` / position state. Next time the desktop freezes, we can read the log and see exactly which subsystem stalled, instead of guessing.
- **No structural changes to the freeze itself yet.** An Explore-agent audit of `now_playing_screen.dart` identified 13 issues, most notably that the smooth ticker fires `setState(() {})` on every frame unconditionally - even when the audio is paused or buffering. That's strongly suspected to be the freeze root, but v1.0.20 will go at it with evidence from the heartbeat logs rather than shotgun-patching. Other audit findings (async `_exitFullScreen` called from `dispose()` without await, missing `mounted` checks in `Future.delayed` callbacks, waveform/chapter/disc-names loaders called from `build()` in addition to the listener) are also staged for v1.0.20.

## 1.0.18 - 2026-04-22
Damage-control release for a latent regression I shipped in v1.0.12. Four related fixes, all traceable to the same root cause.

- **The real story: v1.0.12's pool-holder instrumentation added a `threading.Lock` in `models.py` for tracking who was holding each pooled DB connection. Under eventlet's monkey-patching, `threading.Lock` becomes a green-thread `Semaphore` - fine within the hub thread, but fatal when any background code path touches the lock from a real OS thread.** The What's Happening scheduler was doing exactly that (started via `threading.Thread(...)`), and its periodic DB lookups were eventually tripping `greenlet.error: Cannot switch to a different thread` from inside eventlet's hub timer callbacks. That crash cascaded into all kinds of weirdness - 121 `ConnectionAbortedError` tracebacks in a single session log, silent waveform-generation hangs, and likely the desktop Now Playing freezes too. Fix: dropped the lock entirely (dict operations are atomic under eventlet's cooperative scheduling, the lock was never actually needed for correctness), and converted the What's Happening scheduler from `threading.Thread` to `eventlet.spawn_n` so it matches how the RSS refresh scheduler already worked. No more background DB access from non-hub threads.
- **Waveform generation no longer silently hangs on m4a files over UNC paths.** Separate issue surfaced by the above - librosa's `audioread` fallback has no timeout and was getting stuck indefinitely decoding m4a files from `\\nas\Music\...`. Replaced `librosa.load` with a direct ffmpeg subprocess call: ffmpeg decodes raw PCM to stdout, numpy reads it, hard 60 s timeout. Also found an ffmpeg binary at `C:\ytdl\ffmpeg.exe` which the new code picks up automatically. Added dedup of concurrent generations for the same song_id, so the cast-receiver + phone flow can no longer spawn 6 duplicate decodes per song.
- **Play/pause button no longer gets stuck showing the wrong icon.** The Now Playing screen's `_onPlayerStateChanged` handler only triggered `setState` when song-ID or position changed by >50ms. A pure `isPlaying` flip (tap play → service starts playing) arrived via `notifyListeners` but was silently dropped by the gate because position hadn't moved yet. Button stayed showing "play" while audio was playing; tapping it actually paused the audio but left the icon unchanged; tapping again flipped the icon. Now tracks `_lastIsPlaying` and `_lastIsBuffering` and rebuilds on any of them flipping.
- **Desktop Now Playing UI freeze is very likely resolved by the above combination.** The Flutter UI was dropping state transitions (play/pause/buffer) whenever the smooth ticker wasn't firing - buttons kept working (taps routed directly to the audio service) but the repaint couldn't recover until a position update came through. The same setState-gate fix closes that gap. If the freeze persists after this release, that's a separate bug and we'll go hunting.
- **Backend restart required** for the backend fixes (lock removal, scheduler conversion, ffmpeg waveform decode). The setState gate fix needs the APK install.

## 1.0.17 - 2026-04-20
- **Podcast auto-advance on the phone actually works now.** Longstanding bug - end an episode, it restarts from 0 instead of advancing to the next. Root cause found: just_audio's `LoopMode` persists across source swaps, so if you'd ever tapped the repeat-one button during a music session, the `LoopMode.one` setting silently carried into every podcast that played afterward. When an episode hit end-of-stream, just_audio's built-in loop fired first and restarted it at 0, beating the app's manual "advance to the next episode in the queue" logic to the punch. Fixes across four call sites:
  - `playPodcastEpisode` (first episode loaded) now explicitly calls `setLoopMode(LoopMode.off)` before loading the source.
  - `_advanceToNextPodcastEpisode` (subsequent episodes) re-enforces it on every transition.
  - `toggleRepeat` still updates the UI repeat state when you tap the button during a podcast, but no longer pushes that setting down to just_audio while a podcast is playing - so mid-podcast repeat-toggling can't break the advance chain.
  - The restore-from-saved-state path checks if it's restoring a podcast session and forces loop off regardless of what `_repeatMode` was saved from a prior music session.
- Same belt-and-suspenders fix applied to the desktop `media_kit` path via `PlaylistMode.none`, even though this was almost exclusively a mobile bug.

## 1.0.16 - 2026-04-20
- **Torrent-add errors actually tell you what to do now.** Previous behaviour: Prowlarr returns a 500 because upstream (e.g. RuTracker-via-Knaben) timed out → backend threw the raw urllib exception → frontend snackbar shows `Failed to fetch torrent: 500 Server Error: Internal Server Error for url: http://<prowlarr>:9696/8/download?apikey=...<giant base64 blob>...`. Useless. Now the backend classifies HTTP failures by status code and returns a plain-English sentence: 502/503/504 → "The indexer's upstream source isn't responding right now (this is common for RuTracker-sourced results). Try a different result or try again later."; 500 → "The indexer couldn't fetch this .torrent file - the original source may be down or the torrent may have been removed. Try a different result."; 404 → "This torrent is no longer available at the source. Try a different result."; 401/403 → "Prowlarr rejected the request - API key may be wrong, or this indexer needs re-authentication."; 429 → "Rate-limited by the indexer. Wait a minute and try again."; plus `ConnectionError` → "Can't reach Prowlarr. Check that the Prowlarr container is running and the URL is correct." No more giant URL blobs in the snackbar.
- **Error snackbar gets longer legs.** The frontend snackbar for failed adds now strips the `Exception: ` / `Failed to add torrent: ` prefixes Dart normally adds, wraps up to 4 lines (instead of clipping to one), floats above the bottom nav, stays visible for 8 seconds, and has a DISMISS action. You can actually read the message now without feeling rushed.

## 1.0.15 - 2026-04-20
- **"Failed to add torrent" finally tells you why.** Tried adding a torrent, got the generic snackbar with nothing in any log - three things were conspiring to hide the error: the Python `add_torrent()` returned `{"success": False, "error": "..."}` without ever logging, the Flask route wrapped that in a 500 without logging either, and the frontend's `addTorrent` in `api_service.dart` threw a bare `Exception('Failed to add torrent')` without reading the response body. Now: backend logs the failure detail to `combined.log` (`❌ Transmission add failed (url=…): <reason>`), and the frontend parses the `error` field out of non-200 responses so the real reason ("Failed to fetch torrent: timeout", "Indexer error: unauthorized", transmission RPC error, etc.) ends up in the red snackbar where you can actually read it.
- **Prowlarr "in library" chips now catch way more of your collection.** The query-cleaning regex didn't know about scene-release tags, so titles like `Van Halen Fair Warning 1981 PBTHAL LP 24 96 FLAC 88` got cleaned down to a word list including `pbthal` and then tried to match "pbthal" against your album titles (obviously none matched). Added to the strip list: `PBTHAL`, `WEB`, `WEBRip`, `BDRip`, `DTS`, `LP`, `EP`, `CD\d*`, `disc\d*`, plus extra codec tags (`opus`, `m4a`). Also now strips loose 1-3 digit numbers (bitrates / sample rates / track counts like "24 96 88") after the format-word pass - 4-digit years were already handled. Result: those six Van Halen torrents in the screenshot that didn't show chips should all show them now, except for the "1984" torrent where both the album name AND the year are 1984, which collapses to just `[van, halen]` and matches any Van Halen album (good enough for the in-library check - directionally correct).

## 1.0.14 - 2026-04-20
- **Prowlarr's "already in library" check actually works for the first time ever.** The backend endpoint had a `NameError: name 'folder_path' is not defined` bug sitting in it since 2025-12-26 - a partial variable rename where the outer loop was renamed `folder_path` → `query`, but three references inside the match branch and the fallback branch never got updated. Every Prowlarr search from the phone hit this error, the backend logged a traceback, and the frontend quietly swallowed the 500 in a `catch { /* silently fail - not critical */ }`. The net effect was: you never saw the green "in library" chip next to Prowlarr results, but everything else still worked, so the feature just... didn't exist for four months. Fixed the names, dropped the dead `_get_folder_quality(query)` call (meaningless when we only have a search string, not an actual folder).
- **Reason you're only seeing it now:** v1.0.5 added centralized backend logging + the System Logs screen on the phone. Before that, this traceback fired into a console window you rarely watched. Now every backend exception flows into `combined.log` and the in-app viewer, so month-old silent failures start surfacing.
- **Silent frontend catches get a little less silent.** The Prowlarr library-match `catch` in `prowlarr_search_screen.dart` now logs the exception + stack trace to `AppLogger.instance.error()` instead of swallowing them into `// Silently fail - not critical`. The feature is still non-fatal - the rest of the search works even if this breaks - but future breakage will show up in System Logs and the centralized `combined.log` instead of vanishing.

## 1.0.13 - 2026-04-20
- **Casting podcasts to the TV actually plays audio now.** The Cast `contentType` was hardcoded to `audio/flac` for every stream - music, podcasts, transcoded or lossless. The Chromecast CAF receiver routes to different hardware decoders based on that header, so podcast MP3 bytes labeled "FLAC" failed to decode. That's why the UI updated on the TV but the audio kept playing on your phone. New `_mimeForStream` helper on `CastService` now picks: `audio/mpeg` for podcasts, `audio/mpeg` for non-lossless music (the backend transcodes to MP3 for anything other than lossless quality), and the right MIME per file extension for lossless music (flac / mp3 / m4a / wav / ogg / opus / aiff). The log line that prints on every cast now includes the chosen content-type so future mismatches are easier to spot.

## 1.0.12 - 2026-04-20
- **Landscape fullscreen on Now Playing actually shows controls now.** v1.0.11 reused the desktop fullscreen layout verbatim - a single Column with the artwork at 45 % of screen height plus title/artist/album/progress/controls stacked below. On a phone in landscape the screen is only ~430 px tall, so the artwork ate nearly half and everything below the album title was clipped. Fixed by branching on `isMobileLandscape`: artwork now fills the left half of the screen (square, vertically-centred), and title / artist / album / progress bar / playback controls sit in a column on the right. Portrait phone + desktop keep the original Column layout.
- **DB connection pool now tells you who's hogging it.** simpson1045 restarted the backend and got an immediate `connection pool exhausted` on the first phone request - the v1.0.7 fix covered LRCLIB/Spotify but there's clearly another endpoint holding connections across something slow. Added lease tracking in `backend/app/models.py`: every call to `Database.get_connection()` registers the Flask endpoint, request path, caller file:line, and acquisition time; release on `PooledConnection.close()`. When psycopg2 raises `PoolError("connection pool exhausted")` we now dump every current holder to stderr with how long they've been out, sorted oldest first - so the prime suspect is always at the top of the list. `/api/health` also returns the same list as `pool.holders`, which the phone's System Logs screen can show live. **Backend restart required** to pick up the instrumentation.

## 1.0.11 - 2026-04-20
- **Cast receiver idle screen actually looks like NASRadio now.** The old idle screen was just the word "NASRadio" in cyan, spaced out, on a flat background - nothing tying it to the app. Replaced with the real radio-tower logo at 220 px, sitting in front of four concentric cyan rings that pulse outward from behind it (staggered 1.2 s so one's always near centre and another is fading at the edge), breathing glow on the logo, wordmark under it with a matching cyan glow, "READY TO CAST" tagline, dark radial-gradient background instead of flat navy. The logo's served from `/cast/nasradio_logo.svg` - no app rebuild needed for this piece; the receiver reloads it the next time a cast session starts. **Backend restart required to pick up the new receiver files.**
- **Now Playing goes fullscreen automatically when you rotate the phone to landscape.** Same immersive layout desktop's had for ages - artwork centred, chrome hidden - now kicks in on Android too. Watches `MediaQuery.orientation` on the Now Playing screen; landscape calls `SystemChrome.setEnabledSystemUIMode(immersiveSticky)` (hides the status bar and the Android gesture/nav bar) and flips the same `_isFullScreen` flag that desktop uses, so the existing fullscreen layout is reused. Rotate back to portrait and the bars come back. Only fires on Now Playing - you don't get weird immersive fullscreen when you rotate on a library screen.
- **Android Auto app icon no longer has a visible border.** The old launcher PNGs had transparent rounded corners - so Android Auto applied its own rounded-square mask on top of those already-rounded corners and showed a visible transparent ring. Regenerated all five mipmap sizes (mdpi → xxxhdpi) as full-bleed dark-navy squares with the tower + "NAS" wordmark scaled up to fill the entire canvas. Android Auto, the phone launcher, and any other mask template now get a clean edge-to-edge PNG to crop - no more border. Originals are recoverable from git history if the change ever needs reverting.

## 1.0.10 - 2026-04-20
- **Rename / remove is now discoverable via a three-dot menu (⋮).** In v1.0.9 the rename/remove actions were only reachable via long-press, which is a hidden gesture - couldn't find it without being told. Each "Recent" device entry and the "Currently casting" tile now show a visible ⋮ on the right side; tap it for Rename, Reset to original name, or Remove from Recent. Long-press still works as a shortcut.
- **You can rename while actively casting.** The rename menu used to only be available in the Recent list, which is hidden whenever you're connected. Now the tile at the top of the picker (the one that says what you're casting to) has the same ⋮ menu.
- **Custom device names propagate everywhere.** If you rename your C2 to "Living Room TV", you'll now see "Casting to Living Room TV" in the picker header and the "Currently casting" tile label - previously those still showed the broadcast name and only the Recent list used the custom one.

## 1.0.9 - 2026-04-20
- **Cast discovery streams devices live as they're found.** The picker sheet used to just show a spinner for the full scan duration and then drop every device in at once - now each device pops into the list the instant its mDNS record resolves. Scan window also bumped from 8 s → 12 s so slower-to-respond devices (and anything on a sleepier corner of the network) actually get picked up. A small "Still searching…" indicator sits below the list while scanning continues, so you know more might arrive.
- **Saved devices / "Recent" section.** Any time you successfully connect to a Cast target, it gets auto-saved. Next time you open the picker, those devices appear in a pinned "Recent" section at the top with a colored status dot - 🟢 green if present in the current scan, ⚪ grey while scanning, 🔴 red if the scan finished without them. Offline devices are disabled until they show up on the network again.
- **Device icons inferred from mDNS.** Chromecast broadcasts include a model hint (`md`) in their mDNS TXT record - LG C2 reports as an OLED TV, Nest Hub reports as a smart display, Google Home Mini reports as a speaker, etc. The picker reads that and picks the right icon instead of showing a generic speaker for everything.
- **Rename and remove saved devices.** Long-press any "Recent" entry for a menu: **Rename** (edit to whatever you want), **Reset to original name** (restores the Google-Home-assigned name if you renamed it), **Remove from Recent**. The custom name sticks even if the device goes offline and comes back.
- Stored in `SharedPreferences` under `cast_saved_devices_v1` - keyed by the stable mDNS service name, so IP changes and router reboots don't lose your list.

## 1.0.8 - 2026-04-19
- **Log screens no longer hide under the Android system nav bar.** Both the Frontend Logs and System Logs screens now wrap their bottom status bar in a `SafeArea`, so the entry count / PG-pool / Essentia-Transcode indicators sit above the home/back/app gesture area instead of being clipped by it.
- **"Server unreachable" banner stops flickering on random transient glitches.** The health-check endpoint on the backend was making two HTTP calls (to the Essentia and Transcode sidecars) with 5-second timeouts each - if either was briefly slow, the whole `/api/health` response would blow past the client's 5-second budget and show the banner, even though the main server was fine. Two things were fixed:
  - Backend: sidecar probe timeouts cut from 5 s → 1.5 s each, so `/api/health` returns well under the client's ceiling.
  - Frontend: client timeout bumped from 5 s → 8 s, and the banner now requires **two consecutive failures** before it appears. One transient miss just increments a counter; a single success resets it.
- **Retry button actually looks like it's doing something now.** When you tap Retry, the button swaps out its text for a white spinner and disables itself until the health check resolves. If the check succeeds, the banner drops away immediately. If it's still unreachable, an orange snackbar pops up saying so - previously the button acted like it did nothing whether it worked or not.

## 1.0.7 - 2026-04-19
- **Fix: connection pool exhaustion during rapid Chromecast skipping.** The lyrics endpoint was holding a pooled Postgres connection across its 10-second call to LRCLIB. On every song change the app/cast receiver fetches lyrics - so flipping tracks fast on the TV would pile up dozens of connections all blocked on the same external HTTP, eventually draining the 50-connection pool. Once drained, the backend would start returning 500s on *everything*: waveforms, songs, logs, the lot. Now the DB connection is released before the LRCLIB call and only reacquired briefly for the INSERT.
- **Same fix applied to `/api/artist/<id>/spotify-top-tracks`.** Artist-detail pages held a pooled conn across a MusicBrainz MBID lookup + Spotify Pathfinder play-count fetch. Restructured the endpoint into three phases so the DB is only touched before/after the HTTP, never during.
- **Frontend now cancels in-flight requests on song or screen change.** If you skip past the current track before lyrics/waveform/spotify-top-tracks come back, the pending HTTP is aborted immediately - which tears down the backend request and releases whatever resources it was holding. Applies to: cast-receiver waveform+lyrics push, in-app lyrics view, artist detail screen's Spotify top tracks.
- No user-visible feature changes - this is a stability/reliability release. If the backend stopped responding on you while casting, this is the fix.

## 1.0.6 - 2026-04-19
- **"Resume from device" actually carries the queue + playlist identity now** - previously, hopping to your phone to resume what desktop was playing would load the current song's *album* instead of the desktop's queue. Now the target device loads everything verbatim: queue order, shuffle state, repeat mode, position, and the "Playing from simpson1045's Mix" label that was being dropped.
- **Cold-start podcast auto-sync across devices** - when the app starts up and the last-played thing was a podcast, it reconciles with the server:
  - If you finished the episode on another device, your app redirects to whatever episode you've actually moved on to in that feed (instead of resuming the completed one).
  - If you're still on the same episode but another device has you ahead, position silently syncs when the server's is >3 s newer.
- **Recently Added, Continue Listening, Most Played** on the Home screen no longer include podcasts - music-only carousels. Podcasts live in the Podcast section where they belong.
- **Resume banner on feed detail** no longer depends on sort direction - it shows the episode you're actually on, regardless of whether the list is sorted newest- or oldest-first.
- Independent per-device playback is preserved - phone and desktop can still play different things at the same time. Resume is explicit (user taps it), podcast auto-sync only fires on cold start for podcast episodes.
- Under the hood: `playback_state` gains `source_type` / `source_id` / `source_name` columns so the "Playing from X" context survives across devices. New backend endpoint `GET /api/rss/feeds/<id>/current-episode` powers the cold-start redirect.

## 1.0.5 - 2026-04-19
- **Centralized logging across devices** - backend, phone, and desktop all ship their logs to a single file on the server (`backend/logs/combined.log`) with per-device tags and timestamps. Next time something goes weird (ASOT restart, UI not updating, etc.) we'll have a complete, ordered record to read instead of having to piece together three separate logs from three places.
  - Line format: `2026-04-19 10:23:45.123  [SM-S928U    ]  [ERROR]  message`
  - Error-level events ship immediately; routine events batch every 30 s
  - Basic rotation at 10 MB (one backup kept)
  - Existing in-app log viewer (long-press dashboard refresh) now supports a `device=` filter
- No user-visible feature changes in this release - instrumentation update

## 1.0.4 - 2026-04-17
Big one. Five work-sessions of podcast fixes and features in a single release.

**Fixes from real-world use**
- Podcast Discovery sections no longer silently vanish when a load fails - each section now shows an inline error tile with a Retry button when its API call errors out.
- Download button actually tells you what's happening: spins while downloading, shows a green check when done, snackbars for success and failure. Backend emits a matching failure WebSocket event so errors aren't silent anymore either.
- HTML tags and entities (`&amp;`, `&mdash;`, `&#8220;`, `<p>`, `<br>`...) are now stripped from every episode description display site - no more raw markup leaking through on Megaphone / WordPress feeds.
- Continue Listening on the Discovery screen now updates in real time when another device advances an episode. Previously only the open feed detail screen got WebSocket updates.
- Sort toggle on feed detail no longer double-fires if you tap twice fast.
- Nav bar spacing on Podcast Discovery - fixed the weird gap between the mini player and the tab bar.
- Skip +30 / -10 buttons now handle rapid mashing correctly - each tap accumulates into a single target seek instead of stacking up behind buffering.

**Chapter polish**
- Tick marks appear on the progress scrubber at each chapter's start time (red for skippable chapters like ads).
- New chapter list modal: tap the list icon next to the chapter strip for a full scrollable view. Shows chapter artwork when feeds provide it, falls back to numbered tiles. Active chapter highlighted, tap to seek.

**Per-feed controls (new "Feed settings..." menu on each feed)**
- Auto-download new episodes as they publish (the `rss_feeds.auto_download` field finally has a UI).
- Skip intro: jump forward N seconds when any episode starts (0-120s slider, 0 disables). Great for podcasts with baked-in pre-rolls.
- Skip outro: auto-advance to the next episode when N seconds from the end (skip the outro + wait for the next). 0-120s.
- Auto-delete played episodes older than N days - 0, 7, 14, 30, 60, 90, 180, 365 day presets. Unplayed episodes are never touched. Sweeps run after every feed refresh.

**Inside a feed**
- Search bar on feed detail - tap the search icon to filter episodes by title. Server-side, so even a 1,287-episode feed like ASOT responds instantly. Debounced while you type.
- "Mark all as played" - one tap to clear an entire feed's unplayed count, with a confirmation dialog.
- Add episodes to queue or to any playlist from the episode long-press menu. Playlists can now mix music and podcast episodes freely.
- Sleep timer surfaced as a visible button on the podcast Now Playing screen (was buried in the three-dot menu).

**Subscription backup / migration**
- OPML export: download your full subscription list as an OPML file. Every podcast app reads OPML.
- OPML import: paste an OPML URL from another app, or paste the XML directly. Dedupes against existing subscriptions; per-feed result counts (added / already subscribed / failed) surfaced after import.

**Under the hood**
- Four copies of the podcast progress-save timer consolidated into one `_startPodcastProgressTimer()` method - fewer places for bugs to hide.
- Backend cleaner: centralized stripHtml helper, retention policy runs in one place, download route emits both success and failure events.

## 1.0.3 - 2026-04-17
- **Podcast chapters** - ASOT, Talk Ville, and any podcast with ID3 chapters or a `<podcast:chapters>` RSS tag now show a scrollable chapter strip on Now Playing. Tap a chapter to jump there; the active one highlights and auto-scrolls as playback advances. Known ads (Squarespace, BetterHelp, NordVPN, etc.) are flagged with an AD badge.
- **Much faster podcast playback start** - podcast tracker redirect chains (Podtrac → Chartable → Megaphone etc.) are now resolved server-side once and cached, so subsequent plays skip straight to the CDN. Talk Ville cuts from ~3.6s to sub-second. All 4,482 episodes in your library are pre-resolved.
- **Music library no longer clutters with podcasts** - Artists, Albums, Songs, and Search only show actual music. Podcast feeds/hosts stay in the podcast section where they belong.
- **Per-feed sort order** - the newest/oldest toggle on a podcast feed now persists per-feed. Talk Ville can stay oldest-first (binge from S01E01) while ASOT stays newest-first. Before: one global setting that was wrong for half your shows.
- Under the hood: unified schema groundwork for podcasts (they're now real rows in the `songs` table with `source_type='podcast'`, same plumbing as music) - every `song.id < 0` check replaced with `song.sourceType == 'podcast'`. See PODCAST_REFACTOR_PLAN.md for the full architectural detail.

## 1.0.2 - 2026-04-17
- Fixed in-app updater - version comparison now includes build number, so patch releases within the same semver (e.g. 1.0.1+2 → 1.0.1+3) correctly trigger the update banner
- Silenced noisy "Recommender call failed: WSAECONNREFUSED" backend log spam when the recommender service is stopped; real recommender errors still log
- Laid groundwork for an upcoming podcast system refactor (see PODCAST_REFACTOR_PLAN.md in the repo) - no user-facing changes yet in this release

## 1.0.1 - 2026-04-16
- Fixed podcast episode advance - episodes now actually advance when one ends, and the Now Playing screen reflects the new episode
- Fixed podcast resume position so opening an episode picks up where you left off (including progress synced from other devices)
- Fixed mid-playback restart - network hiccups no longer jump the episode back to zero
- Fixed switching from podcast back to music - tapping a music track after a podcast now plays correctly
- Podcast Discovery hub now keeps the main bottom navigation bar visible

## 1.0.0 - 2026-04-15
- Initial release with music streaming, playlists, and library management
- Chromecast support and device sync
- Spotify discovery and import
- Song recognition via Shazam
- Weather alerts with TTS announcements
- Podcast RSS feed support
- Android home screen widget
- Windows desktop support with media keys
