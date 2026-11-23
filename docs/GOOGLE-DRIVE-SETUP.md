# Google Drive setup

This takes about 15 minutes, and you only do it once. You need two things:
a **free Google API key**, and **one shared Drive folder per console**.

> Only put files in your folders that you have the right to use, such as copies of your own cartridges.

## 1. Create your API key

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and sign in. You don't need a payment card.
2. **Create a project.** Open the project picker at the top, click **NEW PROJECT**, name it `Pocket Drop` and click **CREATE**. Make sure it's selected.
3. **Enable the Drive API.** Go to **☰ → APIs & Services → Library**, search for **Google Drive API** and click **ENABLE**.
4. **Create the key.** Go to **APIs & Services → Credentials → + CREATE CREDENTIALS → API key** and copy the key. It starts with `AIza`.
5. **Lock it down (recommended).** Click the key, go to **API restrictions → Restrict key**, tick **Google Drive API** and click **SAVE**. Leave *Application restrictions* on **None**.

## 2. Share one folder per console

1. In [Google Drive](https://drive.google.com), make a folder for each console, such as `GBA` or `SNES`, and upload your files.
2. Right-click a folder and choose **Share**. Under **General access**, choose **Anyone with the link** (Viewer), then click **Copy link**.

Keep these links private: anyone who has one can see that folder.

## 3. Add the key and links to Pocket Drop

Open `PocketDrop/drive_links.ini` on your PC with Notepad:

```ini
api_key = AIzaSy...your key...

GBA  = https://drive.google.com/drive/folders/1AbC...?usp=sharing
SNES = https://drive.google.com/drive/folders/1XyZ...?usp=sharing
```

Leave the consoles you don't use empty, then save.
You can also link a console on the device itself: highlight it and press **X**.

## Troubleshooting

| Message | Fix |
| --- | --- |
| **API key is wrong** | Re-enter it in *Settings → Google API key*, or fix `api_key` in `drive_links.ini`. |
| **Refused the request (403)** when opening a folder | The Google Drive API isn't enabled (step 1.3), or the key is restricted to another API. |
| **Download limit reached** | Google pauses a file after many downloads in a short time. Wait, usually under 24 hours. |
| **Google can't see this folder** | Share it as *Anyone with the link* (Viewer). |
| Google Docs or Sheets files missing | These are skipped. Upload real files instead. |

Your key is hidden in `log.txt`, so the log is safe to share when asking for help.
