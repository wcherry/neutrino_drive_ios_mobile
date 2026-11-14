# Manual Verification: Universal Links between the Neutrino apps

`NeutrinoAppLinkTests`, `CompanionAppLauncherTests` and `DeepLinkRouterTests` (in all three
repositories) cover the link format, the routing table, the launcher's both branches, and what each
app claims — without a device or a network.

**What no test in any of these repositories can prove:**

1. **That iOS routes the link at all.** Universal Link routing depends on the
   `apple-app-site-association` document Apple's CDN fetches from `www.getneutrino.app`, the
   `applinks:` entitlement in the signed build, and the device's own association cache. None of the
   three is reachable from a unit test, and all three fail *silently* — a misconfiguration looks
   exactly like Safari opening, which is also the correct behaviour when the app is absent.
2. **`UIApplication.open(_:options: [.universalLinksOnly: true])`.** The launcher's `Opener` is
   injected in tests, so the one call that talks to iOS is the one never exercised.
3. **The simulator cannot be trusted here.** Associated domains work on a simulator only
   inconsistently; treat a physical device as the only real result.

## Prerequisites

- [ ] A build of the `neutrino` API service that includes the
      `/.well-known/apple-app-site-association` handler is deployed, and **both** hosts reach it
      with `Content-Type: application/json` and no redirects. Verify first — everything below fails
      identically if this is wrong, and the apex is the part the handler cannot settle by itself:
      ```sh
      curl -sSI https://www.getneutrino.app/.well-known/apple-app-site-association
      curl -sSI https://getneutrino.app/.well-known/apple-app-site-association
      ```
- [ ] The Associated Domains capability is enabled for all three App IDs in the developer portal
      (`com.neutrino.drive`, `com.neutrino.notes`, `com.neutrino.docs`), and the provisioning
      profiles have been regenerated since. A stale profile fails the build with
      "doesn't include the com.apple.developer.associated-domains entitlement".
- [ ] A **physical device** running iOS 16+.
- [ ] All three apps installed from the same team, signed in to the same account, with the
      encryption key imported.
- [ ] At least one note (`.md` created in Notes) and one document (created in Docs) visible in
      Drive, plus one ordinary file (a PDF or photo).
- [ ] Console.app attached, filtering subsystems `com.neutrino.drive`, `com.neutrino.notes`,
      `com.neutrino.docs`, category `DeepLinkRouter`.

> Freshly installed apps refetch the association immediately; a change to the served document can
> take up to 24 hours to reach devices that already have the app. When in doubt, delete and
> reinstall.

---

## 1. Drive → Notes

- [ ] In Drive, open My Drive and tap a note.
- [ ] **Neutrino Notes comes to the front** showing that note, at its current content — not a
      download, not the web viewer.
- [ ] The Notes log shows `accepted note link file=<id>`.
- [ ] Edit a word in Notes, return to Drive, tap the same note again: the edit is there. (This is
      the "no duplicated download, always current" property — Notes fetched, it did not receive
      bytes from Drive.)
- [ ] Back-swipe in Notes lands on the notes list, not on a blank screen.

## 2. Drive → Docs

- [ ] Repeat with a document. **Neutrino Docs** opens it in the editor.
- [ ] The Docs log shows `accepted document link file=<id>`.
- [ ] The document opens on the **Home** tab's stack — the tab bar switches to Home if it was
      elsewhere.

## 3. Long-press menu

- [ ] Long-press a note in Drive: the menu's first item reads **Open in Neutrino Notes**.
- [ ] Long-press a document: **Open in Neutrino Docs**.
- [ ] Long-press a PDF: no companion entry — **Download & Open** as before.
- [ ] The entry appears in Starred, Shared and Recents too, not only My Drive.

## 4. Companion app missing

- [ ] Delete Neutrino Notes from the device.
- [ ] In Drive, tap a note. **Safari must not open.** Expect the alert
      *"Neutrino Notes Isn't Installed"*.
- [ ] Tap **Open in Drive**: the file opens the way it did before this feature (web viewer or
      download + Quick Look).
- [ ] Tap the note again and choose **Cancel**: nothing happens, no viewer, no download.
- [ ] Reinstall Notes and confirm tapping a note routes there again. (May need a relaunch for iOS to
      re-associate.)

## 5. Cold launch from a link

- [ ] Force-quit Notes. In Drive, tap a note. Notes launches **from cold** and lands on that note.
- [ ] Sign out of Notes, force-quit it, then tap a note in Drive. Notes opens on the **login
      screen**; after signing in, the linked note opens by itself. This is the pending-link
      round trip — if it opens the notes list instead, the router cleared `pending` too early.
- [ ] Repeat with the app lock enabled (Settings → Security): the lock screen appears first, and the
      note is there after unlocking.

## 6. Links from outside the apps

- [ ] Email `https://www.getneutrino.app/open/note/<id>` to yourself and tap it in Mail. Notes opens.
      (Tapping a link in **Safari's address bar** deliberately does not trigger Universal Links —
      that is iOS behaviour, not a bug. Use Mail, Messages, or Notes.app to test.)
- [ ] Tap a `/open/doc/<id>` link on a device where **Docs is not installed**: Safari opens the web
      app and lands on `/docs/editor?id=<id>` with that document open. This is the Option 2
      pay-off.
- [ ] Paste `https://www.getneutrino.app/open/doc/<id>` into a note and tap it from **inside Notes**:
      Docs opens, not Notes. (Notes rejects non-note kinds.)

## 7. Wrong and hostile links

- [ ] `https://www.getneutrino.app/open/note/<a document's id>` → Notes shows *"Couldn't Open Note"*
      rather than an empty or garbled editor.
- [ ] `https://www.getneutrino.app/open/note/does-not-exist` → the same alert, no crash.
- [ ] `https://evil.example.com/open/note/<id>` → nothing opens; the log shows no `accepted` line.
- [ ] `https://www.getneutrino.app/pricing` → opens in Safari as an ordinary web page.

## 8. The browser fallback

Do these in a **desktop browser**, where Universal Links never apply and the web app always answers.

- [ ] `https://www.getneutrino.app/open/note/<id>` lands on `/notes/editor?id=<id>`.
- [ ] `https://www.getneutrino.app/open/doc/<id>` lands on `/docs/editor?id=<id>`.
- [ ] `https://www.getneutrino.app/open/file/<id>` for a **PDF** lands on `/drive?preview=<id>` with
      the preview open — not on a bare listing.
- [ ] `https://www.getneutrino.app/open/file/<id>` for a **document** lands in the Docs editor: the
      generic kind resolves by MIME type server-side.
- [ ] `.../open/note/does-not-exist` shows "Can't open this link", not a spinner forever.
- [ ] `.../open/banana/<id>` shows the same error.
- [ ] **Signed out**, open `.../open/note/<id>`: the sign-in page appears with `?next=` in the URL,
      and signing in lands on that note — not on Drive.
- [ ] `https://www.getneutrino.app/sign-in?next=https://example.com` signs in to **Drive**, not to
      example.com. (Open-redirect guard.)

## 9. No regressions

- [ ] Drive: the key-file "Open In" flow still works — AirDrop a `neutrino-key.json` to the device
      and choose Neutrino Drive. The import alert appears. (`onOpenURL` now has two claimants; this
      is the one that must still get its `file://` URL.)
- [ ] Drive: tapping a PDF, an image, and a folder behaves exactly as before.
- [ ] Notes and Docs launched normally (from the Home screen) open on their usual screen with no
      stray editor pushed.
