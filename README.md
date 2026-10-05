# 🧠 Neo Ear-EEG Mobile App & Stage Presentation Suite

This suite is built for your **Competition Demo Day**. It provides:
1. **Instant Mobile Web Companion:** Runs right now on your Mac using standard Python (zero dependencies). You can open it on your Android or iPhone immediately to rehearse and record your screen for PowerPoint.
2. **Native Android Flutter Codebase:** Ready to build into an installable `.apk` directly in the cloud using GitHub Actions (no need to install 20 GB of developer tools on your Mac).
3. **High-Visibility Stage Mode:** Designed with glowing cyan and violet waveforms, large fonts, and bold status badges so it can be seen by judges from a distance.
4. **Interactive Seizure Trigger:** Tap **`[⚡ TRIGGER SEIZURE DEMO]`** to inject high-amplitude epileptic spikes live on stage and demonstrate the clinical seizure detection capability to investors.

---

## 🚀 Quick Start 1: Run the App on Your Phone Right Now (2 Minutes)

You do **not** need the hardware or developer tools to test the mobile app on your phone today.

### Step 1: Start the Companion Server on Your Mac
Open Terminal on your Mac and run:
```bash
python3 /Users/tzekhai/.gemini/antigravity/scratch/neo_mobile_app/stage_companion/server.py
```

### Step 2: Open It on Your Phone
The terminal will display your Mac's local IP address, for example:
```
[*] Open on your Phone: http://192.168.1.50:8080
```
1. Make sure your phone and Mac are on the same Wi-Fi (or your phone's personal hotspot).
2. Open that link in **Chrome** (Android) or **Safari** (iPhone).
3. *(Optional Pro-Tip)*: Tap your browser menu and choose **"Add to Home Screen"**. The app will now launch full-screen with no browser address bar, looking 100% like a native app!

---

## ⚡ Quick Start 2: Rehearse Against `neo-fake` (Hardware Simulator)

In a separate terminal window on your Mac, run the mock hardware simulator from the Neuravance repository:
```bash
neo-fake --auto
```
The server will automatically discover `neo-fake` on UDP port 5000, send `START`, and stream live simulated ear-EEG straight into your phone! You can type `blink`, `clench`, `alpha`, or `button` into the `neo-fake` terminal to inject real-time artifacts.

---

## 📱 Quick Start 3: Build the Standalone Native Android APK

If you want a native `.apk` file to install directly onto an Android phone:

1. Push this folder to your GitHub account:
   ```bash
   cd /Users/tzekhai/.gemini/antigravity/scratch/neo_mobile_app
   git init
   git add .
   git commit -m "feat: Neo mobile companion app"
   git remote add origin https://github.com/<your-username>/neo-mobile-app.git
   git push -u origin main
   ```
2. In your GitHub repository, click the **"Actions"** tab.
3. The **"Build Android APK"** workflow will automatically run and compile the APK in the cloud.
4. Once complete (~3 minutes), download **`neo-companion-android-apk`** from the Actions summary page, send it to your Android phone, and tap **Install**!

---

## 🎯 Demo Day Pitch Playbook

When presenting to judges and investors:

1. **Holding the Phone Live on Stage:**
   * The app is set to **50 µV / div** with thick neon-cyan (Channel 1) and violet (Channel 2) traces.
   * Point out the **`● 250 SPS • LIVE`** indicator and the **`100% CONTACT • GOOD`** electrode impedance badge.
2. **The "Seizure Detection" Moment:**
   * Explain: *"Our device continuously monitors brainwaves for early seizure onset..."*
   * Tap **`[⚡ TRIGGER SEIZURE DEMO]`** on your phone.
   * Watch the screen:
     * The trace instantly erupts into classic 3 Hz spike-and-wave discharges.
     * The banner flashes crimson: **`⚠️ SEIZURE DETECTED (94%)`**.
     * A real-time duration timer counts the episode length.
   * Tap **`[📄 REPORT]`** to display the clinical summary report (aligned with the European SeizeIT2 clinical ear-EEG trial).
3. **PowerPoint Video Recording:**
   * Use your phone's built-in Screen Recorder to record a 15-second clip of you tapping the seizure button and the alert firing.
   * Embed this high-resolution video directly into your presentation slide as a backup!
