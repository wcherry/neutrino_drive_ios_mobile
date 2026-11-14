# Feature: Universal Links between the Neutrino apps

Option 2 from `agent_docs/handoff-to-notes.md`. Drive hands a file to the app that owns its
format — Notes for `application/x-neutrino-note`, Docs for `application/x-neutrino-doc` — over an
`https` link that also works in a browser when the app is not installed.

Touches three repositories:

| Repository                  | Role                                                        |
| --------------------------- | ----------------------------------------------------------- |
| `neutrino_drive_ios_mobile` | mints links, opens them, receives `/open/file/*`             |
| `neutrino_notes_ios_mobile` | receives `/open/note/*`                                      |
| `neutrino_docs_ios_mobile`  | receives `/open/doc/*`                                       |

## The link

```
https://www.getneutrino.app/open/<kind>/<file id>[?v=<content version>]
```

`kind` is one of `file`, `note`, `doc`, `sheet`, `slide`, `diagram`, `drawing`.

**Only the file id travels.** No contents, no key, no token. The receiving app fetches the current
version from the server against its own session, which is what keeps permissions centralised, avoids
a second download of something Drive already has, and guarantees the reader sees the latest revision
rather than whatever Drive last cached. `v` carries the server's `contentVersion` as a hint and is
advisory — nothing branches on it today.

Why a path segment per app rather than `?app=notes`: iOS routes Universal Links by *path pattern*,
so one segment per app is what lets all three share a domain without negotiating. See
`deploy/apple-app-site-association`.

Why one domain rather than one per app: `www.getneutrino.app` already serves the web app, so every
link degrades to a working web page when the app is absent — which is the entire advantage of Option
2 over the custom URL scheme in Option 1.

## Why not the alternatives

- **Custom URL schemes (Option 1).** Nothing stops another app registering `neutrinonotes://`, and a
  link that lands on a device without the app dies with no error the sender ever sees. Universal
  Links are claimed cryptographically against a domain the team controls.
- **`UIDocumentInteractionController` (Option 3/4).** Hands over *bytes*. That means a second
  download, a plaintext copy on disk outside the E2EE envelope, and an editor working on a snapshot
  that starts going stale the moment it opens.
- **`NSUserActivity` / Handoff (Option 5).** Built for continuing an activity across the user's own
  devices, not for "open this file in that app".

## Shared code

`NeutrinoAppLink.swift` — the URL vocabulary and the MIME → app routing table — is **duplicated
verbatim** in all four repositories (Drive, Notes, Docs, and Sheets). It is a wire format between
separately shipped binaries: an app built last month must still open a link minted today. The copies
must stay identical, and Drive, Notes, and Docs each have the same `NeutrinoAppLinkTests` suite
pinning them.

The MIME table matches three vintages, because one Drive listing routinely holds all of them:

| Spelling | Written by |
| --- | --- |
| `application/vnd.openxmlformats-…` (`.docx`, `.xlsx`, `.pptx`) | Docs, Sheets, and Slides today |
| `application/x-neutrino-*` | the bespoke JSON that predates OOXML, still read and written |
| `application/vnd.neutrino.*` | the oldest form, still in old records and `DriveItem.NeutrinoMIME` |

The OOXML row is the one that matters most in practice. A Neutrino document **is** a real `.docx`, a
spreadsheet a real `.xlsx`, a deck a real `.pptx` (issue #127 — `src/drive/storage/native_types.rs`,
`api-core/src/ooxml.ts`). Before those types were in the table, tapping a `.docx` in Drive fell all
the way through to download-and-Quick-Look, so the app's own primary format was the one thing the
hand-off did not handle. Legacy `.doc`/`.xls`/`.ppt` are deliberately *not* claimed: Neutrino cannot
parse them, and routing one to an editor that fails on it is worse than the download it gets today.

Because Docs and Sheets validate an inbound link's MIME on the way in (`DocsDriveService.fetchItem`
rejects anything `kind(forMIME:)` does not call a `.doc`), the OOXML entries are load-bearing in the
*receiving* copies too — a Drive-only change would open Docs and show an error.

## Outbound (Drive)

`CompanionAppLauncher` opens the link with `UIApplication.open(_:options: [.universalLinksOnly:
true])`. The option is there for the *negative* answer: there is no API that reports whether another
app is installed (`canOpenURL` says yes to every `https` URL, because Safari can always take it).
With `universalLinksOnly`, iOS either routes to the installed app or reports failure — it never
drops the user into Safari behind Drive's back, which is what makes the fallback possible.

