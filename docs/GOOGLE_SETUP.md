# Connecting Google Calendar and Gmail (step-by-step)

This guide gets the app talking to your **real** Google Calendar and Gmail. It is written for
someone who has never used the Google Cloud console before — every term is explained the first
time it appears. Nothing here costs money; all of it uses Google's free tier.

You do this **once**. After it works, the app remembers your permission and quietly renews it
in the background — you won't be asked again unless you disconnect or Google expires the grant.

---

## What you're about to do (the big picture)

The app needs your permission to see your Google data. Google only grants that permission to a
registered "app" that **you** own. So the steps are:

1. Create a free **Google Cloud project** — think of this as a folder Google uses to track one
   app's settings.
2. Turn on the **Calendar** and **Gmail** APIs — "API" just means "the doorway other programs
   use to talk to Google."
3. Register this app as an **OAuth client** — "OAuth" is the industry-standard "Sign in with
   Google" permission system. The "client" is the ID card that identifies this specific app.
4. List yourself as a **test user** so Google lets you (and only you) use it.
5. Copy the app's ID into a local settings file and run the app.

Set aside about 15 minutes. You'll need a Google account and a Mac with the app's source code.

---

## Part 1 — Create the Google Cloud project

1. Go to **https://console.cloud.google.com/** and sign in with the Google account whose
   Calendar and Gmail you want the app to read.
2. At the very top of the page, click the **project picker** (it's a dropdown near the Google
   Cloud logo, and may say "Select a project").
3. Click **New Project**.
4. For **Name**, type something you'll recognize, e.g. `Personal Ops Agent`. Leave everything
   else as-is and click **Create**.
