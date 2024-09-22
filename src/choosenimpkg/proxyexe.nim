# This file is embedded in the `choosenim` executable and is written to
# ~/.nimble/bin/. It emulates a portable symlink with some nice additional
# features.

import strutils, os

import nimblepkg/cli
import nimblepkg/common as nimbleCommon
import cliparams, common

when defined(windows) or not defined(useExec):
  import std/osproc
  import nimblepkg/[options, version]

when defined(windows):
  import winlean
else:
  import posix

proc getSelectedPath(params: CliParams): string =
  var path = ""
  try:
    path = params.getCurrentFile()
    if not fileExists(path):
      let msg = "No installation has been chosen. (File missing: $1)" % path
      raise newException(ChooseNimError, msg)

    result = readFile(path)
  except Exception as exc:
    let msg = "Unable to read $1. (Error was: $2)" % [path, exc.msg]
    raise newException(ChooseNimError, msg)

proc getExePath(params: CliParams): tuple[name, path: string]
  {.raises: [ChooseNimError, ValueError].} =
  let exe = getAppFilename().extractFilename
  let exeName = exe.splitFile.name
  result.name = exeName

  try:
    if exeName in mingwProxies and defined(windows):
      result.path = getMingwBin(params) / exe
    else:
      result.path = getSelectedPath(params) / "bin" / exe
  except Exception as exc:
    let msg = "getAppFilename failed. (Error was: $1)" % exc.msg
    raise newException(ChooseNimError, msg)

proc main(params: CliParams) {.raises: [ChooseNimError, ValueError].} =
  let exe = getExePath(params)
  if not fileExists(exe.path):
    raise newException(ChooseNimError,
        "Requested executable is missing. (Path: $1)" % exe.path)

  # Launch the desired process.
  when defined(useExec) and defined(posix):
    let c_params = allocCStringArray(@[exe.name] & commandLineParams())
    let res = execv(exe.path.cstring, c_params)
    deallocCStringArray(c_params)
    if res == -1:
      raise newException(ChooseNimError,
          "Exec of process $1 failed." % exe.path)
  else:
    try:
      let p = startProcess(exe.path, args=commandLineParams(),
                           options={poParentStreams})
      let exitCode = p.waitForExit()
      p.close()
      quit(exitCode)
    except Exception as exc:
      raise newException(ChooseNimError,
          "Spawning of process failed. (Error was: $1)" % exc.msg)

when isMainModule:
  var error = ""
  var hint = ""
  var params = newCliParams(proxyExeMode = true)
  try:
    parseCliParams(params, proxyExeMode = true)
    main(params)
  except NimbleError as exc:
    (error, hint) = getOutputInfo(exc)

  if error.len > 0:
    displayTip()
    display("Error:", error, Error, HighPriority)
    if hint.len > 0:
      display("Hint:", hint, Warning, HighPriority)

    display("Info:", "If unexpected, please report this error to " &
            "https://github.com/nim-lang/choosenim", Warning, HighPriority)
    quit(1)
