# Copyright (C) Dominik Picheta. All rights reserved.
# BSD-3-Clause License. Look at license.txt for more info.
import osproc, streams, unittest, strutils, os, sequtils, sugar, logging

var rootDir = getCurrentDir()
var exePath = rootDir / "bin" / addFileExt("choosenim", ExeExt)
var nimbleDir = rootDir / "tests" / "nimbleDir"
var choosenimDir = rootDir / "tests" / "choosenimDir"

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

template beginTest() =
  # Clear custom dirs.
  removeDir(nimbleDir)
  createDir(nimbleDir)
  removeDir(choosenimDir)
  createDir(choosenimDir)

proc outputReader(stream: Stream, missedEscape: var bool): string =
  result = ""

  template handleEscape: untyped {.dirty.} =
    missedEscape = false
    result.add('\27')
    let escape = stream.readStr(1)
    result.add(escape)
    if escape[0] == '[':
      result.add(stream.readStr(2))

    return

  # TODO: This would be much easier to implement if `peek` was supported.
  if missedEscape:
    handleEscape()

  while true:
    let c = stream.readStr(1)

    if c.len() == 0:
      return

    case c[0]
    of '\c', '\l':
      result.add(c[0])
      return
    of '\27':
      if result.len > 0:
        missedEscape = true
        return

      handleEscape()
    else:
      result.add(c[0])

proc exec(args: varargs[string], exe=exePath,
          yes=true, liveOutput=false,
          global=false): tuple[output: string, exitCode: int] =
  var quotedArgs: seq[string] = @[exe]
  if yes:
    quotedArgs.add("-y")
  quotedArgs.add(@args)
  if not global:
    quotedArgs.add("--nimbleDir:" & nimbleDir)
    if exe.splitFile().name != "nimble":
      quotedArgs.add("--chooseNimDir:" & choosenimDir)
  quotedArgs.add("--noColor")

  for i in 0..quotedArgs.len-1:
    if " " in quotedArgs[i]:
      quotedArgs[i] = "\"" & quotedArgs[i] & "\""

  echo "exec(): ", quotedArgs.join(" ")
  if not liveOutput:
    result = execCmdEx(quotedArgs.join(" "))
  else:
    result.output = ""
    let process = startProcess(quotedArgs.join(" "),
                               options={poEvalCommand, poStdErrToStdOut})
    var missedEscape = false
    while true:
      if not process.outputStream.atEnd:
        let line = process.outputStream.outputReader(missedEscape)
        result.output.add(line)
        stdout.write(line)
        if line.len() != 0 and line[0] != '\27':
          stdout.flushFile()
      else:
        result.exitCode = process.peekExitCode()
        if result.exitCode != -1: break

    process.close()

proc processOutput(output: string): seq[string] =
  output.strip.splitLines().filter((x: string) => (x.len > 0))

proc inLines(lines: seq[string], word: string): bool =
  for i in lines:
    if word.normalize in i.normalize: return true

proc hasLine(lines: seq[string], line: string): bool =
  for i in lines:
    if i.normalize.strip() == line.normalize(): return true

test "can compile choosenim":
  var args = @["build"]
  when defined(release):
    args.add "-d:release"
  when defined(staticBuild):
    args.add "-d:staticBuild"
  let (_, exitCode) = exec(args, exe="nimble", global=true, liveOutput=true)
  check exitCode == QuitSuccess

test "refuses invalid path":
  beginTest()
  block:
    let (output, exitCode) = exec(getTempDir() / "blahblah")
    check exitCode == QuitFailure
    check inLines(output.processOutput, "invalid")
    check inLines(output.processOutput, "version")
    check inLines(output.processOutput, "path")

  block:
    let (output, exitCode) = exec(getTempDir())
    check exitCode == QuitFailure
    check inLines(output.processOutput, "no")
    check inLines(output.processOutput, "binary")
    check inLines(output.processOutput, "found")

test "fails on bad flag":
  beginTest()
  let (output, exitCode) = exec("--qwetqsdweqwe")
  check exitCode == QuitFailure
  check inLines(output.processOutput, "unknown")
  check inLines(output.processOutput, "flag")

when defined(linux) or defined(windows):
  test "can choose #v1.0.0":
    beginTest()
    block:
      let (output, exitCode) = exec("\"#v1.0.0\"", liveOutput=true)
      check exitCode == QuitSuccess
  
      check inLines(output.processOutput, "building")
      check inLines(output.processOutput, "downloading")
      check inLines(output.processOutput, "building tools")
      check hasLine(output.processOutput, "switched to nim #v1.0.0")
  
    block:
      let (output, exitCode) = exec("\"#v1.0.0\"")
      check exitCode == QuitSuccess
  
      check hasLine(output.processOutput, "info: version #v1.0.0 already selected")
  
    # block:
    #   let (output, exitCode) = exec("--version", exe=nimbleDir / "bin" / "nimble")
    #   check exitCode == QuitSuccess
    #   check inLines(output.processOutput, "v0.11.0")
  
    # Verify that we cannot remove currently selected #v1.0.0.
    block:
      let (output, exitCode) = exec(["remove", "\"#v1.0.0\""], liveOutput=true)
      check exitCode == QuitFailure
  
      check inLines(output.processOutput, "Cannot remove current version.")

