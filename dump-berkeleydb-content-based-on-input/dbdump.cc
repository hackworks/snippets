// -*-c++-*-

#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <libgen.h>

#include <iomanip>
#include <typeinfo>
#include <iostream>
#include <algorithm>

// Some stuff from tr1
#include <tr1/tuple>
#include <tr1/unordered_map>

#ifdef _ONTAP_
#include <bdb/db_cxx.h>
#include <bdb/dbstl_map.h>
#include <bdb/dbstl_vector.h>
#else
#include <db_cxx.h>
#include <dbstl_map.h>
#include <dbstl_vector.h>
#endif

using namespace std;
using namespace dbstl;

// Generic containers mapping to various BerkeleyDB access methods
typedef db_vector<ElementRef<Dbt> > mds_vec_t;
typedef db_map<Dbt, Dbt, ElementRef<Dbt> > mds_map_t;
typedef db_multimap<Dbt, Dbt, ElementRef<Dbt> > mds_mmap_t;

// A type for hex printing
typedef struct hex_t;

// Function pointer of PrintDataByType
typedef size_t (*f_PrintDataByType)(void *, size_t);

// Store the program name without the path information
static string progname;

//-----------------------------------------------------------------------------
// usage
//-----------------------------------------------------------------------------
static void
usage(int ret, const char *msg = NULL)
{
    if (msg) {
        cerr << msg << endl;
    }

    cerr << "Usage: " << progname
         << " [-k fmt] [-v fmt] [-erh] [-f] db_file" << endl;
    cerr << "\t -e \tUse DB environment to open DB file" << endl;
    cerr << "\t -r \tRun recovery on the environment" << endl;
    cerr << "\t -k \tSpecify the format to interpret the key" << endl;
    cerr << "\t -v \tSpecify the format to interpret the value" << endl;
    cerr << "\t    \tFormat is ':' separated combination of the following"
         << endl;
    cerr << "\t    \t o 'c' for char" << endl;
    cerr << "\t    \t o 's' for string" << endl;
    cerr << "\t    \t o 'i32' for int32" << endl;
    cerr << "\t    \t o 'u32' for unit32" << endl;
    cerr << "\t    \t o 'i64' for int64" << endl;
    cerr << "\t    \t o 'u64' for uint64" << endl;
    cerr << "\t    \t o 'hex' for hexadecimal" << endl;
    cerr << "\t -f \tSpecify the db_file" << endl;
    cerr << "\t -h \tShow this help" << endl;

    exit(ret);
}

//-----------------------------------------------------------------------------
// PrintDataByType
//  Functor to print data as per type
//-----------------------------------------------------------------------------
template <typename T>
size_t PrintDataByType(void *data, size_t remaining) {
    cout << *(T *)data;
    return (remaining > sizeof(T)) ? sizeof(T) : remaining;
}

//-----------------------------------------------------------------------------
// PrintDataByType<char *>
//  Specialize for string printing
//-----------------------------------------------------------------------------
template <>
size_t PrintDataByType<char *>(void *data, size_t remaining) {
    cout << (char *)data;
    return (strlen((char *)data) + 1);
}

//-----------------------------------------------------------------------------
// PrintDataByType<hex_t>
//   Specialized for hex printing
//-----------------------------------------------------------------------------
template <>
size_t PrintDataByType<hex_t>(void *data, size_t remaining) {
    for (size_t cc = 0; cc < remaining; cc++) {
        cout << hex << (int)((char *)data)[cc];
    }
    return remaining;
}

//-----------------------------------------------------------------------------
// Generic printer class
//-----------------------------------------------------------------------------
template<typename T>
class PrintData {
public:
    // For vector types: queue and recno
    PrintData(string &valFmt) {
        _bFirst = true;
        ParseOpt(valFmt, _valFmt);
    }

    // For associated types: map or multi-map
    PrintData(string &keyFmt, string &valFmt) {
        _bFirst = true;
        ParseOpt(keyFmt, _keyFmt);
        ParseOpt(valFmt, _valFmt);
    }

