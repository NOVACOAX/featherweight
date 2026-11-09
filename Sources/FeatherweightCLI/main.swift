import FeatherweightCore
import Foundation

switch CLIArguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let command):
    exit(Commands(paths: CLIPaths.resolve()).run(command))
case .failure(let error):
    Output.error(error.message)
    Output.error("")
    Output.error(Commands.usage)
    exit(2)
}
