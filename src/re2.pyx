# cython: infer_types(False)
"""Regular expressions using Google's RE2 engine.

Compared to Python's ``re``, the RE2 engine converts regular expressions to
deterministic finite automata, which guarantees linear-time behavior.

Intended as a drop-in replacement for ``re``. Unicode is supported by encoding
to UTF-8, and bytes strings are treated as UTF-8. For best performance, work
with UTF-8 encoded bytes strings.

Regular expressions that are not compatible with RE2 are processed with
fallback to ``re``. Examples of features not supported by RE2:

    - lookahead assertions ``(?!...)``
    - backreferences (``\\n`` in search pattern)
    - \W and \S not supported inside character classes

On the other hand, unicode character classes are supported.
Syntax reference: https://github.com/google/re2/wiki/Syntax
"""

import sys
import re
import warnings
cimport _re2
cimport cpython.unicode
from cython.operator cimport preincrement as inc, dereference as deref
from cpython.buffer cimport Py_buffer, PyBUF_SIMPLE
from cpython.buffer cimport PyObject_GetBuffer, PyBuffer_Release
from cpython.version cimport PY_MAJOR_VERSION

cdef extern from *:
    cdef int PY2
    cdef void emit_ifndef_py_unicode_wide "#if !defined(Py_UNICODE_WIDE) //" ()
    cdef void emit_endif "#endif //" ()
    ctypedef char* const_char_ptr "const char*"
    ctypedef void* const_void_ptr "const void*"

cdef extern from "Python.h":
    int PY_MAJOR_VERSION
    int PyObject_CheckReadBuffer(object)
    int PyObject_AsReadBuffer(object, const_void_ptr *, Py_ssize_t *)


# Import re flags to be compatible.
I, M, S, U, X, L = re.I, re.M, re.S, re.U, re.X, re.L
IGNORECASE = re.IGNORECASE
MULTILINE = re.MULTILINE
DOTALL = re.DOTALL
UNICODE = re.UNICODE
VERBOSE = re.VERBOSE
LOCALE = re.LOCALE
DEBUG = re.DEBUG

FALLBACK_QUIETLY = 0
FALLBACK_WARNING = 1
FALLBACK_EXCEPTION = 2

VERSION = (0, 2, 23)
VERSION_HEX = 0x000217

cdef int _I = I, _M = M, _S = S, _U = U, _X = X, _L = L
cdef int current_notification = FALLBACK_QUIETLY

# Type of compiled re object from Python stdlib
SREPattern = type(re.compile(''))

_cache = {}
_cache_repl = {}

_MAXCACHE = 100


include "compile.pxi"
include "pattern.pxi"
include "match.pxi"


def search(pattern, string, int flags=0):
    """Scan through string looking for a match to the pattern, returning
    a match object or none if no match was found."""
    return compile(pattern, flags).search(string)


def match(pattern, string, int flags=0):
    """Try to apply the pattern at the start of the string, returning
    a match object, or None if no match was found."""
    return compile(pattern, flags).match(string)


def fullmatch(pattern, string, int flags=0):
    """Try to apply the pattern to the entire string, returning
    a match object, or None if no match was found."""
    return compile(pattern, flags).fullmatch(string)


def finditer(pattern, string, int flags=0):
    """Return an list of all non-overlapping matches in the
    string.  For each match, the iterator returns a match object.

    Empty matches are included in the result."""
    return compile(pattern, flags).finditer(string)


def findall(pattern, string, int flags=0):
    """Return an list of all non-overlapping matches in the
    string.  For each match, the iterator returns a match object.

    Empty matches are included in the result."""
    return compile(pattern, flags).findall(string)


def split(pattern, string, int maxsplit=0, int flags=0):
    """Split the source string by the occurrences of the pattern,
    returning a list containing the resulting substrings."""
    return compile(pattern, flags).split(string, maxsplit)


def sub(pattern, repl, string, int count=0, int flags=0):
    """Return the string obtained by replacing the leftmost
    non-overlapping occurrences of the pattern in string by the
    replacement repl.  repl can be either a string or a callable;
    if a string, backslash escapes in it are processed.  If it is
    a callable, it's passed the match object and must return
    a replacement string to be used."""
    return compile(pattern, flags).sub(repl, string, count)


def subn(pattern, repl, string, int count=0, int flags=0):
    """Return a 2-tuple containing (new_string, number).
    new_string is the string obtained by replacing the leftmost
    non-overlapping occurrences of the pattern in the source
    string by the replacement repl.  number is the number of
    substitutions that were made. repl can be either a string or a
    callable; if a string, backslash escapes in it are processed.
    If it is a callable, it's passed the match object and must
    return a replacement string to be used."""
    return compile(pattern, flags).subn(repl, string, count)


def escape(pattern):
    """Escape all non-alphanumeric characters in pattern."""
    cdef bint uni = isinstance(pattern, unicode)
    cdef list s
    if PY2 or uni:
        s = list(pattern)
    else:
        s = [bytes([c]) for c in pattern]
    for i in range(len(pattern)):
        # c = pattern[i]
        c = s[i]
        if ord(c) < 0x80 and not c.isalnum():
            if uni:
                if c == u'\000':
                    s[i] = u'\\000'
                else:
                    s[i] = u"\\" + c
            else:
                if c == b'\000':
                    s[i] = b'\\000'
                else:
                    s[i] = b'\\' + c
    return u''.join(s) if uni else b''.join(s)


class RegexError(re.error):
    """Some error has occured in compilation of the regex."""
    pass

error = RegexError


class BackreferencesException(Exception):
    """Search pattern contains backreferences."""
    pass


class CharClassProblemException(Exception):
    """Search pattern contains unsupported character class."""
    pass


