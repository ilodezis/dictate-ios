# Dictate for iOS

Push-to-talk dictation for iPhone. A keyboard with one large microphone button types what you say into any text field. The microphone belongs to the app: a session keeps it running in the background, and the keyboard asks the app to record and receives the text back. An Action Button shortcut works without the keyboard: press to record, press again to stop, and the text goes to the clipboard. Recordings are sent to a server you run, which transcribes them with a speech model and accepts a dictionary of terms as spelling hints. A recording that fails to send is kept as audio and can be sent again.

## How the pieces fit

- **App** (`App/`) holds the microphone session. While a session is on, a Live Activity shows it. The app sends recordings to the server and keeps history and the dictionary.
- **Keyboard** (`Keyboard/`) has no microphone access. It posts requests through Darwin notifications and reads the state and the text from the shared App Group defaults. If no session is running, it opens the app once to start one.
- **Shared** (`Shared/`) holds the bridge between the app and the keyboard, and the `L()` helper for localized strings.
- **Action Button** (`App/DictateApp.swift`) is an `AudioRecordingIntent` that toggles recording and copies the result.
- **Widgets** (`Widgets/`) draw the Live Activity.

The build also uses the audio and chunking code and the app icon from the macOS client, which this repository includes.

## Build

You need macOS with Xcode 26 and XcodeGen:

```sh
brew install xcodegen
bash ios/ci-build.sh
```

The script generates the Xcode project, builds the app without code signing, and writes `ios/build/Dictate.ipa`. The bundle ID and App Group default to the values in `ci-build.sh` and can be overridden with the `DICTATE_BUNDLE_ID` and `DICTATE_APP_GROUP` variables.

The CI workflow runs the same script on every push to `main` and uploads `Dictate.ipa` to the release tagged `latest`.

## Install

The `.ipa` is unsigned. Re-sign it on the device with your own certificate and provisioning profile before installing. The bundle ID and App Group must match what that profile allows. The app and the keyboard must share the same App Group.

## Setup in the app

1. Open Settings, enter the HTTPS address of your server, and save the token.
2. Choose how long the session keeps the microphone without dictation.
3. Add the keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → Dictate. Turn on Allow Full Access, which the keyboard needs to reach the app.
4. Optional: assign the Dictate shortcut to the Action Button.

The server is not part of this repository. It must accept `POST /v1/dictate` with the audio as multipart form data and answer `{"text": "..."}`, and serve `/v1/vocabulary` for the dictionary. Both use a bearer token.
