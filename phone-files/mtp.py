"""Minimal ctypes binding to libmtp, covering what a file browser needs.

libmtp talks to Android phones over MTP (the "File transfer" USB mode).
Every call goes through one lock because an MTP session is strictly
one-request-at-a-time.
"""

import ctypes
import ctypes.util
import os
import subprocess
import threading
import time
from ctypes import (CFUNCTYPE, POINTER, Structure, c_char_p, c_int, c_int64,
                    c_uint, c_uint8, c_uint16, c_uint32, c_uint64, c_ubyte,
                    c_void_p)

ROOT = 0xFFFFFFFF
FILETYPE_FOLDER = 0
FILETYPE_UNKNOWN = 44
HANDLER_OK, HANDLER_ERROR, HANDLER_CANCEL = 0, 1, 2

# A few extension -> libmtp filetype hints for uploads; Android ignores most of it.
_UPLOAD_TYPES = {
    ".mp3": 2, ".ogg": 4, ".mp4": 6, ".avi": 9, ".mpg": 10, ".mov": 12,
    ".jpg": 14, ".jpeg": 14, ".tif": 16, ".tiff": 16, ".bmp": 17, ".gif": 18,
    ".png": 20, ".txt": 27, ".html": 28, ".aac": 30, ".flac": 32, ".m4a": 34,
    ".doc": 35, ".xml": 36, ".xls": 37, ".ppt": 38,
}


class Storage(Structure):
    pass


Storage._fields_ = [
    ("id", c_uint32),
    ("StorageType", c_uint16),
    ("FilesystemType", c_uint16),
    ("AccessCapability", c_uint16),
    ("MaxCapacity", c_uint64),
    ("FreeSpaceInBytes", c_uint64),
    ("FreeSpaceInObjects", c_uint64),
    ("StorageDescription", c_char_p),
    ("VolumeIdentifier", c_char_p),
    ("next", POINTER(Storage)),
    ("prev", POINTER(Storage)),
]


class File(Structure):
    pass


File._fields_ = [
    ("item_id", c_uint32),
    ("parent_id", c_uint32),
    ("storage_id", c_uint32),
    ("filename", c_void_p),  # heap char*, freed by LIBMTP_destroy_file_t
    ("filesize", c_uint64),
    ("modificationdate", c_int64),
    ("filetype", c_int),
    ("next", POINTER(File)),
]


class Device(Structure):
    # Only the leading fields we read; we never allocate this struct ourselves.
    _fields_ = [
        ("object_bitsize", c_uint8),
        ("params", c_void_p),
        ("usbinfo", c_void_p),
        ("storage", POINTER(Storage)),
    ]


class DeviceEntry(Structure):
    _fields_ = [("vendor", c_char_p), ("vendor_id", c_uint16), ("product", c_char_p),
                ("product_id", c_uint16), ("device_flags", c_uint32)]


class RawDevice(Structure):
    _fields_ = [("device_entry", DeviceEntry), ("bus_location", c_uint32), ("devnum", c_uint8)]


class Error(Structure):
    pass


Error._fields_ = [("errornumber", c_int), ("error_text", c_char_p), ("next", POINTER(Error))]

PutFunc = CFUNCTYPE(c_uint16, c_void_p, c_void_p, c_uint32, POINTER(c_ubyte), POINTER(c_uint32))


def _load():
    path = ctypes.util.find_library("mtp") or "/opt/homebrew/lib/libmtp.dylib"
    lib = ctypes.CDLL(path)
    sig = {
        "LIBMTP_Init": (None, []),
        "LIBMTP_Detect_Raw_Devices": (c_int, [POINTER(POINTER(RawDevice)), POINTER(c_int)]),
        "LIBMTP_Open_Raw_Device_Uncached": (POINTER(Device), [POINTER(RawDevice)]),
        "LIBMTP_Release_Device": (None, [POINTER(Device)]),
        "LIBMTP_Get_Modelname": (c_void_p, [POINTER(Device)]),
        "LIBMTP_Get_Friendlyname": (c_void_p, [POINTER(Device)]),
        "LIBMTP_Get_Serialnumber": (c_void_p, [POINTER(Device)]),
        "LIBMTP_Get_Batterylevel": (c_int, [POINTER(Device), POINTER(c_uint8), POINTER(c_uint8)]),
        "LIBMTP_Get_Storage": (c_int, [POINTER(Device), c_int]),
        "LIBMTP_Get_Files_And_Folders": (POINTER(File), [POINTER(Device), c_uint32, c_uint32]),
        "LIBMTP_Get_Filemetadata": (POINTER(File), [POINTER(Device), c_uint32]),
        "LIBMTP_destroy_file_t": (None, [POINTER(File)]),
        "LIBMTP_new_file_t": (POINTER(File), []),
        "LIBMTP_Get_File_To_Handler": (c_int, [POINTER(Device), c_uint32, PutFunc, c_void_p, c_void_p, c_void_p]),
        "LIBMTP_Send_File_From_File": (c_int, [POINTER(Device), c_char_p, POINTER(File), c_void_p, c_void_p]),
        "LIBMTP_Get_Thumbnail": (c_int, [POINTER(Device), c_uint32, POINTER(POINTER(c_ubyte)), POINTER(c_uint)]),
        "LIBMTP_Create_Folder": (c_uint32, [POINTER(Device), c_char_p, c_uint32, c_uint32]),
        "LIBMTP_Delete_Object": (c_int, [POINTER(Device), c_uint32]),
        "LIBMTP_Get_Errorstack": (POINTER(Error), [POINTER(Device)]),
        "LIBMTP_Clear_Errorstack": (None, [POINTER(Device)]),
        "LIBMTP_FreeMemory": (None, [c_void_p]),
    }
    for name, (res, args) in sig.items():
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = res, args
    return lib


