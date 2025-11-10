# FindMySyncPlus

---

### Overview

**FindMyPlus** is designed to publish FindMy data to Home Assistant.  It's based on [FindMySync](https://github.com/MartinPham/FindMySync), but it works on new MacOS versions.  Starting from macOS 14.4, Apple has encrypted the FindMy data files, mostly breaking that project. [Pnut-GGG](https://github.com/Pnut-GGG) has reverse engineered the crypto and published his python project here: [findmy-cache-decryptor](https://github.com/Pnut-GGG/findmy-cache-decryptor). I've incorporated their ideas into this Swift project.  FindMySync+ requires Pnut-GGG's [FMIPDataManager-extractor]( https://github.com/Pnut-GGG/FMIPDataManager-extractor) to export the protected encryption keys in keychain.
                                                                                            
### Features

- Dock and menu bar functionality
- Device manager to abstract aliases from physical devices allowing for changing UUIDs, tracking on specifical devices, naming of devices in Home Assistant
- Support for both Devices and Items types
- Configurable automatic launching of FindMy to refresh cache data (no need for AppleScript)
- Secure storage of encryption keys and other sensitive data in keychain                         
- So much more... (I need better documentation!)
                                                                                              
### Notice

I am not a Swift programmer. I forked findmy-cache-decryptor and recreated FindMySync in python and then used AI to help me code this over a 6 week period. I am sure there are better ways to implement this code. That said, I have been running it for a while now and it works well.  Please let me know if you find any bugs or if there is a better way to do this.
