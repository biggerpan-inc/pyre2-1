#!/usr/bin/env python
import sys
import os
import re
from distutils.core import setup, Extension, Command

MINIMUM_CYTHON_VERSION = '0.15'


def cmp(a, b):
    return (a > b) - (a < b)


class TestCommand(Command):
    description = 'Run packaged tests'
    user_options = []
    def initialize_options(self):
        pass

    def finalize_options(self):
        pass

    def run(self):
        from tests import re2_test
        re2_test.testall()


def version_compare(version1, version2):
    def normalize(v):
        return [int(x) for x in re.sub(r'(\.0+)*$','', v).split(".")]
    return cmp(normalize(version1), normalize(version2))

cmdclass = {'test': TestCommand}

ext_files = []
if '--cython' in sys.argv[1:] or not os.path.exists('src/re2.cpp'):
    # Using Cython
    try:
        sys.argv.remove('--cython')
    except ValueError:
        pass
    from Cython.Compiler.Main import Version
    if version_compare(MINIMUM_CYTHON_VERSION, Version.version) > 0:
        raise ValueError("Cython is version %s, but needs to be at least %s." %
                         (Version.version, MINIMUM_CYTHON_VERSION))
    from Cython.Distutils import build_ext
    from Cython.Build import cythonize
    cmdclass['build_ext'] = build_ext
    use_cython = True
else:
    # Building from C
    ext_files.append("src/re2.cpp")
    use_cython = False


# Locate the re2 module
_re2_prefixes = [
    '/usr',
    '/usr/local',
    '/opt/',
]

for re2_prefix in _re2_prefixes:
    if os.path.exists(os.path.join(re2_prefix, "include", "re2")):
        break
else:
    re2_prefix = ""

BASE_DIR = os.path.dirname(__file__)

def get_long_description():
    readme_f = open(os.path.join(BASE_DIR, "README.rst"))
    readme = readme_f.read()
    readme_f.close()
    return readme

def get_authors():
    author_re = re.compile(r'^\s*(.*?)\s+<.*?\@.*?>', re.M)
    authors_f = open(os.path.join(BASE_DIR, "AUTHORS"))
    authors = [match.group(1) for match in author_re.finditer(authors_f.read())]
    authors_f.close()
    return ', '.join(authors)

def main():
    include_dirs = [os.path.join(re2_prefix, "include")] if re2_prefix else []
    libraries = ["re2"]
    library_dirs = [os.path.join(re2_prefix, "lib")] if re2_prefix else []
    runtime_library_dirs = [os.path.join(re2_prefix, "lib")
            ] if re2_prefix else []
    ext_modules = [
        Extension(
            "re2",
            sources=["src/re2.pyx" if use_cython else "src/re2.cpp"],
            language="c++",
            include_dirs=include_dirs,
            libraries=libraries,
            extra_compile_args=['-std=c++11'],
            library_dirs=library_dirs,
            runtime_library_dirs=runtime_library_dirs,
        )]
    if use_cython:
        ext_modules = cythonize(ext_modules,
            language_level=3,
            annotate=True,
            compiler_directives={
                'embedsignature': True,
                'warn.unused': True,
                'warn.unreachable': True,
            })
    setup(
        name="re2",
        version="0.2.23",
        description="Python wrapper for Google's RE2 using Cython",
        long_description=get_long_description(),
        author=get_authors(),
        license="New BSD License",
        author_email = "mike@axiak.net",
        url = "http://github.com/axiak/pyre2/",
        ext_modules = ext_modules,
        cmdclass=cmdclass,
        classifiers = [
            'License :: OSI Approved :: BSD License',
            'Programming Language :: Cython',
            'Programming Language :: Python :: 2.5',
            'Programming Language :: Python :: 2.6',
            'Intended Audience :: Developers',
            'Topic :: Software Development :: Libraries :: Python Modules',
            ],
        )

if __name__ == '__main__':
    main()
