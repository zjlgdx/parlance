import ArgumentParser
import ParlanceCLI

let status = await PL.execute(arguments: Array(CommandLine.arguments.dropFirst()))
PL.exit(withError: status)
