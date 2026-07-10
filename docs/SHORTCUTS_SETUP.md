# Forwarding iMessages to Personal Ops Agent (Shortcuts setup)

This guide sets up a **personal automation** so that when you receive a text message, its
content is quietly handed to Personal Ops Agent. The app turns it into a **pending item in your
Ops Inbox** that you review later — it never schedules anything, never replies, and never saves
anything to memory on its own. You approve or dismiss every item.

## Why this is needed

Apple does **not** allow any app to read your Messages in the background. The only permitted way
to get a text into the app is for *you* to set up a Shortcuts automation that forwards the
message text to the app. This is deliberately best-effort: it only covers messages the automation
catches, and it treats every forwarded text as **untrusted** (clearly marked as coming from a
message, not from your verified calendar).

## What you'll build

A "When I get a message" automation that runs one action: **Send a message to Personal Ops**.
That action passes the message's text to the app.

## Before you start

- You need the **Shortcuts** app (built into iOS — if you deleted it, reinstall from the App
  Store).
- Personal Ops Agent must be installed on the same iPhone.

## Step-by-step

1. Open the **Shortcuts** app.
2. Tap the **Automation** tab at the bottom.
3. Tap the **+** in the top-right, then tap **Create Personal Automation**.
   (If this is your first automation, you'll go straight to the "New Automation" list.)
4. Scroll down and tap **Message**.
5. Under **Message**, choose when it should run. You have two useful options:
   - **Message Contains** a word you'll use as a trigger (for example, type `ops` so only texts
     containing "ops" are forwarded), **or**
   - **Sender** set to yourself (a common trick: text yourself notes, and only those get
     forwarded). Choose whichever fits how you want to use it. Starting narrow (a keyword) is the
     least noisy.
6. Set **Run** to **Run Immediately** (so it doesn't ask you to tap every time). Tap **Next**.
7. On the "Actions" screen, tap **Add Action**.
8. In the search box, type **Personal Ops** (or **Send a message to Personal Ops**). Tap that
   action when it appears.
9. The action shows a **Message text** field. Tap it, then tap the **Shortcut Input** or
   **Messages** variable so it inserts the incoming message's **Content**. This is what tells the
   automation to pass the actual text of the message.
   - Optional: if a "Received at" field is offered, you can leave it empty — the app handles it
     either way. (If you fill it, a message that somehow arrives very late is safely ignored.)
10. Tap **Next**, review, and tap **Done**.

That's it. From now on, a matching message is handed to Personal Ops Agent in the background.

## Trying it out

1. Send yourself (or have someone send you) a text that matches your trigger and contains a
   plan, for example:
   `ops dinner with Sam on March 5 at 7pm`
2. Open Personal Ops Agent and go to the **Inbox** tab.
3. You should see a **pending** item created from that text — for a message with a clear date and
   time, it proposes an event on your **agent calendar** (not your real calendar); for a message
   with no date/time, it proposes remembering the note. Approve it to act on it, or dismiss it.

## What the app does — and does not — do with a forwarded message

- **Does**: read the text, look for a clear date/time, and create **one pending Ops Inbox item**
  marked as coming from an (untrusted) message.
- **Does not**: schedule anything automatically, write to your real calendars, send any reply,
  or save anything to memory without your explicit approval.
- **Dropped silently**: an empty message, a blank/whitespace message, or one that arrives a long
  time late produces **nothing** — the app does not guess.

## Notes and limits

- This is **best-effort**. It is normal for it not to catch every message; that's an iOS
  limitation, not a bug.
- Attachments, tapback reactions, edited messages, and deleted messages are **not** handled in
  this version.
- You can turn the automation off at any time from the **Automation** tab in Shortcuts without
  affecting anything else in the app.
- If the **Send a message to Personal Ops** action doesn't appear in the search, open Personal
  Ops Agent once (so iOS indexes its Shortcuts action), then try adding the action again.
