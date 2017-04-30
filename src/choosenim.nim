import os

import nimblepkg/[cli, tools, version]
import nimblepkg/common as nimbleCommon

import choosenim/[download, builder, switcher, common, cliparams]
import choosenim/utils

proc parseVersion(versionStr: string): Version =
  try:
    result = newVersion(versionStr)
  except:
    let msg = "Invalid version or path. Try 0.16.0, #head or #commitHash."
    raise newException(ChooseNimError, msg)

proc choose(params: CliParams) =
  if dirExists(params.command):
    # Command is a file path likely pointing to an existing Nim installation.
    switchTo(params.command, params)
  else:
    # Command is a version.
    let version = parseVersion(params.command)

    if not params.isVersionInstalled(version):
      # Install the requested version.
      let path = download(version, params)
      # Extract the downloaded file.
      let extractDir = params.getInstallationDir(version)
      extract(path, extractDir)
      # Build the compiler
      build(extractDir, version, params)

    switchTo(version, params)

when isMainModule:
  var error = ""
  var hint = ""
  try:
    let params = getCliParams()
    choose(params)
  except NimbleError:
    let currentExc = (ref NimbleError)(getCurrentException())
    (error, hint) = getOutputInfo(currentExc)

  if error.len > 0:
    displayTip()
    display("Error:", error, Error, HighPriority)
    if hint.len > 0:
      display("Hint:", hint, Warning, HighPriority)
    quit(1)