5. Wait a few seconds, then make sure the project picker at the top now shows your new project
   (select it if it doesn't). Everything below must happen **inside this project**.

---

## Part 2 — Turn on the Calendar and Gmail doorways (APIs)

1. In the search bar at the top, type **Google Calendar API** and click the matching result.
2. Click the blue **Enable** button. Wait for it to finish.
3. Search again for **Gmail API**, open it, and click **Enable**.

That's it — the two doorways are now open for your project.

---

## Part 3 — Tell Google what the permission screen should say (OAuth consent screen)

Before Google will hand out permission, it wants to know what to show you on the "do you allow
this app?" screen.

1. In the search bar, type **OAuth consent screen** and open it (it lives under
   "APIs & Services").
2. If asked to choose a **User Type**, pick **External** and click **Create**. ("External" just
   means "not limited to a company workspace" — it's the right choice for a personal Google
   account.)
3. Fill in the required fields:
   - **App name**: `Personal Ops Agent` (or anything you like).
   - **User support email**: pick your own email from the dropdown.
   - **Developer contact information**: type your email again at the bottom.
4. Click **Save and Continue**.
5. On the **Scopes** step, you don't need to add anything here — click **Save and Continue**.
   ("Scopes" are the specific permissions the app asks for; the app requests them itself, so
   this page can stay empty.)
6. On the **Test users** step, click **+ Add Users**, type the **same Google email** you're
   signed in with, and click **Add**. This is important: while the app is in "Testing" status,
   **only** the emails listed here are allowed to use it. Click **Save and Continue**.
7. Review and click **Back to Dashboard**. Leave the **Publishing status** as **Testing** — you
   do not need to publish or get verified for personal single-user use.

---

## Part 4 — Create the app's ID card (OAuth client ID)

1. In the search bar, type **Credentials** and open it (under "APIs & Services").
2. Click **+ Create Credentials** at the top, then choose **OAuth client ID**.
3. For **Application type**, choose **iOS**. (This app runs on iPhone; the iOS client type is
   what makes the secure sign-in window work correctly, and it needs no password/secret.)
4. For **Bundle ID**, enter exactly:

   ```
   com.rajatarora.PersonalOpsAgent
   ```

   (The "Bundle ID" is the app's unique name on the phone. It must match the app exactly, or
   Google will refuse the sign-in.)
5. Click **Create**.
6. A box pops up showing your **Client ID**. It looks like:

   ```
   1234567890-abc123def456.apps.googleusercontent.com
   ```

   Click the copy icon to copy it. (There is **no client secret** for an iOS client — that's
   normal and correct. The app proves its identity a different, more secure way called PKCE.)

Keep this Client ID handy for the next part.

---

## Part 5 — Put the Client ID into the app

1. On your Mac, open the app's source folder. Inside it is a folder named **`Secrets`** with a
   file called **`Config.example`**.
2. Make a copy of that file in the same folder and rename the copy to **`Config.local`**.
   (`Config.local` is deliberately ignored by version control, so your private values never get
   committed or logged.)
3. Open `Config.local` in any text editor. Find the line that starts with
   `GOOGLE_OAUTH_CLIENT_ID=` and replace the placeholder after the `=` with the Client ID you
   copied. It should end up looking like:

   ```
   GOOGLE_OAUTH_CLIENT_ID=1234567890-abc123def456.apps.googleusercontent.com
   ```

   Leave the other two lines (`GEMINI_API_KEY`, `ELEVENLABS_API_KEY`) as they are — they're for
   later phases and can stay as placeholders for now.
4. Save the file.

> For a build running on your phone, `Config.local` needs to be included in the app bundle so
> the app can read it at launch. In Xcode, drag `Secrets/Config.local` into the project and make
> sure it's checked for the **PersonalOpsAgent** target under "Target Membership." If the app
> can't find the file it simply starts **unconfigured** (see below) — it won't crash.

---

## Part 6 — Connect, inside the app

1. Build and run the app on your iPhone (or the iOS Simulator) from Xcode.
2. Tap the **Integrations** tab at the bottom.
3. You'll see **Calendar** and **Gmail**, each marked **Not connected**.
4. Tap **Connect**. A secure Google sign-in window slides up.
5. Choose your Google account and read the permission screen. Because the app is in "Testing",
   Google may show a **"Google hasn't verified this app"** warning — this is expected for an app
   only you use. Click **Continue** (you may need to click **Advanced → Go to Personal Ops
   Agent** first).
6. Approve the requested permissions.
7. The window closes and both **Calendar** and **Gmail** should now show **Connected**, with a
   freshness line like "Synced just now."

### What you should expect to see

- **Calendar** and **Gmail** both flip to **Connected**.
- A dedicated calendar named **"Personal Ops Agent"** gets created in your Google Calendar the
  first time the app writes to it (later phases). The app **only ever writes to that calendar** —
  it can read your real calendars but is technically incapable of changing them.
- If you tap **Disconnect**, the app forgets the permission on this device and both rows return
  to **Not connected**.

---

## What "degraded" looks like (and why it's on purpose)

The app is built to **tell you when something's wrong instead of pretending everything's fine**:

- **No Client ID configured** (you skipped Part 5, or the file wasn't bundled): the Integrations
  screen still opens, both rows say **Not connected**, and tapping **Connect** shows
  *"Missing configuration: GOOGLE_OAUTH_CLIENT_ID. See docs/SETUP.md."* Nothing crashes.
- **Permission expired or you revoked it** (e.g. from your Google Account's "Third-party access"
  page): the affected rows switch to **Reconnect needed** with an orange **Reconnect** button.
  The app never silently drops your data — it asks you to reconnect.
- **You're offline**: the rows keep their last-synced time and show it as out of date rather than
  claiming to be current.

---

## The permissions the app asks for (and why these exact ones)

The app requests the **narrowest** permissions that let it do its job:

| Permission (scope)            | What it allows                                              | Why this one |
|-------------------------------|------------------------------------------------------------|--------------|
| `calendar.readonly`           | **Read** all your calendars. Cannot change anything.       | Needed to show your real schedule in the morning briefing. Read-only, so it can never edit your events. |
| `calendar.app.created`        | Create and manage events **only on calendars the app made**. | This is the safety guarantee: the app's own "Personal Ops Agent" calendar is the *only* place it can write. It is structurally unable to touch your real calendars — not just "promises not to." |
| `gmail.readonly`              | **Read** your email (list/search + previews). No sending.  | Needed to spot plan-like emails (later phases). We deliberately avoid any "send" permission — the app can never email on your behalf. |

We intentionally did **not** request the broader "read/write all calendars" permission, and
there is **no** Gmail send permission anywhere in the app.

---

## What was verified automatically vs. what only you can verify

The app's logic is fully covered by automated tests that use a **mocked** Google server (a stand-in
that returns canned responses), so the following are proven without any real account:

- Silent token refresh when the access token expires.
- A revoked permission producing the visible **Reconnect** state (never a crash).
- A retried calendar write reusing the same event ID and producing exactly **one** event.
- Gmail sync storing only the allowed fields (message ID, thread ID, received date, scan time).

The following can only be confirmed with your real Google account by following Parts 1–6 above,
because they need Google's live servers:

- The real consent window actually appearing and returning a working permission.
- Your real calendar events showing up in the app.
- The "Personal Ops Agent" calendar being created in your real Google Calendar.
- The iOS Keychain (the phone's secure password vault) storing the permission across app
  restarts on a real signed build. (In the iOS Simulator, an unsigned test build can't reach the
  Keychain, so that one automated check is skipped there and is instead confirmed on a real
  device or a signed run.)
