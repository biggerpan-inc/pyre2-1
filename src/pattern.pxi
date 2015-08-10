cdef class Pattern:
    cdef readonly object pattern  # original pattern in Python format
    cdef readonly int flags
    cdef readonly int groups  # number of groups
    cdef readonly dict groupindex  # name => group number
    cdef object __weakref__

    cdef bint encoded  # True if this was originally a Unicode pattern
    cdef _re2.RE2 * re_pattern

    def search(self, object string, int pos=0, int endpos=-1):
        """Scan through string looking for a match, and return a corresponding
        Match instance. Return None if no position in the string matches."""
        return self._search(string, pos, endpos, _re2.UNANCHORED)

    def match(self, object string, int pos=0, int endpos=-1):
        """Matches zero or more characters at the beginning of the string."""
        return self._search(string, pos, endpos, _re2.ANCHOR_START)

    def fullmatch(self, object string, int pos=0, int endpos=-1):
        """"fullmatch(string[, pos[, endpos]]) --> Match object or None."

        Matches the entire string."""
        return self._search(string, pos, endpos, _re2.ANCHOR_BOTH)

    cdef _search(self, object string, int pos, int endpos,
            _re2.re2_Anchor anchoring):
        """Scan through string looking for a match, and return a corresponding
        Match instance. Return None if no position in the string matches."""
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int retval
        cdef int encoded = 0
        cdef _re2.StringPiece * sp
        cdef Match m = Match(self, self.groups + 1)
        cdef int cpos = 0, upos = pos

        if 0 <= endpos <= pos:
            return None

        bytestr = unicode_to_bytes(string, &encoded, self.encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        try:
            if encoded and (pos or endpos != -1):
                utf8indices(cstring, size, &pos, &endpos)
                cpos = pos
            if pos > size:
                return None
            if 0 <= endpos < size:
                size = endpos

            sp = new _re2.StringPiece(cstring, size)
            with nogil:
                retval = self.re_pattern.Match(
                        sp[0],
                        pos,
                        size,
                        anchoring,
                        m.matches,
                        self.groups + 1)
            del sp
            if retval == 0:
                return None

            m.encoded = encoded
            m.nmatches = self.groups + 1
            m.string = string
            m.pos = pos
            if endpos == -1:
                m.endpos = size
            else:
                m.endpos = endpos
            m._make_spans(cstring, size, &cpos, &upos)
            m._init_groups()
        finally:
            release_cstring(&buf)
        return m

    def findall(self, object string, int pos=0, int endpos=-1):
        """Return all non-overlapping matches of pattern in string as a list
        of strings."""
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int retval
        cdef _re2.StringPiece * sp
        cdef list resultlist = []
        cdef int encoded = 0
        cdef _re2.StringPiece * matches

        bytestr = unicode_to_bytes(string, &encoded, self.encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        try:
            if encoded and (pos or endpos != -1):
                utf8indices(cstring, size, &pos, &endpos)
            if pos > size:
                return []
            if 0 <= endpos < size:
                size = endpos

            sp = new _re2.StringPiece(cstring, size)
            matches = _re2.new_StringPiece_array(self.groups + 1)

            while True:
                with nogil:
                    retval = self.re_pattern.Match(
                            sp[0],
                            pos,
                            size,
                            _re2.UNANCHORED,
                            matches,
                            self.groups + 1)
                if retval == 0:
                    break
                if self.groups > 1:
                    if encoded:
                        resultlist.append(tuple([
                            '' if matches[i].data() is NULL else
                            matches[i].data()[:matches[i].length()
                                ].decode('utf8')
                            for i in range(1, self.groups + 1)]))
                    else:
                        resultlist.append(tuple([
                            b'' if matches[i].data() is NULL
                            else matches[i].data()[:matches[i].length()]
                            for i in range(1, self.groups + 1)]))
                else:
                    if encoded:
                        resultlist.append(matches[self.groups].data()[
                            :matches[self.groups].length()].decode('utf8'))
                    else:
                        resultlist.append(matches[self.groups].data()[
                            :matches[self.groups].length()])
                if pos == size:
                    break
                # offset the pos to move to the next point
                if matches[0].length() == 0:
                    pos += 1
                else:
                    pos = matches[0].data() - cstring + matches[0].length()
        finally:
            release_cstring(&buf)
        del sp
        return resultlist

    def finditer(self, object string, int pos=0, int endpos=-1):
        """Yield all non-overlapping matches of pattern in string as Match
        objects."""
        result = iter(self._finditer(string, pos, endpos))
        next(result)  # dummy value to raise error before start of generator
        return result

    def _finditer(self, object string, int pos=0, int endpos=-1):
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int retval
        cdef _re2.StringPiece * sp
        cdef Match m
        cdef int encoded = 0
        cdef int cpos = 0, upos = pos

        bytestr = unicode_to_bytes(string, &encoded, self.encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        try:
            if encoded and (pos or endpos != -1):
                utf8indices(cstring, size, &pos, &endpos)
                cpos = pos
            if pos > size:
                return
            if 0 <= endpos < size:
                size = endpos

            sp = new _re2.StringPiece(cstring, size)

            yield
            while True:
                m = Match(self, self.groups + 1)
                m.string = string
                with nogil:
                    retval = self.re_pattern.Match(
                            sp[0],
                            pos,
                            size,
                            _re2.UNANCHORED,
                            m.matches,
                            self.groups + 1)
                if retval == 0:
                    break
                m.encoded = encoded
                m.nmatches = self.groups + 1
                m.pos = pos
                if endpos == -1:
                    m.endpos = size
                else:
                    m.endpos = endpos
                m._make_spans(cstring, size, &cpos, &upos)
                m._init_groups()
                yield m
                if pos == size:
                    break
                # offset the pos to move to the next point
                if m.matches[0].length() == 0:
                    pos += 1
                else:
                    pos = m.matches[0].data() - cstring + m.matches[0].length()
        finally:
            release_cstring(&buf)
        del sp

    def split(self, string, int maxsplit=0):
        """split(string[, maxsplit = 0]) --> list

        Split a string by the occurrences of the pattern."""
        cdef char * cstring
        cdef Py_ssize_t size
        cdef int retval
        cdef int pos = 0
        cdef int lookahead = 0
        cdef int num_split = 0
        cdef _re2.StringPiece * sp
        cdef _re2.StringPiece * matches
        cdef list resultlist = []
        cdef int encoded = 0
        cdef Py_buffer buf

        if maxsplit < 0:
            maxsplit = 0

        bytestr = unicode_to_bytes(string, &encoded, self.encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        try:
            matches = _re2.new_StringPiece_array(self.groups + 1)
            sp = new _re2.StringPiece(cstring, size)

            while True:
                with nogil:
                    retval = self.re_pattern.Match(
                            sp[0],
                            pos + lookahead,
                            size,
                            _re2.UNANCHORED,
                            matches,
                            self.groups + 1)
                if retval == 0:
                    break

                match_start = matches[0].data() - cstring
                match_end = match_start + matches[0].length()

                # If an empty match, just look ahead until you find something
                if match_start == match_end:
                    if pos + lookahead == size:
                        break
                    lookahead += 1
                    continue

                if encoded:
                    resultlist.append(
                            char_to_unicode(&sp.data()[pos], match_start - pos))
                else:
                    resultlist.append(sp.data()[pos:match_start])
                if self.groups > 0:
                    for group in range(self.groups):
                        if matches[group + 1].data() == NULL:
                            resultlist.append(None)
                        else:
                            if encoded:
                                resultlist.append(char_to_unicode(
                                        matches[group + 1].data(),
                                        matches[group + 1].length()))
                            else:
                                resultlist.append(matches[group + 1].data()[:
                                        matches[group + 1].length()])

                # offset the pos to move to the next point
                pos = match_end
                lookahead = 0

                num_split += 1
                if maxsplit and num_split >= maxsplit:
                    break

            if encoded:
                resultlist.append(
                        char_to_unicode(&sp.data()[pos], sp.length() - pos))
            else:
                resultlist.append(sp.data()[pos:])
            _re2.delete_StringPiece_array(matches)
        finally:
            release_cstring(&buf)
        del sp
        return resultlist

    def sub(self, repl, string, int count=0):
        """sub(repl, string[, count = 0]) --> newstring

        Return the string obtained by replacing the leftmost non-overlapping
        occurrences of pattern in string by the replacement repl."""
        cdef int num_repl = 0
        return self._subn(repl, string, count, &num_repl)

    def subn(self, repl, string, int count=0):
        """subn(repl, string[, count = 0]) --> (newstring, number of subs)

        Return the tuple (new_string, number_of_subs_made) found by replacing
        the leftmost non-overlapping occurrences of pattern with the
        replacement repl."""
        cdef int num_repl = 0
        result = self._subn(repl, string, count, &num_repl)
        return result, num_repl

    cdef _subn(self, repl, string, int count, int *num_repl):
        cdef bytes repl_b
        cdef char * cstring
        cdef object result
        cdef Py_ssize_t size
        cdef _re2.cpp_string * fixed_repl = NULL
        cdef _re2.StringPiece * sp
        cdef _re2.cpp_string * input_str
        cdef int string_encoded = 0
        cdef int repl_encoded = 0

        if callable(repl):
            # This is a callback, so let's use the custom function
            return self._subn_callback(repl, string, count, num_repl)

        repl_b = unicode_to_bytes(repl, &repl_encoded, self.encoded)
        if not repl_encoded and not isinstance(repl, bytes):
            repl_b = bytes(repl)  # coerce buffer to bytes object

        if count > 1 or (b'\\' if PY2 else <char>b'\\') in repl_b:
            # Limit on number of substitution or replacement string contains
            # escape sequences, handle with Match.expand() implementation.
            # RE2 does support simple numeric group references \1, \2,
            # but the number of differences with Python behavior is
            # non-trivial.
            return self._subn_expand(repl_b, string, count, num_repl)

        cstring = repl_b
        size = len(repl_b)
        sp = new _re2.StringPiece(cstring, size)

        bytestr = unicode_to_bytes(string, &string_encoded, self.encoded)
        if not string_encoded and not isinstance(bytestr, bytes):
            bytestr = bytes(bytestr)  # coerce buffer to bytes object
        input_str = new _re2.cpp_string(bytestr, len(bytestr))
        # NB: RE2 treats unmatched groups in repl as empty string;
        # Python raises an error.
        with nogil:
            if count == 0:
                num_repl[0] = _re2.pattern_GlobalReplace(
                        input_str, self.re_pattern[0], sp[0])
            elif count == 1:
                num_repl[0] = _re2.pattern_Replace(
                        input_str, self.re_pattern[0], sp[0])

        if string_encoded or (repl_encoded and num_repl[0] > 0):
            result = cpp_to_unicode(input_str[0])
        else:
            result = cpp_to_bytes(input_str[0])
        del fixed_repl, input_str, sp
        return result

    cdef _subn_callback(self, callback, string, int count, int * num_repl):
        # This function is probably the hardest to implement correctly.
        # This is my first attempt, but if anybody has a better solution,
        # please help out.
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int retval
        cdef int endpos
        cdef int pos = 0
        cdef int encoded = 0
        cdef _re2.StringPiece * sp
        cdef Match m
        cdef bytearray result = bytearray()
        cdef int cpos = 0, upos = 0

        if count < 0:
            count = 0

        bytestr = unicode_to_bytes(string, &encoded, self.encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        sp = new _re2.StringPiece(cstring, size)
        try:
            while True:
                m = Match(self, self.groups + 1)
                m.string = string
                with nogil:
                    retval = self.re_pattern.Match(
                            sp[0],
                            pos,
                            size,
                            _re2.UNANCHORED,
                            m.matches,
                            self.groups + 1)
                if retval == 0:
                    break

                endpos = m.matches[0].data() - cstring
                result.extend(sp.data()[pos:endpos])
                pos = endpos + m.matches[0].length()

                m.encoded = encoded
                m.nmatches = self.groups + 1
                m._make_spans(cstring, size, &cpos, &upos)
                m._init_groups()
                tmp = callback(m)
                if tmp:
                    result.extend(tmp.encode('utf8') if encoded else tmp)
                else:
                    result.extend(b'')

                num_repl[0] += 1
                if count and num_repl[0] >= count:
                    break
            result.extend(sp.data()[pos:])
        finally:
            release_cstring(&buf)
            del sp
        return result.decode('utf8') if encoded else bytes(result)

    cdef _subn_expand(self, bytes repl, string, int count, int * num_repl):
        """Perform ``count`` substitutions with replacement string and
        Match.expand."""
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int retval
        cdef int endpos
        cdef int pos = 0
        cdef int encoded = 0
        cdef _re2.StringPiece * sp
        cdef Match m
        cdef bytearray result = bytearray()

        if count < 0:
            count = 0

        bytestr = unicode_to_bytes(string, &encoded, self.encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        sp = new _re2.StringPiece(cstring, size)
        try:
            while True:
                m = Match(self, self.groups + 1)
                m.string = string
                with nogil:
                    retval = self.re_pattern.Match(
                            sp[0],
                            pos,
                            size,
                            _re2.UNANCHORED,
                            m.matches,
                            self.groups + 1)
                if retval == 0:
                    break

                endpos = m.matches[0].data() - cstring
                result.extend(sp.data()[pos:endpos])
                pos = endpos + m.matches[0].length()

                m.encoded = encoded
                m.nmatches = self.groups + 1
                m._init_groups()
                m._expand(repl, result)

                num_repl[0] += 1
                if count and num_repl[0] >= count:
                    break
            result.extend(sp.data()[pos:])
        finally:
            release_cstring(&buf)
            del sp
        return result.decode('utf8') if encoded else bytes(result)

    def scanner(self, arg):
        return re.compile(self.pattern).scanner(arg)
        # raise NotImplementedError

    def _dump_pattern(self):
        cdef _re2.cpp_string * s
        s = <_re2.cpp_string *>_re2.addressofs(self.re_pattern.pattern())
        if self.encoded:
            return cpp_to_bytes(s[0]).decode('utf8')
        return cpp_to_bytes(s[0])

    def __repr__(self):
        if self.flags == 0:
            return 're2.compile(%r)' % self.pattern
        return 're2.compile(%r, %r)' % (self.pattern, self.flags)

    def __reduce__(self):
        return (compile, (self.pattern, self.flags))

    def __dealloc__(self):
        del self.re_pattern


cdef utf8indices(char * cstring, int size, int *pos, int *endpos):
    """Convert unicode indices pos and endpos to UTF-8 indices.

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
