<p align="center">
  <img width="256" height="256" alt="App icon" src="https://github.com/user-attachments/assets/89f11698-3c9d-4e5a-9290-c8fd4b7fbe3f" />
</p>

<p align="center">
  <img width="1512" height="982" alt="image" src="https://github.com/user-attachments/assets/fad68e26-beba-46b5-a31e-556ff8f209f2" />
</p>

<p align="center">
  <img width="902" height="793" alt="image" src="https://github.com/user-attachments/assets/e6b906e3-8e99-4bc8-acf3-12d23f9a09d6" />
</p>

<p align="center">
  <img width="902" height="793" alt="image" src="https://github.com/user-attachments/assets/d420b5ee-be7e-4469-9719-b55fd8ff36d0" />
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