On failure `FileBrowserView` prompts, offering **Get \<app\>** and **Open in Drive**. The second is
exactly the pre-existing behaviour (the in-app web viewer, or download + Quick Look).

`.note`, `.doc`, `.sheet`, and `.slide` are all offered (`Kind.hasCompanionApp`). Diagrams and
Drawings are excluded because they exist only on the web — an offer could never resolve into
anything but the Drive viewer the user already had.

Sheets and Slides are offered *ahead of their releases*. A miss there is not a dead end: the prompt
still opens the file in Drive, which is what tapping it did anyway, so one route covers every Office
file instead of two that diverge on release dates. When those apps ship, move their paths in the
AASA document and flip `FeatureFlags.appLinks` in their repositories; nothing here changes.

### The install offer

`CompanionAppStore` maps a `Kind` to its App Store item id and builds an `itms-apps://` link (rather
than `https://apps.apple.com/…`, which can bounce through Safari first — a browser flashing up on
the way to an install reads as the link having failed).

**The table is empty.** App Store Connect mints product ids at first submission, so they cannot be
derived from anything in these repositories; each entry carries a `TODO` to be filled in as the app
is published. That is why the empty state has to be inert rather than broken: `url(for:)` returns
nil, `hasListing(for:)` is false, the prompt omits its button and reworks its message, and the user
still gets "Open in Drive". A missing button is a much smaller failure than a button that opens a
404 on the App Store — and it is what lets Sheets and Slides be routed today.

`CompanionAppLauncher.Opener` therefore takes `universalLinksOnly` as a parameter: a companion app
is reached by Universal Link and must fail rather than fall into Safari, while `itms-apps:` is
claimed by *scheme* and demanding a universal link would reject it outright.

## Inbound (all three)

`DeepLinkRouter` holds the destination; the view layer consumes it. A link can arrive at a cold
launch straight onto the login screen, or while the lock overlay is up, and nothing but `consume()`
clears `pending` — so a link that arrives before sign-in survives the whole login round trip.

Each app claims only what it can render:

| App   | Accepts       | Rejects                                                   |
| ----- | ------------- | --------------------------------------------------------- |
| Notes | `note`        | everything else                                            |
| Docs  | `doc`         | everything else                                            |
| Drive | every kind    | non-Neutrino URLs (so the key-file `file://` flow still works) |

Drive accepts every kind on purpose: it is the last resort for a link whose own app has been
deleted, and every one of them is a Drive file.

Resolution is cache-then-server. `item(id:)` only sees listings this session has loaded, and a link
routinely names a file in a folder nobody has opened — hence `fetchItem(id:)` on each drive service,
against `GET /api/v1/drive/files/{id}/metadata`. Notes and Docs additionally check the MIME on the
way in: an `/open/doc/…` link pointing at a spreadsheet is a malformed link, and rendering the bytes
anyway would show the user garbage instead of an error.

## Feature flags

`FeatureFlags.companionAppLinks` (Drive), `FeatureFlags.appLinks` (Notes, Docs). Each is a real kill
switch for the runtime behaviour, but **not** for the entitlement: `applinks:` is a bundle property,
so iOS still launches the app with the URL and `onOpenURL` drops it.

## The server side

Implemented in the `neutrino` repository, because none of the above routes without it:

- `static/apple-app-site-association`, embedded and served as `application/json` from
  `/.well-known/apple-app-site-association` by a handler in `src/main.rs`. It is a route, not a
  static file: `actix_files` skips hidden paths and would guess the wrong content type for an
  extensionless one, and Apple rejects both. Covered by `tests::apple_app_site_association`, which
  pins the app ids and path patterns these three apps mint links against.
- `web/apps/web/src/app/(apps)/open/[kind]/[id]` — the browser fallback. Redirects to the editor
  that owns the format; `/open/file/<id>` resolves the MIME server-side first and falls back to
  `/drive?preview=<id>`. A dynamic route under a static export, using the same
  `generateStaticParams` placeholder trick as `/users/[id]`.
- `?next=` on sign-in, so a link followed while signed out survives the login round trip.

Still outside every repository: TLS termination must reach the API service on **both**
`www.getneutrino.app` and the apex without redirecting, and the Associated Domains capability must
be enabled on all three App IDs. See `deploy/README.md`.
