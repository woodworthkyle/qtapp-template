"""
Platform detection and capability flags.

Usage:
    from qtapp.platform import IS_IOS, IS_ANDROID, IS_DESKTOP
"""

import sys

IS_IOS     = sys.platform == "ios"
IS_ANDROID = sys.platform == "android" or hasattr(sys, "getandroidapilevel")
IS_MACOS   = sys.platform == "darwin"
IS_LINUX   = sys.platform == "linux"
IS_WINDOWS = sys.platform == "win32"
IS_DESKTOP = IS_MACOS or IS_LINUX or IS_WINDOWS
IS_MOBILE  = IS_IOS or IS_ANDROID
