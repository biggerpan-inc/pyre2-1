all:
	python setup.py build_ext --cython

install:
	python setup.py install --user --cython

test: all
	cp build/lib*-2.*/re2.so tests/
	(cd tests && python re2_test.py)
	(cd tests && python test_re.py)

py3:
	python3 setup.py build_ext --cython

install3:
	python3 setup.py install --user --cython

test3: py3
	cp build/lib*-3.*/re2*.so tests/re2.so
	(cd tests && python3 re2_test.py)
	(cd tests && python3 test_re.py)

clean:
	rm -rf build &>/dev/null
	rm -rf src/*.so src/*.html &>/dev/null
	rm -rf re2.so tests/re2.so &>/dev/null
	rm -rf src/re2.cpp &>/dev/null
