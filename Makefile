install:
	python setup.py install --user --cython

test: install
	(cd tests && python re2_test.py)
	(cd tests && python test_re.py)

install3:
	python3 setup.py install --user --cython

test3: install3
	(cd tests && python3 re2_test.py)
	(cd tests && python3 test_re.py)

clean:
	rm -rf build &>/dev/null
	rm -rf src/*.so src/*.html &>/dev/null
	rm -rf re2.so tests/re2.so &>/dev/null
	rm -rf src/re2.cpp &>/dev/null

valgrind:
	python3.5-dbg setup.py install --user --cython && \
	(cd tests && valgrind --tool=memcheck --suppressions=../valgrind-python.supp \
	--leak-check=full --show-leak-kinds=definite \
	python3.5-dbg test_re.py)

valgrind2:
	python3.5-dbg setup.py install --user --cython && \
	(cd tests && valgrind --tool=memcheck --suppressions=../valgrind-python.supp \
	--leak-check=full --show-leak-kinds=definite \
	python3.5-dbg re2_test.py)