def set_fallback_notification(level):
    """Set the fallback notification to a level; one of:
        FALLBACK_QUIETLY
        FALLBACK_WARNING
        FALLBACK_EXCEPTION
    """
    global current_notification
    level = int(level)
    if level < 0 or level > 2:
        raise ValueError("This function expects a valid notification level.")
    current_notification = level


cdef bint ishex(unsigned char c):
    """Test whether ``c`` is in ``[0-9a-fA-F]``"""
    return (b'0' <= c <= b'9' or b'a' <= c <= b'f' or b'A' <= c <= b'F')


cdef bint isoct(unsigned char c):
    """Test whether ``c`` is in ``[0-7]``"""
    return b'0' <= c <= b'7'


cdef bint isdigit(unsigned char c):
    """Test whether ``c`` is in ``[0-9]``"""
    return b'0' <= c <= b'9'


cdef bint isident(unsigned char c):
    """Test whether ``c`` is in ``[a-zA-Z0-9_]``"""
    return (b'a' <= c <= b'z' or b'A' <= c <= b'Z'
        or b'0' <= c <= b'9' or c == b'_')


cdef inline bytes cpp_to_bytes(_re2.cpp_string input):
    """Convert from a std::string object to a python string."""
    # By taking the slice we go to the right size,
    # despite spurious or missing null characters.
    return input.data()[:input.length()]


cdef inline unicode cpp_to_unicode(_re2.cpp_string input):
    """Convert a std::string object to a unicode string."""
    return cpython.unicode.PyUnicode_DecodeUTF8(
            input.data(), input.length(), 'strict')


cdef inline unicode char_to_unicode(_re2.const_char_ptr input, int length):
    """Convert a C string to a unicode string."""
    return cpython.unicode.PyUnicode_DecodeUTF8(input, length, 'strict')


cdef inline unicode_to_bytes(object pystring, int * encoded,
        int checkotherencoding):
    """Convert a unicode string to a utf8 bytes object, if necessary.

    If pystring is a bytes string or a buffer, return unchanged.
    If checkotherencoding is 0 or 1 and using Python 3, raise an error
    if encoded is not equal to it."""
    if cpython.unicode.PyUnicode_Check(pystring):
        pystring = pystring.encode('utf8')
        encoded[0] = 1
    else:
        encoded[0] = 0
    if not PY2 and checkotherencoding > 0 and not encoded[0]:
        raise TypeError("can't use a string pattern on a bytes-like object")
    elif not PY2 and checkotherencoding == 0 and encoded[0]:
        raise TypeError("can't use a bytes pattern on a string-like object")
    return pystring


cdef inline int pystring_to_cstring(
        object pystring, char ** cstring, Py_ssize_t * size,
        Py_buffer * buf):
    """Get a pointer from a bytes/buffer object."""
    cdef int result = -1
    cstring[0] = NULL
    size[0] = 0

    if PY2:
        if PyObject_CheckReadBuffer(pystring) == 1:
            result = PyObject_AsReadBuffer(
                    pystring, <const_void_ptr *>cstring, size)
    else:  # Python 3
        result = PyObject_GetBuffer(pystring, buf, PyBUF_SIMPLE)
        if result == 0:
            cstring[0] = <char *>buf.buf
            size[0] = buf.len
    return result


cdef inline void release_cstring(Py_buffer *buf):
    """Release buffer if necessary."""
    if not PY2:
        PyBuffer_Release(buf)


cdef utf8indices(char * cstring, int size, int *pos, int *endpos):
    """Convert unicode indices ``pos`` and ``endpos`` to UTF-8 indices.

    If the indices are out of range, leave them unchanged."""
    cdef unsigned char * data = <unsigned char *>cstring
    cdef int newpos = pos[0], newendpos = -1
    cdef int cpos = 0, upos = 0
    while cpos < size:
        if data[cpos] < 0x80:
            cpos += 1
            upos += 1
        elif data[cpos] < 0xe0:
            cpos += 2
            upos += 1
        elif data[cpos] < 0xf0:
            cpos += 3
            upos += 1
        else:
            cpos += 4
            upos += 1
            # wide unicode chars get 2 unichars when python is compiled
            # with --enable-unicode=ucs2
            # TODO: verify this
            emit_ifndef_py_unicode_wide()
            upos += 1
            emit_endif()

        if upos == pos[0]:
            newpos = cpos
            if endpos[0] == -1:
                break
        elif upos == endpos[0]:
            newendpos = cpos
            break
    pos[0] = newpos
    endpos[0] = newendpos


cdef list unicodeindices(list positions,
        char * cstring, int size, int * cpos, int * upos):
    """Convert a list of UTF-8 byte indices to unicode indices."""
    cdef unsigned char * s = <unsigned char *>cstring
    cdef int i = 0
    cdef list result = []

    if positions[i] == -1:
        result.append(-1)
        i += 1
        if i == len(positions):
            return result
    if positions[i] == cpos[0]:
        result.append(upos[0])
        i += 1
        if i == len(positions):
            return result

    while cpos[0] < size:
        if s[cpos[0]] < 0x80:
            cpos[0] += 1
            upos[0] += 1
        elif s[cpos[0]] < 0xe0:
            cpos[0] += 2
            upos[0] += 1
        elif s[cpos[0]] < 0xf0:
            cpos[0] += 3
            upos[0] += 1
        else:
            cpos[0] += 4
            upos[0] += 1
            # wide unicode chars get 2 unichars when python is compiled
            # with --enable-unicode=ucs2
            # TODO: verify this
            emit_ifndef_py_unicode_wide()
            upos[0] += 1
            emit_endif()

        if positions[i] == cpos[0]:
            result.append(upos[0])
            i += 1
            if i == len(positions):
                break
    return result
