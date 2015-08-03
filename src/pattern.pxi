cdef class Pattern:
    cdef readonly int flags
    cdef readonly int groups
    cdef readonly object pattern

    cdef _re2.RE2 * re_pattern
    cdef bint encoded
    cdef object __weakref__

    def search(self, object string, int pos=0, int endpos=-1):
        """Scan through string looking for a match, and return a corresponding
        Match instance. Return None if no position in the string matches."""
        return self._search(string, pos, endpos, _re2.UNANCHORED)

    def match(self, object string, int pos=0, int endpos=-1):
        """Matches zero or more characters at the beginning of the string."""
        return self._search(string, pos, endpos, _re2.ANCHOR_START)

    def findall(self, object string, int pos=0, int endpos=-1):
        """Return all non-overlapping matches of pattern in string as a list
        of strings."""
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int result
        cdef _re2.StringPiece * sp
        cdef list resultlist = []
        cdef int encoded = 0
        cdef _re2.StringPiece * matches

        bytestr = unicode_to_bytes(string, &encoded)
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
                    result = self.re_pattern.Match(
                            sp[0],
                            pos,
                            size,
                            _re2.UNANCHORED,
                            matches,
                            self.groups + 1)
                if result == 0:
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
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int result
        cdef _re2.StringPiece * sp
        cdef Match m
        cdef int encoded = 0
        cdef int cpos = 0, upos = pos

        bytestr = unicode_to_bytes(string, &encoded)
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

            while True:
                m = Match(self, self.groups + 1)
                m.string = string
                with nogil:
                    result = self.re_pattern.Match(
                            sp[0],
                            <int>pos,
                            <int>size,
                            _re2.UNANCHORED,
                            m.matches,
                            self.groups + 1)
                if result == 0:
                    break
                m.encoded = encoded
                m.named_groups = _re2.addressof(
                        self.re_pattern.NamedCapturingGroups())
                m.nmatches = self.groups + 1
                m.pos = pos
                if endpos == -1:
                    m.endpos = size
                else:
                    m.endpos = endpos
                m._make_spans(cstring, size, &cpos, &upos)
                m.init_groups()
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
        cdef int result
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

        bytestr = unicode_to_bytes(string, &encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        try:
            matches = _re2.new_StringPiece_array(self.groups + 1)
            sp = new _re2.StringPiece(cstring, size)

            while True:
                with nogil:
                    result = self.re_pattern.Match(
                            sp[0],
                            pos + lookahead,
                            size,
                            _re2.UNANCHORED,
                            matches,
                            self.groups + 1)
                if result == 0:
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
        return self.subn(repl, string, count)[0]

    def subn(self, repl, string, int count=0):
        """subn(repl, string[, count = 0]) --> (newstring, number of subs)

        Return the tuple (new_string, number_of_subs_made) found by replacing
        the leftmost non-overlapping occurrences of pattern with the
        replacement repl."""
        cdef char * cstring
        cdef Py_ssize_t size
        cdef _re2.cpp_string * fixed_repl
        cdef _re2.StringPiece * sp
        cdef _re2.cpp_string * input_str
        cdef int total_replacements = 0
        cdef int string_encoded = 0
        cdef int repl_encoded = 0

        if callable(repl):
            # This is a callback, so let's use the custom function
            return self._subn_callback(repl, string, count)

        bytestr = unicode_to_bytes(string, &string_encoded)
        repl = unicode_to_bytes(repl, &repl_encoded)
        cstring = <bytes>repl
        size = len(repl)

        fixed_repl = NULL
        cdef _re2.const_char_ptr s = cstring
        cdef _re2.const_char_ptr end = s + size
        cdef int c = 0
        while s < end:
            c = s[0]
            if (c == b'\\'):
                s += 1
                if s == end:
                    raise RegexError("Invalid rewrite pattern")
                c = s[0]
                if c == b'\\' or (c >= b'0' and c <= b'9'):
                    if fixed_repl != NULL:
                        fixed_repl.push_back(b'\\')
                        fixed_repl.push_back(c)
                else:
                    if fixed_repl == NULL:
                        fixed_repl = new _re2.cpp_string(
                                cstring, s - cstring - 1)
                    if c == b'n':
                        fixed_repl.push_back(b'\n')
                    else:
                        fixed_repl.push_back(b'\\')
                        fixed_repl.push_back(b'\\')
                        fixed_repl.push_back(c)
            else:
                if fixed_repl != NULL:
                    fixed_repl.push_back(c)

            s += 1
        if fixed_repl != NULL:
            sp = new _re2.StringPiece(fixed_repl.c_str())
        else:
            sp = new _re2.StringPiece(cstring, size)

        # FIXME: bytestr may be a buffer
        input_str = new _re2.cpp_string(bytestr)
        if not count:
            with nogil:
                total_replacements = _re2.pattern_GlobalReplace(
                        input_str, self.re_pattern[0], sp[0])
        elif count == 1:
            with nogil:
                total_replacements = _re2.pattern_Replace(
                        input_str, self.re_pattern[0], sp[0])
        else:
            del fixed_repl
            del input_str
            del sp
            raise NotImplementedError(
                    "So far pyre2 does not support custom replacement counts")

        if string_encoded or (repl_encoded and total_replacements > 0):
            result = cpp_to_unicode(input_str[0])
        else:
            result = cpp_to_bytes(input_str[0])
        del fixed_repl
        del input_str
        del sp
        return (result, total_replacements)

    def _subn_callback(self, callback, string, int count=0):
        # This function is probably the hardest to implement correctly.
        # This is my first attempt, but if anybody has a better solution,
        # please help out.
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int result
        cdef int endpos
        cdef int pos = 0
        cdef int encoded = 0
        cdef int num_repl = 0
        cdef _re2.StringPiece * sp
        cdef Match m
        cdef list resultlist = []
        cdef int cpos = 0, upos = 0

        if count < 0:
            count = 0

        bytestr = unicode_to_bytes(string, &encoded)
        if pystring_to_cstring(bytestr, &cstring, &size, &buf) == -1:
            raise TypeError('expected string or buffer')
        sp = new _re2.StringPiece(cstring, size)
        try:
            while True:
                m = Match(self, self.groups + 1)
                m.string = string
                with nogil:
                    result = self.re_pattern.Match(
                            sp[0],
                            pos,
                            size,
                            _re2.UNANCHORED,
                            m.matches,
                            self.groups + 1)
                if result == 0:
                    break

                endpos = m.matches[0].data() - cstring
                if encoded:
                    resultlist.append(
                            char_to_unicode(&sp.data()[pos], endpos - pos))
                else:
                    resultlist.append(sp.data()[pos:endpos])
                pos = endpos + m.matches[0].length()

                m.encoded = encoded
                m.named_groups = _re2.addressof(
                        self.re_pattern.NamedCapturingGroups())
                m.nmatches = self.groups + 1
                m._make_spans(cstring, size, &cpos, &upos)
                m.init_groups()
                resultlist.append(callback(m) or '')

                num_repl += 1
                if count and num_repl >= count:
                    break

            if encoded:
                resultlist.append(
                        char_to_unicode(&sp.data()[pos], sp.length() - pos))
                return (u''.join(resultlist), num_repl)
            else:
                resultlist.append(sp.data()[pos:])
                return (b''.join(resultlist), num_repl)
        finally:
            release_cstring(&buf)
            del sp

    cdef _search(self, object string, int pos, int endpos,
            _re2.re2_Anchor anchoring):
        """Scan through string looking for a match, and return a corresponding
        Match instance. Return None if no position in the string matches."""
        cdef char * cstring
        cdef Py_ssize_t size
        cdef Py_buffer buf
        cdef int result
        cdef int encoded = 0
        cdef _re2.StringPiece * sp
        cdef Match m = Match(self, self.groups + 1)
        cdef int cpos = 0, upos = pos

        if 0 <= endpos <= pos:
            return None

        bytestr = unicode_to_bytes(string, &encoded)
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
                result = self.re_pattern.Match(
                        sp[0],
                        <int>pos,
                        <int>size,
                        anchoring,
                        m.matches,
                        self.groups + 1)
            del sp
            if result == 0:
                return None

            m.encoded = encoded
            m.named_groups = _re2.addressof(
                    self.re_pattern.NamedCapturingGroups())
            m.nmatches = self.groups + 1
            m.string = string
            m.pos = pos
            if endpos == -1:
                m.endpos = size
            else:
                m.endpos = endpos
            m._make_spans(cstring, size, &cpos, &upos)
            m.init_groups()
        finally:
            release_cstring(&buf)
        return m

    def __repr__(self):
        return 're2.compile(%r, %r)' % (self.pattern, self.flags)

    def _dump_pattern(self):
        cdef _re2.cpp_string * s
        s = <_re2.cpp_string *>_re2.addressofs(self.re_pattern.pattern())
        return cpp_to_bytes(s[0]).decode('utf8')

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
