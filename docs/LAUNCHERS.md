# Windows launchers

Madeira can run the Windows versions of Ubisoft Connect, Epic Games Launcher
and Rockstar Games Launcher in the Wine desktop. The launchers are not shipped
in the app. In **Settings › PC game launchers**, Madeira downloads the current
installer from the vendor's HTTPS endpoint, puts it in
`wine/drive_c/madeira-downloads`, and adds it to the library. Run that entry
once, then use **Add to library** for the installed launcher.

## Ubisoft Connect and older Assassin's Creed games

Ubisoft renamed Uplay to Ubisoft Connect. Older Assassin's Creed releases can
still look for `Uplay.exe` and for the 32-bit Ubisoft registry view. Adding
Ubisoft Connect performs both repairs before each launcher start:

* creates `Uplay.exe` and `UbisoftGameLauncher.exe` compatibility aliases when
  the installed client does not provide them;
* updates the Ubisoft launcher install path in both Wine registry views;
* registers the `uplay://` and `ubisoft-connect://` protocol handlers in the
  user classes hive; and
* starts the client in a Wine desktop with Windows services running.

The same Ubisoft repair also runs before Steam/Dock games start when Connect is
installed. This covers Assassin's Creed titles that start their Ubisoft
entitlement check from Steam or Epic rather than from the Ubisoft library card.
If an alias is a stale symbolic link left by a launcher update, Madeira replaces
that link; a real file with the same name is preserved.

The repair is idempotent and keeps `.madeira-bak` copies of registry files
before changing them. Games still need to be owned by the Ubisoft account that
signs in to Connect. A game purchased from Steam or Epic may also require its
own platform client and entitlement.

## Epic and Rockstar sign-in

Both launchers are added with the same desktop and service-manager profile.
Their login pages run inside the launcher's own Windows web client; Madeira
does not collect or proxy credentials. Keep the launcher's executable in
`Program Files` (or add it from the library if it was installed elsewhere).

## .NET

* **.NET Framework** programs use Wine Mono, which is downloaded from WineHQ
  through the existing **Settings › .NET Framework** page.
* Modern WPF/WinForms programs use **Settings › .NET Desktop Runtime**. The
  page reads Microsoft's release metadata, downloads the selected x64 or x86
  Windows Desktop Runtime installer, verifies the published SHA-512 when
  available, and adds the installer to the library. Run the installer in the
  Wine desktop and restart Madeira before starting the application that needs
  it. x86 requires the optional i386 Wine build.

Neither runtime is silently installed into a running prefix: Wine keeps its
registry in memory for a session, so the installer must finish while the
desktop session is open and Madeira must be restarted afterward.
