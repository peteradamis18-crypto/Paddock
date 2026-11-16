# YouTube: the one-time Google steps

Written 2026-11-13, made shorter 2026-11-15. Checked against Google's own pages on 2026-11-13
(`developers.google.com/youtube/v3/guides/auth/installed-apps`, `support.google.com/cloud/answer/6158849`,
`support.google.com/cloud/answer/15549945`). Google renames buttons now and then: if a button is not exactly as
written, press the one that means the same.

This is the only part Paddock cannot do for you: Google wants the owner of the channel to make the key.
About 10 minutes, once. After it, SHARE on a race uploads it by itself.

**You only click and press one Download button. Never type or paste any code, id or secret anywhere.**
**Easier still: ask Claude to do the clicks in your Chrome while you watch. You only sign in to Google yourself.**

## 1. Make the Paddock project (2 minutes)

1. Open `https://console.cloud.google.com` and sign in with the Google account that owns your YouTube channel.
2. If Google asks you to accept its terms: tick the box, press **Agree and continue**.
3. Press the project picker at the top (the box next to the Google Cloud logo), then **New project**.
4. **Project name:** `Paddock`. Press **Create**.
5. Wait a few seconds. The picker at the top must now say **Paddock** (press it and pick Paddock if not).

## 2. Turn on YouTube (1 minute)

1. Open `https://console.cloud.google.com/apis/library/youtube.googleapis.com` (YouTube Data API v3).
2. Check **Paddock** is the project at the top. Press **Enable**.

## 3. The sign-in screen (4 minutes)

1. Open `https://console.cloud.google.com/auth/overview`. Press **Get started**.
2. **App name:** `Paddock`. **User support email:** pick your own. Press **Next**.
3. **Audience:** **External**. Press **Next**.
4. **Contact information:** your own email. Press **Next**.
5. Tick the box to agree to the Google API Services User Data Policy. Press **Continue**, then **Create**.
6. Left menu: **Data Access**. Press **Add or remove scopes**.
7. In **Manually add scopes** paste exactly: `https://www.googleapis.com/auth/youtube.upload`
8. Press **Add to table**, then **Update**, then **Save** at the bottom.
9. Left menu: **Audience**. Press **Publish app**, then **Confirm**. It must say **In production**.
   (On **Testing** Google signs you out every 7 days.)

## 4. The key file (1 minute)

1. Left menu: **Clients**. Press **Create client**.
2. **Application type:** **Desktop app**. **Name:** `Paddock`. Press **Create**.
3. A box opens with **Download JSON**. Press it. Your browser saves a file whose name starts with `client_secret`.
4. That is all. Paddock takes the file from your Downloads folder by itself within 10 seconds (it keeps it as
   `dash\yt\client.json`, which never goes to GitHub). Nothing to rename or move. Close the Google page.

## 5. Sign in once, on the top screen

1. Open **RACES** on the top screen. The gold button **Sign in to YouTube** is there (also on a race's card after SHARE).
2. Press it. A browser tab opens on Google's sign-in page. Pick your account (the one that owns the channel).
3. If Google warns that the app is not verified (normal: it is your own private app): press **Advanced** at the
   bottom left, then **Go to Paddock (unsafe)**.
4. Press **Allow** (or **Continue**). The tab says it is done. Close it.
5. Paddock is signed in for good. SHARE on any race now uploads it. If a card ever says **Sign in to YouTube
   again**, press it and do this part once more.

## Limits

- About 100 uploads a day. You will never get near it.
- Only you sign in with this key (Google allows 100 people for an unverified app; you use 1).
