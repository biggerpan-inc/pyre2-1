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
    cdef void emit_ifndef_py_unicode_wide "#if !defined(Py_UNICODE_WIDE) //" ()
    cdef void emit_if_py2 "#if PY_MAJOR_VERSION == 2 //" ()
    cdef void emit_else "#else //" ()
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
    s = list(pattern)
    for i in range(len(pattern)):
        c = pattern[i]
        if ord(c) < 0x80 and not c.isalnum():
            if c == "\000":
                s[i] = "\\000"
            else:
                s[i] = "\\" + c
    return pattern[:0].join(s)


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


cdef inline bytes cpp_to_bytes(_re2.cpp_string input):
    """Convert from a std::string object to a python string."""
    # By taking the slice we go to the right size,
    # despite spurious or missing null characters.
    return input.c_str()[:input.length()]


cdef inline unicode cpp_to_unicode(_re2.cpp_string input):
    """Convert a std::string object to a unicode string."""
    return cpython.unicode.PyUnicode_DecodeUTF8(
            input.c_str(), input.length(), 'strict')


cdef inline unicode char_to_unicode(_re2.const_char_ptr input, int length):
    """Convert a C string to a unicode string."""
    return cpython.unicode.PyUnicode_DecodeUTF8(input, length, 'strict')


cdef inline unicode_to_bytes(object pystring, int * encoded):
    """Convert a unicode string to a utf8 bytes object, if necessary.

    If pystring is a bytes string or a buffer, return unchanged."""
    if cpython.unicode.PyUnicode_Check(pystring):
        encoded[0] = 1
        return pystring.encode('utf8')
    encoded[0] = 0
    return pystring


cdef inline int pystring_to_cstring(
        object pystring, char ** cstring, Py_ssize_t * size,
        Py_buffer * buf):
    """Get a pointer from a bytes/buffer object."""
    cdef int result = -1
    cstring[0] = NULL
    size[0] = 0

    emit_if_py2()
    if PyObject_CheckReadBuffer(pystring) == 1:
        result = PyObject_AsReadBuffer(
                pystring, <const_void_ptr *>cstring, size)

    emit_else()
    # Python 3
    result = PyObject_GetBuffer(pystring, buf, PyBUF_SIMPLE)
    if result == 0:
        cstring[0] = <char *>buf.buf
        size[0] = buf.len

    emit_endif()
    return result


cdef inline void release_cstring(Py_buffer *buf):
    """Release buffer if necessary."""
    emit_if_py2()
    pass
    emit_else()
    # Python 3
    PyBuffer_Release(buf)
    emit_endif()
