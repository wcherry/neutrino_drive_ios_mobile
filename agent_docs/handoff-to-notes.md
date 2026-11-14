Integrate drive with other Neutrino apps.

> **Decided: Option 2 (Universal Links), implemented.** Drive, Notes, and Docs all ship it —
> `https://www.getneutrino.app/open/<kind>/<file id>`, one path segment per app, carrying only the
> file id so the receiving app fetches the current version itself. The design, the trade-offs
> against the other four options, and the manual verification steps are in
> `agent_docs/plans/feature-universal-links.md` and
> `agent_docs/plans/feature-universal-links-verification.md`. The routing table that makes it work
> lives in `deploy/apple-app-site-association` and still has to be served from the domain.
>
> The "make it generic" idea at the bottom of this document is what the `Kind` enum in
> `NeutrinoAppLink.swift` implements: Sheets, Slides, Diagrams, and Drawings already have link kinds
> and MIME mappings, and open in Drive until those iOS apps exist.

## Option 1: Custom URL Schemes (Simple)

Your Notes app registers a custom URL scheme such as:

```
neutrinonotes://open?id=12345
```

From your Drive app:

```swift
if let url = URL(string: "neutrinonotes://open?id=\(fileId)") {
    UIApplication.shared.open(url)
}
```

In your Notes app:

```xml
CFBundleURLTypes
    URL Schemes:
        neutrinonotes
```

Then handle it in your `App`:

```swift
.onOpenURL { url in
    // Parse URL
    // Load requested note
}
```

### Pros

- Very easy
- Works well for apps from the same developer
- Can pass IDs, paths, etc.

### Cons

- Anyone could theoretically invoke your URL scheme (though you can require authentication).

---

## Option 2: Universal Links (Recommended if files may come from the web)

Instead of:

```
neutrinonotes://open?id=123
```

You use

```
https://drive.neutrino.com/open?id=123
```

If Notes is installed:

- launches Notes

Otherwise:

- opens Safari

This is Apple's preferred approach.

---

## Option 3: UIDocumentInteractionController

If your Drive app downloads the file locally:

```
Notes.md
```

you can ask iOS to open it in another app that supports Markdown.

This behaves like Files.app.

Not ideal if you specifically want your own Notes app.

---

## Option 4: Document Types + Open In Place (Probably Best for Neutrino)

Your Notes app declares support for:

```
text/markdown
text/plain
application/x-neutrino-note
```

(or a custom Uniform Type Identifier (UTType))

When your Drive app has downloaded a file it can call:

```swift
UIDocumentInteractionController
```

or

```swift
UIActivityViewController
```

and iOS will know your Notes app is capable of opening it.

---

# Option 5: NSUserActivity / Handoff

Apple also supports continuing activities between apps, although this is more intended for Handoff and Spotlight than simple "open this file."

Probably unnecessary for your use case.

---

# What I'd recommend for Neutrino

Since your ecosystem already consists of multiple apps (Drive, Notes, Sheets, Slides, etc.), I'd use a combination of **custom URL schemes (or Universal Links)** for app-to-app launching and a **shared file identifier** rather than passing file contents.

For example, in Drive:

```
User taps:
Meeting Notes.md
```

Drive checks:

```
Can Notes handle markdown?
```

If yes:

```
neutrinonotes://open?
    workspace=abc
    file=0d0f7c...
    version=42
```

Notes launches, authenticates if needed, and retrieves the latest version of the file from your Neutrino backend using the file ID. This avoids duplicating downloads, keeps permissions centralized, and ensures the user sees the current version.

If the Notes app isn't installed:

- Prompt the user to install it.
- Or fall back to a read-only preview within Drive.

## You can even make this generic

Given your architecture (Drive, Notes, Sheets, Slides), consider having every app advertise the MIME types or UTTypes it supports.

For example:

| App | MIME Types |
|------|------------|
| Notes | `text/markdown`, `text/plain`, `application/x-neutrino-note` |
| Sheets | `application/vnd.neutrino.sheet`, `text/csv`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` |
| Slides | `application/vnd.neutrino.slides`, `application/vnd.openxmlformats-officedocument.presentationml.presentation` |

Then your Drive app can determine the appropriate destination app based on the file's MIME type and launch it via its URL scheme or Universal Link. This creates an experience similar to how Google Drive launches Docs, Sheets, and Slides on iOS while keeping each editor as a separate app.