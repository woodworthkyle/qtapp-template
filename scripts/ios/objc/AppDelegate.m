//
//  AppDelegate.m
//  Python + Qt iOS bootstrap — no Toga, no Rubicon.
//
//  applicationDidFinishLaunching: runs the Python app module so that
//  QApplication is created after UIApplicationMain is running, as required by
//  Qt's iOS platform plugin (QIOSIntegration) for CFRunLoop integration.
//
//  MainModule in Info.plist selects which Python module to run (default: qtapp).
//  The module's main() is called via runpy._run_module_as_main, which resolves
//  to qtapp/__main__.py → app.main() → _Bootstrap.main_loop() (no-op on iOS;
//  Qt is already integrated with CFRunLoop by QIOSIntegration at this point).
//

#import "AppDelegate.h"
#import <UIKit/UIKit.h>
#include <Python/Python.h>

void crash_dialog(NSString *);

// ── Python helper: run a string of Python code, log + crash on error ─────────
static void run_python(const char *code, const char *label) {
    if (PyRun_SimpleString(code) != 0) {
        PyObject *exc = PyErr_Occurred();
        NSString *details = @"(no exception info)";
        if (exc) {
            PyObject *type, *value, *tb;
            PyErr_Fetch(&type, &value, &tb);
            PyErr_NormalizeException(&type, &value, &tb);

            // Format with traceback if available
            PyObject *io_mod    = PyImport_ImportModule("io");
            PyObject *tb_mod    = PyImport_ImportModule("traceback");
            PyObject *sio       = NULL;
            PyObject *print_exc = NULL;
            PyObject *result    = NULL;
            NSString *formatted = nil;

            if (io_mod && tb_mod) {
                sio = PyObject_CallMethod(io_mod, "StringIO", NULL);
                if (sio) {
                    print_exc = PyObject_GetAttrString(tb_mod, "print_exception");
                    if (print_exc) {
                        PyObject *args = Py_BuildValue("(OOO)", type, value, tb ? tb : Py_None);
                        PyObject *kwargs = PyDict_New();
                        PyDict_SetItemString(kwargs, "file", sio);
                        result = PyObject_Call(print_exc, args, kwargs);
                        Py_XDECREF(args);
                        Py_XDECREF(kwargs);
                    }
                    if (result) {
                        PyObject *getvalue = PyObject_GetAttrString(sio, "getvalue");
                        if (getvalue) {
                            PyObject *s = PyObject_CallObject(getvalue, NULL);
                            if (s) {
                                const char *cstr = PyUnicode_AsUTF8(s);
                                if (cstr) formatted = [NSString stringWithUTF8String:cstr];
                                Py_DECREF(s);
                            }
                            Py_DECREF(getvalue);
                        }
                    }
                }
            }
            if (formatted) {
                details = formatted;
            } else {
                // Fallback: repr(value)
                PyObject *repr = PyObject_Repr(value);
                if (repr) {
                    const char *cstr = PyUnicode_AsUTF8(repr);
                    if (cstr) details = [NSString stringWithUTF8String:cstr];
                    Py_DECREF(repr);
                }
            }
            Py_XDECREF(result);
            Py_XDECREF(print_exc);
            Py_XDECREF(sio);
            Py_XDECREF(tb_mod);
            Py_XDECREF(io_mod);
            Py_XDECREF(tb);
            Py_XDECREF(value);
            Py_XDECREF(type);
            PyErr_Clear();
        }
        crash_dialog([NSString stringWithFormat:@"Python error in %s:\n\n%@", label, details]);
        exit(-1);
    }
}
// ─────────────────────────────────────────────────────────────────────────────


@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // ── Determine which Python module to run ──────────────────────────────
    NSDictionary *info    = [[NSBundle mainBundle] infoDictionary];
    NSString     *module  = info[@"MainModule"];
    if (!module || module.length == 0) {
        module = @"qtapp";
    }
    NSLog(@"AppDelegate: launching Python module '%@'", module);

    // ── Run the Python module via runpy._run_module_as_main ───────────────
    // This resolves to <module>/__main__.py.
    // On iOS, app.main() creates QApplication and then _Bootstrap.main_loop()
    // returns immediately (Qt integrates with CFRunLoop via QIOSIntegration;
    // calling QApplication.exec() here would block and trigger the watchdog).
    NSString *pycode = [NSString stringWithFormat:
        @"import runpy as _rp\n"
         "_rp._run_module_as_main('%@', False)\n",
        module];

    NSLog(@"AppDelegate: running runpy._run_module_as_main('%@', False)...", module);
    run_python([pycode UTF8String], "applicationDidFinishLaunching");
    NSLog(@"AppDelegate: Python module returned — CFRunLoop takes over.");

    return YES;
}

// ── URL scheme handler (iOS 9+) ───────────────────────────────────────────
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
    // Dispatch to Python via qtapp.platform.ios._handle_open_url().
    // Apps register handlers with ios.register_url_handler() during startup.
    NSLog(@"AppDelegate: openURL: %@", url.absoluteString);

    // Escape single-quotes in the URL before embedding in Python string literal.
    NSString *escaped = [url.absoluteString
        stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped
        stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];

    NSString *pycode = [NSString stringWithFormat:
        @"try:\n"
         "    from qtapp.platform import ios as _ios\n"
         "    _ios._handle_open_url('%@')\n"
         "except Exception as _e:\n"
         "    import sys; print('openURL handler error:', _e, file=sys.stderr)\n",
        escaped];

    PyRun_SimpleString([pycode UTF8String]);
    return YES;
}

@end
