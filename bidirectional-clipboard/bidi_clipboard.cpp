//----------------------------------------------------------------------------
// File  : bidi_clipboard.cpp
// Author : Dhruva Krishnamurthy
//
// Usage :
//	o From corporate : bidi_clipboard.exe L:\ved2corp.0 L:\corp2ved.0
//	o From VED       : bidi_clipboard.exe L:\corp2ved.0 L:\ved2corp.0
//
// Say you want to access VED from home machine :
//	o From new machine: bidi_clipboard.exe L:\ved2corp.0 L:\home2ved.0
//		o You will be prompted to update the input file only if you
//        want to remap
//
// Desc : BIDI clipboard implementation using file based sharing of clipboard
//
// DISCLAIMER :
//	o Use discretion and you own the responsibility for what you place
//	  in the Airlock.
//	o Do not try to circumvent Airlock auditing by storing encrypted data or
//	  other means
//	o I take no responsibility for misusing the tool - You use it, you own it
//
//----------------------------------------------------------------------------

// We are not interested in building a UNICODE variant - argv
#undef UNICODE

// We want to use simple POSIX interface
#define _CRT_SECURE_NO_WARNINGS

#include <iostream>
#include <string>
#include <sstream>
#include <stdexcept>
#include <atomic>
#include <io.h>
#include <conio.h>
#include <windows.h>

using namespace std;

// Debug flag for verbose messaging
bool bidi_debug = false;

// Windows share caches data - reopen file to ensure
// we are not served stale data from the SMB client
bool bidi_no_refresh = false;

// Default clipboard format for cross platform usage
unsigned int bidi_cb_format = CF_TEXT;

class BIDIState;
bool main_loop(BIDIState* pState);
BOOL WINAPI HandlerRoutine(DWORD sig);

// Main class with the required state to process the clipboard
// over airlock
class BIDIState {
public:
	BIDIState(const char* in, const char* out) {
		_shut = false;

		// Set the output file details
		_outfilename = out;
		_outfile = fopen(out, "wb");

		if (!_outfile) {
			DWORD err = GetLastError();
			std::ostringstream msg;
			msg << "Failed to open file \"" << out
				<< "\" for write with error " << err;
			throw std::exception(msg.str().c_str());
		}

		// Set the input details
		_infile = NULL;
		_dirHandle = INVALID_HANDLE_VALUE;
		(void)setIn(in);
	}

	void Shutdown(bool shut) { _shut = shut; }
	bool Shutdown() { return _shut; }

	bool setIn(const char* f) {
		if (std::string(f) == _outfilename) {
			cerr << "Error: Input and output files cannot be same" << endl;
			return false;
		}

		if (_infile) {
			fclose(_infile);
		}

		// Check we are not refering to the same string
		if (f != _infilename.c_str()) {
			_infilename = f;
		}

		// Get the directory name to begin watching it for change
		do {
			size_t pos = _infilename.rfind('\\');
			if (std::string::npos == pos) {
				pos = _infilename.rfind('/');
			}

			std::string dirName = (std::string::npos == pos) ? "." : _infilename.substr(0, pos);

			if (dirName == _dirName) {
				break;
			}

			// Update the new dir name and start monitoring it
			_dirName = dirName;

			if (INVALID_HANDLE_VALUE != _dirHandle) {
				FindCloseChangeNotification(_dirHandle);
				_dirHandle = INVALID_HANDLE_VALUE;
			}

			_dirHandle = FindFirstChangeNotification(_dirName.c_str(), false, FILE_NOTIFY_CHANGE_LAST_WRITE);
		} while (0);

		_infile = fopen(_infilename.c_str(), "rb");

		return !!_infile;
	}

	bool DidDirectoryChange(DWORD timeout) {
		if (INVALID_HANDLE_VALUE == _dirHandle) {
			Sleep(timeout);
		}
		else if (WAIT_OBJECT_0 == WaitForSingleObject(_dirHandle, timeout)) {
			FindNextChangeNotification(_dirHandle);
			return true;
		}

		return false;
	}

	FILE* getIn(bool refresh = false /* Re-open the file */) {
		if ((!refresh && _infile) || _infilename.empty()) {
			return _infile;
		}

		(void)setIn(_infilename.c_str());

		return _infile;
	}

	FILE* getOut() { return _outfile; }

