# Universal Links deployment

`apple-app-site-association` is the routing table for every `https://www.getneutrino.app/open/…`
link. Until it is served, **no** app link works: iOS fetches this document when an app with the
`applinks:` entitlement is installed, and an app it does not mention gets nothing.

## Where it is served from

**The served artifact lives in the `neutrino` repository**, at `static/apple-app-site-association`,
embedded into the API binary and returned by the handler in `src/main.rs`. The copy in this
directory is the iOS-side reference — the two must agree, and the backend's
`tests::apple_app_site_association` suite pins the app ids and path patterns that the iOS
`NeutrinoAppLink.swift` mints links against.

It is a route rather than a static file because all three of these fail *silently*:

- `actix_files::Files` does not serve hidden paths, so a file under `web/.well-known/` falls through
  to the SPA's `index.html` handler and Apple is handed HTML.
- The document has no extension, so a static file server guesses `application/octet-stream`; Apple
  requires `application/json`.
- It must not redirect — `NormalizePath` is configured `MergeOnly` for this reason.

## Serving it at both hosts

The route answers on whatever host reaches the API service, so both of these must terminate at it:

```
https://www.getneutrino.app/.well-known/apple-app-site-association
https://getneutrino.app/.well-known/apple-app-site-association
```

Requirements Apple enforces, all of which fail silently:

- `Content-Type: application/json`. No `.json` extension on the path.
- Plain HTTPS with a valid certificate. **No redirects** — a 301 from the apex to `www.` breaks the
  apex claim, so serve the document at both hosts rather than redirecting one to the other. This is
  the one part not settled by the handler: check whatever terminates TLS in front of it.
- No authentication, no cookies, no `Vary` on anything the CDN might mangle.
- Unsigned JSON. The signed (`CMS`) form is legacy and not needed.

## Verifying

```sh
curl -sSI https://www.getneutrino.app/.well-known/apple-app-site-association   # expect 200 + application/json
curl -sS  https://www.getneutrino.app/.well-known/apple-app-site-association | jq .
```

Apple's CDN caches the document; a change can take up to 24 hours to reach devices that already
have the app installed. During development, install with the entitlement in `developer` mode
(`applinks:` + the `Associated Domains Development` capability) so the device bypasses the CDN, or
delete and reinstall the app to force a refetch.

## Path ownership

One path segment per app is what lets all three share the domain:

| Path              | App             | Notes                                       |
| ----------------- | --------------- | ------------------------------------------- |
| `/open/note/*`    | Neutrino Notes  | `application/x-neutrino-note`                |
| `/open/doc/*`     | Neutrino Docs   | `application/x-neutrino-doc`                 |
| `/open/file/*`    | Neutrino Drive  | anything else                                |
| `/open/sheet/*`   | Neutrino Drive  | reassign when the Sheets iOS app ships       |
| `/open/slide/*`   | Neutrino Drive  | reassign when the Slides iOS app ships       |
| `/open/diagram/*` | Neutrino Drive  | reassign when the Diagrams iOS app ships     |
| `/open/drawing/*` | Neutrino Drive  | reassign when the Drawings iOS app ships     |

The link format itself lives in `NeutrinoAppLink.swift`, which is duplicated verbatim in the Notes
and Docs repositories. Changing a path here means changing it in all three.

## Web fallback

Every one of these URLs also renders in a browser — that is what a recipient without the app
installed gets, and it is the whole advantage of Universal Links over a custom URL scheme.

The `neutrino` repository serves it: `web/apps/web/src/app/(apps)/open/[kind]/[id]` redirects
`/open/<kind>/<id>` to the editor that owns the format (`/notes/editor?id=…`, `/docs/editor?id=…`,
and so on). A `/open/file/<id>` link, which names no format, asks the server what the file is and
routes on its MIME type, falling back to `/drive?preview=<id>` for files with no editor.

A recipient who is not signed in keeps their destination through the login round trip
(`?next=`, validated against off-site redirects in `src/lib/signInRedirect.ts`).
