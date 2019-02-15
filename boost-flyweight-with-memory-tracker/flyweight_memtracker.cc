#include <iostream>
#include <string>
#include <vector>
#include <set>
#include <pthread.h>
#include <boost/flyweight.hpp>

// -- Boost flyweight with memory usage tracking --
template<typename T, typename R>
class MemTrackerAllocator {
public:
    typedef T value_type;
    typedef value_type* pointer;
    typedef const value_type* const_pointer;
    typedef value_type& reference;
    typedef const value_type& const_reference;
    typedef std::size_t size_type;
    typedef std::ptrdiff_t difference_type;

    template<typename U>
    struct rebind {
        typedef MemTrackerAllocator<U, R> other;
    };

public:
    inline pointer address(reference r) { return &r; }
    inline const_pointer address(const_reference r) { return &r; }

    inline pointer allocate(size_type cnt, typename std::allocator<void>::const_pointer = 0) {
        pointer p = reinterpret_cast<pointer>(::operator new(cnt * sizeof (T)));
        if (p) {
            volatile size_t &bytes = mem_used();
	        (void)__sync_fetch_and_add(&bytes, cnt);
        }

        return p;
    }

    inline void deallocate(pointer p, size_type cnt) {
        ::operator delete(p);
        volatile size_t &bytes = mem_used();
        (void)__sync_fetch_and_sub(&bytes, cnt);
    }

    inline size_type max_size() const {
        return std::numeric_limits<size_type>::max() / sizeof(T);
    }

    inline void construct(pointer p, const T& t) { new(p) T(t); }
    inline void destroy(pointer p) { p->~T(); }

    inline bool operator==(MemTrackerAllocator const&) const { return true; }
    inline bool operator!=(MemTrackerAllocator const& a) const { return !operator==(a); }

    static volatile size_t& mem_used() { static volatile size_t bytes(0); return bytes; }
};

typedef struct {} stub_HostString_t;
typedef MemTrackerAllocator<char, stub_HostString_t> HostAllocator;
typedef std::basic_string<char, std::char_traits<char>, HostAllocator> HostString_t;

typedef boost::flyweights::flyweight<HostString_t> HostName_t;
typedef std::set<HostName_t> Host_t;

typedef std::vector<std::string> Hosts_t;

Hosts_t hosts;

void *
start_routine(void* arg) {
    Host_t* h = (Host_t*)arg;

    for (Hosts_t::iterator it = hosts.begin(); it != hosts.end(); ++it) {
        h->insert(HostName_t(it->c_str()));
    }

    return arg;
}

int
main(int argc, char* argv[]) {
    Host_t ht, hm;
    void* ret = NULL;
    pthread_t thread;

    for (size_t cc = 1000; cc < 2000; ++cc) {
        char buff[32];
        sprintf(buff, "%d", cc);
        hosts.push_back(buff);
    }

    int tid = pthread_create(&thread, NULL, start_routine, &ht);
    // start_routine(&hm);

    Hosts_t hosts2;
    for (size_t cc = 1000; cc < 2000; ++cc) {
        char buff[32];
        sprintf(buff, "%d", cc);
        hosts2.push_back(buff);
    }

    for (Hosts_t::iterator it = hosts2.begin(); it != hosts2.end(); ++it) {
        hm.insert(HostName_t(it->c_str()));
    }

    pthread_join(thread, &ret);
    std::cout << HostAllocator::mem_used() << std::endl;

    return 0;
}