	virtual ~BIDIState() {
		if (_infile) {
			fclose(_infile);
		}

		// Truncate output file before shutting down
		if (_outfile) {
			(void)_chsize(_fileno(_outfile), 0);
			fclose(_outfile);
		}

		if (INVALID_HANDLE_VALUE != _dirHandle) {
			FindCloseChangeNotification(_dirHandle);
		}
	}

private:
	FILE* _infile;
	FILE* _outfile;
	std::string _infilename;
	std::string _outfilename;

	std::string _dirName;
	HANDLE _dirHandle;

	std::atomic<bool> _shut;
};

// Global state object
BIDIState* g_pBIDI = NULL;


// Read the local clipboard and write into a file in Airlock
// so that the remote side can pick up the contents and update its clipboard
BOOL GetClipboardText(FILE* fp, std::string& prevInData, std::string& prevOutData)
{
	if (!OpenClipboard(NULL)) {
		return false;
	}

	BOOL ret = FALSE;
	HGLOBAL hMem = 0;
	do {
		hMem = GetClipboardData(bidi_cb_format);
		if (!hMem) {
			break;
		}

		LPTSTR ptxt = (LPTSTR)GlobalLock(hMem);
		if (!ptxt) {
			break;
		}

		size_t sz = lstrlen(ptxt);

		stringstream oss;
		oss << sz;
		oss.write(ptxt, (sz > 256) ? 256 : sz);

		// Avoid duplicate processing
		if (prevInData == oss.str() || prevOutData == oss.str()) {
			ret = TRUE;
			break;
		}

		// Write the size of data in clipboard
		int dataSz = (int)sz;

		// Handle corrupt data resulting in large size_t value
		if (dataSz < 0) {
			break;
		}

		// Truncate the file
		(void)_chsize(_fileno(fp), 0);

		// Write from top
		fseek(fp, 0, SEEK_SET);
		if (0 == fwrite(&dataSz, sizeof(dataSz), 1, fp) && ferror(fp)) {
			break;
		}

		// Write the actual clipboard contents
		size_t wrsz = 0;
		while (wrsz < sz) {
			wrsz += fwrite(ptxt + wrsz, sizeof(char), sz - wrsz, fp);
			if (feof(fp) || ferror(fp)) {
				break;
			}
		}

		// Flush the contents since we do not have unbuffered IO support
		fflush(fp);

		prevOutData = oss.str();
		ret = TRUE;
	} while (0);

	if (hMem) {
		GlobalUnlock(hMem);
	}

	CloseClipboard();

	return ret;
}

// Read the file containing the remote clipboard and populate the local
// clipboard only if the contents are different from the previous update
BOOL SetClipboardText(FILE* fp, std::string& prevInData, std::string& prevOutData)
{
	BOOL ret = FALSE;
	char ReadBuffer[1024];
	char* pBuff = &ReadBuffer[0];

	if (!OpenClipboard(NULL)) {
		return false;
	}

	do {
		int dataSz = 0;

		// Read from the top
		fseek(fp, 0, SEEK_SET);
		if (0 == fread(&dataSz, sizeof(dataSz), 1, fp) && ferror(fp)) {
			break;
		}

		// Handle corrupt data resulting in large size_t value
		if (dataSz < 0) {
			break;
		}

		size_t sz = (size_t)dataSz;
		if (sz > (sizeof(ReadBuffer) - 1)) {
			pBuff = new char[sz + 2];
		}
		pBuff[sz + 1] = '\0';

		// Read the actual clipboard contents
		size_t rdsz = 0;
		while (rdsz < sz) {
			rdsz += fread(pBuff + rdsz, sizeof(char), sz - rdsz, fp);
			if (feof(fp) || ferror(fp)) {
				break;
			}
		}

		// Ensure we have read the whole file
		if (sz == rdsz) {
			stringstream oss;
			oss << sz;
			oss.write(pBuff, (sz > 256) ? 256 : sz);

			// Avoid duplicate updation to clipboard
			if (prevInData == oss.str() || prevOutData == oss.str()) {
				break;
			}

			// The text should be placed in "global" memory
			HGLOBAL hMem = GlobalAlloc(GMEM_SHARE | GMEM_MOVEABLE, rdsz + 1);
			if (!hMem) {
				break;
			}

			LPTSTR ptxt = (LPTSTR)GlobalLock(hMem);
			if (!ptxt) {
				GlobalFree(hMem);
				break;
			}

			memcpy(ptxt, pBuff, rdsz);
			ptxt[rdsz + 1] = '\0';

			EmptyClipboard();
			if (SetClipboardData(bidi_cb_format, hMem)) {
				prevInData = oss.str();
			}
		}
	} while (0);

	// Close the clipboard and relinquish control
	CloseClipboard();

	// Delete the buffer only if we have allocated it
	if (pBuff != &ReadBuffer[0]) {
		delete[] pBuff;
	}

	return ret;
}

