// Ends a test process whose runner is gone.
//
// SwiftPM starts xctest in a process group of its own, so cancelling a `swift test` never signals
// it. A hung test then outlives the run with its windows on screen, and nothing ever ends it. This
// constructor watches the process that started the test bundle and exits as soon as it exits.
//
// The process that starts the bundle must outlive the tests. `swift test` and xcodebuild both
// do. When it exits first, the tests stop at once: the guard writes one line to stderr and ends
// the process with `_exit(1)`, so no later test runs and nothing is cleaned up.
//
// It is linked into the package's one test bundle, so it guards every test target.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/event.h>
#include <unistd.h>

static void end_test_process(void) {
  static const char message[] =
      "the test runner that started this process is gone, so the tests stop here\n";

  write(STDERR_FILENO, message, sizeof message - 1);
  _exit(1);
}

static void *watch_runner(void *argument) {
  pid_t runner = (pid_t)(intptr_t)argument;
  int queue = kqueue();

  if (queue < 0) return NULL;

  struct kevent change;
  struct kevent event;

  EV_SET(&change, runner, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);

  for (;;) {
    int count = kevent(queue, &change, 1, &event, 1, NULL);

    if (count < 0 && errno == EINTR) continue;

    // A runner that exited before the watch began is reported as an error on the event.
    if (count < 0) {
      if (errno == ESRCH) end_test_process();

      return NULL;
    }

    if (count == 1 && (event.flags & EV_ERROR) != 0 && event.data != ESRCH) return NULL;

    end_test_process();
  }
}

__attribute__((constructor)) static void start_test_process_guard(void) {
  pid_t runner = getppid();

  // A process launchd started directly has no runner to outlive.
  if (runner <= 1) return;

  pthread_t thread;

  if (pthread_create(&thread, NULL, watch_runner, (void *)(intptr_t)runner) == 0) {
    pthread_detach(thread);
  }
}
