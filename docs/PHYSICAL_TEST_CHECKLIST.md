# Physical test checklist — TECNO Spark 30C (KL5), Android 14 / HiOS 14.5

None of these have been run yet. They require the real phone, the ESP8266 and
the coin slot. **Do not call the kiosk production-ready until every row passes.**
Record date, result and notes for each.

Setup before testing: phone provisioned as Device Owner, production mode on,
controller paired, at least two approved apps (e.g. YouTube, a game) and at
least one installed but **unapproved** app (e.g. Chrome), loss timeout 30 s.

## A. Navigation containment
| # | Test | Expected | Result |
|---|---|---|---|
| A1 | Unpaid: press Home, Back, Recents; swipe gestures (HiOS gesture nav **and** 3-button nav) | Stays on payment screen; Recents does nothing | |
| A2 | Unpaid: pull down status bar / quick settings | Nothing opens | |
| A3 | Unpaid: long-press Power | No power menu (restart only by hardware hold) | |
| A4 | Paid: open approved app A, press Home | Returns to the kiosk launcher with timer | |
| A5 | Paid: switch A → B via Recents and via launcher | Works; only approved apps listed | |
| A6 | Paid: try to open the unapproved app (share sheet, link, app's "open in…" buttons) | Blocked / nothing happens | |
| A7 | Paid: from an approved app try to reach Settings (e.g. app info, permission link) | Blocked | |
| A8 | Paid: Back out of an approved app completely | Returns to kiosk | |
| A9 | Try HiOS-specific gestures (smart panel, side bar, three-finger screenshot, game mode overlay) | Nothing escapes the kiosk | |

## B. Time and expiry
| # | Test | Expected | Result |
|---|---|---|---|
| B1 | Insert 1-peso (1 pulse) coin | +4:00, LCD and phone agree within ~2 s | |
| B2 | Insert 5, 10, 20-pulse coins | +20, +40, +80 min | |
| B3 | Insert coin during a session | Time extends; "+N min added" | |
| B4 | **Expiry while an approved app is in front** | App closes within ~1–2 s, payment screen shows "Time expired" | |
| B5 | Expiry while screen is off | On wake: payment screen; app not resumable | |
| B6 | Rapid coin insertion (two coins quickly) | Counted correctly, no duplicates | |

## C. Network
| # | Test | Expected | Result |
|---|---|---|---|
| C1 | Unplug the router's internet (Wi-Fi stays up) | "Cloud: offline", access continues, coins work | |
| C2 | Restore internet | Dashboard receives buffered events once | |
| C3 | Turn off the Wi-Fi router while paid | After 30 s: "disconnected", app closed, payment screen | |
| C4 | Restore Wi-Fi within the remaining time | Access returns with the controller's current time | |
| C5 | Power off only the ESP8266 while paid | Same as C3 | |

## D. Restarts
| # | Test | Expected | Result |
|---|---|---|---|
| D1 | Reboot the phone while unpaid | Boots straight into the kiosk, locked | |
| D2 | Reboot the phone while paid | Boots into kiosk; access restored only after a fresh controller report; no stale time | |
| D3 | Restart the ESP8266 while paid (`RESUME_AFTER_RESTART=1`) | Time resumes from checkpoint (≤60 s difference); phone follows the new boot id | |
| D4 | Power-cycle both together | Safe state, then correct time | |
| D5 | Force-stop the app via adb (`adb shell am force-stop online.ebnleadgen.vendokiosk`) while paid | Customer app closed within ~1 min (watchdog) and kiosk returns | |
| D6 | Leave running 24 h; check HiOS does not kill the service | Still enforcing; dashboard shows phone online | |

## E. Administrator
| # | Test | Expected | Result |
|---|---|---|---|
| E1 | Tap the timer 7 times within 4 s → PIN | Admin settings open; 6 taps or slow taps do nothing | |
| E2 | Wrong PIN ×4 | Lockout message; persists after app restart and reboot | |
| E3 | Recovery code → new PIN | Works once; new code issued | |
| E4 | Exit kiosk | Normal phone; Settings reachable | |
| E5 | Re-enable production | Locked again | |
| E6 | `adb shell am task lock stop` (recovery path) | Leaves lock task | |
| E6b | ADB recovery broadcast (docs/RECOVERY.md) | Kiosk released, setup asks for a new PIN; pairing kept | |
| E6c | Same broadcast sent from another app (no adb) | Rejected (permission denial in logcat) | |
| E7 | Remove Device Owner (on a test phone) | Restrictions removed; app uninstallable | |

## F. Demo mode (personal phone, not Device Owner)
| # | Test | Expected | Result |
|---|---|---|---|
| F1 | Install APK, choose Demo | Demo banner visible on every customer screen | |
| F2 | Simulated coins 1/5/10/20 | Countdown 4/20/40/80 min | |
| F3 | Launch an approved app; let time expire | Notification "time expired"; (other apps are not blocked — expected) | |
| F4 | Choose Production on a non-Device-Owner phone | Refused with provisioning instructions | |