    // Functor to enable being called from stl algorithm
    void operator() (T &obj);

private:
    bool _bFirst;
    vector<f_PrintDataByType> _keyFmt;
    vector<f_PrintDataByType> _valFmt;

    static bool
    IsPrintable(char *ptr, size_t sz) {
        if ('\0' != ptr[--sz]) {
            return false;
        }

        for (size_t cc = 0; cc < sz; cc++) {
            if (!isprint(ptr[cc])) {
                return false;
            }
        }

        return true;
    }

    // Parse the output format into more usable format
    static bool
    ParseOpt(string &fmt, vector<f_PrintDataByType> &funcs) {
        char buff[1024];
        strcpy(buff, fmt.c_str());
        char *tok = strtok((char *)buff, ":");

        while (NULL != tok) {
            if (0 == strcmp(tok, "c")) {
                funcs.push_back(PrintDataByType<char>);
            } else if (0 == strcmp(tok, "s")) {
                funcs.push_back(PrintDataByType<char *>);
            } else if (0 == strcmp(tok, "i32")) {
                funcs.push_back(PrintDataByType<int32_t>);
            } else if (0 == strcmp(tok, "u32")) {
                funcs.push_back(PrintDataByType<uint32_t>);
            } else if (0 == strcmp(tok, "i64")) {
                funcs.push_back(PrintDataByType<int64_t>);
            } else if (0 == strcmp(tok, "u64")) {
                funcs.push_back(PrintDataByType<uint64_t>);
            } else if (0 == strcmp(tok, "hex")) {
                funcs.push_back(PrintDataByType<hex_t>);
            } else {
                funcs.clear();
                cerr << "Error: Unrecognized format \""
                     << tok << "\"" << endl;
                usage(-1);
                return false;
            }

            tok = strtok(NULL, ":");
        }

        return true;
    }

    // Interpret and print the data based on the format specified
    void
    static DoPrint(Dbt &obj, vector<f_PrintDataByType> &fmt) {
        vector<f_PrintDataByType>::const_iterator it;

        size_t sz = obj.get_size();
        void *data = obj.get_data();

        // Should happen only for Attribute Db
        if (fmt.empty()) {
            string opt;

            if (PrintData<T>::IsPrintable((char *)data, sz)) {
                opt = "s";
            } else {
                // We know it is long but the size of long on 32b is 4
                // and on 64b is 8. Attempting to print the right long type
                if (sz == sizeof(int32_t)) {
                    opt = "i32";
                } else if (sz == sizeof(int64_t)) {
                    opt = "i64";
                } else {
                    // Fallback on printing it as a bunch of int64_t types
                    opt = "i64";
                    for (size_t cc = 1; cc < sz/sizeof(int64_t); cc++) {
                        opt += ":i64";
                    }
                }
            }

            // Get the appropriate list of print functors
            ParseOpt(opt, fmt);
        }

        for (it = fmt.begin(); it != fmt.end(); ++it) {
            if (it != fmt.begin()) {
                cout << ",";
            }

            // Gets the size of actual data printed
            size_t written = (*it)(data, sz);

            // Offset the data to advance to the next member
            data = (char *)data + written;
            sz -= written;
        }

        return;
    }
};

//-----------------------------------------------------------------------------
// Specialize for vector type
//-----------------------------------------------------------------------------
template<>
void PrintData<Dbt>::operator() (Dbt &obj)
{
    // Print the output header
    if (_bFirst) {
        cout << "#value" << endl;
    }

    PrintData<Dbt>::DoPrint(obj, _valFmt);
    cout << endl;

    // Do this at the end so that all code that depends on this
    // flag gets a chance to see the correct state
    if (_bFirst) {
        _bFirst = false;
    }

    return;
}

//-----------------------------------------------------------------------------
// For associated array types: key/value pairs
//-----------------------------------------------------------------------------
template<typename T>
void PrintData<T>::operator() (T &obj)
{
    // Print the output header
    if (_bFirst) {
        cout << "#key:value" << endl;
    }

    PrintData<T>::DoPrint(obj.first, _keyFmt);
    cout << ":";
    PrintData<T>::DoPrint(obj.second, _valFmt);
    cout << endl;

    // Do this at the end so that all code that depends on this
    // flag gets a chance to see the correct state
    if (_bFirst) {
        _bFirst = false;
    }

    return;
}

