# Package

version       = "0.8.6"
author        = "Dominik Picheta"
description   = "The Nim toolchain installer."
license       = "BSD"

srcDir = "src"
binDir = "bin"
bin = @["choosenim"]

skipExt = @["nim"]

# Dependencies

requires "https://github.com/nim-lang/sat"
requires "nim", "nimble#ed0b6ee"
when defined(macosx):
  requires "libcurl >= 1.0.0"

requires "analytics >= 0.3.0"
requires "https://github.com/nim-lang/osinfo#437486dff62eb9d91ab1e55c780f84dd0d225e2b"
requires "zippy >= 0.7.2"
when defined(windows):
  requires "puppy >= 1.5.4"

task release, "Build a release binary":
  exec "nimble build -d:release"
