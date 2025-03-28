## enumext — Enumerate exercise sheets
![GitHub release (latest by date)](https://img.shields.io/github/v/release/pablgonz/enumext?label=version)
![GitHub Release Date](https://img.shields.io/github/release-date/pablgonz/enumext)
![GitHub last commit](https://img.shields.io/github/last-commit/pablgonz/enumext)

## Description

This package provides enumerated list environments compatible with
_tagging_ PDF for creating “simple exercise sheets” along with
“multiple choice questions”, storing the “answers” to these in memory
using <code>&langle;multicol&rangle;</code> and <code>&langle;scontents&rangle;</code> packages.


## Requirements

The minimum requirement is `LaTeX` release 2024-11-01. Loads and depends on updated versions of:

- [scontents](https://ctan.org/pkg/scontents)
- [multicol](https://ctan.org/pkg/multicol)

## Installation

The <code>&langle;enumext&rangle;</code> package is present in [TeX Live](https://www.tug.org/texlive/) and [MiKTeX](https://miktex.org/), use the
package manager to install.

For manual installation, download [enumext.zip](http://mirrors.ctan.org/macros/latex/contrib/enumext.zip) and unzip it,
then run:

```
$ luatex enumext.ins
```

and move all files to appropriate locations:

```
  enumext.sty  ->  TDS:tex/latex/enumext/enumext.sty
  enumext.pdf  ->  TDS:doc/latex/enumext/enumext.pdf
  README.md    ->  TDS:doc/latex/enumext/README.md
  enumext.dtx  ->  TDS:source/latex/enumext/enumext.dtx
  enumext.ins  ->  TDS:source/latex/enumext/enumext.ins
```

then run `mktexlsr`. To produce the documentation with source code run `arara enumext.dtx`.

## Examples

The file <code>&langle;enumext.pdf&rangle;</code> contains attached examples, which can be extracted
from the PDF viewer or from the command line by running:

```
$ pdfdetach -saveall enumext.pdf
```

and then you can use the excellent `arara` tool to compile them.

## Development

The version numbers and dates are guaranteed to be correct in
the repository is in the `l3build` configuration file `build.lua`.

The date format is `YYYY-MM-DD`. If it is important to you
that the files created have the correct version and date, you should run
`l3build tag` before any other build-related task.

You can run:

- `l3build unpack` to extract the code files into the directory `build/unpacked/`.
- `l3build doc` to build the documentation.
- `l3build install` put all files  in your `TEXMFHOME`.
- `l3build uninstall` will remove them.
- `l3build testpkg` to test files.
- `l3build examples` to compile example files.

## License

The <code>&langle;enumext&rangle;</code> package may be modified and distributed under the terms and
conditions of the [LaTeX Project Public License](https://www.latex-project.org/lppl/), version 1.3c or greater.

## Content of the repository

```
├── README.md
├── build.lua
├── ctan.ann
└── sources
    ├── CTANREADME.md
    ├── enumext.dtx
    ├── enumext.ins
    ├── enumext.sty
    └── test-pkg
        ├── enumext-01.tex
        ├── enumext-02.tex
        ├── enumext-03.tex
        ├── enumext-04.tex
        ├── enumext-05.tex
        ├── enumext-06.tex     
```

## Copyright

Copyright &#169; 2024-2025 by Pablo González L <pablgonz@educarchile.cl>
