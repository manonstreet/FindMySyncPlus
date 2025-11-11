# FindMySyncPlus

---

### Overview

**FindMySyncPlus** is designed to publish FindMy data to Home Assistant.  It's based on [FindMySync](https://github.com/MartinPham/FindMySync), but it works on new MacOS versions.  Starting from macOS 14.4, Apple has encrypted the FindMy data files, mostly breaking that project. [Pnut-GGG](https://github.com/Pnut-GGG) has reverse engineered the crypto and published his python project here: [findmy-cache-decryptor](https://github.com/Pnut-GGG/findmy-cache-decryptor). I've incorporated their ideas into this Swift project.  FindMySync+ requires Pnut-GGG's [FMIPDataManager-extractor]( https://github.com/Pnut-GGG/FMIPDataManager-extractor) to export the protected encryption keys in keychain.
                                                                                            
### Features

- Dock and menu bar functionality
- Device manager to abstract aliases from physical devices allowing for changing UUIDs, tracking of specific devices, naming of entities in Home Assistant
- Support for both Devices and Items types
- Configurable automatic launching of FindMy to refresh cache data (no need for AppleScript)
- Secure storage of encryption keys and other sensitive data in keychain                         
- So much more... (I need better documentation!)
                                                                                              
### Getting Started - High Level

1. Use [FMIPDataManager-extractor]( https://github.com/Pnut-GGG/FMIPDataManager-extractor) to extract your FMIPDataManager encryption keys
    1. *Note:* This is a mandatory pre-requisite and I cannot provide technical support for this step.
2. Either clone this repository and compile the program using Xcode, or download the binary from the Releases section.
3. Place the binary in your Applications folder (optional) and run it.
4. Upon launch, you will see the Home screen with Not Set errors in the Configuration Summary section. Click on one to be taken to the Access pane.
5. Configure all access parameters on this page:
    1. Enter your Home Assistant device_see endpoint
    2. Enter your authorization header including the Bearer prefix
    3. Click Test Auth to verify
    4. Click Import Key and chose the FMIPDataManager plist (or binary plist) file exported from step 1. Make sure you do not chose FMFDataManager, which is also exported by the extractor tool
    5. Click Open Preferences to grant Full Disk Access
    6. Chose Quit & Reopen
    7. Relaunch FindMySync+
6. If prompted by Keychain, enter your credentials and click Always Allow
    1. If you compile the application yourself, in Xcode under Signing & Capabilities, chose Automatically manage signing and set your Team to your personal developer certificate. This will remove Keychain prompts.
    2. If you downloaded a pre-complied Release, you may need to permit the application to access the two keys it writes to keychain (decryption key & HA bearer token). You will only need to do this once per released version.
7. Under the General pane, chose your desired options. I would recommend:
    1. Enable Open at Login
    2. Disable Open Main Window on Startup so the app runs in the menu bar
    3. Enable Auto-start Scheduler
    4. Enable Auto-learn UUIDs
8. Click on the Status pane and set your log level to Debug (for now)
9. Click Run Now (play button) in the toolbar and examine the logs
    1. You should see all of your parsed Devices and Items
    2. If there are any errors, they will be displayed here
10. Click the Device Manager button in the toolbar
11. For each device / item you would like to track, click the Assign button
    1. Give the device an alias. The Home Assistant entity_id will be constructed by naming it findmy\__alias_
12. On the Home pane, enable the Scheduler. All tracked alias will now be posted to Home Assistant on the frequency set by the Update Interval in the Settings pane  

### Notice

I am not a Swift programmer. I forked findmy-cache-decryptor and recreated FindMySync in python and then used AI to help me code this over a 6 week period. I am sure there are better ways to implement this code. That said, I have been running it for a while now and it works well.  Please let me know if you find any bugs or if there is a better way to do this.

### Screenshots

![Home View](screenshots/home_view.png)

![Status View](screenshots/status_view.png)

![General Settings](screenshots/general_settings.png)

![Access Settings](screenshots/access_settings.png)

![About](screenshots/about_view.png)

![Device Manager](screenshots/device_manager.png)
