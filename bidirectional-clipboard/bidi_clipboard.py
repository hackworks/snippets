#!/usr/bin/python -u
#------------------------------------------------------------------------------
# File  : bidi_clipboard.py
# Author: Dhruva Krishnamurthy
#
# Usage :
#   o From corporate: python -u bidi_clipboard.py L:\ved2corp.0 L:\corp2ved.0
#   o From VED setup: python -u bidi_clipboard.py /mnt/airlock/corp2ved.0 /mnt/airlock/ved2corp.0
#
#   Say you want to access VED from home machine:
#   o From new machine: python -u bidi_clipboard.py L:\ved2corp.0 L:\home2ved.0
#   o From VED setup: kill -s SIGINT pid_of_bidi_service
#   o                 CTRL-C in term running the service
#     o You will be prompted to update the input file
#     o Specify airlock path to home2ved.0: /mnt/airlock/home2ved.0
#
# Desc  : BIDI clipboard implementation using file based sharing of clipboard
#
# DISCLAIMER:
#   o Use discretion and you own the responsibility for what you place
#     in the Airlock.
#   o Do not try to circumvent Airlock auditing by storing encrypted data or
#     other means
#   o I take no responsibility for misusing the tool - You use it, you own it
#
#------------------------------------------------------------------------------
__author__ = 'dhruva'

import os
import sys
import time
import errno
import ctypes
import struct
import signal
import itertools

# Used to break out of the clipboard polling loop
exit_loop = False


def which(program):
    def is_exe(fpath):
        return os.path.isfile(fpath) and os.access(fpath, os.X_OK)

    fpath, fname = os.path.split(program)
    if fpath:
        if is_exe(program):
            return program
    else:
        for path in os.environ["PATH"].split(os.pathsep):
            path = path.strip('"')
            exe_file = os.path.join(path, program)
            if is_exe(exe_file):
                return exe_file

    return None

# Use to switch inputs when using a different source
# connecting to VED
reopen_input = False


# Signal handler to trigger graceful exit or remap input file
def signal_cb(sig, frame):
    global reopen_input
    if not reopen_input and sig == signal.SIGINT:
        reopen_input = True
    else:
        global exit_loop
        exit_loop = True


# Main python loop
def bidi_service(infile, outfile, key):
    if infile == outfile:
        print "Error: Input and output files cannot be same"
        return

    # Break the loop to take user input
    signal.signal(signal.SIGINT, signal_cb)

    # Ensure we have a clean and graceful exit from the main loop
    signal.signal(signal.SIGTERM, signal_cb)

    # Avoid redundant updates to file/clipboard if nothing has changed
    prev_in_data = None
    prev_out_data = None

    # We cannot overwrite a file on Airlock
    if os.path.isfile(outfile) and not os.access(outfile, os.W_OK):
        print "Error: %s File exists, cannot overwrite file in Airlock" % outfile
        sys.exit(-1)

    # Handle MAC SMB client serving stale data by reopening input file
    refresh_rfh = (sys.platform == 'darwin' and not os.getenv('BIDI_NO_REFRESH'))

    # Open the CLIPBOARD file
    rfh = None
    wfh = open(outfile, 'wb', 0)

    print "Starting local server : pid=%d in=%s out=%s key=%s" % (os.getpid(), infile, outfile, key if key else 'None')
    print "To start remote server: %s %s %s %s" % (sys.argv[0], outfile, infile, key if key else '')
    print "\nCTRL-C to remap the input file"

    # Start the main polling loop
    global exit_loop
    while not exit_loop:
        # Yield for a second
        try:
            time.sleep(1)
        except IOError:
            pass

        # Get clipboard data and write to file
        data = read_from_clipboard()

        if data:
            # Let us not store the whole data for comparison: max 256 bytes
            min_data = str(len(data)) + data[:256]
            # Avoid loop by writing back data read during previous iteration
            if min_data != prev_in_data and min_data != prev_out_data:
                prev_out_data = min_data
                write_clipboard_data(wfh, data, key)
            min_data = None

        # On SIGINT, reopen a different input file if different
        global reopen_input
        if reopen_input:
            try:
                inp = raw_input("Remap clipboard input file [CTRL-C to exit]: ")
                inp = inp.strip(" \t\r\n")

                if inp and len(inp):
                    infile = inp

                    # Ensure we do not have the input and output pointing to same file
                    if infile == outfile:
                        print "Error: Input and output files cannot be same"
                        break

                    reopen_input = False
                    print "Switching server: pid=%d in=%s out=%s" % (os.getpid(), infile, outfile)
                    if rfh:
                        rfh.close()
                        rfh = None
            except (EOFError, KeyboardInterrupt) as e:
                exit_loop = True
                break

        if rfh and refresh_rfh:
            rfh.close()
            rfh = None

        # Open the CLIPBOARD file
        if not rfh:
            try:
                rfh = open(infile, 'rb', 0)
            except IOError:
                continue

        # Get data from file and write to clipboard
        data = read_clipboard_data(rfh, key)

        if data:
            # Let us not store the whole data for comparison: max 256 bytes
            min_data = str(len(data)) + data[:256]
            # Avoid loop by reading back data written above
            if min_data != prev_in_data and min_data != prev_out_data:
                prev_in_data = min_data
                write_to_clipboard(data)
            min_data = None

    print "Shutting down server gracefully"

    # Close the READ file handle
    if rfh:
        rfh.close()

    # Clear and close the WRITE file handle
    if wfh:
        wfh.truncate(0)
        wfh.close()

        # Attempt to clean up the file during testing
        if os.getenv('BIDI_CLIPBOARD_DEBUG'):
            os.unlink(outfile)


