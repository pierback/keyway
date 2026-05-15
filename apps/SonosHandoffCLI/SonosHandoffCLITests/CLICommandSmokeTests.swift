import Testing
@testable import SonosHandoffCLICommands

struct CLICommandSmokeTests {
    @Test
    func parsesTransferCommand() throws {
        let command = try TransferCommand.parse(["office"])

        #expect(command.alias == "office")
    }

    @Test
    func parsesTargetAddCommandWithDeviceName() throws {
        let command = try TargetAddCommand.parse(["office", "--device", "Office Speaker"])

        #expect(command.alias == "office")
        #expect(command.device == "Office Speaker")
    }

    @Test
    func rootCommandContainsExpectedSubcommands() {
        let subcommandNames = SonosHandoffCommandLine.configuration.subcommands.map { String(describing: $0) }

        #expect(subcommandNames.contains("AuthCommand"))
        #expect(subcommandNames.contains("TargetCommand"))
        #expect(subcommandNames.contains("TransferCommand"))
        #expect(subcommandNames.contains("DoctorCommand"))
    }
}
