# Glowra Mobile for iOS

Glowra Mobile is the native iOS companion app for the [Glowra Shop website](https://glowra-shop.netlify.app/). It uses the same Supabase backend and customer accounts as the website.

## Features

- Google sign-in through the shared Supabase authentication project
- Home, shop, cart, and account screens
- Cart synchronisation between the website and mobile app
- Supabase Realtime updates with foreground refresh as a fallback
- Light colour scheme for consistent readability

## Requirements

- macOS with Xcode
- An iPhone running a supported iOS version
- An Apple ID configured under Xcode's Signing & Capabilities settings

## Running the app

1. Open `Glowra.xcodeproj` in Xcode.
2. Select the `Glowra` target.
3. Under **Signing & Capabilities**, choose your Apple development team.
4. Select an iPhone or iPhone Simulator.
5. Press **Run**.

The application is written in Swift and SwiftUI. This repository contains the iOS source code; Android APK files cannot be produced from an Xcode project.