//-----------------------------------------------------------------------------
// is_alive: Callback function for recovery FAILCHK
// TODO: Figure out if we need to do a DB_FAILCHK in a stand alone tool
//-----------------------------------------------------------------------------
static int
is_alive(DbEnv *envp, pid_t pid, db_threadid_t tid, uint32_t flags)
{
    return -1;
}

//-----------------------------------------------------------------------------
// makelower
//  Helper function used to downcase a string
//-----------------------------------------------------------------------------
void
downcase(char &a)
{
    a = tolower(a);
    return;
}

//-----------------------------------------------------------------------------
// GetDefaultFormats
//	Try to get a key/value print format
//	ATTN: REMEMBER TO UPDATE THIS WHEN YOU CREATE A NEW DB FILE TYPE
//-----------------------------------------------------------------------------
void
GetDefaultFormats(string dbfile, string &keyfmt, string &valuefmt)
{
    typedef tr1::tuple<string, string> format;

    static bool bFirst = true;
    static tr1::unordered_map<string, format> fmtMap;

    for_each(dbfile.begin(), dbfile.end(), downcase);

    // Populate the lookup table
    if (bFirst) {
        // All keys in lower case
        fmtMap["attrname.db"] = format("s", "u32:i32");
        fmtMap["attrname_attrid.sdb"] = format("u32:i32", "s");
        fmtMap["oid.db"] = format("hex", "u64");
        fmtMap["oid_oidid.sdb"] = format("u64", "hex");
        fmtMap["oidid.db"] = format("u64", "u32:i32");
        bFirst = false;
    }

    do {
        tr1::unordered_map<string, format>::const_iterator it;

        it = fmtMap.find(dbfile);
        if (fmtMap.end() == it) {
            break;
        }

        if (keyfmt.empty()) {
            keyfmt = tr1::get<0>(it->second);
        }

        if (valuefmt.empty()) {
            valuefmt = tr1::get<1>(it->second);
        }

    } while(0);

    return;
}