test "cannot remove not installed v0.16.0":
  beginTest()
  block:
    let (output, exitCode) = exec(["remove", "0.16.0"], liveOutput=true)
    check exitCode == QuitFailure

    check inLines(output.processOutput, "Version 0.16.0 is not installed.")

when defined(linux):
  test "linux binary install":
    beginTest()
    block:
      let (output, exitCode) = exec("1.0.0", liveOutput=true)
      check exitCode == QuitSuccess

      check inLines(output.processOutput, "downloading")
      check inLines(output.processOutput, "already built")
      check hasLine(output.processOutput, "switched to nim 1.0.0")

      check not dirExists(choosenimDir / "toolchains" / "nim-1.0.0" / "c_code")

test "can update devel with git":
  beginTest()
  block:
    let (output, exitCode) = exec(@["devel", "--latest"], liveOutput=true)

    check inLines(output.processOutput, "extracting")
    check inLines(output.processOutput, "setting")
    check inLines(output.processOutput, "latest changes")
    check inLines(output.processOutput, "building")

    if exitCode != QuitSuccess:
      # Let's be lenient here, latest Nim build could fail for any number of
      # reasons (HEAD could be broken).
      warn("Could not build latest `devel` of Nim, possibly a bug in choosenim")

  block:
    let (output, exitCode) = exec(@["update", "devel", "--latest"], liveOutput=true)

    # TODO: Below lines could fail in rare circumstances: if new commit is
    # made just after the above tests starts.
    # check not inLines(output.processOutput, "extracting")
    # check not inLines(output.processOutput, "setting")
    # TODO Disabling the above until https://github.com/nim-lang/Nim/pull/18945
    # is merged.
    check inLines(output.processOutput, "updating")
    check inLines(output.processOutput, "latest changes")
    check inLines(output.processOutput, "building")

    if exitCode != QuitSuccess:
      # Let's be lenient here, latest Nim build could fail for any number of
      # reasons (HEAD could be broken).
      warn("Could not build latest `devel` of Nim, possibly a bug in choosenim")

test "can install and update nightlies":
  beginTest()
  block:
    # Install nightly
    let (output, exitCode) = exec("devel", liveOutput=true)

    # Travis runs into Github API limit
    if not inLines(output.processOutput, "unavailable"):
      check exitCode == QuitSuccess

      check inLines(output.processOutput, "devel from")
      check inLines(output.processOutput, "setting")
      when not defined(macosx):
        if not inLines(output.processOutput, "recent nightly"):
          check inLines(output.processOutput, "already built")
      check inLines(output.processOutput, "to Nim #devel")

      block:
        # Update nightly
        let (output, exitCode) = exec(@["update", "devel"], liveOutput=true)

        # Travis runs into Github API limit
        if not inLines(output.processOutput, "unavailable"):
          check exitCode == QuitSuccess

          check inLines(output.processOutput, "updating")
          check inLines(output.processOutput, "devel from")
          check inLines(output.processOutput, "setting")
          when not defined(macosx):
            if not inLines(output.processOutput, "recent nightly"):
              check inLines(output.processOutput, "already built")

test "can update self":
  # updateSelf() doesn't use options --choosenimDir and --nimbleDir. It's used getAppDir().
  # This will rewrite $project/bin dir, it's dangerous.
  # So, this test copy bin/choosenim to test/choosenimDir/choosenim, and use it.
  beginTest()
  let testExePath = choosenimDir / extractFilename(exePath)
  copyFileWithPermissions(exePath, testExePath)
  block :
    let (output, exitCode) = exec(["update", "self", "--debug", "--force"], exe=testExePath, liveOutput=true)
    check exitCode == QuitSuccess
    check inLines(output.processOutput, "Info: Updated choosenim to version")

test "fails with invalid version":
  beginTest()
  block:
    let (output, exitCode) = exec("\"#version-1.6\"")
    check exitCode == QuitFailure
    check inLines(output.processOutput, "Version")
    check inLines(output.processOutput, "does not exist")
    
test "can show general informations":
  beginTest()
  block:
    let (_, exitCode) = exec(@["stable"])
    check exitCode == QuitSuccess
  block:
    let (output, exitCode) = exec(@["show"])
    check exitCode == QuitSuccess
    check inLines(output.processOutput, "Selected:")
    check inLines(output.processOutput, "Channel: stable")
    check inLines(output.processOutput, "Path: " & choosenimDir)

test "can show path":
  beginTest()
  block:
    let (_, exitCode) = exec(@["stable"])
    check exitCode == QuitSuccess
  block:
    let (output, exitCode) = exec(@["show", "path"])
    check exitCode == QuitSuccess
    echo output.processOutput
    check inLines(output.processOutput, choosenimDir)
