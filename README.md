<p align="center">
  <img width="256" height="256" alt="App icon" src="https://github.com/user-attachments/assets/89f11698-3c9d-4e5a-9290-c8fd4b7fbe3f" />
</p>

<p align="center">
  <img width="969" height="763" alt="image" src="https://github.com/user-attachments/assets/f6a6a58c-4c92-4ec4-888c-fb8e3abbf1d3" />
</p>

<p align="center">
  <img width="796" height="653" alt="image" src="https://github.com/user-attachments/assets/de15c20f-8f19-49a3-b3ad-b6bab293c2ea" />
</p>

<p align="center">
  <img width="1512" height="982" alt="image" src="https://github.com/user-attachments/assets/6bda1035-034b-4afc-9953-97dc94123c21" />
</p>

## PIN

Turn on **Require a PIN for changes** in Settings › General to lock Settings behind a 4–8 digit PIN. Unlocking covers every tab until you lock it again, close Settings, or a block starts. Quitting, exiting a block early, and resuming a block in place of a snoozed one also need the PIN. Snoozing a block still works without it, where the schedule allows it.

It's a speed bump for self-control, not security: Force Quit or `kill` still stop the app, and the PIN's record can be deleted.

If you forget your PIN, this removes it and leaves your schedules and stats alone:

```
killall ScreenBlocker
defaults delete com.local.ScreenBlocker ScreenBlocker.pinCredential
open /Applications/ScreenBlocker.app
```
