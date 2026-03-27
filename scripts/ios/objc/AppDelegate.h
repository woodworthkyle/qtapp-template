//
//  AppDelegate.h
//  Python + Qt iOS bootstrap — no Toga, no Rubicon.
//
//  Responsibilities:
//    1. applicationDidFinishLaunching: imports and runs the Python app module
//       (reads MainModule from Info.plist, falls back to "qtapp").
//    2. application:openURL:options: dispatches URL scheme events to Python.
//    3. application:handleOpenURL: legacy URL handler (iOS < 9).
//
//  QApplication is created inside the Python module (main()), which runs here,
//  inside applicationDidFinishLaunching:, AFTER UIApplicationMain is running.
//  This is required by Qt's iOS platform plugin for correct CFRunLoop integration.
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

@end
