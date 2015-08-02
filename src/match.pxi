
cdef class Match:
    cdef readonly Pattern re
    cdef readonly object string
    cdef readonly int pos
    cdef readonly int endpos

    cdef _re2.StringPiece * matches
    cdef _re2.const_stringintmap * named_groups
    cdef bint encoded
    cdef int nmatches
    cdef int _lastindex
    cdef tuple _groups
    cdef tuple _spans
    cdef dict _named_groups
    cdef dict _named_indexes

    def __init__(self, Pattern pattern_object, int num_groups):
        self._lastindex = -1
        self._groups = None
        self.pos = 0
        self.endpos = -1
        self.matches = _re2.new_StringPiece_array(num_groups + 1)
        self.nmatches = num_groups
        self.re = pattern_object

    def __dealloc__(self):
       _re2.delete_StringPiece_array(self.matches)

    def __repr__(self):
        return '<re2.Match object; span=%r, match=%r>' % (
                (self.pos, self.endpos), self.string)

    cdef init_groups(self):
        cdef list groups = []
        cdef int i

        if self._groups is not None:
            return

        cdef _re2.const_char_ptr last_end = NULL
        cdef _re2.const_char_ptr cur_end = NULL

        for i in range(self.nmatches):
            if self.matches[i].data() == NULL:
                groups.append(None)
            else:
                if i > 0:
                    cur_end = self.matches[i].data() + self.matches[i].length()

                    if last_end == NULL:
                        last_end = cur_end
                        self._lastindex = i
                    else:
                        # The rules for last group are a bit complicated:
                        # if two groups end at the same point, the earlier one
                        # is considered last, so we don't switch our selection
                        # unless the end point has moved.
                        if cur_end > last_end:
                            last_end = cur_end
                            self._lastindex = i
                groups.append(
                        self.matches[i].data()[:self.matches[i].length()])
        self._groups = tuple(groups)

    def groups(self, default=None):
        self.init_groups()
        if self.encoded:
            return tuple([
                g.decode('utf8') if g else default
                for g in self._groups[1:]])
        if default is not None:
            return tuple([g or default for g in self._groups[1:]])
        return self._groups[1:]

    def group(self, *args):
        if len(args) == 0:
            groupnum = 0
        elif len(args) == 1:
            groupnum = args[0]
        else:  # len(args) > 1:
            return tuple([self.group(i) for i in args])
        if self.encoded:
            return self._group(groupnum).decode('utf8')
        return self._group(groupnum)

    cdef bytes _group(self, object groupnum):
        cdef int idx
        self.init_groups()
        if isinstance(groupnum, int):
            idx = groupnum
            if idx > self.nmatches - 1:
                raise IndexError("no such group %d; available groups: %r"
                        % (idx, list(range(self.nmatches))))
            return self._groups[idx]
        groupdict = self._groupdict()
        if groupnum not in groupdict:
            raise IndexError("no such group %r; available groups: %r"
                    % (groupnum, list(groupdict.keys())))
        return groupdict[groupnum]

    cdef list _convert_positions(self, positions):
        cdef char * s
        cdef int cpos = 0
        cdef int upos = 0
        cdef Py_ssize_t size
        cdef int c
        if pystring_to_cstring(self.string, &s, &size) == -1:
            raise TypeError("expected string or buffer")

        new_positions = []
        i = 0
        num_positions = len(positions)
        if positions[i] == -1:
            new_positions.append(-1)
            inc(i)
            if i == num_positions:
                return new_positions
        if positions[i] == 0:
            new_positions.append(0)
            inc(i)
            if i == num_positions:
                return new_positions

        while cpos < size:
            c = <unsigned char>s[cpos]
            if c < 0x80:
                inc(cpos)
                inc(upos)
            elif c < 0xe0:
                cpos += 2
                inc(upos)
            elif c < 0xf0:
                cpos += 3
                inc(upos)
            else:
                cpos += 4
                inc(upos)
                # wide unicode chars get 2 unichars when python is compiled
                # with --enable-unicode=ucs2
                # TODO: verify this
                emit_ifndef_py_unicode_wide()
                inc(upos)
                emit_endif()

            if positions[i] == cpos:
                new_positions.append(upos)
                inc(i)
                if i == num_positions:
                    return new_positions

    def _convert_spans(self, spans):
        positions = [x for x, _ in spans] + [y for _, y in spans]
        positions = sorted(set(positions))
        posdict = dict(zip(positions, self._convert_positions(positions)))

        return [(posdict[x], posdict[y]) for x, y in spans]


    cdef _make_spans(self):
        if self._spans is not None:
            return

        cdef int start, end
        cdef char * s
        cdef Py_ssize_t size
        cdef _re2.StringPiece * piece
        if pystring_to_cstring(self.string, &s, &size) == -1:
            raise TypeError("expected string or buffer")

        spans = []
        for i in range(self.nmatches):
            if self.matches[i].data() == NULL:
                spans.append((-1, -1))
            else:
                piece = &self.matches[i]
                if piece.data() == NULL:
                    return (-1, -1)
                start = piece.data() - s
                end = start + piece.length()
                spans.append((start, end))

        if self.encoded:
            spans = self._convert_spans(spans)

        self._spans = tuple(spans)

    def expand(self, object template):
        """Expand a template with groups."""
        # TODO - This can be optimized to work a bit faster in C.
        if isinstance(template, unicode):
            template = template.encode('utf8')
        items = template.split(b'\\')
        for i, item in enumerate(items[1:]):
            if item[0:1].isdigit():
                # Number group
                if item[0] == b'0':
                    items[i + 1] = b'\x00' + item[1:]  # ???
                else:
                    items[i + 1] = self._group(int(item[0:1])) + item[1:]
            elif item[:2] == b'g<' and b'>' in item:
                # This is a named group
                name, rest = item[2:].split(b'>', 1)
                items[i + 1] = self._group(name) + rest
            else:
                # This isn't a template at all
                items[i + 1] = b'\\' + item
        if self.encoded:
            return b''.join(items).decode('utf8')
        return b''.join(items)

    cdef dict _groupdict(self):
        cdef _re2.stringintmapiterator it
        cdef dict result = {}
        cdef dict indexes = {}

        self.init_groups()

        if self._named_groups:
            return self._named_groups

        self._named_groups = result
        it = self.named_groups.begin()
        while it != self.named_groups.end():
            indexes[cpp_to_bytes(deref(it).first)] = deref(it).second
            result[cpp_to_bytes(deref(it).first)] = self._groups[
                    deref(it).second]
            inc(it)

        self._named_groups = result
        self._named_indexes = indexes
        return result

    def groupdict(self):
        result = self._groupdict()
        if self.encoded:
            return {a.decode('utf8') if isinstance(a, bytes) else a:
                    b.decode('utf8') for a, b in result.items()}
        return result

    def end(self, group=0):
        return self.span(group)[1]

    def start(self, group=0):
        return self.span(group)[0]

    def span(self, group=0):
        self._make_spans()
        if isinstance(group, int):
            if group > len(self._spans):
                raise IndexError("no such group %d; available groups: %r"
                        % (group, list(range(len(self._spans)))))
            return self._spans[group]
        else:
            self._groupdict()
            if self.encoded:
                group = group.encode('utf8')
            if group not in self._named_indexes:
                raise IndexError("no such group %r; available groups: %r"
                        % (group, list(self._named_indexes)))
            return self._spans[self._named_indexes[group]]

    property regs:
        def __get__(self):
            if self._spans is None:
                self._make_spans()
            return self._spans

    property lastindex:
        def __get__(self):
            self.init_groups()
            if self._lastindex < 1:
                return None
            else:
                return self._lastindex

    property lastgroup:
        def __get__(self):
            self.init_groups()
            cdef _re2.stringintmapiterator it

            if self._lastindex < 1:
                return None

            it = self.named_groups.begin()
            while it != self.named_groups.end():
                if deref(it).second == self._lastindex:
                    return cpp_to_bytes(deref(it).first)
                inc(it)

            return None


