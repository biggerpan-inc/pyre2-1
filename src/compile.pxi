
def compile(pattern, int flags=0, int max_mem=8388608):
    cachekey = (type(pattern), pattern, flags)
    if cachekey in _cache:
        return _cache[cachekey]
    p = _compile(pattern, flags, max_mem)

    if len(_cache) >= _MAXCACHE:
        _cache.popitem()
    _cache[cachekey] = p
    return p


WHITESPACE = b' \t\n\r\v\f'


cdef class Tokenizer:
    cdef bytes string
    cdef bytes next
    cdef int length
    cdef int index

    def __init__(self, bytes string):
        self.string = string
        self.length = len(string)
        self.index = 0
        self._next()

    cdef _next(self):
        cdef bytes ch
        if self.index >= self.length:
            self.next = None
            return
        ch = self.string[self.index:self.index + 1]
        if ch[0:1] == b'\\':
            if self.index + 2 > self.length:
                raise RegexError("bogus escape (end of line)")
            ch = self.string[self.index:self.index + 2]
            self.index += 1
        self.index += 1
        # FIXME: return indices instead of creating new bytes objects
        self.next = ch

    cdef bytes get(self):
        cdef bytes this = self.next
        self._next()
        return this


def prepare_pattern(object pattern, int flags):
    cdef bytearray result = bytearray()
    cdef bytes this
    cdef Tokenizer source = Tokenizer(pattern)

    if flags & (_S | _M):
        result.extend(b'(?')
        if flags & _S:
            result.extend(b's')
        if flags & _M:
            result.extend(b'm')
        result.extend(b')')

    while True:
        this = source.get()
        if this is None:
            break
        if flags & _X:
            if this in WHITESPACE:
                continue
            if this == b"#":
                while True:
                    this = source.get()
                    if this in (None, b'\n'):
                        break
                continue

        if this[0:1] != b'[' and this[0:1] != b'\\':
            result.extend(this)
            continue

        elif this == b'[':
            result.extend(this)
            while True:
                this = source.get()
                if this is None:
                    raise RegexError("unexpected end of regular expression")
                elif this == b']':
                    result.extend(this)
                    break
                elif this[0:1] == b'\\':
                    if flags & _U:
                        if this[1:2] == b'd':
                            result.extend(br'\p{Nd}')
                        elif this[1:2] == b'w':
                            result.extend(br'_\p{L}\p{Nd}')
                        elif this[1:2] == b's':
                            result.extend(br'\s\p{Z}')
                        elif this[1:2] == b'D':
                            result.extend(br'\P{Nd}')
                        elif this[1:2] == b'W':
                            # Since \w and \s are made out of several character
                            # groups, I don't see a way to convert their
                            # complements into a group without rewriting the
                            # whole expression, which seems too complicated.
                            raise CharClassProblemException(repr(this))
                        elif this[1:2] == b'S':
                            raise CharClassProblemException(repr(this))
                        else:
                            result.extend(this)
                    else:
                        result.extend(this)
                else:
                    result.extend(this)
        elif this[0:1] == b'\\':
            if b'8' <= this[1:2] <= b'9':
                raise BackreferencesException('%r %r' % (this, pattern))
            elif b'1' <= this[1:2] <= b'7':
                if source.next and source.next in b'1234567':
                    this += source.get()
                    if source.next and source.next in b'1234567':
                        # all clear, this is an octal escape
                        result.extend(this)
                    else:
                        raise BackreferencesException('%r %r' % (this, pattern))
                else:
                    raise BackreferencesException('%r %r' % (this, pattern))
            elif flags & _U:
                if this[1:2] == b'd':
                    result.extend(br'\p{Nd}')
                elif this[1:2] == b'w':
                    result.extend(br'[_\p{L}\p{Nd}]')
                elif this[1:2] == b's':
                    result.extend(br'[\s\p{Z}]')
                elif this[1:2] == b'D':
                    result.extend(br'[^\p{Nd}]')
                elif this[1:2] == b'W':
                    result.extend(br'[^_\p{L}\p{Nd}]')
                elif this[1:2] == b'S':
                    result.extend(br'[^\s\p{Z}]')
                else:
                    result.extend(this)
            else:
                result.extend(this)

    return <bytes>result


def _compile(object pattern, int flags=0, int max_mem=8388608):
    """Compile a regular expression pattern, returning a pattern object."""
    cdef char * string
    cdef Py_ssize_t length
    cdef _re2.StringPiece * s
    cdef _re2.Options opts
    cdef int error_code
    cdef int encoded = 0

    if isinstance(pattern, (Pattern, SREPattern)):
        if flags:
            raise ValueError(
                    'Cannot process flags argument with a compiled pattern')
        return pattern

    cdef object original_pattern = pattern
    pattern = unicode_to_bytes(pattern, &encoded)
    try:
        pattern = prepare_pattern(pattern, flags)
    except BackreferencesException:
        error_msg = "Backreferences not supported"
        if current_notification == FALLBACK_EXCEPTION:
            # Raise an exception regardless of the type of error.
            raise RegexError(error_msg)
        elif current_notification == FALLBACK_WARNING:
            warnings.warn("WARNING: Using re module. Reason: %s" % error_msg)
        return re.compile(original_pattern, flags)
    except CharClassProblemException:
        error_msg = "\W and \S not supported inside character classes"
        if current_notification == FALLBACK_EXCEPTION:
            # Raise an exception regardless of the type of error.
            raise RegexError(error_msg)
        elif current_notification == FALLBACK_WARNING:
            warnings.warn("WARNING: Using re module. Reason: %s" % error_msg)
        return re.compile(original_pattern, flags)

    # Set the options given the flags above.
    if flags & _I:
        opts.set_case_sensitive(0);

    opts.set_max_mem(max_mem)
    opts.set_log_errors(0)
    opts.set_encoding(_re2.EncodingUTF8)

    # We use this function to get the proper length of the string.
    if pystring_to_cstring(pattern, &string, &length) == -1:
        raise TypeError("first argument must be a string or compiled pattern")
    s = new _re2.StringPiece(string, length)

    cdef _re2.RE2 *re_pattern
    with nogil:
         re_pattern = new _re2.RE2(s[0], opts)

    if not re_pattern.ok():
        # Something went wrong with the compilation.
        del s
        error_msg = cpp_to_bytes(re_pattern.error())
        error_code = re_pattern.error_code()
        del re_pattern
        if current_notification == FALLBACK_EXCEPTION:
            # Raise an exception regardless of the type of error.
            raise RegexError(error_msg)
        elif error_code not in (_re2.ErrorBadPerlOp, _re2.ErrorRepeatSize,
                                _re2.ErrorBadEscape):
            # Raise an error because these will not be fixed by using the
            # ``re`` module.
            raise RegexError(error_msg)
        elif current_notification == FALLBACK_WARNING:
            warnings.warn("WARNING: Using re module. Reason: %s" % error_msg)
        return re.compile(original_pattern, flags)

    cdef Pattern pypattern = Pattern()
    pypattern.pattern = original_pattern
    pypattern.re_pattern = re_pattern
    pypattern.groups = re_pattern.NumberOfCapturingGroups()
    pypattern.encoded = encoded
    pypattern.flags = flags
    del s
    return pypattern