//-----------------------------------------------------------------------------
// main
//-----------------------------------------------------------------------------
int
main(int argc, char *argv[])
{
    // Get the program name for future usage
    progname = basename(argv[0]);

    int opt;
    bool opt_env = false;
    bool opt_recover = false;
    bool opt_file = false;
    string opt_keyfmt;
    string opt_valfmt;

    string dbfile;
    do {
        opt = getopt(argc, argv, "erhk:v:f:");
        switch(opt) {
            case 'e':
                opt_env = true;
                break;
            case 'r':
                opt_recover = true;
                break;
            case 'h':
                usage(0);
                return 0;
            case 'f':
                opt_file = true;
                dbfile = optarg;
                break;
            case 'k':
                opt_keyfmt = optarg;
                break;
            case 'v':
                opt_valfmt = optarg;
                break;
            default:
                break;
        }
    } while(-1 != opt);

    if (false == opt_file) {
        if (argc == optind) {
            usage(-1, "Error: Missing DB file");
            return -1;
        }
        dbfile = argv[optind];
    }

    string dbdir;               // DB folder
    string dbname;              // Name of the DB table
    string dbfilebase;          // Actual DB File portion from path

    size_t pos = dbfile.find_last_of("/");
    if (string::npos == pos) {
        dbfilebase = dbfile;
        dbdir = "./";
    } else {
        dbfilebase = dbfile.substr(pos + 1);
        dbdir = dbfile.substr(0, pos);
    }

    dbname = dbfilebase;
    pos = dbfilebase.find_last_of(".");
    if (string::npos != pos) {
        dbname[pos] = '_';
    }

    // Get the default parameters from the internal lookup
    if (opt_keyfmt.empty() || opt_valfmt.empty()) {
        GetDefaultFormats(dbfilebase, opt_keyfmt, opt_valfmt);
    }

    if (access(dbfile.c_str(), R_OK)) {
        cerr << "Error: Unable to open DB file \""
             << dbfile.c_str() << "\" for read" << endl;
        return -1;
    }

    int ret = -1;
    DbEnv env(DB_CXX_NO_EXCEPTIONS);
    DbEnv *envp = NULL;
    uint32_t envFlags =
        DB_CREATE
        | DB_INIT_LOCK
        | DB_INIT_LOG
        | DB_INIT_TXN
        | DB_REGISTER;
    uint32_t envFlagsRecover =
        DB_CREATE
        | DB_INIT_LOCK
        | DB_INIT_LOG
        | DB_INIT_MPOOL
        | DB_INIT_TXN
        | DB_THREAD
        | DB_PRIVATE
        // | DB_FAILCHK
        | DB_RECOVER;

    if (opt_recover || opt_env) {
        // Set some basic env features
        env.set_lk_detect(DB_LOCK_DEFAULT);
        env.set_errpfx("Error");
        env.set_errfile(0);

        // Required for fail check (disabled for now)
        if (opt_recover && (DB_FAILCHK & envFlagsRecover)) {
            // TODO: This might need to go into mdsd code
            env.set_thread_count(1024);
            env.set_isalive(is_alive);
        }

        // Open the DB env before opening the DB
        ret = env.open(dbdir.c_str(),
                       (opt_recover) ? envFlagsRecover: envFlags, 0);
        if (0 != ret) {
            if (DB_RUNRECOVERY == ret) {
                usage(ret,
                      "Warning: DB environment"
                      " requires recovery,"
                      " run with '-r' option");
            } else {
                cerr << "Error: Failed to "
                    "open DB environment \""
                     << dbdir << "\" with error "
                     << ret << endl;
            }
            return ret;
        }

        // Use DB env for opening DB only if requested
        if (opt_env) {
            env.set_errfile(stderr);
            envp = &env;
        } else {
            env.close(0);
        }
    }

    // Open the given DB for read
    Db dbh(envp, DB_CXX_NO_EXCEPTIONS);
    if (dbh.open(NULL, dbfile.c_str(), dbname.c_str(),
                 DB_UNKNOWN, DB_RDONLY, 0)) {
        cerr << "Error: Failed to open DB \""
             << dbfile << "\"" << endl;
        return -1;
    }

    uint32_t flags = 0;
    DBTYPE type = DB_UNKNOWN;
    // Get the DB type and the underlying flags
    if (dbh.get_type(&type) || dbh.get_flags(&flags)) {
        dbh.stat_print(DB_STAT_ALL);
        return -1;
    }

    int status = -1;
    try {
        if (DB_BTREE & type || DB_HASH & type) {
            // If DB supports duplicate keys, use a multimap
            if (DB_DUP & flags) {
                mds_mmap_t data(&dbh, envp);
                PrintData< mds_mmap_t::value_type_wrap > p(opt_keyfmt,
                                                           opt_valfmt);
                for_each(data.begin(
                            ReadModifyWriteOption::no_read_modify_write(),
                                    true), data.end(), p);
            } else {
                mds_map_t data(&dbh, envp);
                PrintData< mds_map_t::value_type_wrap > p(opt_keyfmt,
                                                          opt_valfmt);
                for_each(data.begin(
                            ReadModifyWriteOption::no_read_modify_write(),
                                    true), data.end(), p);
            }

            status = 0;
        } else if (DB_RECNO & type || DB_QUEUE & type) {
            mds_vec_t data(&dbh, envp);
            PrintData< Dbt > p(opt_valfmt);
            for_each(data.begin(ReadModifyWriteOption::no_read_modify_write(),
                                        true), data.end(), p);

            status = 0;
        } else {
            cerr << "Error: Unrecognized DB type " << type
                 << endl;
            dbh.stat_print(DB_STAT_ALL);
        }
    } catch (...) {
        cerr << "Error: Unhandled exception encountered" << endl;
    }

    return status;
}