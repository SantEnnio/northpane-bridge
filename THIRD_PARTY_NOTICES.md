# Third-party notices

Northpane Bridge uses [SwiftProtobuf](https://github.com/apple/swift-protobuf),
Copyright Apple Inc. and the SwiftProtobuf project authors, distributed under
the Apache License 2.0. The dependency is pinned in `Package.swift` and
`Package.resolved`; its complete license is included in the resolved source
package and must be carried into the release SBOM and notices.

Northpane Bridge uses [Swift Crypto](https://github.com/apple/swift-crypto),
Copyright Apple Inc. and the SwiftCrypto project authors, distributed under
the Apache License 2.0. Swift Crypto resolves
[Swift ASN.1](https://github.com/apple/swift-asn1), also distributed under the
Apache License 2.0. Both versions and revisions are pinned in
`Package.resolved`; their complete licenses must be carried into the release
SBOM and notices.

The native iOS SSH transport in `NorthpaneConnection` uses [SwiftNIO](https://github.com/apple/swift-nio)
2.102.0 and [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) 0.15.0,
Copyright Apple Inc. and the SwiftNIO project authors, distributed under the
Apache License 2.0. Their resolved support packages are Swift Atomics 1.3.1,
Swift Collections 1.6.0, and Swift System 1.8.1, each distributed under the
Apache License 2.0.

The Private Bridge TLS endpoint uses [SwiftNIO SSL](https://github.com/apple/swift-nio-ssl)
2.37.4, distributed under the Apache License 2.0. SwiftNIO SSL includes a
vendored BoringSSL module; its BSD-style license and attribution from the
resolved source package must be reproduced in the distributed notices.

The static Linux binaries are built with the Swift Static Linux SDK and link
into one executable the Swift runtime and Foundation (Apache License 2.0 with
Runtime Library Exception), musl libc (MIT), LLVM libc++, libc++abi and libunwind
(Apache License 2.0 with LLVM Exceptions), mimalloc (MIT), libcurl (curl
license), BoringSSL (OpenSSL, ISC and Apache License 2.0 terms), libxml2 (MIT), zlib (zlib license) and
ICU data (Unicode License). Every release carries the complete license texts of
these components next to the binaries.

The complete upstream license texts from every resolved package must be
included in the release notices.


The native terminal engine uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
at the exact revision in `Package.resolved`, distributed under the MIT License
with upstream copyright attribution to Miguel de Icaza, the xterm.js authors,
SourceLair and Christopher Jeffrey. Its portable graphics dependencies use
[Swift PNG](https://github.com/tayloraswift/swift-png), including LZ77, and
[H](https://github.com/rarestype/h), distributed under the Apache License 2.0.
Their complete upstream license files are carried in the release license archive.
