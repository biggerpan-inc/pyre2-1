
def compile(pattern, int flags=0, int max_mem=8388608):
    cachekey = (type(pattern), pattern, flags)
    if cachekey in _cache:
        return _cache[cachekey]
    p = _compile(pattern, flags, max_mem)

    if len(_cache) >= _MAXCACHE:
        _cache.popitem()
    _cache[cachekey] = p
    return p


def prepare_pattern(bytes pattern, int flags):
    cdef bytearray result = bytearray()
    cdef unsigned char this, that
    cdef unsigned char * cstring = pattern
    cdef int size = len(pattern)
    cdef int n = 0

    if flags & (_S | _M):
        result.extend(b'(?')
        if flags & _S:
            result.extend(b's')
        if flags & _M:
            result.extend(b'm')
        result.extend(b')')
    while n < size:
        this = cstring[n]
        if flags & _X:
            if this in b' \t\n\r\f\v':
                n += 1
                continue
            elif this == b'#':
                while True:
                    n += 1
                    if n >= size:
                        break
                    this = cstring[n]
                    if this == b'\n':
                        break
                n += 1
                continue
        if this != b'[' and this != b'\\':
            try:
                result.append(this)
            except:
                raise ValueError(repr(this))
            n += 1
            continue

        if this != b'[' and this != b'\\':
            result.append(this)
            n += 1
            continue

        elif this == b'[':
            result.append(this)
            while True:
                n += 1
                if n >= size:
                    raise RegexError("unexpected end of regular expression")
                this = cstring[n]
                if this == b']':
                    result.append(this)
                    break
                elif this == b'\\':
                    n += 1
                    that = cstring[n]
                    if flags & _U:
                        if that == b'd':
                            result.extend(br'\p{Nd}')
                        elif that == b'w':
                            result.extend(br'_\p{L}\p{Nd}')
                        elif that == b's':
                            result.extend(br'\s\p{Z}')
                        elif that == b'D':
                            result.extend(br'\P{Nd}')
                        elif that == b'W':
                            # Since \w and \s are made out of several character
                            # groups, I don't see a way to convert their
                            # complements into a group without rewriting the
                            # whole expression, which seems too complicated.
                            raise CharClassProblemException()
                        elif that == b'S':
                            raise CharClassProblemException()
                        else:
                            result.append(this)
                            result.append(that)
                    else:
                        result.append(this)
                        result.append(that)
                else:
                    result.append(this)
        elif this == b'\\':
            n += 1
            that = cstring[n]
            if b'8' <= that <= b'9':
                raise BackreferencesException()
            elif b'1' <= that <= b'7':
                if n + 1 < size and cstring[n + 1] in b'1234567':
                    n += 1
                    if n + 1 < size and cstring[n + 1] in b'1234567':
                        # all clear, this is an octal escape
                        result.append(this)
                        result.append(that)
                        result.append(cstring[n])
                    else:
                        raise BackreferencesException()
                else:
                    raise BackreferencesException()
            elif flags & _U:
                if that == b'd':
                    result.extend(br'\p{Nd}')
                elif that == b'w':
                    result.extend(br'[_\p{L}\p{Nd}]')
                elif that == b's':
                    result.extend(br'[\s\p{Z}]')
                elif that == b'D':
                    result.extend(br'[^\p{Nd}]')
                elif that == b'W':
                    result.extend(br'[^_\p{L}\p{Nd}]')
                elif that == b'S':
                    result.extend(br'[^\s\p{Z}]')
                else:
                    result.append(this)
                    result.append(that)
            else:
                result.append(this)
                result.append(that)
        n += 1
    return <bytes>result


def _compile(object pattern, int flags=0, int max_mem=8388608):
    """Compile a regular expression pattern, returning a pattern object."""
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

    s = new _re2.StringPiece(<char *><bytes>pattern, len(pattern))

    cdef _re2.RE2 *re_pattern
    with nogil:
         re_pattern = new _re2.RE2(s[0], opts)

    if not re_pattern.ok():
        # Something went wrong with the compilation.
        del s
        error_msg = cpp_to_unicode(re_pattern.error())
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


