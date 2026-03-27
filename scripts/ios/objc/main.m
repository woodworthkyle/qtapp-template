//
//  main.m
//  Python + Qt iOS bootstrap — no Toga, no Rubicon.
//
//  Responsibilities:
//    1. Install crash signal handlers.
//    2. Initialize the isolated Python interpreter (PYTHONHOME, PYTHONPATH,
//       app_packages, optional NSLog handler).
//    3. Hand off to UIApplicationMain with AppDelegate.
//
//  Python module execution happens in AppDelegate.applicationDidFinishLaunching:
//  so that QApplication is created after UIApplicationMain is running (required
//  by Qt's iOS platform plugin for CFRunLoop integration).
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <Python/Python.h>
#include <dlfcn.h>
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>

void crash_dialog(NSString *);

// ── Crash signal handler ──────────────────────────────────────────────────────
static void signal_crash_handler(int sig, siginfo_t *info, void *ctx) {
    const char *hdr = "\n========== CRASH SIGNAL HANDLER ==========\n";
    write(STDERR_FILENO, hdr, strlen(hdr));
    const char *signame = "UNKNOWN";
    switch (sig) {
        case SIGABRT: signame = "SIGABRT (abort)";             break;
        case SIGSEGV: signame = "SIGSEGV (segfault)";          break;
        case SIGBUS:  signame = "SIGBUS (bus error)";          break;
        case SIGILL:  signame = "SIGILL (illegal instruction)"; break;
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "Signal: %s (%d)\n", signame, sig);
    write(STDERR_FILENO, buf, strlen(buf));
    void *frames[64];
    int count = backtrace(frames, 64);
    const char *bt_hdr = "Backtrace:\n";
    write(STDERR_FILENO, bt_hdr, strlen(bt_hdr));
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    const char *ftr = "===========================================\n";
    write(STDERR_FILENO, ftr, strlen(ftr));
    fsync(STDERR_FILENO);
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

static void install_crash_handlers(void) {
    struct sigaction sa;
    sa.sa_sigaction = signal_crash_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
}
// ─────────────────────────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;
    wchar_t *wtmp_str;

    install_crash_handlers();

    @autoreleasepool {
        // iOS doesn't export LANG; set it so Python's locale detection works.
        setenv("LANG",
               [[NSString stringWithFormat:@"%@.UTF-8",
                 NSLocale.currentLocale.localeIdentifier] UTF8String],
               1);

        NSString *resourcePath = [[NSBundle mainBundle] resourcePath];

        // ── Isolated Python configuration ─────────────────────────────────
        NSLog(@"Configuring isolated Python...");
        PyPreConfig_InitIsolatedConfig(&preconfig);
        PyConfig_InitIsolatedConfig(&config);

        preconfig.utf8_mode        = 1;   // enforce UTF-8 everywhere
        preconfig.configure_locale = 1;   // set locale (isolated mode won't by default)
        config.buffered_stdio      = 0;   // unbuffered — output appears immediately
        config.write_bytecode      = 0;   // can't write to signed bundle
        config.module_search_paths_set = 1;

        NSLog(@"Pre-initializing Python runtime...");
        status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:
                @"Unable to pre-initialize Python: %s", status.err_msg]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        // ── PYTHONHOME ────────────────────────────────────────────────────
        NSString *python_tag  = @"3.12";
        NSString *python_home = [NSString stringWithFormat:@"%@/python", resourcePath];
        NSLog(@"PythonHome: %@", python_home);
        wtmp_str = Py_DecodeLocale([python_home UTF8String], NULL);
        status = PyConfig_SetString(&config, &config.home, wtmp_str);
        PyMem_RawFree(wtmp_str);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:
                @"Unable to set PYTHONHOME: %s", status.err_msg]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        // ── PyConfig_Read (parses PYTHONPATH etc. from environment) ───────
        status = PyConfig_Read(&config);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:
                @"Unable to read site config: %s", status.err_msg]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        // ── PYTHONPATH ────────────────────────────────────────────────────
        NSLog(@"PYTHONPATH:");
        NSArray<NSString *> *paths = @[
            // Unpacked stdlib
            [NSString stringWithFormat:@"%@/lib/python%@", python_home, python_tag],
            // Binary extension modules
            [NSString stringWithFormat:@"%@/lib/python%@/lib-dynload", python_home, python_tag],
            // App source
            [NSString stringWithFormat:@"%@/app", resourcePath],
        ];
        for (NSString *path in paths) {
            NSLog(@"- %@", path);
            wtmp_str = Py_DecodeLocale([path UTF8String], NULL);
            status = PyWideStringList_Append(&config.module_search_paths, wtmp_str);
            PyMem_RawFree(wtmp_str);
            if (PyStatus_Exception(status)) {
                crash_dialog([NSString stringWithFormat:
                    @"Unable to set PYTHONPATH entry '%@': %s", path, status.err_msg]);
                PyConfig_Clear(&config);
                Py_ExitStatusException(status);
            }
        }

        // ── argv ──────────────────────────────────────────────────────────
        NSLog(@"Configure argc/argv...");
        status = PyConfig_SetBytesArgv(&config, argc, argv);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:
                @"Unable to configure argc/argv: %s", status.err_msg]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        // ── Initialize interpreter ────────────────────────────────────────
        NSLog(@"Initializing Python runtime...");
        status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:
                @"Unable to initialize Python interpreter: %s", status.err_msg]);
            Py_ExitStatusException(status);
        }

        @try {
            // ── Optional NSLog handler (std-nslog package) ────────────────
            const char *nslog_script = [
                [[NSBundle mainBundle] pathForResource:@"app_packages/nslog"
                                                ofType:@"py"]
                cStringUsingEncoding:NSUTF8StringEncoding];
            if (nslog_script == NULL) {
                NSLog(@"No Python NSLog handler found (add std-nslog to dependencies).");
            } else {
                NSLog(@"Installing Python NSLog handler...");
                FILE *fd = fopen(nslog_script, "r");
                if (fd == NULL) { crash_dialog(@"Unable to open nslog.py"); exit(-1); }
                int r = PyRun_SimpleFileEx(fd, nslog_script, 1);
                fclose(fd);
                if (r != 0) { crash_dialog(@"Unable to install NSLog handler"); exit(r); }
            }

            // ── app_packages via site.addsitedir ──────────────────────────
            NSString *app_packages = [NSString stringWithFormat:@"%@/app_packages", resourcePath];
            NSLog(@"Adding app_packages as site directory: %@", app_packages);

            PyObject *site     = PyImport_ImportModule("site");
            PyObject *addsited = PyObject_GetAttrString(site, "addsitedir");
            wchar_t  *wpath    = Py_DecodeLocale([app_packages UTF8String], NULL);
            PyObject *py_path  = PyUnicode_FromWideChar(wpath, wcslen(wpath));
            PyMem_RawFree(wpath);
            PyObject *args     = Py_BuildValue("(O)", py_path);
            PyObject *res      = PyObject_CallObject(addsited, args);
            if (res == NULL) {
                crash_dialog(@"Could not add app_packages via site.addsitedir");
                exit(-15);
            }
            Py_XDECREF(res);
            Py_XDECREF(args);
            Py_XDECREF(py_path);
            Py_XDECREF(addsited);
            Py_XDECREF(site);
        }
        @catch (NSException *exception) {
            crash_dialog([NSString stringWithFormat:
                @"Python runtime setup error: %@", [exception reason]]);
            exit(-7);
        }

        NSLog(@"---------------------------------------------------------------------------");

        // ── Hand off to UIApplicationMain ─────────────────────────────────
        // AppDelegate.applicationDidFinishLaunching: will import and run the
        // Python app module.  QApplication is created there, after
        // UIApplicationMain is running, as required by Qt's iOS platform plugin.
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}

void crash_dialog(NSString *details) {
    NSLog(@"========================");
    NSLog(@"Application has crashed!");
    NSLog(@"========================");
    for (NSString *line in [details componentsSeparatedByString:@"\n"]) {
        NSLog(@"%@", line);
    }
}