# Read data from shared file
def read_clipboard_data(fh, key):
    lock_file(fh.fileno(), False)
    try:
        fh.seek(0, os.SEEK_SET)
        data = fh.read(4)
        if data and len(data) == 4:
            sz = int(struct.unpack("I", data)[0])
            # Read data only if we have data to be read
            if sz > 0:
                data = fh.read(sz)
                # If the read data does not match the expected size, discard it
                if sz != len(data):
                    data = None
                elif key:
                    data = xor_crypt_string(data, key)
    except IOError:
        data = None
    unlock_file(fh.fileno())

    return data


# Write date to a shared file
def write_clipboard_data(fh, data, key):
    if key:
        data = xor_crypt_string(data, key)

    fmt = "I" + str(len(data)) + "s"
    data = struct.pack(fmt, len(data), str(data))

    if data:
        lock_file(fh.fileno(), True)
        try:
            fh.truncate(0)
            fh.seek(0, os.SEEK_SET)
            fh.write(data)
        except IOError:
            pass
        unlock_file(fh.fileno())

    return


# Read the data from the clipboard
def read_from_clipboard():
    if sys.platform == 'win32':
        win32clipboard.OpenClipboard()
        # We support ONLY ASCII text data
        try:
            data = win32clipboard.GetClipboardData()
        except TypeError:
            data = None
            pass

        win32clipboard.CloseClipboard()
        return data
    elif sys.platform == 'darwin':
        cmd = "pbpaste"
    elif sys.platform == 'linux2':
        cmd = "xclip -selection clipboard -o"
    else:
        print "Unsupported platform: " + sys.platform
        raise RuntimeError

    if cmd:
        try:
            p = os.popen(cmd)
            if p:
                data = p.read()
                p.close()
                return data
        except IOError:
            pass

    return None


# Write the data to clipboard
def write_to_clipboard(data):
    if sys.platform == 'win32':
        win32clipboard.OpenClipboard()
        win32clipboard.EmptyClipboard()
        win32clipboard.SetClipboardText(data)
        win32clipboard.CloseClipboard()
        return
    elif sys.platform == 'darwin':
        cmd = "pbcopy"
    elif sys.platform == 'linux2':
        cmd = "xclip -selection clipboard -i"
    else:
        print "Unsupported platform: " + sys.platform
        raise RuntimeError

    if cmd:
        try:
            p = os.popen(cmd, 'w', len(data))
            if p:
                p.write(data)
                p.close()
        except IOError:
            pass

    return


def lock_file(fd, excl):
    if sys.platform == 'win32':
        win32file.LockFile(win32file._get_osfhandle(fd), 0, 0, 4, 0)
    else:
        while True:
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX if excl else fcntl.LOCK_SH, 4, 0, os.SEEK_SET)
            except IOError:
                err = ctypes.get_errno()
                if errno.EPERM == err or errno.EAGAIN == err:
                    continue
            break


def unlock_file(fd):
    if sys.platform == 'win32':
        win32file.UnlockFile(win32file._get_osfhandle(fd), 0, 0, 4, 0)
    else:
        while True:
            try:
                fcntl.lockf(fd, fcntl.LOCK_UN, 4, 0, os.SEEK_SET)
            except IOError:
                err = ctypes.get_errno()
                if errno.EPERM == err or errno.EAGAIN == err:
                    continue
            break


# Poor (wo)man's encryption of data
def xor_crypt_string(data, key):
    return ''.join(chr(ord(x) ^ ord(y)) for (x, y) in itertools.izip(data, itertools.cycle(key)))

# Check if we have the required mechanisms to manipulate the clipboard
if sys.platform == 'win32':
    import win32file
    import win32clipboard
elif sys.platform == 'darwin':
    import fcntl
    if not (which('pbcopy') and which('pbpaste')):
        print "Error: Requires pbcopy & pbpaste binary"
        sys.exit(-1)
elif sys.platform == 'linux2':
    import fcntl
    if not which('xclip'):
        print "Error: Requires xclip binary (/u/dhruva/installs/bin/xclip)"
        sys.exit(-1)


if __name__ == '__main__':
    if len(sys.argv) > 2:
        key = sys.argv[3] if len(sys.argv) > 3 else None
        if key:
            while True:
                try:
                    yn = raw_input("\nEncrypted data in Airlock: Potential NetApp policy violation\n"
                                   "Do you still want to continue? [y/n]: ")
                except KeyboardInterrupt:
                    sys.exit(0)

                yn = yn.strip(" \t\r\n").lower()
                if yn == 'y' or yn == 'yes':
                    break
                elif yn == 'n' or yn == 'no':
                    sys.exit(0)
                else:
                    print "Unrecognized input: %s" % yn

        bidi_service(sys.argv[1], sys.argv[2], key)
        sys.exit(0)
    else:
        print "Error: Insufficient arguments in_file out_file"
        sys.exit(-1)
