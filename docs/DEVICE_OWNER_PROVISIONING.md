# Device Owner provisioning (TECNO Spark 30C, Android 14 / HiOS 14.5)

Production kiosk mode only works when Vendo Kiosk is the phone's **Device
Owner**. The app **never** resets the phone or changes ownership on its own.

## ⚠ Read first: data loss

* Android only accepts a new Device Owner when the phone has **no accounts**
  (Google, TECNO/Transsion/Carlcare, Facebook, etc.) and **no extra users**.
* In practice that means a **factory reset, which erases everything** on the
  phone. Back up anything you need first.
* Removing accounts without a reset sometimes works, but HiOS system apps can
  re-add hidden accounts; if `dpm set-device-owner` complains about accounts,
  do a factory reset.
* After provisioning, Google Factory Reset Protection (FRP) does not apply
  because no Google account was added. Keep the phone physically secure.
* The Device Owner app is bound to its **signing key**. Install the same signed
  APK you will update later; changing the key requires re-provisioning.

## Steps (ADB method)

1. Factory reset: *Settings → System → Reset options → Erase all data*.
2. During setup: connect to Wi-Fi, **skip** Google sign-in and any TECNO
   account, and **do not set a screen lock** (PIN/pattern). A screen lock
   prevents unattended start after reboot.
3. Enable Developer options: *Settings → About phone →* tap *Build number* 7×.
   Enable *USB debugging*. On HiOS also enable *Install via USB* if shown.
4. On the computer (Android SDK platform-tools):
   ```
   adb devices
   adb install -r dist/vendo-kiosk-1.0.0-debug.apk
   adb shell dpm set-device-owner online.ebnleadgen.vendokiosk/.kiosk.KioskDeviceAdminReceiver
   ```
   Expected: `Success: Device owner set to package online.ebnleadgen.vendokiosk`.
   Typical errors:
   * `Not allowed to set the device owner because there are already some accounts`
     → remove accounts / factory reset.
   * `... already several users` → remove extra users (and HiOS "App twin" /
     "Dual app" profiles) or reset.
5. Open Vendo Kiosk → create the admin PIN, write down the recovery code →
   *Production kiosk mode*. The app verifies Device Owner itself; if it is not
   Device Owner it refuses and shows these instructions (no silent demo).
6. Verify: Admin → Kiosk mode should show *Device Owner: yes*, *Lock task:
   locked*, and no policy problems. Then follow `PHYSICAL_TEST_CHECKLIST.md`.

## Verify from the computer

```
adb shell dumpsys device_policy | findstr /i "owner lock"        (Windows)
adb shell dumpsys device_policy | grep -i -E "owner|lock"         (macOS/Linux)
adb shell dumpsys activity activities | findstr /i "mLockTaskModeState"
```

## Leaving production / removing Device Owner

* **Exit kiosk (keep Device Owner)**: Admin → Kiosk mode → *Exit kiosk*. Lock
  task, restrictions and the home override are removed; the app switches to
  demo mode. Re-enable production any time.
* **Remove Device Owner**: Admin → Kiosk mode → *Remove Device Owner*. Then the
  app can be uninstalled normally. Re-provisioning later needs the steps above.
* A debug/test build cannot be removed with `adb shell dpm remove-active-admin`
  unless it was built with `android:testOnly="true"`; use the in-app button.
  See `RECOVERY.md` if the PIN is lost.

## Alternative: QR-code provisioning

Possible for fleets (tap the welcome screen 6×, scan a QR with the APK URL and
signature checksum). It also requires a factory-reset phone. It needs the APK
hosted over HTTPS and a release signing key; not set up in this project yet.
