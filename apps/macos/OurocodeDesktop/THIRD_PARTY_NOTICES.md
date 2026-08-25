# Third-Party Notices

Ourocode Desktop includes the software listed below. The Rust inventory is the
normal and build dependency closure of the bundled `ouro-broker` executable for
Apple targets, resolved from the workspace `Cargo.lock`. Development-only and
non-Apple target dependencies are not shipped in that executable.

## SwiftTerm

- Project: <https://github.com/migueldeicaza/SwiftTerm>
- Pinned revision: `e4f31b091b2efd81b33945ef7609141f827f2753`
- License: MIT

Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

## MesloLGS Nerd Font Mono

- Project: <https://github.com/ryanoasis/nerd-fonts>
- Pinned release: `v3.5.0`, asset `Meslo.tar.xz`
- Asset SHA-256: `24cfe8148aeb600891f1d81180e77ecc967a814cde75dc7e63ec5bc2b0ab3eef`
- Bundled face SHA-256: `7c22b7d11557e59c1ffdb12468c674a6b2d5c322e641b78cf8782ac2c3f84df9`
- License: Apache-2.0

Copyright 2009, 2010, 2013 André Berg

The complete upstream font license is bundled beside the font at
`Fonts/LICENSE-Meslo-Nerd-Font.txt`.


## cua-rs

- Project: <https://github.com/maestrojeong/cua-rs-mcp>
- Pinned release: `v0.9.1`
- Components: `cua-rs`, `cua-overlay`
- License: Apache-2.0

Ourocode uses the upstream binaries through the MCP bridge and does not copy
the upstream Rust sources into the desktop target. The compatibility helper
`scripts/ourocode-cua-mcp-bridge` is Ourocode code and exists only because the
pinned CUA release closes its stdio session on Ouroboros's modern discovery
probe instead of returning the legacy method-not-found response.

## Rust crates in ouro-broker

The following versions are fixed by the workspace `Cargo.lock`. Where an
upstream package offers a choice of MIT or Apache-2.0, this distribution uses
the MIT option. Proc-macro crates are listed because generated code from them is
compiled into the executable.

| Package | Version | License used here | Project |
| --- | --- | --- | --- |
| arrayvec | 0.7.8 | MIT | <https://github.com/bluss/arrayvec> |
| base64 | 0.22.1 | MIT | <https://github.com/marshallpierce/rust-base64> |
| cfg-if | 1.0.4 | MIT | <https://github.com/rust-lang/cfg-if> |
| getrandom | 0.2.17 | MIT | <https://github.com/rust-random/getrandom> |
| itoa | 1.0.18 | MIT | <https://github.com/dtolnay/itoa> |
| libc | 0.2.189 | MIT | <https://github.com/rust-lang/libc> |
| log | 0.4.33 | MIT | <https://github.com/rust-lang/log> |
| memchr | 2.8.3 | MIT | <https://github.com/BurntSushi/memchr> |
| proc-macro2 | 1.0.107 | MIT | <https://github.com/dtolnay/proc-macro2> |
| quote | 1.0.47 | MIT | <https://github.com/dtolnay/quote> |
| serde | 1.0.229 | MIT | <https://github.com/serde-rs/serde> |
| serde_core | 1.0.229 | MIT | <https://github.com/serde-rs/serde> |
| serde_derive | 1.0.229 | MIT | <https://github.com/serde-rs/serde> |
| serde_json | 1.0.151 | MIT | <https://github.com/serde-rs/json> |
| syn | 3.0.3 | MIT | <https://github.com/dtolnay/syn> |
| unicode-ident | 1.0.24 | MIT AND Unicode-3.0 | <https://github.com/dtolnay/unicode-ident> |
| unicode-width | 0.1.14 | MIT | <https://github.com/unicode-rs/unicode-width> |
| utf8parse | 0.2.2 | MIT | <https://github.com/alacritty/vte> |
| vt100 | 0.15.2 | MIT | <https://github.com/doy/vt100-rust> |
| vte | 0.11.1 | MIT | <https://github.com/alacritty/vte> |
| vte_generate_state_changes | 0.1.2 | MIT | <https://github.com/alacritty/vte> |
| zmij | 1.0.23 | MIT | <https://github.com/dtolnay/zmij> |

Upstream copyright notices associated with these packages and incorporated
source portions include:

Copyright (c) Ulrik Sverdrup "bluss" 2015-2023
Copyright 2012-2016 The Rust Project Developers
Copyright (c) 2015 Alice Maz
Copyright (c) 2014 Alex Crichton
Copyright (c) 2018-2024 The rust-random Project Developers
Copyright (c) 2014 The Rust Project Developers
Copyright (c) The Rust Project Developers
Copyright (c) 2014-2015 The Rust Project Developers
Copyright (c) 2015 The Rust Project Developers
Copyright (c) 2015 Andrew Gallant
copyright Alexander Huszagh.
Copyright (c) 2012-2022 The Rust Project Developers
Copyright (c) 2012-2015 The Rust Project Developers
Copyright (c) 2016 Joe Wilm
Copyright (c) 2016 Jesse Luehrs

## MIT License

The following terms apply to SwiftTerm and to every Rust crate identified as
MIT in the table above.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Unicode License v3

The following additional terms apply to `unicode-ident`.

UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2023 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
