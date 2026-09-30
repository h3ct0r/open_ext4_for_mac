# Third-party notices

Ext4Mac is free software under the GNU General Public License, version 3 or
(at your option) any later version -- see `LICENSE`. It contains the
third-party code below, each part under its own licence, all of which permit
this combination. Binary distributions carry this file; the complete source of
every release, including this code as modified, is at
<https://github.com/h3ct0r/open_ext4_for_mac> under the release's tag.

Nothing else is redistributed: Apple's frameworks (FSKit, Security,
CommonCrypto and the rest) are part of macOS and linked from it.

---

## lwext4

The filesystem core is a fork of lwext4 (<https://github.com/gkostka/lwext4>),
imported at upstream commit `58bcf89a121b72d4fb66334f1693d3b30e4cb9c5`
(2022-09-22) and changed since. Every change, and why, is recorded in
`docs/lwext4-changes.md`; files this project changed say so at the top.
Changes made here are offered under the licence of the file they are made to:
BSD-3-Clause for the BSD files, GPL-2.0-or-later for the two GPL files.

### BSD-3-Clause -- 44 files

```
Copyright (c) 2012 Martin Sucha
Copyright (c) 2012 Frantisek Princ
Copyright (c) 2013 Grzegorz Kostka (kostka.grzegorz@gmail.com)
Copyright (c) 2014 Grzegorz Kostka (kostka.grzegorz@gmail.com)
Copyright (c) 2015 Grzegorz Kostka (kostka.grzegorz@gmail.com)
Copyright (c) 2015 Kaho Ng (ngkaho1234@gmail.com)
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.
- The name of the author may not be used to endorse or promote products
  derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### `src/ext4_hash.c` -- BSD, from FreeBSD

```
Copyright (c) 2013 Grzegorz Kostka (kostka.grzegorz@gmail.com)
Copyright (c) 2010, 2013 Zheng Liu <lz@freebsd.org>
Copyright (c) 2012, Vyacheslav Matyushin
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
```

The half-MD4 directory hash in that file (`ext2_half_md4()`) is derived from
the RSA Data Security, Inc. MD4 Message-Digest Algorithm:

```
Copyright (C) 1990-2, RSA Data Security, Inc. All rights reserved.

License to copy and use this software is granted provided that it
is identified as the "RSA Data Security, Inc. MD4 Message-Digest
Algorithm" in all material mentioning or referencing this software
or this function.

License is also granted to make and use derivative works provided
that such works are identified as "derived from the RSA Data
Security, Inc. MD4 Message-Digest Algorithm" in all material
mentioning or referencing the derived work.

RSA Data Security, Inc. makes no representations concerning either
the merchantability of this software or the suitability of this
software for any particular purpose. It is provided "as is"
without express or implied warranty of any kind.

These notices must be retained in any copies of any part of this
documentation and/or software.
```

### `include/misc/queue.h` -- BSD, University of California

```
Copyright (c) 1991, 1993
The Regents of the University of California. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
4. Neither the name of the University nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
```

### `include/misc/tree.h` -- BSD, Niels Provos

```
Copyright 2002 Niels Provos <provos@citi.umich.edu>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### GPL-2.0-or-later -- `src/ext4_extent.c`, `src/ext4_xattr.c`

```
Copyright (c) 2017 Grzegorz Kostka (kostka.grzegorz@gmail.com)
Copyright (c) 2017 Kaho Ng (ngkaho1234@gmail.com)

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.
```

Distributed here under GPL-3.0-or-later, which their "or any later
version" permits; the full text is in `LICENSE`.

---

## Argon2 and BLAKE2b

The LUKS2 key derivation uses the Argon2 reference implementation, release
20190702, including its BLAKE2b (`Core/crypto/argon2/`), unmodified:

```
Argon2 reference source code package - reference C implementations

Copyright 2015
Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, and Samuel Neves

You may use this work under the terms of a Creative Commons CC0 1.0
License/Waiver or the Apache Public License 2.0, at your option. The terms of
these licenses can be found at:

- CC0 1.0 Universal : http://creativecommons.org/publicdomain/zero/1.0
- Apache 2.0        : http://www.apache.org/licenses/LICENSE-2.0
```

The encoding helpers in `encoding.c` were written by Thomas Pornin and
dedicated to the public domain:

```
This file is provided under the terms of Creative Commons CC0 1.0
Public Domain Dedication. To the extent possible under law, the
author (Thomas Pornin) has waived all copyright and related or
neighboring rights to this file. This work is published from: Canada.

Copyright (c) 2015 Thomas Pornin
```

This project uses all of it under CC0 1.0, which asks for nothing in return;
the credit is given anyway.
