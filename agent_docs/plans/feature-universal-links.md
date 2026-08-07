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
verbatim** in all three repositories. It is a wire format between three separately shipped binaries:
an app built last month must still open a link minted today. The copies must stay identical, and
each repository has the same `NeutrinoAppLinkTests` suite pinning them.

The MIME table matches both the `application/x-neutrino-*` spelling the backend writes today
(`src/notes/service.rs`, `src/docs/docs/service.rs`) and the older `application/vnd.neutrino.*` form
still found in `DriveItem.NeutrinoMIME` and in old records, so routing does not depend on which
vintage of the server wrote the row.

## Outbound (Drive)

`CompanionAppLauncher` opens the link with `UIApplication.open(_:options: [.universalLinksOnly:
true])`. The option is there for the *negative* answer: there is no API that reports whether another
app is installed (`canOpenURL` says yes to every `https` URL, because Safari can always take it).
With `universalLinksOnly`, iOS either routes to the installed app or reports failure — it never
drops the user into Safari behind Drive's back, which is what makes the fallback possible.

On failure `FileBrowserView` offers **Open in Drive**, which is exactly the pre-existing behaviour
(the in-app web viewer, or download + Quick Look).

Only `.note` and `.doc` are offered (`Kind.hasCompanionApp`). Sheets, Slides, Diagrams and Drawings
have no iOS app yet, so offering to open them elsewhere would always end in the "isn't installed"
alert. Their links are still well-formed — when those apps ship, flip the flag and move the path in
the AASA document; nothing else changes.

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