_lib = _load()
_libc = ctypes.CDLL(None)
_libc.strdup.restype, _libc.strdup.argtypes = c_void_p, [c_char_p]
_lib.LIBMTP_Init()


class MTPError(Exception):
    pass


def _take_string(ptr):
    """Copy a libmtp-allocated string and free it."""
    if not ptr:
        return None
    s = ctypes.string_at(ptr).decode("utf-8", "replace")
    _lib.LIBMTP_FreeMemory(ptr)
    return s


def free_usb_from_macos():
    """macOS's photo-import daemon grabs MTP phones the moment they appear.

    Kill it right before claiming the device; launchd restarts it on demand,
    but by then libmtp holds the USB interface.
    """
    subprocess.run(["pkill", "-9", "-x", "ptpcamerad"], capture_output=True)


def _open_first_uncached():
    """Open the first phone without libmtp's up-front walk of every file,
    which takes minutes on a phone full of photos. Folders load on demand."""
    raw, count = POINTER(RawDevice)(), c_int()
    if _lib.LIBMTP_Detect_Raw_Devices(ctypes.byref(raw), ctypes.byref(count)) != 0 or count.value < 1:
        return None
    try:
        return _lib.LIBMTP_Open_Raw_Device_Uncached(raw) or None
    finally:
        _lib.LIBMTP_FreeMemory(raw)


