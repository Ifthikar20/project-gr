<!--
  Canonical source of the GemRun Privacy Policy.
  The SAME content ships inside the app (SettingsView.swift, LegalDoc.privacy)
  — when behavior changes, both change in the same commit.
  This file exists so the policy can be hosted at a public URL
  (App Store Connect requires one).

  NOT LEGAL ADVICE: written by the engineering side to accurately describe
  what the code does. Have a qualified attorney review before launch, and
  fill every [bracketed placeholder].
-->

# GemRun Privacy Policy

Last updated: [set on release]

GemRun is a running game: real gems appear on real streets, and you collect
them by physically running past them. That only works with location data, so
this policy is specific about what we collect, when, what leaves your phone,
and what never does. Every statement here describes what the app actually
does — when the app's behavior changes, this policy changes with it.

## 1. Who we are

GemRun is operated by [legal entity name, address]. Contact for anything in
this policy: [privacy@yourdomain — set before launch]. "We" below means that
operator; "the service" means the GemRun iOS app and its server.

## 2. What we collect, and when

**Account.** A username ("handle") you choose. If you sign in with Apple or
Google, we receive a provider account identifier; we store it only as a
one-way cryptographic hash, and we use it solely to recognize your account.
We do not collect or store your email address, phone number, real name, or
any password. Session tokens are likewise stored only as one-way hashes on
our server.

**Location — the heart of the game, and the most carefully scoped thing we
touch:**

- While the app is open, your location positions you on the map, and the
  coordinates of the area you are viewing are sent to our server so it can
  return — and stock — routes and gems near you.
- During an active run, location tracking continues in the background (screen
  off, phone pocketed) until the run ends. iOS shows its background-location
  indicator the entire time. Tracking stops when the run stops. Outside a
  run, we never track you in the background.
- When you finish a run, the app uploads that run's GPS track once, so the
  server can verify your collections were physically real (our anti-cheat).
  The server keeps the verdict — summary numbers, which gems were awarded or
  revoked — not the raw track. Your raw track stays on your phone, where it
  draws your run maps.
- If you place a gem on the map for others, you are publishing that
  coordinate: other players can see and collect it there.

**Motion & fitness.** Live step counts and distance during a run come from
your phone's motion coprocessor, on-device. Step counts are never sent to
our server.

**Apple Health.** Only with your permission, and each direction has its own
switch inside the app: writing finished runs to Health as workouts, and
reading Health's step count for a run's time window. Nothing read from
Health leaves your phone.

**Gameplay.** Runs you complete (distance, time, pace, validation status, XP),
your gem stash, streaks, level, routes you create and publish, and who you
follow.

**Fairness records.** When you attempt to collect a gem, the server records
the attempt and its outcome (collected, already taken, too far) with your
closest distance to the gem — this is how first-come races and disputes stay
auditable.

**Operational logs.** Our server keeps request logs (with short request
identifiers) and the coordinates of map areas requested, for reliability and
abuse prevention, for a limited period. On-device diagnostic logs redact
your precise coordinates.

## 3. How we use it

To run the game: show the map, stock gems near where players actually are,
verify collections, settle runs, compute XP/streaks/leaderboards, and keep
the shared world fair. Nothing else. We do not build advertising or
marketing profiles.

## 4. What other players can see

GemRun is a shared world, so some things are public by design:

- Your handle and level, on leaderboards and in player search.
- Your weekly XP, distance, and run count, to players who follow you.
- Routes you publish: their name, description, path, gem placements, and
  your handle as creator.
- Gems you place on the map, at the coordinate you chose, until collected.
- First-find credit on gems you were first to collect.

Your live location, your GPS tracks, and your run history details are never
shown to other players.

## 5. What we don't do

No ads. No sale, rental, or sharing of personal data with data brokers. No
third-party analytics or tracking SDKs embedded in the app. No email
marketing (we don't have your email). No cross-app or cross-site tracking.

## 6. Third parties the app touches

- **Apple.** Maps, walking directions, and address lookup are provided by
  Apple frameworks on your device; coordinates used for those features are
  processed by Apple under Apple's privacy policy. Sign in with Apple, if
  you use it, is likewise handled by Apple.
- **Google.** Only if you sign in with Google (when that option is enabled),
  Google processes that sign-in under Google's privacy policy.
- **OpenStreetMap.** Our server queries OpenStreetMap's data (via the
  Overpass API) to learn where public walkable paths are, so gems never
  spawn on highways or private grounds. Those queries are about geographic
  areas, come from our server, and are not linked to your account.
- **Infrastructure.** Our server runs on cloud infrastructure providers who
  process data on our behalf under contract: [list providers at launch].

## 7. Cookies, identifiers, and what lives on your phone

GemRun is a native app with no embedded browser: **we use no cookies**, no
advertising identifier (we never request IDFA), and no fingerprinting. What
is stored on your device, under your control:

- Your game cache: routes, your runs (including their map traces), your
  stash, and your profile.
- Preferences: onboarding state, Health switches, feature toggles, and
  which gem fact you saw last.
- A session token while the app is signed in.
- During a run, a crash-recovery file of that run's samples, deleted when
  the run completes or is discarded.

"Erase all local data" in Settings removes the game data above. If we ever
operate a website, it will carry its own cookie notice.

## 8. Retention and deletion

Your data is kept while your account exists. Two controls, both in Settings:

- **Erase all local data** — wipes the game data on your device; your server
  account is untouched.
- **Delete account & data** — permanently deletes your profile, runs, stash,
  and follows from our server, immediately, from inside the app. Gems you
  placed remain on the map but are no longer linked to any account. If the
  deletion request cannot reach the server, the app tells you and deletes
  nothing silently.

## 9. Security

Sign-in identifiers and session tokens are stored only as one-way hashes —
a copy of our database contains no usable credentials. Production traffic
uses TLS. No system is perfectly secure, but we deliberately minimize what
exists to be stolen.

## 10. Children

GemRun is not directed at children under 13, and we do not knowingly collect
personal information from them. If you believe a child under 13 has an
account, contact us and we will delete it.

## 11. Your rights and choices

Depending on where you live, you may have rights to access, correct, delete,
or port your personal data, and to object to or restrict processing. Most of
these are built in: rename your handle in Settings, flip Health and location
permissions in iOS Settings, toggle features off, and delete everything
in-app. For anything else — or to exercise rights in your jurisdiction —
contact [privacy@yourdomain]. You can also complain to your local data
protection authority.

## 12. Where data is processed

Our server currently runs in [region — set at launch]. If you use GemRun
from elsewhere, your data is processed there under this policy and
applicable safeguards.

## 13. Changes to this policy

When the app's behavior changes in a way that matters here, this policy
changes in the same release, with the date above updated. Material changes
will be called out in the app.

## 14. Contact

[privacy@yourdomain] · [postal address] — or through the App Store listing.

Not fine print, just the deal: the game needs your location while you play,
almost everything else stays on your phone, and nothing about you is for
sale.
