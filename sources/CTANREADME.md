## enumext — Enumerate exercise sheets

Release v1.0 \[2024-10-29\]

## Description

This package provides enumerated list environments compatible with
_tagging_ PDF for creating “simple exercise sheets” along with
“multiple choice questions”, storing the “answers” to these in memory
using <code>&langle;multicol&rangle;</code> and <code>&langle;scontents&rangle;</code> packages.

## Requirements

The minimum requirement is LaTeX release 2024-11-01. Loads and depends
on updated versions of:

- [scontents](https://ctan.org/pkg/scontents)
- [multicol](https://ctan.org/pkg/multicol)

## Installation

The <code>&langle;enumext&rangle;</code> package is present in TeX Live and MiKTeX, use the
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

## License

The <code>&langle;enumext&rangle;</code> package may be modified and distributed under the terms and
conditions of the [LaTeX Project Public License](https://www.latex-project.org/lppl/), version 1.3c or greater.

## Contents

- &langle;`README.md`&rangle; \(this file\)
- &langle;`enumext.pdf`&rangle; \(documentation\)
- &langle;`enumext.dtx`&rangle; \(master file that produced all files\)
- &langle;`enumext.ins`&rangle; \(installer to extract all files\)

## Author and copyright

Copyright &#169; 2024 by Pablo González L <pablgonz@educarchile.cl>
