# Package

version       = "0.8.9"
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
when not defined(windows):
  requires "libcurl >= 1.0.0"

requires "osinfo"
requires "zippy >= 0.7.2"
when defined(windows):
  requires "puppy >= 1.5.4"

task release, "Build a release binary":
  exec "nimble build -d:release -d:staticBuild"
