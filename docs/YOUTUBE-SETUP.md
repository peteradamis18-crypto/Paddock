# YouTube setup: the one-time Google steps

Written 2026-11-13. Checked against Google's own pages that day:
`developers.google.com/youtube/v3/guides/auth/installed-apps`, `support.google.com/cloud/answer/6158849`,
`support.google.com/cloud/answer/15549945`, `developers.google.com/youtube/v3/determine_quota_cost`.
Google renames buttons now and then. If a button is not exactly as written, pick the one that means the same.

This is the only part Paddock cannot do for you. It takes about 10 minutes and you do it once. After it, the
**SHARE ON YOUTUBE** key uploads the race for you.

Do not paste any code, id or secret anywhere. You will only click and download one file.

## Part 1: make the Paddock project

1. Open a browser and go to `https://console.cloud.google.com`.
2. Sign in with the Google account that owns your YouTube channel.
3. If Google asks you to accept the terms, tick the box and press **Agree and continue**.
4. At the top of the page, press the project picker (the box next to the Google Cloud logo).
5. In the window that opens, press **New project**.
6. In **Project name**, type `Paddock`.
7. Leave everything else as it is and press **Create**.
8. Wait a few seconds. Make sure the project picker at the top now says **Paddock** (press it and pick Paddock if not).

## Part 2: turn on YouTube

1. Go to `https://console.cloud.google.com/apis/library/youtube.googleapis.com` (this is the **API Library** page for **YouTube Data API v3**).
2. Check that **Paddock** is the project shown at the top.
3. Press **Enable**.
4. Wait until the page shows the API's overview (it has a graph and the word **Manage**).

## Part 3: the sign-in screen (Google calls it the OAuth consent screen)

1. Go to `https://console.cloud.google.com/auth/overview` (**Google Auth Platform**).
2. Press **Get started**.
3. **App name:** type `Paddock`. **User support email:** pick your own email from the list. Press **Next**.
4. **Audience:** pick **External**. Press **Next**.
5. **Contact information:** type your own email. Press **Next**.
6. Tick the box to agree to the **Google API Services User Data Policy**. Press **Continue**, then **Create**.
7. In the menu on the left, press **Data Access**.
8. Press **Add or remove scopes**.
9. In the box named **Manually add scopes**, paste exactly this line: `https://www.googleapis.com/auth/youtube.upload`
10. Press **Add to table**, then **Update**, then **Save** at the bottom of the page.
11. In the menu on the left, press **Audience**.
12. Press **Publish app**, then **Confirm**. The page must now say **In production**.
13. Why step 12 matters: if it stays on **Testing**, Google signs you out every 7 days and you would have to do the first-time sign-in again and again.

## Part 4: the key file

1. In the menu on the left, press **Clients**.
2. Press **Create client**.
3. **Application type:** pick **Desktop app**.
4. **Name:** type `Paddock`.
5. Press **Create**.
6. A box opens with a **Download JSON** button. Press it. Your browser saves a file whose name starts with `client_secret`.
7. Open your **Downloads** folder.
8. Rename that file to exactly `client.json`.
9. Make the folder `C:\Users\peter\iRacingDeck\dash\yt` if it is not there (right-click, **New**, **Folder**, name it `yt`).
10. Move `client.json` into it, so the full path is exactly `C:\Users\peter\iRacingDeck\dash\yt\client.json`.
11. Do not email this file, post it, or put it on GitHub. It stays on this PC. (Paddock's code folder already ignores `dash/yt/`.)

That is all of the Google side. You are done with the console. Close it.

## Part 5: the first SHARE ON YOUTUBE

1. Press **SHARE ON YOUTUBE** on a race, as you normally would.
2. A browser tab opens on Google's sign-in page.
3. Pick your Google account (the one that owns your channel).
4. If Google shows the warning in the next section, follow it. If not, go on.
5. Press **Allow** (or **Continue**).
6. The tab says it is done. Close the tab.
7. Paddock now uploads the race. You will not be asked again.

## If Google shows a warning that the app is not verified

This is normal. Paddock is your own private app and Google has not reviewed it.

1. On the warning page, press **Advanced** (a small link at the bottom left).
2. Press **Go to Paddock (unsafe)**.
3. Go on with Part 5, step 5.

It is safe because you made the app yourself and it only asks to upload videos.

## Limits

- YouTube allows about 100 uploads per day for a project like this. You will never get near it.
- Only you should sign in with this key. Google lets an unverified app have 100 people sign in over its lifetime, and you use 1 of them.
- If Paddock ever says "Sign in to YouTube again", press that key and do Part 5 once more. Nothing else is needed.
