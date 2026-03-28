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

// ── Python helper: format current exception to NSString ──────────────────────
// Call only when PyErr_Occurred() != NULL.  Clears the exception.
static NSString *format_python_exception(void) {
    PyObject *type, *value, *tb;
    PyErr_Fetch(&type, &value, &tb);
    if (!type) return @"(no exception info)";
    PyErr_NormalizeException(&type, &value, &tb);

    NSString *result = nil;

    PyObject *io_mod = PyImport_ImportModule("io");
    PyObject *tb_mod = PyImport_ImportModule("traceback");
    if (io_mod && tb_mod) {
        PyObject *sio = PyObject_CallMethod(io_mod, "StringIO", NULL);
        if (sio) {
            PyObject *print_exc = PyObject_GetAttrString(tb_mod, "print_exception");
            if (print_exc) {
                PyObject *args   = Py_BuildValue("(OOO)", type, value, tb ? tb : Py_None);
                PyObject *kwargs = PyDict_New();
                PyDict_SetItemString(kwargs, "file", sio);
                PyObject *ret = PyObject_Call(print_exc, args, kwargs);
                Py_XDECREF(args);
                Py_XDECREF(kwargs);
                Py_XDECREF(ret);
                Py_DECREF(print_exc);
            }
            PyObject *getvalue = PyObject_GetAttrString(sio, "getvalue");
            if (getvalue) {
                PyObject *s = PyObject_CallObject(getvalue, NULL);
                if (s) {
                    const char *cstr = PyUnicode_AsUTF8(s);
                    if (cstr) result = [NSString stringWithUTF8String:cstr];
                    Py_DECREF(s);
                }
                Py_DECREF(getvalue);
            }
            Py_DECREF(sio);
        }
    }
    Py_XDECREF(tb_mod);
    Py_XDECREF(io_mod);

    if (!result) {
        // Fallback: repr(value)
        PyObject *repr = PyObject_Repr(value);
        if (repr) {
            const char *cstr = PyUnicode_AsUTF8(repr);
            if (cstr) result = [NSString stringWithUTF8String:cstr];
            Py_DECREF(repr);
        }
    }

    Py_XDECREF(tb);
    Py_XDECREF(value);
    Py_XDECREF(type);
    PyErr_Clear();
    return result ?: @"(could not format exception)";
}

// ── Python helper: run a string of Python code, log + crash on error ─────────
// Uses Py_CompileString + PyEval_EvalCode instead of PyRun_SimpleString so that
// we capture the exception *before* it is cleared by an internal PyErr_Print().
static void run_python(const char *code, const char *label) {
    // Get __main__ module globals
    PyObject *main_mod  = PyImport_AddModule("__main__");  // borrowed
    PyObject *globals   = main_mod ? PyModule_GetDict(main_mod) : NULL;  // borrowed

    PyObject *compiled  = Py_CompileString(code, label, Py_file_input);
    if (!compiled) {
        NSString *details = format_python_exception();
        crash_dialog([NSString stringWithFormat:@"Python compile error in %s:\n\n%@", label, details]);
        exit(-1);
    }

    PyObject *result = PyEval_EvalCode(compiled, globals, globals);
    Py_DECREF(compiled);

    if (!result) {
        // Exception is still set — capture it before anything else clears it.
        NSString *details = format_python_exception();
        crash_dialog([NSString stringWithFormat:@"Python error in %s:\n\n%@", label, details]);
        exit(-1);
    }
    Py_DECREF(result);
}
// ─────────────────────────────────────────────────────────────────────────────


@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // ── Create an initial UIWindow so iOS has a key window during launch ──
    // Qt's showMaximized() creates its own QUIWindow and calls makeKeyAndVisible,
    // replacing this as the active window.  Without any window here, keyWindow
    // is nil and Qt's QUIWindow may not become visible on iOS 16+.
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    UIViewController *rootVC = [[UIViewController alloc] init];
    self.window.rootViewController = rootVC;
    [self.window makeKeyAndVisible];

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