class Phone:
    def __init__(self):
        self.lock = threading.RLock()
        self.dev = None
        self.info = {}

    # -- connection -------------------------------------------------------

    def connect(self):
        with self.lock:
            self.disconnect(wait=False)
            for _ in range(4):
                free_usb_from_macos()
                time.sleep(0.2)
                dev = _open_first_uncached()
                if dev:
                    self.dev = dev
                    self.info = {
                        "model": _take_string(_lib.LIBMTP_Get_Modelname(dev)),
                        "name": _take_string(_lib.LIBMTP_Get_Friendlyname(dev)),
                        "serial": _take_string(_lib.LIBMTP_Get_Serialnumber(dev)),
                    }
                    return self.info
                time.sleep(0.5)
            raise MTPError(
                "No phone found, or it could not be opened. Plug it in, unlock it, "
                "and set USB to 'File transfer'.")

    def disconnect(self, wait=True):
        with self.lock:
            dev, self.dev, self.info = self.dev, None, {}
        if not dev:
            return
        if wait:
            _lib.LIBMTP_Release_Device(dev)
        else:
            # After the phone re-enumerates (USB mode switched, cable replugged) the
            # old handle is dead and closing it can block on USB timeouts; let that
            # happen in the background instead of stalling the reconnect.
            threading.Thread(target=_lib.LIBMTP_Release_Device, args=(dev,), daemon=True).start()

    @property
    def connected(self):
        return bool(self.dev)

    def _require(self):
        if not self.dev:
            raise MTPError("Phone is not connected.")
        return self.dev

    def _errors(self, fallback):
        dev = self.dev
        msgs = []
        if dev:
            e = _lib.LIBMTP_Get_Errorstack(dev)
            while e:
                if e.contents.error_text:
                    msgs.append(e.contents.error_text.decode("utf-8", "replace"))
                e = e.contents.next
            _lib.LIBMTP_Clear_Errorstack(dev)
        return MTPError("; ".join(msgs) or fallback)

    # -- queries ----------------------------------------------------------

    def battery(self):
        with self.lock:
            dev = self._require()
            mx, cur = c_uint8(), c_uint8()
            if _lib.LIBMTP_Get_Batterylevel(dev, ctypes.byref(mx), ctypes.byref(cur)) != 0:
                _lib.LIBMTP_Clear_Errorstack(dev)
                return None
            return round(100 * cur.value / mx.value) if mx.value else None

    def storages(self):
        with self.lock:
            dev = self._require()
            if _lib.LIBMTP_Get_Storage(dev, 0) != 0:
                raise self._errors("Could not read storage.")
            out = []
            s = dev.contents.storage
            while s:
                st = s.contents
                out.append({
                    "id": st.id,
                    "name": (st.StorageDescription or b"Storage").decode("utf-8", "replace"),
                    "capacity": st.MaxCapacity,
                    "free": st.FreeSpaceInBytes,
                })
                s = st.next
            if not out:
                raise MTPError("The phone is hiding its storage. Unlock the phone, then press Reconnect.")
            return out

    @staticmethod
    def _file_dict(f):
        name = ctypes.string_at(f.filename).decode("utf-8", "replace") if f.filename else ""
        return {
            "id": f.item_id,
            "parent": f.parent_id,
            "storage": f.storage_id,
            "name": name,
            "size": f.filesize,
            "modified": f.modificationdate,
            "folder": f.filetype == FILETYPE_FOLDER,
        }

    def list(self, storage_id, parent_id=ROOT):
        with self.lock:
            dev = self._require()
            head = _lib.LIBMTP_Get_Files_And_Folders(dev, storage_id, parent_id)
            out = []
            f = head
            while f:
                out.append(self._file_dict(f.contents))
                # Copy the next address out *before* freeing: a ctypes pointer field
                # still reads through the struct's memory, which destroy releases.
                addr = ctypes.cast(f.contents.next, c_void_p).value
                _lib.LIBMTP_destroy_file_t(f)
                f = ctypes.cast(addr, POINTER(File)) if addr else None
            if not out:
                _lib.LIBMTP_Clear_Errorstack(dev)  # an empty folder also reports via the stack
            return out

    def metadata(self, item_id):
        with self.lock:
            dev = self._require()
            f = _lib.LIBMTP_Get_Filemetadata(dev, item_id)
            if not f:
                raise self._errors("File not found.")
            try:
                return self._file_dict(f.contents)
            finally:
                _lib.LIBMTP_destroy_file_t(f)

    def thumbnail(self, item_id):
        with self.lock:
            dev = self._require()
            data, size = POINTER(c_ubyte)(), c_uint()
            if _lib.LIBMTP_Get_Thumbnail(dev, item_id, ctypes.byref(data), ctypes.byref(size)) != 0 or not data:
                _lib.LIBMTP_Clear_Errorstack(dev)
                return None
            try:
                return ctypes.string_at(data, size.value)
            finally:
                _lib.LIBMTP_FreeMemory(data)

    # -- transfers --------------------------------------------------------

    def download(self, item_id, write):
        """Stream a file from the phone, calling write(bytes) per chunk."""
        with self.lock:
            dev = self._require()

            def put(_params, _priv, sendlen, data, putlen):
                try:
                    write(ctypes.string_at(data, sendlen))
                except Exception:
                    return HANDLER_CANCEL
                putlen[0] = sendlen
                return HANDLER_OK

            cb = PutFunc(put)  # keep a reference for the duration of the call
            if _lib.LIBMTP_Get_File_To_Handler(dev, item_id, cb, None, None, None) != 0:
                raise self._errors("Download failed.")

    def upload(self, local_path, name, storage_id, parent_id):
        with self.lock:
            dev = self._require()
            f = _lib.LIBMTP_new_file_t()
            fc = f.contents
            fc.filename = _libc.strdup(name.encode("utf-8"))
            fc.filesize = os.path.getsize(local_path)
            fc.filetype = _UPLOAD_TYPES.get(os.path.splitext(name)[1].lower(), FILETYPE_UNKNOWN)
            fc.parent_id = 0 if parent_id == ROOT else parent_id
            fc.storage_id = storage_id
            try:
                if _lib.LIBMTP_Send_File_From_File(dev, local_path.encode(), f, None, None) != 0:
                    raise self._errors("Upload failed.")
                return fc.item_id
            finally:
                _lib.LIBMTP_destroy_file_t(f)

    def mkdir(self, name, storage_id, parent_id):
        with self.lock:
            dev = self._require()
            buf = ctypes.create_string_buffer(name.encode("utf-8"))
            new_id = _lib.LIBMTP_Create_Folder(dev, buf, 0 if parent_id == ROOT else parent_id, storage_id)
            if new_id == 0:
                raise self._errors("Could not create folder.")
            return new_id

    def delete(self, item_id):
        with self.lock:
            dev = self._require()
            if _lib.LIBMTP_Delete_Object(dev, item_id) != 0:
                raise self._errors("Delete failed.")