// Stop the service on SIGINT
BOOL WINAPI HandlerRoutine(DWORD sig) {
	g_pBIDI->Shutdown(true);
	return true;
}

DWORD WINAPI main_loop(void* arg) {
	BIDIState* pState = reinterpret_cast<BIDIState*>(arg);
	std::string prevInData, prevOutData;

	do {
		// Do not be too agressive
		bool incoming = pState->DidDirectoryChange(1000);

		// Write the contents of the current clipboard to file before getting data from remote
		GetClipboardText(pState->getOut(), prevInData, prevOutData);

		// If there is incoming data, re-open and read the data
		if (incoming) {
			// If we have a valid input file handle, attempt reading it or force refresh based on setting
			FILE* inFp = pState->getIn(!bidi_no_refresh);
			if (inFp) {
				SetClipboardText(inFp, prevInData, prevOutData);
			}
		}
	} while (!pState->Shutdown());

	return true;
}

int main(int argc, char* argv[]) {
	if (!(argc > 2)) {
		cerr << "Error: Insufficient arguments" << endl;
		cerr << "Usage: " << argv[0] << " in_file out_file" << endl;
		cerr << "Version: " << argv[0] << " [" << __DATE__ << ", " << __TIME__ << "]" << endl;
		cerr << endl << "Press any key to exit...";
		(void)_getch();
		return -1;
	}

	bidi_debug = !!getenv("BIDI_DEBUG");
	bidi_no_refresh = !!getenv("BIDI_NO_REFRESH");
	bidi_cb_format = getenv("BIDI_CLIPBOARD_FORMAT") ? atoi(getenv("BIDI_CLIPBOARD_FORMAT")) : CF_TEXT;

	HANDLE singleton = CreateMutex(NULL, false, "BIDI_CLIPBOARD");
	if (NULL == singleton) {
		cerr << "Error: Failed to create singleton mutex with error " << GetLastError() << endl;
		return -1;
	}
	else if (ERROR_ALREADY_EXISTS == GetLastError()) {
		cerr << endl << "Error: Another instance of BIDI clipboard service detected!" << endl;
		cerr <<         "       Run a single instance to avoid messing up the clipboard" << endl;
		CloseHandle(singleton);
		return -1;
	}

	try {
		g_pBIDI = new BIDIState(argv[1], argv[2]);
		SetConsoleCtrlHandler(HandlerRoutine, true);
	}
	catch (std::exception &e) {
		cerr << e.what() << endl;
		return -1;
	}

	// Start the main thread
	HANDLE th = CreateThread(NULL, 0, main_loop, g_pBIDI, 0, NULL);
	if (!th) {
		cerr << "Error: Failed to create service thread" << endl;
		delete g_pBIDI;
		return -1;
	}

	// Log success - some need it
	cout << "Successfully started BIDI clipboard service" << endl << endl;

	// Name the console to help easy idenditification
	SetConsoleTitle("BIDI clipboard service");

	do {
		std::string fin;
		cout << "Remap clipboard input file [CTRL-C to exit]: ";
		cin >> fin;

		if (!fin.empty()) {
			if (g_pBIDI->setIn(fin.c_str())) {
				cout << "Remaped input to file: " << fin << endl;
			}
		}
		else {
			// Give some time for the shutdown event to trigger
			// graceful exit of the thread before prompting user
			Sleep(1000);
		}
	} while (!g_pBIDI->Shutdown());

	// Wait for server thread the exit gracefully
	WaitForSingleObject(th, INFINITE);

	cout << endl << "Gracefully shutting down service" << endl;
	delete g_pBIDI;

	// Close the singleton mutex since we are exiting the service
	CloseHandle(singleton);

	return 0;
}