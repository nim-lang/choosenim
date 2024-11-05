import nimblepkg/common

type
  ChooseNimError* = object of NimbleError

const
  chooseNimVersion* = "0.8.9"

  proxies* = [
      "nim",
      "nimble",
      "nimgrep",
      "nimpretty",
      "nimsuggest",
      "testament",
      "nim-gdb",
    ]

  mingwProxies* = [
    "gcc",
    "g++",
    "gdb",
    "ld"
  ]

proc getOutputInfo*(err: ref NimbleError): (string, string) =
  var error = ""
  var hint = ""
  error = err.msg
  when not defined(release):
    let stackTrace = getStackTrace(err)
    error = stackTrace & "\n\n" & error
  if not err.isNil:
    hint = err.hint

  return (error, hint)
