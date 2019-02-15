// -*-c++-*-
//-----------------------------------------------------------------------------
// Time-stamp: <2014-09-28 12:24:47 dky>
//-----------------------------------------------------------------------------
// File : threadUT.cpp
// Usage: [FIX=1] threadUT [kill SIGNAL]
//	  - Copy the BSD binary to filer and execute
// Desc : Creates a multi threaded process, calls pthread_exit or pthread_kill
//	  based on invocation
// Build:
//	$ source ~dhruva/.bash_funcs
//	$ bsdgcc g++ -ggdb threadUT.cpp -lpthread -o threadUT 
//-----------------------------------------------------------------------------
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/time.h>
#include <sys/types.h>

#include <pthread.h>

bool killMode = false;
volatile pthread_t pLockedThread = 0;

class MgwdNsStats
{
public:
    MgwdNsStats() {
	_mutexThrKey = 0;
#ifdef __linux__
	memset(&_mutex, 0, sizeof(_mutex));
#else
	_mutex = PTHREAD_MUTEX_INITIALIZER;
#endif
	// Instrumentation for burt:846571
	// Initialize the mutex at the earliest and place this away from potential
	// scribbling. This will help in confirming if memory is getting scribbled
	pthread_mutex_init(&_mutex, NULL);
	if (getenv("FIX")) {
	    pthread_key_create(&_mutexThrKey, MgwdNsStats::TLSMutexMonitor::releaseMutex);
	}
    }

    void run(size_t &iter) {
	TLSMutexMonitor m(_mutex, _mutexThrKey);
	pLockedThread = pthread_self();
	if (3 == iter) {
	    printf("thread exiting: %lu\n", pLockedThread);
	    pthread_exit(0);
	}

	if (killMode) {
	    for (size_t count = 5; count; --count) {
		sleep(1);
		printf("thread holding mutex: %lu\n", count);
	    }
	}

	return;
    }

    pthread_mutex_t &getMutex() {
	return _mutex;
    }

private:
    // TLSMutexMonitor
    //  Scoped mutex along with required information to clear a mutex when
    //  thread holding a mutex exits without unlocking it
    class TLSMutexMonitor {
    public:
	TLSMutexMonitor(pthread_mutex_t &mutex, pthread_key_t &key, bool acquireLock = true)
	    : _locked(false), _mutex(mutex), _key(key) {
	    if (acquireLock) {
		lock();
	    }
	}

	~TLSMutexMonitor() {
	    unlock();
	}

	void lock(void) {
	    if (false == _locked) {
		pthread_mutex_lock(&_mutex);
		_locked = true;
		// Set the mutex that needs to be cleaned up at thread exit
		pthread_setspecific(_key, this);
	    }
	}

	void unlock() {
	    if (_locked) {
		pthread_mutex_unlock(&_mutex);
		_locked = false;
		// Clear the entry to disable the mutex cleanup on thread exit
		pthread_setspecific(_key, NULL);
	    }
	}

	// Thread local storage entry cleanup routine
	// NOTE: We should ideally be never called. If this gets called,
	// there is a thread that is holding onto a mutex and dying!
	static void releaseMutex(void *ptr) {
	    printf("**Thread killed, cleaning up via callback: %lu\n", pthread_self());
	    TLSMutexMonitor *pMon = (TLSMutexMonitor *)ptr;
	    pthread_mutex_unlock(&(pMon->_mutex));
	    pthread_setspecific(pMon->_key, NULL);
	    abort();
	}

    private:
	bool			_locked;
	pthread_mutex_t		&_mutex;
	pthread_key_t		&_key;
    };

    pthread_mutex_t						_mutex;
    pthread_key_t						_mutexThrKey;
};

MgwdNsStats nsStats;

//-----------------------------------------------------------------------------
// thread entry function
//-----------------------------------------------------------------------------
void *
start_routine(void *args) {
    size_t loop = 0;
    while (true) {
	nsStats.run(++loop);
    }

    return args;
}

//-----------------------------------------------------------------------------
// main test driver
//-----------------------------------------------------------------------------
int
main(int argc, char *argv[]) {
    void *ret = NULL;
    pthread_t pth[2];

    if (argc > 1 && 0 == strncmp(argv[1], "kill", sizeof("kill") - 1)) {
	killMode = true;
    }

    // Create threads
    pthread_create(&pth[0], NULL, start_routine, NULL);
    printf("Creating thread: %lu\n", pth[0]);

    pthread_create(&pth[1], NULL, start_routine, NULL);
    printf("Creating thread: %lu\n", pth[1]);

    // Test how a pthread_kill() behaves
    if (killMode) {
#ifdef __linux__
	while(pthread_equal(pLockedThread, 0)) sleep(0);
#else
	while (NULL == pLockedThread) sleep(0);
#endif
	int sig = (argc > 2) ? atoi(argv[2]) : 0;
	printf("Killing thread: %lu with signal %d\n", pLockedThread, sig);
	pthread_kill(pLockedThread, sig);
    }

    pthread_join(pth[0], &ret);
    pthread_join(pth[1], &ret);

    pthread_mutex_lock(&nsStats.getMutex());
    printf("Main thread got the mutex: %lu\n", pthread_self());
    pthread_mutex_unlock(&nsStats.getMutex());

    return 0;
}